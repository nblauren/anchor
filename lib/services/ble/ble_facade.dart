import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/utils/logger.dart';
import 'ble_config.dart';
import 'ble_models.dart';
import 'ble_service_interface.dart';
import 'connection/connection_manager.dart';
import 'discovery/ble_scanner.dart';
import 'discovery/profile_reader.dart';
import 'gatt/gatt_server.dart';
import 'gatt/gatt_write_queue.dart';
import 'mesh/mesh_relay_service.dart';
import 'transfer/photo_transfer_handler.dart';

/// Production [BleServiceInterface] — thin orchestrator that wires together
/// the extracted BLE subsystems:
///
/// - [GattServer] — GATT service setup, read/notify handling, advertising
/// - [ConnectionManager] — connection pooling, LRU eviction, connect serialization
/// - [GattWriteQueue] — prioritized write queue with backpressure
/// - [BleScanner] — scan lifecycle, timing, dedup, density modes
/// - [ProfileReader] — GATT profile reads, thumbnail/photo assembly
/// - [MeshRelayService] — message forwarding, peer announce, routing table
/// - [PhotoTransferHandler] — binary photo chunking, preview consent, requests
///
/// This facade owns:
/// - Lifecycle orchestration (initialize → start → stop → dispose)
/// - Peer tracking (visible peers, timeout timers, userId ↔ peerId mapping)
/// - Incoming message dispatch (binary/JSON routing to the correct subsystem)
/// - Stream controllers for the public [BleServiceInterface] API
/// - Platform permissions (Android/iOS Bluetooth + location)
class BleFacade implements BleServiceInterface {
  BleFacade({
    required this.config,
  });

  final BleConfig config;

  // Managers
  late final CentralManager _central;
  late final ConnectionManager _connectionManager;
  late final GattWriteQueue _writeQueue;
  late final BleScanner _scanner;
  late final ProfileReader _profileReader;
  late final MeshRelayService _meshRelay;
  late final PhotoTransferHandler _photoTransfer;
  late final GattServer _gattServer;

  // UUIDs (used by central-side notification routing)
  static final _thumbnailCharUuid =
      UUID.fromString('0000fff2-0000-1000-8000-00805f9b34fb');
  static final _fullPhotosCharUuid =
      UUID.fromString('0000fff4-0000-1000-8000-00805f9b34fb');

  // Status
  BleStatus _status = BleStatus.disabled;
  bool _isInitialized = false;

  // Stream controllers
  final _statusController = StreamController<BleStatus>.broadcast();
  final _peerDiscoveredController =
      StreamController<DiscoveredPeer>.broadcast();
  final _peerLostController = StreamController<String>.broadcast();
  final _peerIdChangedController = StreamController<PeerIdChanged>.broadcast();
  final _messageReceivedController =
      StreamController<ReceivedMessage>.broadcast();
  final _photoProgressController =
      StreamController<PhotoTransferProgress>.broadcast();
  final _photoReceivedController = StreamController<ReceivedPhoto>.broadcast();
  final _anchorDropReceivedController =
      StreamController<AnchorDropReceived>.broadcast();
  final _reactionReceivedController =
      StreamController<ReactionReceived>.broadcast();
  final _photoPreviewReceivedController =
      StreamController<ReceivedPhotoPreview>.broadcast();
  final _photoRequestReceivedController =
      StreamController<ReceivedPhotoRequest>.broadcast();

  // Peer tracking
  final Map<String, DiscoveredPeer> _visiblePeers = {};
  final Map<String, Timer> _peerTimeoutTimers = {};

  // Map from app userId → BLE peerId (peripheral UUID) so incoming messages
  // (which carry the sender's app userId) can be routed to the correct peer.
  final Map<String, String> _userIdToPeerId = {};

  // Map from Central UUID → app userId.  Populated when we receive a write
  // from a Central whose userId isn't in _userIdToPeerId yet (i.e. we haven't
  // scanned their Peripheral advertisement).  Once we discover them via scan
  // and learn their peripheral UUID, we emit PeerIdChanged so conversations
  // migrate from the Central UUID to the correct Peripheral UUID.
  final Map<String, String> _centralUuidToUserId = {};

  // Note: scan lifecycle, timing, dedup are now managed by BleScanner.
  // Profile reading, thumbnail/photo assembly are now managed by ProfileReader.
  // GATT server setup, reads, notifications, advertising are now managed by GattServer.

  // Subscriptions
  StreamSubscription? _centralStateSubscription;
  StreamSubscription? _charNotifiedSubscription;

  // In-memory message ID deduplication — prevents the same BLE write
  // from being processed twice if the transport retransmits it.
  final Set<String> _seenMessageIds = {};

  // Timer that periodically broadcasts this device's neighbor list.
  Timer? _neighborListTimer;

  // Note: Sequential write serialization is now handled by GattWriteQueue.
  // All GATT writes go through _writeQueue with priority levels.
  // GATT server state, cached data, and advertising are now managed by GattServer.


  // ==================== Lifecycle ====================

