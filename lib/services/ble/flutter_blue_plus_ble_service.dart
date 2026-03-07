import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../../core/utils/logger.dart';
import 'ble_config.dart';
import 'ble_models.dart';
import 'ble_service_interface.dart';
import 'photo_chunker.dart';

/// BLE service using `bluetooth_low_energy` which provides both Central
/// (scanning/connecting) and Peripheral (GATT server/advertising) in one
/// package — enabling real peer-to-peer discovery AND messaging on iOS & Android.
///
/// Each device:
///   1. Runs a GATT server with profile metadata + messaging characteristics.
///   2. Advertises the Anchor service UUID + local name.
///   3. Scans for other Anchor devices.
///   4. Connects to discovered peers to read profile / send messages.
class FlutterBluePlusBleService implements BleServiceInterface {
  FlutterBluePlusBleService({
    required this.config,
  }) : _photoReassembler = PhotoReassembler();

  final BleConfig config;
  final PhotoReassembler _photoReassembler;

  // Managers
  late final CentralManager _central;
  late final PeripheralManager _peripheral;

  // UUIDs
  static final _serviceUuid =
      UUID.fromString('0000fff0-0000-1000-8000-00805f9b34fb');
  static final _profileCharUuid =
      UUID.fromString('0000fff1-0000-1000-8000-00805f9b34fb');
  static final _thumbnailCharUuid =
      UUID.fromString('0000fff2-0000-1000-8000-00805f9b34fb');
  static final _messagingCharUuid =
      UUID.fromString('0000fff3-0000-1000-8000-00805f9b34fb');

  // Status
  BleStatus _status = BleStatus.disabled;
  bool _isScanning = false;
  bool _isBroadcasting = false;
  bool _isInitialized = false;

  // Stream controllers
  final _statusController = StreamController<BleStatus>.broadcast();
  final _peerDiscoveredController =
      StreamController<DiscoveredPeer>.broadcast();
  final _peerLostController = StreamController<String>.broadcast();
  final _messageReceivedController =
      StreamController<ReceivedMessage>.broadcast();
  final _photoProgressController =
      StreamController<PhotoTransferProgress>.broadcast();
  final _photoReceivedController = StreamController<ReceivedPhoto>.broadcast();

  // Peer tracking
  final Map<String, DiscoveredPeer> _visiblePeers = {};
  final Map<String, Timer> _peerTimeoutTimers = {};

  // Connected peripherals (for sending messages as central)
  final Map<String, Peripheral> _discoveredPeripherals = {};
  final Map<String, GATTCharacteristic> _messagingChars = {};

  // Map from app userId → BLE peerId (peripheral UUID) so incoming messages
  // (which carry the sender's app userId) can be routed to the correct peer.
  final Map<String, String> _userIdToPeerId = {};

  // Scan lifecycle
  Timer? _scanRestartTimer;
  static const _normalScanDuration = Duration(seconds: 5);
  static const _normalScanPause = Duration(seconds: 15);
  static const _batteryScanDuration = Duration(seconds: 2);
  static const _batteryScanPause = Duration(seconds: 30);
  Duration _scanDuration = _normalScanDuration;
  Duration _scanPause = _normalScanPause;
  // Whether the user has explicitly enabled battery saver (vs auto-adaptive)
  bool _explicitBatterySaver = false;

  // Subscriptions
  StreamSubscription? _centralStateSubscription;
  StreamSubscription? _peripheralStateSubscription;
  StreamSubscription? _discoveredSubscription;
  StreamSubscription? _charReadSubscription;
  StreamSubscription? _charWriteSubscription;
  StreamSubscription? _charNotifyStateSubscription;
  StreamSubscription? _charNotifiedSubscription;

  // In-memory message ID deduplication — prevents the same BLE write
  // from being processed twice if the transport retransmits it.
  final Set<String> _seenMessageIds = {};

  // Throttle peer_announce broadcasts: don't re-announce the same peer
  // more than once every 5 minutes to avoid flooding connected peers.
  final Map<String, DateTime> _lastAnnouncedAt = {};

  // Mesh relay toggle (mutable at runtime via setMeshRelayMode)
  late bool _meshRelayEnabled;

  // Routing table: sender userId → set of peer IDs they directly see.
  // Built from incoming neighbor_list messages.
  final Map<String, Set<String>> _neighborMap = {};

  // Timer that periodically broadcasts this device's neighbor list.
  Timer? _neighborListTimer;

  // GATT characteristics (server side)
  GATTCharacteristic? _serverProfileChar;
  GATTCharacteristic? _serverThumbnailChar;
  GATTCharacteristic? _serverMessagingChar;
  bool _gattServerReady = false; // true once addService succeeds
  bool _settingUpGatt = false; // prevents concurrent _setupGattServer calls
  bool _startCalled = false; // true after start() has been called at least once

  // Cached profile data for GATT server read requests
  Uint8List _profileData = Uint8List(0);
  // Raw thumbnail bytes served via the dedicated thumbnail characteristic (fff2).
  // For multi-photo: concatenation of all photo thumbnails in display order.
  Uint8List _thumbnailData = Uint8List(0);
  // Sizes of individual photo thumbnails concatenated in _thumbnailData (server side).
  List<int> _ownPhotoSizes = [];
  BroadcastPayload? _pendingPayload;

  // Per-peer characteristic cache (central side — for reading remote profiles)
  final Map<String, GATTCharacteristic> _profileChars = {};
  final Map<String, GATTCharacteristic> _thumbnailChars = {};
  // Throttle profile re-reads to once per 60 s per peer
  final Map<String, DateTime> _lastProfileReadTime = {};

  // Per-peer thumbnail assembly buffers (notification-based chunked delivery)
  final Map<String, List<int>> _thumbnailBuffers = {};
  final Map<String, int> _thumbnailExpectedSizes = {};
  // Per-peer photo sizes for splitting the reassembled thumbnail buffer (central side).
  // Only set when the remote peer advertises multiple photos via 'photo_sizes'.
  final Map<String, List<int>> _peerPhotoSizes = {};

  // Active incoming binary photo transfers (keyed by centralUuid)
  // Stores metadata from the photo_start message so binary chunks
  // can be correlated without carrying their own metadata.
  final Map<String, _IncomingPhotoTransfer> _incomingPhotoTransfers = {};

  // ==================== Lifecycle ====================