  @override
  Future<void> initialize() async {
    if (_isInitialized) return;

    Logger.info('BleService: Initializing...', 'BLE');

    try {
      _central = CentralManager();
      final peripheral = PeripheralManager();

      // GattServer: GATT service setup, read/notify handling, advertising
      _gattServer = GattServer(peripheral: peripheral);
      _gattServer.onWriteReceived = _onMessageWriteReceived;
      _gattServer.startListening();

      _connectionManager = ConnectionManager(
        central: _central,
        config: config,
      );
      _connectionManager.startListening();
      _writeQueue = GattWriteQueue(central: _central);

      // Scanner: handles scan lifecycle, timing, dedup
      _scanner = BleScanner(
        central: _central,
        connectionManager: _connectionManager,
        config: config,
      );
      _scanner.onPeerDiscovered = _onScannerPeerDiscovered;
      _scanner.onPeerNeedsProfile = _onScannerPeerNeedsProfile;

      // ProfileReader: handles GATT profile reads, thumbnail/photo assembly
      final prefs = await SharedPreferences.getInstance();
      _profileReader = ProfileReader(
        central: _central,
        connectionManager: _connectionManager,
        prefs: prefs,
      );
      _profileReader.loadPersistedSizes();
      _profileReader.onProfileRead = _onProfileReadResult;
      _profileReader.onThumbnailAssembled = _onThumbnailAssembled;
      _profileReader.onPhotosAssembled = _onPhotosAssembled;
      _profileReader.onFullPhotosAssembled = _onFullPhotosAssembled;

      // MeshRelayService: mesh relay, peer announce, routing
      _meshRelay = MeshRelayService(
        connectionManager: _connectionManager,
        writeQueue: _writeQueue,
        config: config,
      );
      _meshRelay.getOwnUserId = () => _gattServer.ownUserId;
      _meshRelay.getAppUserIdForPeer = _getAppUserIdForPeer;
      _meshRelay.getVisiblePeerCount = () => _visiblePeers.length;
      _meshRelay.onRelayedPeerDiscovered = _onRelayedPeerDiscovered;
      _meshRelay.isDirectPeer = (peerId) {
        final peer = _visiblePeers[peerId];
        return peer != null && !peer.isRelayed;
      };

      // PhotoTransferHandler: photo send/receive, preview, requests
      _photoTransfer = PhotoTransferHandler(
        connectionManager: _connectionManager,
        writeQueue: _writeQueue,
        config: config,
      );
      _photoTransfer.getOwnUserId = () => _gattServer.ownUserId;
      _photoTransfer.onProgress = _photoProgressController.add;
      _photoTransfer.onPhotoReceived = _photoReceivedController.add;
      _photoTransfer.onPhotoPreviewReceived =
          _photoPreviewReceivedController.add;
      _photoTransfer.onPhotoRequestReceived =
          _photoRequestReceivedController.add;

      // Forward ConnectionManager disconnect events to peer lost handling
      _connectionManager.onDisconnected.listen(_onConnectionManagerDisconnect);
      _connectionManager.onPeerUnreachable.listen(_onPeerLost);

      // Listen to central manager state
      _centralStateSubscription =
          _central.stateChanged.listen((e) => _onStateChanged(e.state));

      // Central-side notification routing (thumbnail/photo assembly via ProfileReader)
      _charNotifiedSubscription =
          _central.characteristicNotified.listen(_onCharacteristicNotified);

      // Note: peripheral state is now managed by GattServer.startListening().

      _isInitialized = true;

      // Check initial central state
      _onStateChanged(_central.state);

      Logger.info('BleService: Initialized successfully', 'BLE');
    } catch (e) {
      Logger.error('BleService: Initialization failed', e, null, 'BLE');
      _setStatus(BleStatus.error);
      rethrow;
    }
  }

  @override
  Future<void> start() async {
    _ensureInitialized();
    Logger.info('BleService: Starting...', 'BLE');

    try {
      _gattServer.markStartCalled();
      await _gattServer.setup(force: true);
      await startScanning();
      _setStatus(BleStatus.ready);
    } catch (e) {
      Logger.error('BleService: Start failed', e, null, 'BLE');
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    Logger.info('BleService: Stopping...', 'BLE');

    await stopScanning();
    await _gattServer.teardown();

    _writeQueue.clear();
    _connectionManager.clear();
    _profileReader.clear();
    _scanner.clear();
    _meshRelay.clear();
    _userIdToPeerId.clear();
    _centralUuidToUserId.clear();
    _neighborListTimer?.cancel();
    _neighborListTimer = null;
    _setStatus(BleStatus.ready);
  }

  @override
  Future<void> dispose() async {
    Logger.info('BleService: Disposing...', 'BLE');

    await stop();

    for (final timer in _peerTimeoutTimers.values) {
      timer.cancel();
    }

    _writeQueue.dispose();
    await _scanner.dispose();
    await _connectionManager.dispose();
    await _gattServer.dispose();

    await _centralStateSubscription?.cancel();
    await _charNotifiedSubscription?.cancel();

    await _statusController.close();
    await _peerDiscoveredController.close();
    await _peerLostController.close();
    await _peerIdChangedController.close();
    await _messageReceivedController.close();
    await _photoProgressController.close();
    await _photoReceivedController.close();
    await _anchorDropReceivedController.close();
    await _reactionReceivedController.close();

    _photoTransfer.clear();
    _isInitialized = false;
  }

  void _ensureInitialized() {
    if (!_isInitialized) {
      throw StateError('BleService not initialized. Call initialize() first.');
    }
  }

  void _onStateChanged(BluetoothLowEnergyState state) {
    Logger.info('BleService: Central state changed: $state', 'BLE');

    switch (state) {
      case BluetoothLowEnergyState.poweredOn:
        if (_status == BleStatus.disabled) {
          _setStatus(BleStatus.ready);
        }
        // Retry pending advertising (central ready — peripheral may already be ready too)
        _gattServer.retryAdvertisingIfNeeded();
        break;
      case BluetoothLowEnergyState.poweredOff:
        _setStatus(BleStatus.disabled);
        break;
      case BluetoothLowEnergyState.unauthorized:
        _setStatus(BleStatus.noPermission);
        break;
      case BluetoothLowEnergyState.unsupported:
        _setStatus(BleStatus.disabled);
        break;
      default:
        break;
    }
  }

  // Note: Peripheral state management, GATT server setup, read request handling,
  // notify pushes, and advertising lifecycle are now managed by GattServer.

  /// Called by GattServer when a write arrives on the messaging characteristic (fff3).
  /// Handles binary dispatch, JSON parsing, sender resolution, and type-based routing.
  void _onMessageWriteReceived(Uint8List data, UUID centralUuid) {
    try {
      // Binary photo chunk: first byte is 0x02
      if (data[0] == 0x02) {
        _photoTransfer.handleBinaryPhotoChunk(data, centralUuid.toString());
        return;
      }

      // Binary thumbnail chunk (preview consent flow): first byte is 0x03
      if (data[0] == 0x03) {
        _photoTransfer.handleBinaryThumbnailChunk(
            data, centralUuid.toString());
        return;
      }

      // JSON payload (text messages, photo_start, legacy photo_chunk)
      final jsonStr = utf8.decode(data);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;

      final fromPeerId = _resolveSenderPeerId(json, centralUuid);
      final type = json['type'] as String? ?? 'message';

      // Peer is alive — refresh their timeout timer.
      _refreshPeerTimeout(fromPeerId);

      // If we received a message from a Central that we haven't discovered
      // as a Peripheral yet, trigger an immediate scan so we can establish
      // the reverse connection and send messages back.
      if (!_connectionManager.canSendTo(fromPeerId) &&
          _connectionManager.getPeripheral(fromPeerId) == null) {
        _scanner.triggerImmediateScan();
      }

      if (type == 'photo_start') {
        _photoTransfer.handlePhotoStart(json, fromPeerId);
      } else if (type == 'photo_chunk') {
        _photoTransfer.handleReceivedPhotoChunk(json, fromPeerId);
      } else if (type == 'photo_preview') {
        _photoTransfer.handlePhotoPreviewStart(json, fromPeerId);
      } else if (type == 'photo_request') {
        _photoTransfer.handlePhotoRequest(json, fromPeerId);
      } else if (type == 'peer_announce') {
        _meshRelay.handlePeerAnnounce(json, fromPeerId);
      } else if (type == 'neighbor_list') {
        _meshRelay.handleNeighborList(json);
      } else if (type == 'drop_anchor') {
        _handleDropAnchor(fromPeerId);
      } else if (type == 'reaction') {
        _handleReaction(json, fromPeerId);
      } else {
        _handleReceivedMessage(json, fromPeerId);
      }
    } catch (e) {
      Logger.error('BleService: Write receive failed', e, null, 'BLE');
    }
  }

  /// Resolve the sender's peerId from the payload's sender_id field,
  /// mapping their app userId back to the BLE peripheral UUID we use
  /// in our database.
  ///
  /// On iOS the Central UUID ≠ the Peripheral UUID for the same device.
  /// If we haven't scanned the sender's Peripheral yet, we fall back to the
  /// Central UUID and record a pending `_centralUuidToUserId` entry so that
  /// when the scan completes and we learn the correct Peripheral UUID, we can
  /// emit [PeerIdChanged] and migrate the conversation.
  String _resolveSenderPeerId(Map<String, dynamic> json, UUID centralUuid) {
    final senderId = json['sender_id'] as String?;
    if (senderId != null &&
        senderId.isNotEmpty &&
        _userIdToPeerId.containsKey(senderId)) {
      return _userIdToPeerId[senderId]!;
    }

    // We don't know this userId → peripheral mapping yet.  Record the
    // central UUID → userId so _updatePeerFromProfile can migrate later.
    final centralId = centralUuid.toString();
    if (senderId != null && senderId.isNotEmpty) {
      _centralUuidToUserId[centralId] = senderId;
    }
    return centralId;
  }

  void _handleReceivedMessage(Map<String, dynamic> json, String fromPeerId) {
    final messageId = json['message_id'] as String? ?? '';

    // Deduplicate — BLE transport can retransmit the same write
    if (messageId.isNotEmpty) {
      if (_seenMessageIds.contains(messageId)) {
        Logger.info('BleService: Duplicate message ignored: $messageId', 'BLE');
        return;
      }
      _seenMessageIds.add(messageId);
      // Evict after 5 minutes to avoid unbounded growth
      Future.delayed(
          const Duration(minutes: 5), () => _seenMessageIds.remove(messageId));
    }

    // Mesh routing: check if this message is addressed to us
    final destinationId = json['destination_id'] as String?;
    final ownUserId = _gattServer.ownUserId;
    final isForUs = destinationId == null ||
        destinationId.isEmpty ||
        destinationId == ownUserId;

    if (isForUs) {
      final message = ReceivedMessage(
        fromPeerId: fromPeerId,
        messageId: messageId,
        type: MessageType.values[json['message_type'] as int? ?? 0],
        content: json['content'] as String? ?? '',
        timestamp: DateTime.now(),
        replyToId: json['reply_to_id'] as String?,
      );
      _messageReceivedController.add(message);
      Logger.info(
        'BleService: Received message from '
            '${fromPeerId.substring(0, min(8, fromPeerId.length))}',
        'BLE',
      );
    } else {
      // Not for us — attempt to relay toward the destination
      _meshRelay.maybeRelayMessage(json, fromPeerId);
    }
  }

  /// Returns the app userId for a given BLE peripheral UUID, or null if
  /// the mapping hasn't been established yet (peer profile not yet read).
  String? _getAppUserIdForPeer(String blePeerId) {
    for (final entry in _userIdToPeerId.entries) {
      if (entry.value == blePeerId) return entry.key;
    }
    return null;
  }

  // ==================== Mesh Relay (delegated to MeshRelayService) ====================

  @override
  Future<void> setMeshRelayMode(bool enabled) async {
    _meshRelay.enabled = enabled;
  }

  @override
  bool get isMeshRelayEnabled => _meshRelay.enabled;

  @override
  int get meshRelayedPeerCount =>
      _visiblePeers.values.where((p) => p.isRelayed).length;

  @override
  int get meshRoutingTableSize => _meshRelay.routingTableSize;

  /// Called by MeshRelayService when a relayed peer is discovered via mesh.
  void _onRelayedPeerDiscovered(RelayedPeerResult result) {
    final peer = result.peer;
    _visiblePeers[peer.peerId] = peer;
    _peerTimeoutTimers[peer.peerId]?.cancel();
    _peerTimeoutTimers[peer.peerId] = Timer(
      config.peerLostTimeout,
      () => _onPeerLost(peer.peerId),
    );

    if (result.userId != null && result.userId!.isNotEmpty) {
      _userIdToPeerId[result.userId!] = peer.peerId;
    }

    _peerDiscoveredController.add(peer);
  }


  // ==================== Status ====================

  @override
  BleStatus get status => _status;

  @override
  Stream<BleStatus> get statusStream => _statusController.stream;

  @override
  Future<bool> isBluetoothAvailable() async {
    return true; // If we got this far, BLE is available
  }

  @override
  Future<bool> isBluetoothEnabled() async {
    if (!_isInitialized) return false;
    final state = _central.state;
    return state == BluetoothLowEnergyState.poweredOn ||
        state == BluetoothLowEnergyState.unknown;
  }

  @override
  Future<bool> requestPermissions() async {
    try {
      if (Platform.isAndroid) {
        final permissions = <Permission>[];

        if (await Permission.bluetoothScan.isDenied) {
          permissions.add(Permission.bluetoothScan);
        }
        if (await Permission.bluetoothConnect.isDenied) {
          permissions.add(Permission.bluetoothConnect);
        }
        if (await Permission.bluetoothAdvertise.isDenied) {
          permissions.add(Permission.bluetoothAdvertise);
        }
        if (await Permission.locationWhenInUse.isDenied) {
          permissions.add(Permission.locationWhenInUse);
        }

        if (permissions.isEmpty) return true;
        final statuses = await permissions.request();
        return statuses.values.every((s) => s.isGranted);
      }

      // iOS: permissions are requested implicitly by the BLE managers
      return true;
    } catch (e) {
      Logger.error('BleService: Permission request failed', e, null, 'BLE');
      return false;
    }
  }

  @override
  Future<bool> hasPermissions() async {
    if (Platform.isAndroid) {
      return await Permission.bluetoothScan.isGranted &&
          await Permission.bluetoothConnect.isGranted &&
          await Permission.locationWhenInUse.isGranted;
    } else if (Platform.isIOS) {
      if (!_isInitialized) return false;
      final state = _central.state;
      return state != BluetoothLowEnergyState.unauthorized &&
          state != BluetoothLowEnergyState.unknown;
    }
    return false;
  }

  void _setStatus(BleStatus newStatus) {
    if (_status != newStatus) {
      _status = newStatus;
      _statusController.add(newStatus);
    }
  }

  // ==================== Broadcasting (delegated to GattServer) ====================

  @override
  Future<void> broadcastProfile(BroadcastPayload payload) async {
    _ensureInitialized();
    await _gattServer.broadcastProfile(payload);
  }

  @override
  Future<void> stopBroadcasting() async {
    await _gattServer.stopAdvertising();
  }

  @override
  bool get isBroadcasting => _gattServer.isBroadcasting;

  // ==================== Discovery ====================

  @override
  Stream<DiscoveredPeer> get peerDiscoveredStream =>
      _peerDiscoveredController.stream;

  @override
  Stream<String> get peerLostStream => _peerLostController.stream;

  @override
  Stream<PeerIdChanged> get peerIdChangedStream =>
      _peerIdChangedController.stream;

  @override
  Future<void> startScanning() async {
    _ensureInitialized();

    _setStatus(BleStatus.scanning);

    // Periodic neighbor-list broadcast for routing table maintenance
    _neighborListTimer?.cancel();
    _neighborListTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _broadcastNeighborList(),
    );

    await _scanner.start();
  }