  @override
  Future<void> initialize() async {
    if (_isInitialized) return;
    _meshRelayEnabled = _meshRelayEnabled;

    Logger.info('BleService: Initializing...', 'BLE');

    try {
      _central = CentralManager();
      _peripheral = PeripheralManager();

      // Listen to central manager state
      _centralStateSubscription =
          _central.stateChanged.listen((e) => _onStateChanged(e.state));

      // Listen to peripheral manager state so we can set up the GATT server
      // and retry advertising once the peripheral is powered on.
      _peripheralStateSubscription = _peripheral.stateChanged
          .listen((e) => _onPeripheralStateChanged(e.state));

      _isInitialized = true;

      // Check initial state
      _onStateChanged(_central.state);
      _onPeripheralStateChanged(_peripheral.state);

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
      _startCalled = true;
      await _setupGattServer(force: true);
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
    await stopBroadcasting();

    try {
      await _peripheral.removeAllServices();
    } catch (e) {
      Logger.error('BleService: Remove services failed', e, null, 'BLE');
    }

    _gattServerReady = false;
    _settingUpGatt = false;
    _startCalled = false;
    _discoveredPeripherals.clear();
    _messagingChars.clear();
    _profileChars.clear();
    _thumbnailChars.clear();
    _maxWriteLengths.clear();
    _lastProfileReadTime.clear();
    _userIdToPeerId.clear();
    _thumbnailBuffers.clear();
    _thumbnailExpectedSizes.clear();
    _peerPhotoSizes.clear();
    _lastAnnouncedAt.clear();
    _neighborMap.clear();
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

    await _centralStateSubscription?.cancel();
    await _peripheralStateSubscription?.cancel();
    await _discoveredSubscription?.cancel();
    await _charReadSubscription?.cancel();
    await _charWriteSubscription?.cancel();
    await _charNotifyStateSubscription?.cancel();
    await _charNotifiedSubscription?.cancel();

    await _statusController.close();
    await _peerDiscoveredController.close();
    await _peerLostController.close();
    await _messageReceivedController.close();
    await _photoProgressController.close();
    await _photoReceivedController.close();

    _photoReassembler.clear();
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
        if (_pendingPayload != null && !_isBroadcasting) {
          _startAdvertisingAndGatt(_pendingPayload!);
        }
        break;
      case BluetoothLowEnergyState.poweredOff:
        _setStatus(BleStatus.disabled);
        _isScanning = false;
        _isBroadcasting = false;
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

  /// Called when the PeripheralManager state changes.
  ///
  /// The peripheral and central managers share the same Bluetooth adapter on
  /// iOS/Android, but their state callbacks can fire at slightly different times.
  /// Listening here ensures the GATT server is (re-)registered and pending
  /// advertising is retried as soon as the peripheral is ready — even if
  /// [_onStateChanged] (central) already fired.
  void _onPeripheralStateChanged(BluetoothLowEnergyState state) {
    Logger.info('BleService: Peripheral state changed: $state', 'BLE');

    if (state == BluetoothLowEnergyState.poweredOn &&
        _startCalled &&
        !_gattServerReady) {
      // start() was called but the GATT server setup failed because the
      // peripheral wasn't ready yet. Retry now that it's powered on.
      _setupGattServer().then((_) {
        if (_pendingPayload != null && !_isBroadcasting) {
          _startAdvertisingAndGatt(_pendingPayload!);
        }
      });
    }
  }

  // ==================== GATT Server ====================

  Future<void> _setupGattServer({bool force = false}) async {
    if (_settingUpGatt && !force) return; // skip if already in progress
    _settingUpGatt = true;
    _gattServerReady = false;
    Logger.info('BleService: Setting up GATT server...', 'BLE');

    try {
      await _peripheral.removeAllServices();

      // Profile characteristic: centrals read this to get our profile metadata
      // Kept small (userId/name/age/bio, <512 bytes) to stay within ATT limits.
      _serverProfileChar = GATTCharacteristic.mutable(
        uuid: _profileCharUuid,
        properties: [
          GATTCharacteristicProperty.read,
        ],
        permissions: [
          GATTCharacteristicPermission.read,
        ],
        descriptors: [],
      );

      // Thumbnail characteristic: centrals read this to get our profile photo.
      // Also has notify so the peripheral can push the thumbnail in chunks
      // when the central subscribes — bypassing the single-packet ATT read limit.
      _serverThumbnailChar = GATTCharacteristic.mutable(
        uuid: _thumbnailCharUuid,
        properties: [
          GATTCharacteristicProperty.read,
          GATTCharacteristicProperty.notify,
        ],
        permissions: [
          GATTCharacteristicPermission.read,
        ],
        descriptors: [],
      );

      // Messaging characteristic: centrals write to this to send us messages
      _serverMessagingChar = GATTCharacteristic.mutable(
        uuid: _messagingCharUuid,
        properties: [
          GATTCharacteristicProperty.write,
          GATTCharacteristicProperty.writeWithoutResponse,
        ],
        permissions: [
          GATTCharacteristicPermission.write,
        ],
        descriptors: [],
      );

      final service = GATTService(
        uuid: _serviceUuid,
        isPrimary: true,
        includedServices: [],
        characteristics: [
          _serverProfileChar!,
          _serverThumbnailChar!,
          _serverMessagingChar!,
        ],
      );

      await _peripheral.addService(service);

      // Handle profile + thumbnail read requests (single stream, dispatch by UUID)
      await _charReadSubscription?.cancel();
      _charReadSubscription = _peripheral.characteristicReadRequested
          .listen(_onCharacteristicReadRequested);

      // Handle incoming messages (writes to messaging characteristic)
      await _charWriteSubscription?.cancel();
      _charWriteSubscription = _peripheral.characteristicWriteRequested
          .listen(_onMessageWriteReceived);

      // Handle thumbnail characteristic notify subscriptions from centrals.
      // When a central subscribes, push the thumbnail in chunks.
      await _charNotifyStateSubscription?.cancel();
      _charNotifyStateSubscription = _peripheral
          .characteristicNotifyStateChanged
          .listen(_onThumbnailNotifyStateChanged);

      // Handle thumbnail notification chunks arriving at the central side.
      await _charNotifiedSubscription?.cancel();
      _charNotifiedSubscription =
          _central.characteristicNotified.listen(_onCharacteristicNotified);

      _gattServerReady = true;
      Logger.info('BleService: GATT server ready', 'BLE');
    } catch (e) {
      Logger.error('BleService: GATT server setup failed', e, null, 'BLE');
    } finally {
      _settingUpGatt = false;
    }
  }

  /// Handles read requests for ALL readable characteristics.
  /// Dispatches by UUID so both the profile char (fff1) and the thumbnail
  /// char (fff2) are served from the correct data buffer.
  ///
  /// iOS issues Read Blob Requests with increasing offsets for data > ATT MTU.
  /// We respond with the slice starting at `offset`; CoreBluetooth clips the
  /// response to MTU-1 bytes and issues the next request automatically.
  void _onCharacteristicReadRequested(
      GATTCharacteristicReadRequestedEventArgs args) async {
    try {
      final charUuid = args.characteristic.uuid;
      final offset = args.request.offset;

      final Uint8List sourceData;
      final String charName;
      if (charUuid == _profileCharUuid) {
        sourceData = _profileData;
        charName = 'profile';
      } else if (charUuid == _thumbnailCharUuid) {
        sourceData = _thumbnailData;
        charName = 'thumbnail';
      } else {
        await _peripheral.respondReadRequestWithValue(
          args.request,
          value: Uint8List(0),
        );
        return;
      }

      final slice = offset < sourceData.length
          ? sourceData.sublist(offset)
          : Uint8List(0);

      Logger.info(
        'BleService: Read request [$charName] offset=$offset '
            'total=${sourceData.length}B responding=${slice.length}B',
        'BLE',
      );

      await _peripheral.respondReadRequestWithValue(
        args.request,
        value: slice,
      );
    } catch (e) {
      Logger.error(
          'BleService: Characteristic read response failed', e, null, 'BLE');
    }
  }

  void _onMessageWriteReceived(
      GATTCharacteristicWriteRequestedEventArgs args) async {
    try {
      // Respond to the write request
      await _peripheral.respondWriteRequest(args.request);

      final data = args.request.value;
      if (data.isEmpty) return;

      // Binary photo chunk: first byte is 0x02
      if (data[0] == 0x02) {
        _handleBinaryPhotoChunk(data, args.central.uuid);
        return;
      }

      // JSON payload (text messages, photo_start, legacy photo_chunk)
      final jsonStr = utf8.decode(data);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;

      final fromPeerId = _resolveSenderPeerId(json, args.central.uuid);
      final type = json['type'] as String? ?? 'message';

      if (type == 'photo_start') {
        _handlePhotoStart(json, fromPeerId);
      } else if (type == 'photo_chunk') {
        _handleReceivedPhotoChunk(json, fromPeerId);
      } else if (type == 'peer_announce') {
        _handlePeerAnnounce(json, fromPeerId);
      } else if (type == 'neighbor_list') {
        _handleNeighborList(json);
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
  String _resolveSenderPeerId(Map<String, dynamic> json, UUID centralUuid) {
    final senderId = json['sender_id'] as String?;
    if (senderId != null &&
        senderId.isNotEmpty &&
        _userIdToPeerId.containsKey(senderId)) {
      return _userIdToPeerId[senderId]!;
    }
    return centralUuid.toString();
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
    final ownUserId = _pendingPayload?.userId ?? '';
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
      );
      _messageReceivedController.add(message);
      Logger.info(
        'BleService: Received message from '
            '${fromPeerId.substring(0, min(8, fromPeerId.length))}',
        'BLE',
      );
    } else {
      // Not for us — attempt to relay toward the destination
      _maybeRelayMessage(json, fromPeerId);
    }
  }

  /// Forward a mesh message to all currently-connected peers except the one
  /// we received it from.  Decrements TTL and appends our userId to
  /// relay_path for loop detection.
  ///
  /// Intentionally does NOT queue messages for offline peers — relay packets
  /// are only forwarded to peers currently connected via GATT.  Queuing relay
  /// messages would cause stale-message floods when peers reconnect.
  void _maybeRelayMessage(Map<String, dynamic> json, String receivedFromPeerId) {
    if (!_meshRelayEnabled) return;

    final ttl = json['ttl'] as int? ?? 0;
    if (ttl <= 0) {
      Logger.info('BleService: Mesh TTL exhausted, dropping relay', 'BLE');
      return;
    }

    final ownUserId = _pendingPayload?.userId ?? '';
    final relayPath =
        List<String>.from((json['relay_path'] as List<dynamic>? ?? []));

    // Loop guard: don't relay if we've already forwarded this message
    if (relayPath.contains(ownUserId)) {
      Logger.info('BleService: Already in relay path, dropping', 'BLE');
      return;
    }

    final relayJson = Map<String, dynamic>.from(json);
    relayJson['ttl'] = ttl - 1;
    relayJson['relay_path'] = [...relayPath, ownUserId];

    final data = Uint8List.fromList(utf8.encode(jsonEncode(relayJson)));

    // Directed routing: if we know which connected peer can reach the
    // destination directly, send only to that peer instead of flooding.
    final destinationId = json['destination_id'] as String? ?? '';
    if (destinationId.isNotEmpty) {
      final bestRelay = _findBestRelayPeer(destinationId, receivedFromPeerId);
      if (bestRelay != null) {
        _writeRelayData(data, bestRelay);
        Logger.info(
            'BleService: Directed relay to best peer (TTL ${ttl - 1})', 'BLE');
        return;
      }
    }

    // In high-density mode, apply probabilistic relay to reduce flood traffic.
    final isHighDensity =
        _visiblePeers.length >= config.highDensityPeerThreshold;
    final relayProb =
        isHighDensity ? config.highDensityRelayProbability : 1.0;
    final rng = Random();

    // Fallback: flood to all connected peers except sender
    int relayCount = 0;
    for (final entry in _messagingChars.entries) {
      final targetPeerId = entry.key;
      if (targetPeerId == receivedFromPeerId) continue;
      final peripheral = _discoveredPeripherals[targetPeerId];
      if (peripheral == null) continue;
      if (rng.nextDouble() > relayProb) continue; // probabilistic drop
      _writeRelayData(data, targetPeerId);
      relayCount++;
    }

    Logger.info(
      'BleService: Flooded message to $relayCount peers '
          '(TTL remaining: ${ttl - 1})',
      'BLE',
    );
  }

  /// Returns the app userId for a given BLE peripheral UUID, or null if
  /// the mapping hasn't been established yet (peer profile not yet read).
  String? _getAppUserIdForPeer(String blePeerId) {
    for (final entry in _userIdToPeerId.entries) {
      if (entry.value == blePeerId) return entry.key;
    }
    return null;
  }

  // ==================== Mesh Utilities ====================

  @override
  Future<void> setMeshRelayMode(bool enabled) async {
    _meshRelayEnabled = enabled;
    Logger.info(
        'BleService: Mesh relay ${enabled ? "enabled" : "disabled"}', 'BLE');
  }

  @override
  bool get isMeshRelayEnabled => _meshRelayEnabled;

  @override
  int get meshRelayedPeerCount =>
      _visiblePeers.values.where((p) => p.isRelayed).length;

  @override
  int get meshRoutingTableSize => _neighborMap.length;

  /// Returns the BLE peerId of the connected peer most likely to forward
  /// a message toward [destinationUserId], or null if no routing info exists.
  String? _findBestRelayPeer(String destinationUserId, String excludePeerId) {
    for (final entry in _messagingChars.entries) {
      if (entry.key == excludePeerId) continue;
      final peerUserId = _getAppUserIdForPeer(entry.key);
      if (peerUserId == null) continue;
      final neighbors = _neighborMap[peerUserId] ?? const {};
      if (neighbors.contains(destinationUserId)) return entry.key;
    }
    return null;
  }

  /// Write pre-serialised relay data to a specific connected peer.
  void _writeRelayData(Uint8List data, String targetPeerId) {
    final char = _messagingChars[targetPeerId];
    final peripheral = _discoveredPeripherals[targetPeerId];
    if (char == null || peripheral == null) return;
    _central
        .writeCharacteristic(
          peripheral,
          char,
          value: data,
          type: GATTCharacteristicWriteType.withResponse,
        )
        .catchError((Object e) => Logger.warning(
            'BleService: Relay write failed to $targetPeerId: $e', 'BLE'));
  }

  // ==================== Mesh Peer Discovery ====================

  /// Broadcast a `peer_announce` for a directly-discovered peer so that
  /// devices connected to us can learn about peers beyond their direct range.
  ///
  /// Throttled to once per 5 minutes per peer to avoid excessive traffic.
  /// Only fires after the peer's thumbnail is available (richest data).
  void _announcePeerToMesh(DiscoveredPeer peer) {
    if (!_meshRelayEnabled) return;
    if (_messagingChars.isEmpty) return;
    if (peer.isRelayed) return; // never re-announce relayed peers

    final now = DateTime.now();
    final lastAnnounced = _lastAnnouncedAt[peer.peerId];
    if (lastAnnounced != null &&
        now.difference(lastAnnounced).inMinutes < 5) {
      return;
    }
    _lastAnnouncedAt[peer.peerId] = now;

    final ownUserId = _pendingPayload?.userId ?? '';
    final thumbnailB64 = peer.thumbnailBytes != null
        ? base64Encode(peer.thumbnailBytes!)
        : null;

    final msgId = const Uuid().v4();
    final json = <String, dynamic>{
      'type': 'peer_announce',
      'message_id': msgId,
      'peer_id': peer.peerId,
      'peer_user_id': _getAppUserIdForPeer(peer.peerId) ?? '',
      'name': peer.name,
      if (peer.age != null) 'age': peer.age,
      if (peer.bio != null) 'bio': peer.bio,
      if (thumbnailB64 != null) 'thumbnail_b64': thumbnailB64,
      // TTL starts at meshTtl - 1 because this device counts as hop 1
      'ttl': config.meshTtl - 1,
      'relay_path': <String>[ownUserId],
    };

    // Mark as seen so our own announce doesn't get re-relayed back to us
    _seenMessageIds.add(msgId);
    Future.delayed(
        const Duration(minutes: 5), () => _seenMessageIds.remove(msgId));

    final data = Uint8List.fromList(utf8.encode(jsonEncode(json)));
    int count = 0;
    for (final entry in _messagingChars.entries) {
      final peripheral = _discoveredPeripherals[entry.key];
      if (peripheral == null) continue;
      _central
          .writeCharacteristic(
            peripheral,
            entry.value,
            value: data,
            type: GATTCharacteristicWriteType.withResponse,
          )
          .catchError((Object e) => Logger.warning(
              'BleService: Peer announce write failed to ${entry.key}: $e',
              'BLE'));
      count++;
    }

    Logger.info(
        'BleService: Announced "${peer.name}" to $count mesh peers', 'BLE');
  }

  /// Handle an incoming `peer_announce` — emit the announced peer to the
  /// discovery stream (marked as relayed) and forward further if TTL allows.
  void _handlePeerAnnounce(Map<String, dynamic> json, String fromPeerId) {
    final messageId = json['message_id'] as String? ?? '';

    // Dedup
    if (messageId.isNotEmpty) {
      if (_seenMessageIds.contains(messageId)) return;
      _seenMessageIds.add(messageId);
      Future.delayed(
          const Duration(minutes: 5), () => _seenMessageIds.remove(messageId));
    }

    final announcedPeerId = json['peer_id'] as String? ?? '';
    if (announcedPeerId.isEmpty) return;

    // Don't emit ourselves as a discovered peer
    final announcedUserid = json['peer_user_id'] as String? ?? '';
    final ownUserId = _pendingPayload?.userId ?? '';
    if (announcedUserid.isNotEmpty && announcedUserid == ownUserId) return;

    // Don't overwrite a directly-seen peer with a relayed version
    final existing = _visiblePeers[announcedPeerId];
    if (existing != null && !existing.isRelayed) {
      // Still relay onward so others can benefit, but skip the local emit
      _relayPeerAnnounce(json, fromPeerId);
      return;
    }

    // Decode thumbnail
    Uint8List? thumbnail;
    final thumbB64 = json['thumbnail_b64'] as String?;
    if (thumbB64 != null && thumbB64.isNotEmpty) {
      try {
        thumbnail = base64Decode(thumbB64);
      } catch (_) {}
    }

    final relayPath =
        List<String>.from(json['relay_path'] as List<dynamic>? ?? []);
    final hopCount = relayPath.length;

    final peer = DiscoveredPeer(
      peerId: announcedPeerId,
      name: json['name'] as String? ?? 'Unknown',
      age: json['age'] as int?,
      bio: json['bio'] as String?,
      thumbnailBytes: thumbnail,
      rssi: null, // no RSSI for relayed peers
      timestamp: DateTime.now(),
      isRelayed: true,
      hopCount: hopCount,
    );

    // Update visible peers map and restart timeout timer
    _visiblePeers[announcedPeerId] = peer;
    _peerTimeoutTimers[announcedPeerId]?.cancel();
    _peerTimeoutTimers[announcedPeerId] = Timer(
      config.peerLostTimeout,
      () => _onPeerLost(announcedPeerId),
    );

    // Record userId→peerId mapping for mesh message routing
    if (announcedUserid.isNotEmpty) {
      _userIdToPeerId[announcedUserid] = announcedPeerId;
    }

    _peerDiscoveredController.add(peer);
    Logger.info(
      'BleService: Mesh-discovered "${peer.name}" ($hopCount hops away)',
      'BLE',
    );

    _relayPeerAnnounce(json, fromPeerId);
  }

  /// Forward a `peer_announce` to all connected peers except the sender.
  void _relayPeerAnnounce(Map<String, dynamic> json, String excludePeerId) {
    final ttl = json['ttl'] as int? ?? 0;
    if (ttl <= 0) return;

    final ownUserId = _pendingPayload?.userId ?? '';
    final relayPath =
        List<String>.from(json['relay_path'] as List<dynamic>? ?? []);
    if (relayPath.contains(ownUserId)) return;

    final relayJson = Map<String, dynamic>.from(json);
    relayJson['ttl'] = ttl - 1;
    relayJson['relay_path'] = [...relayPath, ownUserId];

    final data = Uint8List.fromList(utf8.encode(jsonEncode(relayJson)));

    // Directed: prefer a peer who already knows the announced peer
    final announcedPeerId = json['peer_id'] as String? ?? '';
    final announcedUserId = json['peer_user_id'] as String? ?? '';
    final targetId = announcedUserId.isNotEmpty ? announcedUserId : announcedPeerId;
    if (targetId.isNotEmpty) {
      final best = _findBestRelayPeer(targetId, excludePeerId);
      if (best != null) {
        _writeRelayData(data, best);
        return;
      }
    }

    // Fallback: flood
    for (final entry in _messagingChars.entries) {
      if (entry.key == excludePeerId) continue;
      final peripheral = _discoveredPeripherals[entry.key];
      if (peripheral == null) continue;
      _central
          .writeCharacteristic(
            peripheral,
            entry.value,
            value: data,
            type: GATTCharacteristicWriteType.withResponse,
          )
          .catchError((Object e) => Logger.warning(
              'BleService: Peer announce relay failed: $e', 'BLE'));
    }
  }

  void _handleReceivedPhotoChunk(Map<String, dynamic> json, String fromPeerId) {
    final dataField = json['data'];
    Uint8List chunkData;
    if (dataField is String) {
      // base64 encoded
      chunkData = base64Decode(dataField);
    } else if (dataField is List) {
      // legacy int array fallback
      chunkData = Uint8List.fromList(dataField.cast<int>());
    } else {
      chunkData = Uint8List(0);
    }

    final chunk = PhotoChunk(
      messageId: json['message_id'] as String? ?? '',
      chunkIndex: json['chunk_index'] as int? ?? 0,
      totalChunks: json['total_chunks'] as int? ?? 1,
      data: chunkData,
      totalSize: json['total_size'] as int? ?? 0,
    );

    Logger.info(
      'BleService: Received photo chunk ${chunk.chunkIndex + 1}/${chunk.totalChunks} '
          'for ${chunk.messageId.substring(0, min(8, chunk.messageId.length))}',
      'BLE',
    );

    // Emit receive-side progress
    _photoProgressController.add(PhotoTransferProgress(
      messageId: chunk.messageId,
      peerId: fromPeerId,
      progress: (chunk.chunkIndex + 1) / chunk.totalChunks,
      status: PhotoTransferStatus.inProgress,
    ));

    // Feed to reassembler
    final result = _photoReassembler.addChunk(chunk);

    if (result.isComplete && result.photoData != null) {
      Logger.info(
        'BleService: Photo reassembly complete: ${chunk.messageId} '
            '(${result.photoData!.length} bytes)',
        'BLE',
      );

      _photoReceivedController.add(ReceivedPhoto(
        fromPeerId: fromPeerId,
        messageId: chunk.messageId,
        photoBytes: result.photoData!,
        timestamp: DateTime.now(),
      ));

      _photoProgressController.add(PhotoTransferProgress(
        messageId: chunk.messageId,
        peerId: fromPeerId,
        progress: 1.0,
        status: PhotoTransferStatus.completed,
      ));
    }
  }

  /// Handle photo_start JSON message — stores metadata for the upcoming
  /// binary chunk stream from this central.
  void _handlePhotoStart(Map<String, dynamic> json, String fromPeerId) {
    final messageId = json['message_id'] as String? ?? '';
    final totalChunks = json['total_chunks'] as int? ?? 0;
    final totalSize = json['total_size'] as int? ?? 0;

    // Key by fromPeerId — one active transfer per peer
    _incomingPhotoTransfers[fromPeerId] = _IncomingPhotoTransfer(
      messageId: messageId,
      totalChunks: totalChunks,
      totalSize: totalSize,
      receivedData: BytesBuilder(copy: false),
      receivedCount: 0,
    );

    Logger.info(
      'BleService: Photo transfer starting from '
          '${fromPeerId.substring(0, min(8, fromPeerId.length))}: '
          '$totalChunks chunks, $totalSize bytes',
      'BLE',
    );

    _photoProgressController.add(PhotoTransferProgress(
      messageId: messageId,
      peerId: fromPeerId,
      progress: 0,
      status: PhotoTransferStatus.starting,
    ));
  }

  /// Handle a binary photo chunk: [0x02][uint16 chunk_index][raw data]
  void _handleBinaryPhotoChunk(Uint8List data, UUID centralUuid) {
    if (data.length < 3) return; // too short

    final chunkIndex = (data[1] << 8) | data[2];
    final chunkData = data.sublist(3);

    // Resolve peer ID from central UUID
    final centralId = centralUuid.toString();
    // Try to find the transfer by checking both the centralId directly and
    // via the userIdToPeerId mapping
    var fromPeerId = centralId;
    _IncomingPhotoTransfer? transfer = _incomingPhotoTransfers[centralId];

    if (transfer == null) {
      // Try resolving via known peer IDs — the photo_start may have been
      // stored under the resolved peerId
      for (final entry in _incomingPhotoTransfers.entries) {
        if (_userIdToPeerId.values.contains(entry.key) ||
            entry.key == centralId) {
          transfer = entry.value;
          fromPeerId = entry.key;
          break;
        }
      }
    } else {
      fromPeerId = centralId;
    }

    if (transfer == null) {
      Logger.warning(
        'BleService: Binary photo chunk received but no active transfer '
            'from $centralId (chunk $chunkIndex)',
        'BLE',
      );
      return;
    }

    transfer.receivedData.add(chunkData);
    transfer.receivedCount++;

    // Log every 50 chunks to avoid spam
    if (transfer.receivedCount % 50 == 0 ||
        transfer.receivedCount == transfer.totalChunks) {
      Logger.info(
        'BleService: Photo chunk ${transfer.receivedCount}/${transfer.totalChunks} '
            'for ${transfer.messageId.substring(0, min(8, transfer.messageId.length))}',
        'BLE',
      );
    }

    // Emit progress
    _photoProgressController.add(PhotoTransferProgress(
      messageId: transfer.messageId,
      peerId: fromPeerId,
      progress: transfer.receivedCount / transfer.totalChunks,
      status: PhotoTransferStatus.inProgress,
    ));

    // Check if transfer is complete
    if (transfer.receivedCount >= transfer.totalChunks) {
      final photoBytes = transfer.receivedData.toBytes();

      Logger.info(
        'BleService: Binary photo complete: ${transfer.messageId} '
            '(${photoBytes.length} bytes)',
        'BLE',
      );

      _photoReceivedController.add(ReceivedPhoto(
        fromPeerId: fromPeerId,
        messageId: transfer.messageId,
        photoBytes: photoBytes,
        timestamp: DateTime.now(),
      ));

      _photoProgressController.add(PhotoTransferProgress(
        messageId: transfer.messageId,
        peerId: fromPeerId,
        progress: 1.0,
        status: PhotoTransferStatus.completed,
      ));

      _incomingPhotoTransfers.remove(fromPeerId);
    }
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

  // ==================== Broadcasting ====================

  @override
  Future<void> broadcastProfile(BroadcastPayload payload) async {
    _ensureInitialized();
    _pendingPayload = payload;

    // Concatenate all photo thumbnails; fall back to single thumbnailBytes.
    // _ownPhotoSizes is set BEFORE _encodeProfileData so the JSON includes it.
    if (payload.thumbnailsList != null && payload.thumbnailsList!.isNotEmpty) {
      _ownPhotoSizes = payload.thumbnailsList!.map((b) => b.length).toList();
      _thumbnailData = Uint8List.fromList(
        payload.thumbnailsList!.expand((b) => b).toList(),
      );
    } else {
      _ownPhotoSizes = payload.thumbnailBytes != null ? [payload.thumbnailBytes!.length] : [];
      _thumbnailData = payload.thumbnailBytes ?? Uint8List(0);
    }
    _profileData = _encodeProfileData(payload);

    Logger.info(
      'BleService: Broadcasting profile for ${payload.name} '
          '(profileData=${_profileData.length}B, thumbnailData=${_thumbnailData.length}B)',
      'BLE',
    );

    final state = _peripheral.state;
    if (state != BluetoothLowEnergyState.poweredOn) {
      Logger.warning(
        'BleService: Peripheral not ready ($state), will retry when ready',
        'BLE',
      );
      return;
    }

    await _startAdvertisingAndGatt(payload);
  }

  Future<void> _startAdvertisingAndGatt(BroadcastPayload payload) async {
    try {
      if (_isBroadcasting) {
        await _peripheral.stopAdvertising();
        _isBroadcasting = false;
      }

      // Encode compact name for advertisement
      final compactName = _encodeLocalName(payload);

      Logger.info(
        'BleService: Advertising with name="$compactName"',
        'BLE',
      );

      await _peripheral.startAdvertising(Advertisement(
        name: compactName,
        serviceUUIDs: [
          _serviceUuid,
          _messagingCharUuid,
          _profileCharUuid,
          _thumbnailCharUuid
        ],
      ));

      _isBroadcasting = true;
      Logger.info('BleService: Advertising started', 'BLE');
    } catch (e) {
      Logger.error('BleService: Advertising failed', e, null, 'BLE');
      _isBroadcasting = false;
    }
  }

  @override
  Future<void> stopBroadcasting() async {
    Logger.info('BleService: Stopped broadcasting', 'BLE');
    try {
      await _peripheral.stopAdvertising();
    } catch (e) {
      Logger.error('BleService: Stop advertising failed', e, null, 'BLE');
    }
    _isBroadcasting = false;
  }

  @override
  bool get isBroadcasting => _isBroadcasting;

  /// Encode local name: "A:<name>:<age>"
  String _encodeLocalName(BroadcastPayload payload) {
    final name =
        payload.name.length > 8 ? payload.name.substring(0, 8) : payload.name;
    final age = payload.age ?? 0;
    return 'A:$name:$age';
  }

  /// Decode local name "A:<name>:<age>"
  ///
  /// Age is optional — BLE ad packets are capped at 31 bytes and the name
  /// field may arrive truncated, dropping the trailing ":<age>" segment.
  ({String name, int? age})? _decodeLocalName(String advName) {
    if (!advName.startsWith('A:')) return null;
    final parts = advName.split(':');
    if (parts.length < 2) return null;
    final name = parts[1];
    final age = parts.length >= 3 ? int.tryParse(parts[2]) : null;
    return (
      name: name.isEmpty ? 'Anchor User' : name,
      age: (age == null || age == 0) ? null : age,
    );
  }

  /// Encode profile metadata as a small JSON for the profile characteristic.
  ///
  /// Intentionally excludes the thumbnail — that is served separately via the
  /// dedicated thumbnail characteristic (fff2) as raw binary bytes, avoiding
  /// the base64 inflation that would push the JSON well past the 512-byte
  /// ATT attribute value limit.
  Uint8List _encodeProfileData(BroadcastPayload payload) {
    final json = <String, dynamic>{
      'userId': payload.userId,
      'name': payload.name,
      'age': payload.age,
      'bio': payload.bio,
      // Multi-photo: include individual sizes so the central can split the buffer.
      // Single photo: use legacy thumbnail_size for backward compatibility with
      // older clients that don't understand photo_sizes.
      if (_thumbnailData.isNotEmpty)
        if (_ownPhotoSizes.length > 1)
          'photo_sizes': _ownPhotoSizes
        else
          'thumbnail_size': _thumbnailData.length,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  // ==================== Discovery ====================

  @override
  Stream<DiscoveredPeer> get peerDiscoveredStream =>
      _peerDiscoveredController.stream;

  @override
  Stream<String> get peerLostStream => _peerLostController.stream;

  @override
  Future<void> startScanning() async {
    if (_isScanning) return;
    _ensureInitialized();

    Logger.info('BleService: Starting periodic scan...', 'BLE');

    _isScanning = true;
    _setStatus(BleStatus.scanning);

    // Listen for discovered peripherals
    await _discoveredSubscription?.cancel();
    _discoveredSubscription = _central.discovered.listen(_onDeviceDiscovered);

    // Periodic neighbor-list broadcast for routing table maintenance
    _neighborListTimer?.cancel();
    _neighborListTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _broadcastNeighborList(),
    );

    // Start first scan cycle
    _runScanCycle();
  }

  void _runScanCycle() async {
    if (!_isScanning) return;

    try {
      Logger.info('BleService: Scan cycle starting...', 'BLE');

      await _central.startDiscovery(serviceUUIDs: [_serviceUuid]);

      // Stop after scan duration and schedule next cycle
      _scanRestartTimer?.cancel();
      _scanRestartTimer = Timer(_scanDuration, () async {
        if (!_isScanning) return;
        try {
          await _central.stopDiscovery();
        } catch (_) {}

        // Pause then restart
        if (_isScanning) {
          _scanRestartTimer = Timer(_scanPause, _runScanCycle);
        }
      });
    } catch (e) {
      Logger.error('BleService: Scan cycle failed', e, null, 'BLE');

      if (_isScanning) {
        _scanRestartTimer?.cancel();
        _scanRestartTimer = Timer(_scanPause, _runScanCycle);
      }
    }
  }

  @override
  Future<void> stopScanning() async {
    if (!_isScanning) return;

    Logger.info('BleService: Stopping scan...', 'BLE');

    _isScanning = false;
    _scanRestartTimer?.cancel();
    _scanRestartTimer = null;
    _neighborListTimer?.cancel();
    _neighborListTimer = null;

    try {
      await _central.stopDiscovery();
      await _discoveredSubscription?.cancel();
      _discoveredSubscription = null;
    } catch (e) {
      Logger.error('BleService: Scan stop failed', e, null, 'BLE');
    }
  }

  @override
  bool get isScanning => _isScanning;

  final Map<String, int> _lastRssi = {}; // peerId → last seen RSSI
  final Map<String, DateTime> _lastEmit = {}; // peerId → last emit time

  void _onDeviceDiscovered(DiscoveredEventArgs event) {
    final peripheral = event.peripheral;
    final deviceId = peripheral.uuid.toString();
    final adv = event.advertisement;
    final rssi = event.rssi;
    final now = DateTime.now();

    // Skip if same peer and RSSI change < 5 dBm within 3 seconds
    if (_lastEmit.containsKey(deviceId)) {
      final timeSince = now.difference(_lastEmit[deviceId]!);
      final rssiDelta = (_lastRssi[deviceId]! - rssi).abs();
      if (timeSince < const Duration(seconds: 3) && rssiDelta < 5) {
        return;
      }
    }

    _lastRssi[deviceId] = rssi;
    _lastEmit[deviceId] = now;

    // Check service UUID
    final hasAnchorService = adv.serviceUUIDs.contains(_serviceUuid);

    // Check local name prefix
    final advName = adv.name ?? '';
    final decoded = advName.isNotEmpty ? _decodeLocalName(advName) : null;

    // Not an Anchor device if neither marker is present
    if (!hasAnchorService && decoded == null) return;

    // Never fall back to the raw advName — it would expose our internal
    // "A:<name>:<age>" encoding prefix in the UI and get persisted to the DB.
    // The GATT profile read will supply the real name shortly after.
    final name = decoded?.name ?? 'Anchor User';
    final age = decoded?.age;

    Logger.info(
      'BleService: Discovered peer "$name" '
          '(hasService: $hasAnchorService, RSSI: $rssi, id: $deviceId)',
      'BLE',
    );

    // Store the peripheral for later connection
    _discoveredPeripherals[deviceId] = peripheral;

    // Preserve age, bio and thumbnail already fetched via GATT in a prior scan
    // cycle.  Advertisement packets can be truncated (31-byte limit), dropping
    // the age field entirely — and they never carry bio or thumbnail at all.
    // Always fall back to the richer GATT-fetched value when the ad is missing.
    final existing = _visiblePeers[deviceId];
    final peer = DiscoveredPeer(
      peerId: deviceId,
      name: name,
      age: age ?? existing?.age,
      bio: existing?.bio,
      thumbnailBytes: existing?.thumbnailBytes,
      rssi: rssi,
      timestamp: DateTime.now(),
    );
    _emitPeer(peer);

    // Try to connect and read full profile in the background
    _connectAndReadProfile(deviceId, peripheral);
  }

  /// Connect to a discovered peer to read their profile + thumbnail from GATT.
  ///
  /// On first contact: connects, negotiates MTU, discovers services, caches
  /// all characteristics. On subsequent sightings (peer already connected):
  /// skips the connect step and re-reads the profile + thumbnail directly,
  /// throttled to once every 60 seconds so a peer updating their photo is
  /// picked up without excessive GATT traffic.
  // Cached maximum write lengths per peripheral (avoids repeated queries)
  final Map<String, int> _maxWriteLengths = {};

  Future<void> _connectAndReadProfile(
      String peerId, Peripheral peripheral) async {
    final isAlreadyConnected = _messagingChars.containsKey(peerId);

    if (!isAlreadyConnected) {
      // ── First contact: full connect + GATT discovery ──
      try {
        await _central.connect(peripheral);

        // Request larger MTU on Android (iOS auto-negotiates)
        if (Platform.isAndroid) {
          try {
            await _central.requestMTU(peripheral, mtu: 517);
          } catch (e) {
            Logger.warning('BleService: MTU request failed for $peerId', 'BLE');
          }
        }

        // Query the safe write length for photo transfers
        try {
          final maxLen = await _central.getMaximumWriteLength(
            peripheral,
            type: GATTCharacteristicWriteType.withResponse,
          );
          _maxWriteLengths[peerId] = maxLen;
          Logger.info(
            'BleService: Max write length for $peerId: $maxLen bytes',
            'BLE',
          );
        } catch (e) {
          Logger.warning(
            'BleService: getMaximumWriteLength failed for $peerId',
            'BLE',
          );
        }

        final services = await _central.discoverGATT(peripheral);
        final anchorService =
            services.where((s) => s.uuid == _serviceUuid).firstOrNull;

        if (anchorService == null) {
          await _central.disconnect(peripheral);
          return;
        }

        // Cache all readable/writable characteristics for future use
        for (final char in anchorService.characteristics) {
          if (char.uuid == _profileCharUuid) {
            _profileChars[peerId] = char;
          } else if (char.uuid == _thumbnailCharUuid) {
            _thumbnailChars[peerId] = char;
          } else if (char.uuid == _messagingCharUuid) {
            _messagingChars[peerId] = char;
            Logger.info('BleService: Messaging ready for $peerId', 'BLE');
          }
        }

      } catch (e) {
        Logger.warning(
          'BleService: Connect to $peerId failed: $e',
          'BLE',
        );
        return;
      }
    }

    // ── Throttled profile + thumbnail re-read ──
    // Always read on first contact; re-read at most once per 30 s thereafter
    // so devices pick up profile updates (e.g. newly added photo) quickly.
    final lastRead = _lastProfileReadTime[peerId];
    final shouldReread = lastRead == null ||
        DateTime.now().difference(lastRead) > const Duration(seconds: 30);

    Logger.info(
      'BleService: _connectAndReadProfile $peerId '
          'alreadyConnected=$isAlreadyConnected '
          'hasProfileChar=${_profileChars.containsKey(peerId)} '
          'hasThumbnailChar=${_thumbnailChars.containsKey(peerId)} '
          'shouldReread=$shouldReread',
      'BLE',
    );

    if (!shouldReread) return;
    _lastProfileReadTime[peerId] = DateTime.now();

    // Read profile metadata (small JSON: userId/name/age/bio)
    final profileChar = _profileChars[peerId];
    if (profileChar != null) {
      try {
        final data = await _central.readCharacteristic(peripheral, profileChar);
        Logger.info(
          'BleService: Profile char read → ${data.length}B from $peerId',
          'BLE',
        );
        _updatePeerFromProfile(peerId, data);
      } catch (e) {
        Logger.warning(
            'BleService: Profile read failed for $peerId: $e', 'BLE');
      }
    } else {
      Logger.warning(
        'BleService: No profile char cached for $peerId — skip profile read',
        'BLE',
      );
    }

    // Subscribe to thumbnail char notifications AFTER the profile read so that
    // _thumbnailExpectedSizes[peerId] is already set when chunks arrive.
    // Unsubscribe first to guarantee the peripheral sees a state-change event
    // (false → true) and re-pushes the thumbnail, even if we were already
    // subscribed from a prior attempt.
    final thumbnailChar = _thumbnailChars[peerId];
    if (thumbnailChar != null) {
      try {
        // Clear any stale buffer so we accumulate a fresh delivery.
        _thumbnailBuffers.remove(peerId);

        try {
          await _central.setCharacteristicNotifyState(
            peripheral,
            thumbnailChar,
            state: false,
          );
        } catch (_) {
          // Ignore — may not have been subscribed yet
        }

        await _central.setCharacteristicNotifyState(
          peripheral,
          thumbnailChar,
          state: true,
        );
        Logger.info(
          'BleService: Subscribed to thumbnail notifications from $peerId',
          'BLE',
        );
      } catch (e) {
        Logger.warning(
          'BleService: Failed to subscribe to thumbnail notifications from $peerId: $e',
          'BLE',
        );
      }
    } else {
      Logger.warning(
        'BleService: No thumbnail char found for $peerId '
            '— peer may be running old code without fff2',
        'BLE',
      );
    }
  }

  void _updatePeerFromProfile(String peerId, Uint8List data) {
    try {
      final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      final existingPeer = _visiblePeers[peerId];
      if (existingPeer == null) return;

      // Prepare thumbnail assembly buffer.
      // Multi-photo peers advertise 'photo_sizes: [n1, n2, ...]' so we can split.
      // Single-photo (or old) peers use 'thumbnail_size: N' (backward compat).
      final rawPhotoSizes = json['photo_sizes'] as List?;
      final thumbnailSize = json['thumbnail_size'] as int?;
      int? totalExpected;

      if (rawPhotoSizes != null && rawPhotoSizes.isNotEmpty) {
        final photoSizes = rawPhotoSizes.cast<int>();
        _peerPhotoSizes[peerId] = photoSizes;
        totalExpected = photoSizes.reduce((a, b) => a + b);
      } else if (thumbnailSize != null && thumbnailSize > 0) {
        _peerPhotoSizes.remove(peerId); // single photo — no split needed
        totalExpected = thumbnailSize;
      }

      if (totalExpected != null && totalExpected > 0) {
        _thumbnailExpectedSizes[peerId] = totalExpected;
        // Preserve any chunks already buffered — they may have arrived before
        // this profile read completed. Only create the buffer if absent.
        final buffer = _thumbnailBuffers.putIfAbsent(peerId, () => []);
        Logger.info(
          'BleService: Expecting ${totalExpected}B thumbnail data from $peerId '
              '(${rawPhotoSizes?.length ?? 1} photo(s), ${buffer.length}B already buffered)',
          'BLE',
        );
        // If chunks arrived early and we already have everything, reassemble now.
        if (buffer.length >= totalExpected) {
          final allBytes = Uint8List.fromList(buffer.sublist(0, totalExpected));
          _thumbnailBuffers.remove(peerId);
          _thumbnailExpectedSizes.remove(peerId);
          _splitAndUpdatePeerPhotos(peerId, allBytes);
        }
      }

      final userId = json['userId'] as String?;

      // Record userId → BLE peerId mapping so incoming messages (which carry
      // the sender's app userId) can be routed to the correct peer.
      if (userId != null && userId.isNotEmpty) {
        _userIdToPeerId[userId] = peerId;
      }

      // Update the existing peer entry in-place — keep the BLE peripheral UUID
      // as the stable peerId to avoid creating duplicate database records.
      // Thumbnail is NOT in the profile JSON (lives in the fff2 characteristic).
      // Preserve any thumbnail bytes we have already read.
      final updatedPeer = DiscoveredPeer(
        peerId: peerId,
        name: json['name'] as String? ?? existingPeer.name,
        age: json['age'] as int? ?? existingPeer.age,
        bio: json['bio'] as String?,
        thumbnailBytes: existingPeer.thumbnailBytes,
        rssi: existingPeer.rssi,
        timestamp: DateTime.now(),
      );

      _emitPeer(updatedPeer);
      Logger.info(
        'BleService: Updated profile for "${updatedPeer.name}"',
        'BLE',
      );
    } catch (e) {
      Logger.warning('BleService: Profile decode failed', 'BLE');
    }
  }

  /// Split the reassembled thumbnail buffer by [_peerPhotoSizes] and update
  /// the peer with all photo thumbnails. Falls back to a single thumbnail when
  /// no multi-photo size data is available.
  void _splitAndUpdatePeerPhotos(String peerId, Uint8List allBytes) {
    final photoSizes = _peerPhotoSizes.remove(peerId);

    if (photoSizes != null && photoSizes.length > 1) {
      final photos = <Uint8List>[];
      var offset = 0;
      for (final size in photoSizes) {
        if (offset + size <= allBytes.length) {
          photos.add(allBytes.sublist(offset, offset + size));
          offset += size;
        }
      }
      if (photos.isNotEmpty) {
        _updatePeerPhotos(peerId, photos);
        return;
      }
    }

    // Single photo or size-split failed — use full bytes as primary thumbnail.
    _updatePeerThumbnail(peerId, allBytes);
  }

  /// Update an existing visible peer with multiple photo thumbnails.
  void _updatePeerPhotos(String peerId, List<Uint8List> photos) {
    final existingPeer = _visiblePeers[peerId];
    if (existingPeer == null) return;

    final updatedPeer = existingPeer.copyWith(
      thumbnailBytes: photos.first,
      photoThumbnails: photos,
      timestamp: DateTime.now(),
    );
    _emitPeer(updatedPeer);
    _announcePeerToMesh(updatedPeer);
    Logger.info(
      'BleService: Updated ${photos.length} photo(s) for "${updatedPeer.name}" '
          '(total: ${photos.fold(0, (s, b) => s + b.length)}B)',
      'BLE',
    );
  }

  /// Update an existing visible peer's thumbnail bytes after reading the
  /// dedicated thumbnail characteristic (fff2).
  void _updatePeerThumbnail(String peerId, Uint8List thumbnailBytes) {
    final existingPeer = _visiblePeers[peerId];
    if (existingPeer == null) return;

    final updatedPeer = existingPeer.copyWith(
      thumbnailBytes: thumbnailBytes,
      timestamp: DateTime.now(),
    );
    _emitPeer(updatedPeer);
    _announcePeerToMesh(updatedPeer);
    Logger.info(
      'BleService: Updated thumbnail for "${updatedPeer.name}" '
          '(${thumbnailBytes.length}B)',
      'BLE',
    );
  }

  /// Called on the PERIPHERAL side when a central subscribes to the thumbnail
  /// characteristic.  Push the thumbnail in MTU-sized chunks so the central can
  /// reassemble the full JPEG without being limited by a single ATT read payload.
  void _onThumbnailNotifyStateChanged(
      GATTCharacteristicNotifyStateChangedEventArgs args) async {
    if (args.characteristic.uuid != _thumbnailCharUuid) return;
    if (!args.state) return; // Unsubscribed — nothing to do

    final data = _thumbnailData;
    if (data.isEmpty) return;

    final central = args.central;
    int maxChunk;
    try {
      maxChunk = await _peripheral.getMaximumNotifyLength(central);
    } catch (_) {
      maxChunk = 500; // Conservative fallback
    }

    Logger.info(
      'BleService: Central subscribed to thumbnail — pushing '
          '${data.length}B in ≤${maxChunk}B chunks',
      'BLE',
    );

    var offset = 0;
    while (offset < data.length) {
      final end = min(offset + maxChunk, data.length);
      final chunk = data.sublist(offset, end);
      try {
        await _peripheral.notifyCharacteristic(
          central,
          _serverThumbnailChar!,
          value: chunk,
        );
        offset = end;
      } catch (e) {
        Logger.warning(
          'BleService: Thumbnail chunk failed at offset $offset: $e',
          'BLE',
        );
        break;
      }
    }
    Logger.info(
      'BleService: Thumbnail push complete (${data.length}B sent)',
      'BLE',
    );
  }

  /// Called on the CENTRAL side when a notification arrives on any characteristic.
  /// Accumulates thumbnail chunks and calls [_updatePeerThumbnail] when complete.
  void _onCharacteristicNotified(GATTCharacteristicNotifiedEventArgs args) {
    if (args.characteristic.uuid != _thumbnailCharUuid) return;

    final peerId = args.peripheral.uuid.toString();
    var buffer = _thumbnailBuffers[peerId] ??= []; // create if missing
    var expected = _thumbnailExpectedSizes[peerId];

    buffer.addAll(args.value);

    // If we still don't know expected size, but buffer is getting big → log warning
    if (expected == null && buffer.length > 32000) {
      Logger.warning(
          'Receiving thumbnail chunks without knowing size – possible race',
          'BLE');
      // Optionally: keep buffering anyway and wait for late profile read
    }

    if (expected != null && buffer.length >= expected) {
      final allBytes = Uint8List.fromList(buffer.sublist(0, expected));
      _thumbnailBuffers.remove(peerId);
      _thumbnailExpectedSizes.remove(peerId);
      _splitAndUpdatePeerPhotos(peerId, allBytes);
    }
  }

  void _emitPeer(DiscoveredPeer peer) {
    _visiblePeers[peer.peerId] = peer;
    _peerDiscoveredController.add(peer);
    _updateScanTiming(); // Adapt scan cadence to current density

    _peerTimeoutTimers[peer.peerId]?.cancel();
    _peerTimeoutTimers[peer.peerId] = Timer(
      config.peerLostTimeout,
      () => _onPeerLost(peer.peerId),
    );
  }

  void _onPeerLost(String peerId) {
    if (_visiblePeers.containsKey(peerId)) {
      final peer = _visiblePeers.remove(peerId);
      _peerTimeoutTimers.remove(peerId)?.cancel();
      _peerLostController.add(peerId);
      _messagingChars.remove(peerId);
      _profileChars.remove(peerId);
      _thumbnailChars.remove(peerId);
      _maxWriteLengths.remove(peerId);
      _lastProfileReadTime.remove(peerId);
      _thumbnailBuffers.remove(peerId);
      _thumbnailExpectedSizes.remove(peerId);
      _peerPhotoSizes.remove(peerId);
      _userIdToPeerId.removeWhere((_, v) => v == peerId);
      _lastAnnouncedAt.remove(peerId);
      Logger.info('BleService: Lost peer ${peer?.name}', 'BLE');
      _updateScanTiming(); // Re-evaluate density after peer lost
    }
  }

  // ==================== Routing Table ====================

  /// Store the sender's neighbor list in our routing table.
  void _handleNeighborList(Map<String, dynamic> json) {
    final senderId = json['sender_id'] as String? ?? '';
    if (senderId.isEmpty) return;
    final peers = List<String>.from(json['peers'] as List<dynamic>? ?? []);
    _neighborMap[senderId] = Set<String>.from(peers);
    Logger.info(
      'BleService: Updated routing table for $senderId '
          '(${peers.length} neighbors)',
      'BLE',
    );
  }

  /// Broadcast our directly-visible peer userId list to all connected peers
  /// so they can build a routing table entry for us.
  void _broadcastNeighborList() {
    if (!_meshRelayEnabled || _messagingChars.isEmpty) return;

    final ownUserId = _pendingPayload?.userId ?? '';
    final directPeerUserIds = _visiblePeers.entries
        .where((e) => !e.value.isRelayed)
        .map((e) => _getAppUserIdForPeer(e.key))
        .whereType<String>()
        .where((uid) => uid.isNotEmpty)
        .toList();

    if (directPeerUserIds.isEmpty) return;

    final json = <String, dynamic>{
      'type': 'neighbor_list',
      'sender_id': ownUserId,
      'peers': directPeerUserIds,
      'ttl': 1, // neighbor lists are never relayed further
    };

    final data = Uint8List.fromList(utf8.encode(jsonEncode(json)));
    for (final entry in _messagingChars.entries) {
      final peripheral = _discoveredPeripherals[entry.key];
      if (peripheral == null) continue;
      _central
          .writeCharacteristic(
            peripheral,
            entry.value,
            value: data,
            type: GATTCharacteristicWriteType.withResponse,
          )
          .catchError((Object e) => Logger.warning(
              'BleService: Neighbor list broadcast failed: $e', 'BLE'));
    }

    Logger.info(
      'BleService: Broadcast neighbor list '
          '(${directPeerUserIds.length} peers to ${_messagingChars.length} nodes)',
      'BLE',
    );
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
      // Find the messaging characteristic and peripheral
      var msgChar = _messagingChars[peerId];
      var peripheral = _discoveredPeripherals[peerId];

      // Try to connect if not already connected
      if (msgChar == null && peripheral != null) {
        await _connectAndReadProfile(peerId, peripheral);
        msgChar = _messagingChars[peerId];
      }

      if (msgChar == null || peripheral == null) {
        Logger.info('BleService: Peer not reachable: $peerId', 'BLE');
        return false;
      }

      final data = _serializeMessagePayload(
        payload,
        destinationUserId: _getAppUserIdForPeer(peerId),
      );
      await _central.writeCharacteristic(
        peripheral,
        msgChar,
        value: data,
        type: GATTCharacteristicWriteType.withResponse,
      );

      Logger.info('BleService: Message sent successfully', 'BLE');
      return true;
    } catch (e) {
      Logger.error('BleService: Message send failed', e, null, 'BLE');
      // Clear cached connection so it retries next time
      _messagingChars.remove(peerId);
      return false;
    }
  }

  @override
  Stream<ReceivedMessage> get messageReceivedStream =>
      _messageReceivedController.stream;

  Uint8List _serializeMessagePayload(MessagePayload payload,
      {String? destinationUserId}) {
    final ownUserId = _pendingPayload?.userId ?? '';
    final json = <String, dynamic>{
      'type': 'message',
      'sender_id': ownUserId,
      'message_type': payload.type.index,
      'message_id': payload.messageId,
      'content': payload.content,
      'timestamp': DateTime.now().toIso8601String(),
    };
    if (_meshRelayEnabled) {
      json['origin_id'] = ownUserId;
      json['destination_id'] = destinationUserId ?? '';
      json['ttl'] = config.meshTtl;
      json['relay_path'] = <String>[ownUserId];
    }
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  // ==================== Photo Transfer ====================

  // Track cancelled transfers so in-flight sends stop early
  final Set<String> _cancelledTransfers = {};

  @override
  Future<bool> sendPhoto(
      String peerId, Uint8List photoData, String messageId) async {
    _ensureInitialized();

    if (photoData.length > config.maxPhotoSize) {
      Logger.error(
        'BleService: Photo too large (${photoData.length} > ${config.maxPhotoSize})',
        null,
        null,
        'BLE',
      );
      return false;
    }

    Logger.info(
      'BleService: Starting photo transfer $messageId '
          '(${photoData.length} bytes) to ${peerId.substring(0, min(8, peerId.length))}',
      'BLE',
    );

    try {
      // Ensure we have a connection to this peer
      var msgChar = _messagingChars[peerId];
      var peripheral = _discoveredPeripherals[peerId];

      if (msgChar == null && peripheral != null) {
        await _connectAndReadProfile(peerId, peripheral);
        msgChar = _messagingChars[peerId];
      }

      if (msgChar == null || peripheral == null) {
        Logger.info('BleService: Peer not reachable for photo: $peerId', 'BLE');
        _photoProgressController.add(PhotoTransferProgress(
          messageId: messageId,
          peerId: peerId,
          progress: 0,
          status: PhotoTransferStatus.failed,
          errorMessage: 'Peer not reachable',
        ));
        return false;
      }

      // --- Binary photo transfer protocol ---
      //
      // iOS CoreBluetooth has a very limited "prepare queue" on the GATT
      // server side. Any writeWithResponse whose payload exceeds the ATT MTU
      // (~185 bytes iOS-to-iOS) gets split into Prepare Write + Execute Write
      // ATT operations, and the receiver's queue overflows (CBATTError code 9).
      //
      // To avoid this we use a two-phase binary protocol:
      //   Phase 1: Send a small JSON "photo_start" message with metadata.
      //   Phase 2: Send raw binary chunks with only 3 bytes overhead each:
      //            [0x02][uint16 chunk_index][raw photo bytes]
      //
      // This keeps every single write well under the ATT MTU.

      // Use a conservative max payload — iOS default ATT MTU is 185,
      // usable payload is MTU - 3 = 182 bytes.
      final maxWriteLen = _maxWriteLengths[peerId] ?? 182;
      // Binary chunk overhead: 1 (marker) + 2 (index) = 3 bytes
      const binaryOverhead = 3;
      final rawChunkSize = max(20, maxWriteLen - binaryOverhead);

      // Split photo into chunks
      final totalChunks = (photoData.length + rawChunkSize - 1) ~/ rawChunkSize;

      Logger.info(
        'BleService: Photo binary transfer: ${photoData.length}B, '
            '$totalChunks chunks (${rawChunkSize}B each, maxWrite=$maxWriteLen)',
        'BLE',
      );

      // Phase 1: Send photo_start metadata as JSON (no photo data, small payload)
      final startPayload = utf8.encode(jsonEncode({
        'type': 'photo_start',
        'sender_id': _pendingPayload?.userId ?? '',
        'message_id': messageId,
        'total_chunks': totalChunks,
        'total_size': photoData.length,
      }));

      await _central.writeCharacteristic(
        peripheral,
        msgChar,
        value: Uint8List.fromList(startPayload),
        type: GATTCharacteristicWriteType.withResponse,
      );

      await Future.delayed(const Duration(milliseconds: 50));

      // Emit starting progress
      _photoProgressController.add(PhotoTransferProgress(
        messageId: messageId,
        peerId: peerId,
        progress: 0,
        status: PhotoTransferStatus.starting,
      ));

      // Phase 2: Send binary chunks
      for (var i = 0; i < totalChunks; i++) {
        // Check if transfer was cancelled
        if (_cancelledTransfers.contains(messageId)) {
          _cancelledTransfers.remove(messageId);
          _photoProgressController.add(PhotoTransferProgress(
            messageId: messageId,
            peerId: peerId,
            progress: i / totalChunks,
            status: PhotoTransferStatus.cancelled,
          ));
          return false;
        }

        // Build binary payload: [0x02][uint16 chunk_index][raw data]
        final dataStart = i * rawChunkSize;
        final dataEnd = min(dataStart + rawChunkSize, photoData.length);
        final chunkData = photoData.sublist(dataStart, dataEnd);

        final payload = Uint8List(binaryOverhead + chunkData.length);
        payload[0] = 0x02; // photo chunk marker
        payload[1] = (i >> 8) & 0xFF; // chunk index high byte
        payload[2] = i & 0xFF; // chunk index low byte
        payload.setRange(binaryOverhead, payload.length, chunkData);

        await _central.writeCharacteristic(
          peripheral,
          msgChar,
          value: payload,
          type: GATTCharacteristicWriteType.withResponse,
        );

        // Pace writes to let the receiver's GATT server process each one
        if (i < totalChunks - 1) {
          await Future.delayed(const Duration(milliseconds: 50));
        }

        // Emit progress
        final progress = (i + 1) / totalChunks;
        _photoProgressController.add(PhotoTransferProgress(
          messageId: messageId,
          peerId: peerId,
          progress: progress,
          status: i == totalChunks - 1
              ? PhotoTransferStatus.completed
              : PhotoTransferStatus.inProgress,
        ));
      }

      Logger.info('BleService: Photo transfer completed: $messageId', 'BLE');
      return true;
    } catch (e) {
      Logger.error('BleService: Photo transfer failed', e, null, 'BLE');
      _messagingChars.remove(peerId);
      _photoProgressController.add(PhotoTransferProgress(
        messageId: messageId,
        peerId: peerId,
        progress: 0,
        status: PhotoTransferStatus.failed,
        errorMessage: e.toString(),
      ));
      return false;
    }
  }

  @override
  Stream<PhotoTransferProgress> get photoProgressStream =>
      _photoProgressController.stream;

  @override
  Stream<ReceivedPhoto> get photoReceivedStream =>
      _photoReceivedController.stream;

  @override
  Future<void> cancelPhotoTransfer(String messageId) async {
    Logger.info('BleService: Cancelling photo transfer $messageId', 'BLE');
    _cancelledTransfers.add(messageId);
    _photoReassembler.cancel(messageId);
  }

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
    _explicitBatterySaver = enabled;
    _updateScanTiming();
    Logger.info(
        'BleService: Battery saver ${enabled ? 'enabled' : 'disabled'} '
        '(scan ${_scanDuration.inSeconds}s / pause ${_scanPause.inSeconds}s)',
        'BLE');
  }

  /// Recalculates scan duration/pause based on explicit battery saver flag
  /// and current peer density.  Call after peer count changes or after
  /// toggling battery saver.
  void _updateScanTiming() {
    if (_explicitBatterySaver) {
      _scanDuration = _batteryScanDuration;
      _scanPause = _batteryScanPause;
      return;
    }
    final isHighDensity = _visiblePeers.length >= config.highDensityPeerThreshold;
    if (isHighDensity) {
      _scanDuration = _batteryScanDuration;
      _scanPause = config.highDensityScanPause;
    } else {
      _scanDuration = _normalScanDuration;
      _scanPause = config.normalScanPause;
    }
  }
}

/// Tracks an incoming binary photo transfer from a specific peer.
class _IncomingPhotoTransfer {
  _IncomingPhotoTransfer({
    required this.messageId,
    required this.totalChunks,
    required this.totalSize,
    required this.receivedData,
    required this.receivedCount,
  });

  final String messageId;
  final int totalChunks;
  final int totalSize;
  final BytesBuilder receivedData;
  int receivedCount;
}