  @override
  Future<void> stopScanning() async {
    _neighborListTimer?.cancel();
    _neighborListTimer = null;

    await _scanner.stop();
  }

  @override
  bool get isScanning => _scanner.isScanning;

  // ==================== Scanner/ProfileReader Callbacks ====================

  /// Called by BleScanner when a peer is discovered via advertisement.
  void _onScannerPeerDiscovered(String peerId, String name, int? age, int rssi,
      Peripheral peripheral) {
    // Preserve age, bio and thumbnail already fetched via GATT in a prior scan
    // cycle. Advertisement packets can be truncated (31-byte limit).
    final existing = _visiblePeers[peerId];

    // If the scanner decoded a fallback name ("Anchor User") but we already
    // have a real name from a prior GATT profile read, keep the real name.
    // This prevents the name from flickering back to "Anchor User" on every
    // scan cycle when the advertisement local name is truncated or absent.
    final effectiveName = (name == 'Anchor User' &&
            existing != null &&
            existing.name != 'Anchor User')
        ? existing.name
        : name;

    final peer = DiscoveredPeer(
      peerId: peerId,
      name: effectiveName,
      age: age ?? existing?.age,
      bio: existing?.bio,
      thumbnailBytes: existing?.thumbnailBytes,
      rssi: rssi,
      timestamp: DateTime.now(),
    );
    _emitPeer(peer);
  }

  /// Called by BleScanner when a discovered peer needs its profile read.
  void _onScannerPeerNeedsProfile(String peerId, Peripheral peripheral) {
    _refreshPeerTimeout(peerId);
    _profileReader.readProfile(peerId, peripheral);
  }

  /// Called by ProfileReader when a profile is read from a peer.
  void _onProfileReadResult(ProfileReadResult result) {
    final peerId = result.peerId;
    final json = result.profileJson;
    final existingPeer = _visiblePeers[peerId];
    if (existingPeer == null) return;

    _refreshPeerTimeout(peerId);

    final userId = json['userId'] as String?;

    // Record userId → BLE peerId mapping so incoming messages (which carry
    // the sender's app userId) can be routed to the correct peer.
    if (userId != null && userId.isNotEmpty) {
      final previousPeerId = _userIdToPeerId[userId];
      if (previousPeerId != null && previousPeerId != peerId) {
        Logger.info(
          'BleService: userId $userId rotated MAC '
              '$previousPeerId → $peerId, retiring stale entry',
          'BLE',
        );
        _peerIdChangedController.add(PeerIdChanged(
          oldPeerId: previousPeerId,
          newPeerId: peerId,
          userId: userId,
        ));
        _onPeerLost(previousPeerId);
      }
      _userIdToPeerId[userId] = peerId;

      // Check if a Central UUID was temporarily used as the peerId
      final centralId = _centralUuidToUserId.entries
          .where((e) => e.value == userId)
          .map((e) => e.key)
          .firstOrNull;
      if (centralId != null && centralId != peerId) {
        Logger.info(
          'BleService: Migrating Central UUID $centralId → Peripheral $peerId '
              'for userId $userId',
          'BLE',
        );
        _centralUuidToUserId.remove(centralId);
        _peerIdChangedController.add(PeerIdChanged(
          oldPeerId: centralId,
          newPeerId: peerId,
          userId: userId,
        ));
      }
    }

    // Update the existing peer entry with profile data
    final photoCount = json['photo_count'] as int?;
    final position = json['pos'] as int?;
    final interests = json['int'] as String?;
    final newName = json['name'] as String? ?? existingPeer.name;
    final newAge = json['age'] as int? ?? existingPeer.age;
    final newBio = json['bio'] as String?;
    final newPosition = position ?? existingPeer.position;
    final newInterests = interests ?? existingPeer.interests;
    final newPhotoCount = photoCount ?? existingPeer.fullPhotoCount;

    // Skip emit if nothing changed — profile is re-read every 30s but rarely changes.
    final unchanged = newName == existingPeer.name &&
        newAge == existingPeer.age &&
        newBio == existingPeer.bio &&
        newPosition == existingPeer.position &&
        newInterests == existingPeer.interests &&
        newPhotoCount == existingPeer.fullPhotoCount;

    if (unchanged) {
      Logger.debug(
        'BleService: Profile unchanged for "${existingPeer.name}", skipping emit',
        'BLE',
      );
      return;
    }

    final updatedPeer = DiscoveredPeer(
      peerId: peerId,
      name: newName,
      age: newAge,
      bio: newBio,
      position: newPosition,
      interests: newInterests,
      thumbnailBytes: existingPeer.thumbnailBytes,
      photoThumbnails: existingPeer.photoThumbnails,
      rssi: existingPeer.rssi,
      timestamp: DateTime.now(),
      isRelayed: existingPeer.isRelayed,
      hopCount: existingPeer.hopCount,
      fullPhotoCount: newPhotoCount,
    );

    _emitPeer(updatedPeer);
    Logger.info(
      'BleService: Updated profile for "${updatedPeer.name}"',
      'BLE',
    );
  }

  /// Called by ProfileReader when a single primary thumbnail is assembled.
  void _onThumbnailAssembled(String peerId, Uint8List thumbnailBytes) {
    final existingPeer = _visiblePeers[peerId];
    if (existingPeer == null) return;

    final updatedPeer = existingPeer.copyWith(
      thumbnailBytes: thumbnailBytes,
      timestamp: DateTime.now(),
    );
    _emitPeer(updatedPeer);
    _meshRelay.announcePeerToMesh(updatedPeer);
    Logger.info(
      'BleService: Updated thumbnail for "${updatedPeer.name}" '
          '(${thumbnailBytes.length}B)',
      'BLE',
    );
  }

  /// Called by ProfileReader when multiple photos are assembled (legacy fff2).
  void _onPhotosAssembled(String peerId, List<Uint8List> photos) {
    final existingPeer = _visiblePeers[peerId];
    if (existingPeer == null) return;

    final updatedPeer = existingPeer.copyWith(
      thumbnailBytes: photos.first,
      photoThumbnails: photos,
      timestamp: DateTime.now(),
    );
    _emitPeer(updatedPeer);
    _meshRelay.announcePeerToMesh(updatedPeer);
    Logger.info(
      'BleService: Updated ${photos.length} photo(s) for "${updatedPeer.name}" '
          '(total: ${photos.fold(0, (s, b) => s + b.length)}B)',
      'BLE',
    );
  }

  /// Called by ProfileReader when full-photo set is assembled from fff4.
  void _onFullPhotosAssembled(String peerId, List<Uint8List> photos) {
    final existingPeer = _visiblePeers[peerId];
    if (existingPeer == null) return;

    final updatedPeer = existingPeer.copyWith(
      thumbnailBytes: photos.first,
      photoThumbnails: photos,
      timestamp: DateTime.now(),
    );
    _emitPeer(updatedPeer);
    Logger.info(
      'BleService: Full-photos received for "${updatedPeer.name}": '
          '${photos.length} photo(s), ${photos.fold(0, (s, b) => s + b.length)}B total',
      'BLE',
    );
  }

  // Note: Thumbnail and full-photos notify push handlers are now in GattServer.

  /// Called when ConnectionManager reports a peer has disconnected.
  /// Triggers peer lost handling if the peer was visible in discovery.
  void _onConnectionManagerDisconnect(String peerId) {
    if (_visiblePeers.containsKey(peerId)) {
      Logger.info(
        'BleService: Peripheral $peerId disconnected — removing peer',
        'BLE',
      );
      _onPeerLost(peerId);
    }
  }

  /// Called on the CENTRAL side when a notification arrives on any characteristic.
  /// Routes to ProfileReader for thumbnail/photo assembly.
  void _onCharacteristicNotified(GATTCharacteristicNotifiedEventArgs args) {
    final peerId = args.peripheral.uuid.toString();
    if (args.characteristic.uuid == _thumbnailCharUuid) {
      _profileReader.handleThumbnailChunk(peerId, args.value);
    } else if (args.characteristic.uuid == _fullPhotosCharUuid) {
      _profileReader.handleFullPhotosChunk(peerId, args.value);
    }
  }

  @override
  Future<bool> fetchFullProfilePhotos(String peerId) async {
    return _profileReader.fetchFullProfilePhotos(peerId);
  }

  void _emitPeer(DiscoveredPeer peer) {
    final isNew = !_visiblePeers.containsKey(peer.peerId);
    _visiblePeers[peer.peerId] = peer;
    _peerDiscoveredController.add(peer);
    _scanner.updateDensity(_visiblePeers.length);

    // Only start the timeout timer on first discovery.  Subsequent scan
    // results may come from the iOS Core Bluetooth cache even after the
    // peer's app has closed, so we must NOT reset the timer every time.
    // The timer is refreshed to the full duration after a successful GATT
    // interaction in _refreshPeerTimeout().
    if (isNew || !_peerTimeoutTimers.containsKey(peer.peerId)) {
      _peerTimeoutTimers[peer.peerId]?.cancel();
      _peerTimeoutTimers[peer.peerId] = Timer(
        config.peerLostTimeout,
        () => _onPeerLost(peer.peerId),
      );
    }
  }

  /// Reset the peer timeout to the full [peerLostTimeout] duration.
  /// Called after a confirmed GATT interaction (profile read, message sent)
  /// which proves the peer is actually alive, not a cached scan result.
  void _refreshPeerTimeout(String peerId) {
    if (!_visiblePeers.containsKey(peerId)) return;
    _peerTimeoutTimers[peerId]?.cancel();
    _peerTimeoutTimers[peerId] = Timer(
      config.peerLostTimeout,
      () => _onPeerLost(peerId),
    );
  }

  void _onPeerLost(String peerId) {
    if (_visiblePeers.containsKey(peerId)) {
      final peer = _visiblePeers.remove(peerId);
      _peerTimeoutTimers.remove(peerId)?.cancel();
      _peerLostController.add(peerId);

      // Cancel any queued writes for this peer
      _writeQueue.cancelPeer(peerId);
      // ConnectionManager handles all connection state cleanup in one call
      _connectionManager.disconnect(peerId, markDead: true);

      // Clean up per-peer state in extracted components
      _profileReader.clearPeer(peerId);
      _scanner.clearPeer(peerId);
      _meshRelay.clearPeer(peerId);

      // Keep _userIdToPeerId mapping — the userId→peripheralUUID relationship
      // is still valid even if the peer is temporarily out of range.

      Logger.info('BleService: Lost peer ${peer?.name}', 'BLE');
      _scanner.updateDensity(_visiblePeers.length);
    }
  }

  /// Broadcast our directly-visible peer userId list via mesh relay service.
  void _broadcastNeighborList() {
    final directPeerUserIds = _visiblePeers.entries
        .where((e) => !e.value.isRelayed)
        .map((e) => _getAppUserIdForPeer(e.key))
        .whereType<String>()
        .where((uid) => uid.isNotEmpty)
        .toList();

    _meshRelay.broadcastNeighborList(directPeerUserIds);
  }

  // ==================== Messaging ====================

  @override
  Future<bool> sendMessage(String peerId, MessagePayload payload) async {
    _ensureInitialized();

    Logger.info(
      'BleService: Sending ${payload.type.name} to ${peerId.substring(0, min(8, peerId.length))}',
      'BLE',
    );

    try {
      // Get or establish connection via ConnectionManager
      var conn = _connectionManager.getConnection(peerId);

      // Try to connect if not already connected
      if (conn == null || !conn.canSendMessages) {
        final peripheral = _connectionManager.getPeripheral(peerId);
        if (peripheral != null) {
          conn = await _connectionManager.connect(peerId, peripheral);
        }
      }

      final destinationUserId = _getAppUserIdForPeer(peerId);

      if (conn == null || !conn.canSendMessages) {
        // Direct connection unavailable — try mesh relay as fallback.
        // The peer may be reachable through an intermediate node (e.g.
        // A→B→C when C moved out of A's direct range).
        if (_meshRelay.enabled && _connectionManager.activeConnectionCount > 0) {
          final data = _serializeMessagePayload(
            payload,
            destinationUserId: destinationUserId,
          );
          final relayed = _meshRelay.originateMessage(
            data,
            destinationUserId ?? '',
          );
          if (relayed) {
            Logger.info(
              'BleService: Message relayed via mesh for $peerId',
              'BLE',
            );
            return true;
          }
        }

        Logger.info(
            'BleService: Peer not reachable: $peerId — triggering scan', 'BLE');
        _scanner.triggerImmediateScan();
        return false;
      }

      final data = _serializeMessagePayload(
        payload,
        destinationUserId: destinationUserId,
      );
      final success = await _writeQueue.enqueue(
        peerId: peerId,
        peripheral: conn.peripheral,
        characteristic: conn.messagingChar!,
        data: data,
        priority: WritePriority.userMessage,
      );

      if (success) {
        Logger.info('BleService: Message sent successfully', 'BLE');
        _connectionManager.touchPeer(peerId);
        _refreshPeerTimeout(peerId);
      } else {
        Logger.warning('BleService: Message write failed via queue', 'BLE');
      }
      return success;
    } catch (e) {
      Logger.error('BleService: Message send failed', e, null, 'BLE');
      // Disconnect so it retries with a fresh connection next time
      _connectionManager.disconnect(peerId);
      return false;
    }
  }

  @override
  Stream<ReceivedMessage> get messageReceivedStream =>
      _messageReceivedController.stream;

  // ==================== Drop Anchor ====================

  @override
  Future<bool> sendDropAnchor(String peerId) async {
    _ensureInitialized();

    Logger.info(
      'BleService: Sending drop_anchor to ${peerId.substring(0, min(8, peerId.length))}',
      'BLE',
    );

    try {
      var conn = _connectionManager.getConnection(peerId);

      if (conn == null || !conn.canSendMessages) {
        final peripheral = _connectionManager.getPeripheral(peerId);
        if (peripheral != null) {
          conn = await _connectionManager.connect(peerId, peripheral);
        }
      }

      final ownUserId = _gattServer.ownUserId;
      final destinationUserId = _getAppUserIdForPeer(peerId);
      final anchorPayload = <String, dynamic>{
        'type': 'drop_anchor',
        'sender_id': ownUserId,
        'timestamp': DateTime.now().toIso8601String(),
        if (_meshRelay.enabled) ...{
          'destination_id': destinationUserId ?? '',
          'ttl': config.meshTtl,
          'relay_path': <String>[ownUserId],
        },
      };
      final data = Uint8List.fromList(utf8.encode(jsonEncode(anchorPayload)));

      if (conn == null || !conn.canSendMessages) {
        // Direct connection unavailable — try mesh relay
        if (_meshRelay.enabled && _connectionManager.activeConnectionCount > 0) {
          final relayed = _meshRelay.originateMessage(
            data,
            destinationUserId ?? '',
          );
          if (relayed) {
            Logger.info(
              'BleService: Anchor drop relayed via mesh for $peerId',
              'BLE',
            );
            return true;
          }
        }

        Logger.info(
            'BleService: Cannot drop anchor — peer not reachable: $peerId',
            'BLE');
        return false;
      }

      final success = await _writeQueue.enqueue(
        peerId: peerId,
        peripheral: conn.peripheral,
        characteristic: conn.messagingChar!,
        data: data,
        priority: WritePriority.userMessage,
      );

      if (success) {
        Logger.info('BleService: Anchor drop sent successfully', 'BLE');
      }
      return success;
    } catch (e) {
      Logger.error('BleService: Anchor drop send failed', e, null, 'BLE');
      return false;
    }
  }

  @override
  Stream<AnchorDropReceived> get anchorDropReceivedStream =>
      _anchorDropReceivedController.stream;

  void _handleDropAnchor(String fromPeerId) {
    final drop = AnchorDropReceived(
      fromPeerId: fromPeerId,
      timestamp: DateTime.now(),
    );
    _anchorDropReceivedController.add(drop);
    Logger.info(
      'BleService: Anchor drop received from '
          '${fromPeerId.substring(0, min(8, fromPeerId.length))}',
      'BLE',
    );
  }

  // ==================== Reactions ====================

  @override
  Future<bool> sendReaction({
    required String peerId,
    required String messageId,
    required String emoji,
    required String action,
  }) async {
    _ensureInitialized();

    Logger.info(
      'BleService: Sending reaction $emoji ($action) to '
          '${peerId.substring(0, min(8, peerId.length))}',
      'BLE',
    );

    try {
      var conn = _connectionManager.getConnection(peerId);

      if (conn == null || !conn.canSendMessages) {
        final peripheral = _connectionManager.getPeripheral(peerId);
        if (peripheral != null) {
          conn = await _connectionManager.connect(peerId, peripheral);
        }
      }

      final ownUserId = _gattServer.ownUserId;
      final payload = <String, dynamic>{
        'type': 'reaction',
        'sender_id': ownUserId,
        'message_id': messageId,
        'emoji': emoji,
        'action': action,
        'timestamp': DateTime.now().toIso8601String(),
      };
      final data = Uint8List.fromList(utf8.encode(jsonEncode(payload)));

      if (conn == null || !conn.canSendMessages) {
        Logger.info(
          'BleService: Cannot send reaction — peer not reachable: $peerId',
          'BLE',
        );
        return false;
      }

      final success = await _writeQueue.enqueue(
        peerId: peerId,
        peripheral: conn.peripheral,
        characteristic: conn.messagingChar!,
        data: data,
        priority: WritePriority.userMessage,
      );

      if (success) {
        Logger.info('BleService: Reaction sent successfully', 'BLE');
      }
      return success;
    } catch (e) {
      Logger.error('BleService: Reaction send failed', e, null, 'BLE');
      return false;
    }
  }

  @override
  Stream<ReactionReceived> get reactionReceivedStream =>
      _reactionReceivedController.stream;

  void _handleReaction(Map<String, dynamic> json, String fromPeerId) {
    final messageId = json['message_id'] as String?;
    final emoji = json['emoji'] as String?;
    final action = json['action'] as String?;
    final timestampStr = json['timestamp'] as String?;

    if (messageId == null || emoji == null || action == null) {
      Logger.warning('BleService: Malformed reaction payload', 'BLE');
      return;
    }

    final timestamp = timestampStr != null
        ? DateTime.tryParse(timestampStr) ?? DateTime.now()
        : DateTime.now();

    final reaction = ReactionReceived(
      fromPeerId: fromPeerId,
      messageId: messageId,
      emoji: emoji,
      action: action,
      timestamp: timestamp,
    );
    _reactionReceivedController.add(reaction);
    Logger.info(
      'BleService: Reaction $emoji ($action) received from '
          '${fromPeerId.substring(0, min(8, fromPeerId.length))}',
      'BLE',
    );
  }

  Uint8List _serializeMessagePayload(MessagePayload payload,
      {String? destinationUserId}) {
    final ownUserId = _gattServer.ownUserId;
    final json = <String, dynamic>{
      'type': 'message',
      'sender_id': ownUserId,
      'message_type': payload.type.index,
      'message_id': payload.messageId,
      'content': payload.content,
      'timestamp': DateTime.now().toIso8601String(),
    };
    if (payload.replyToId != null) {
      json['reply_to_id'] = payload.replyToId;
    }
    if (_meshRelay.enabled) {
      json['origin_id'] = ownUserId;
      json['destination_id'] = destinationUserId ?? '';
      json['ttl'] = config.meshTtl;
      json['relay_path'] = <String>[ownUserId];
    }
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  // ==================== Photo Transfer (delegated to PhotoTransferHandler) ====================

  @override
  Future<bool> sendPhoto(String peerId, Uint8List photoData, String messageId,
      {String? photoId}) {
    _ensureInitialized();
    return _photoTransfer.sendPhoto(peerId, photoData, messageId,
        photoId: photoId);
  }

  @override
  Stream<PhotoTransferProgress> get photoProgressStream =>
      _photoProgressController.stream;

  @override
  Stream<ReceivedPhoto> get photoReceivedStream =>
      _photoReceivedController.stream;

  @override
  Future<void> cancelPhotoTransfer(String messageId) async {
    _photoTransfer.cancelTransfer(messageId);
  }

  // ==================== Photo Preview / Consent Flow ====================

  @override
  Future<bool> sendPhotoPreview({
    required String peerId,
    required String messageId,
    required String photoId,
    required Uint8List thumbnailBytes,
    required int originalSize,
  }) {
    _ensureInitialized();
    return _photoTransfer.sendPhotoPreview(
      peerId: peerId,
      messageId: messageId,
      photoId: photoId,
      thumbnailBytes: thumbnailBytes,
      originalSize: originalSize,
    );
  }

  @override
  Future<bool> sendPhotoRequest({
    required String peerId,
    required String messageId,
    required String photoId,
  }) {
    _ensureInitialized();
    return _photoTransfer.sendPhotoRequest(
      peerId: peerId,
      messageId: messageId,
      photoId: photoId,
    );
  }

  @override
  Stream<ReceivedPhotoPreview> get photoPreviewReceivedStream =>
      _photoPreviewReceivedController.stream;

  @override
  Stream<ReceivedPhotoRequest> get photoRequestReceivedStream =>
      _photoRequestReceivedController.stream;

  // ==================== Utilities ====================

  @override
  int? getSignalStrength(String peerId) {
    return _visiblePeers[peerId]?.rssi;
  }

  @override
  bool isPeerReachable(String peerId) {
    return _visiblePeers.containsKey(peerId);
  }

  @override
  List<String> get visiblePeerIds => _visiblePeers.keys.toList();

  @override
  Future<void> setBatterySaverMode(bool enabled) async {
    _scanner.setBatterySaverMode(enabled);
    Logger.info(
        'BleService: Battery saver ${enabled ? 'enabled' : 'disabled'}',
        'BLE');
  }
}
