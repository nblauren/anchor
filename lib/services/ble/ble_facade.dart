import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/utils/logger.dart';
import '../encryption/encryption.dart';
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
/// - Peer tracking (visible peers, timeout timers)
/// - Incoming message dispatch (binary/JSON routing to the correct subsystem)
/// - Stream controllers for the public [BleServiceInterface] API
/// - Platform permissions (Android/iOS Bluetooth + location)
class BleFacade implements BleServiceInterface {
  BleFacade({
    required this.config,
    this.encryptionService,
  });

  final BleConfig config;

  /// Optional E2EE service.  When provided, messages are encrypted with
  /// Noise_XK / XChaCha20-Poly1305.  When null, encryption is skipped
  /// (backward-compatible plaintext mode).
  final EncryptionService? encryptionService;

  final _noiseHandshakeController =
      StreamController<NoiseHandshakeReceived>.broadcast();

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
  static final _messagingCharUuid =
      UUID.fromString('0000fff3-0000-1000-8000-00805f9b34fb');
  static final _fullPhotosCharUuid =
      UUID.fromString('0000fff4-0000-1000-8000-00805f9b34fb');
  static final _reversePathCharUuid =
      UUID.fromString('0000fff5-0000-1000-8000-00805f9b34fb');

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

  // Note: scan lifecycle, timing, dedup are now managed by BleScanner.
  // Profile reading, thumbnail/photo assembly are now managed by ProfileReader.
  // GATT server setup, reads, notifications, advertising are now managed by GattServer.

  // Subscriptions
  StreamSubscription? _centralStateSubscription;
  StreamSubscription? _charNotifiedSubscription;

  // In-memory message ID deduplication — capacity-bounded LRU cache.
  // Evicts the oldest entry when full instead of using fire-and-forget timers.
  final _seenMessageIds = _BoundedDedup(10000);

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
        encryptionService: encryptionService,
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

    await _noiseHandshakeController.close();
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
      final centralId = centralUuid.toString();

      // Binary photo chunk: first byte is 0x02
      if (data[0] == 0x02) {
        Logger.debug(
          'BleService: [RECV] Binary photo chunk (0x02) ${data.length}B '
          'from central=${centralId.substring(0, min(8, centralId.length))}',
          'BLE',
        );
        _photoTransfer.handleBinaryPhotoChunk(data, centralId);
        return;
      }

      // Binary thumbnail chunk (preview consent flow): first byte is 0x03
      if (data[0] == 0x03) {
        Logger.debug(
          'BleService: [RECV] Binary thumbnail chunk (0x03) ${data.length}B '
          'from central=${centralId.substring(0, min(8, centralId.length))}',
          'BLE',
        );
        _photoTransfer.handleBinaryThumbnailChunk(data, centralId);
        return;
      }

      // JSON payload (text messages, photo_start, legacy photo_chunk)
      final jsonStr = utf8.decode(data);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;

      final fromPeerId = _resolveSenderPeerId(json, centralUuid);
      final type = json['type'] as String? ?? 'message';

      Logger.info(
        'BleService: [RECV] type=$type from '
        'sender=${fromPeerId.substring(0, min(8, fromPeerId.length))} '
        'central=${centralId.substring(0, min(8, centralId.length))} '
        '(${data.length}B)',
        'BLE',
      );

      // Record Central UUID → userId mapping so TransportManager/PeerRegistry
      // can resolve this peer even before GATT profile scanning discovers them.
      // Critical on Android where GATT reads are less reliable: the sender_id
      // in the message payload gives us the userId before profile reading does.
      if (fromPeerId != centralId && fromPeerId.isNotEmpty) {
        final senderName = json['sender_name'] as String?;
        _registerCentralAsPeer(centralId, fromPeerId, senderName);
      }

      // Peer is alive — refresh their timeout timer.
      // Try both the Central UUID and the resolved userId — _peerTimeoutTimers
      // may be keyed by either depending on which was discovered first.
      _refreshPeerTimeout(centralId);
      if (fromPeerId != centralId) {
        _refreshPeerTimeout(fromPeerId);
      }

      // If we received a message from a Central that we haven't discovered
      // as a Peripheral yet, trigger an immediate scan so we can establish
      // the reverse connection and send messages back.
      if (!_connectionManager.canSendTo(fromPeerId) &&
          _connectionManager.getPeripheral(fromPeerId) == null) {
        _scanner.triggerImmediateScan();
      }

      if (type == 'photo_start') {
        _photoTransfer.handlePhotoStart(json, fromPeerId, centralId: centralId);
      } else if (type == 'photo_chunk') {
        _photoTransfer.handleReceivedPhotoChunk(json, fromPeerId);
      } else if (type == 'photo_preview') {
        _photoTransfer.handlePhotoPreviewStart(json, fromPeerId, centralId: centralId);
      } else if (type == 'photo_request') {
        _photoTransfer.handlePhotoRequest(json, fromPeerId);
      } else if (type == 'peer_announce') {
        _meshRelay.handlePeerAnnounce(json, fromPeerId);
      } else if (type == 'neighbor_list') {
        _meshRelay.handleNeighborList(json);
      } else if (type == 'noise_hs') {
        _handleNoiseHandshake(json, fromPeerId);
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

  /// Resolve the sender's canonical peer ID from the payload's sender_id
  /// field. The canonical ID is always the app-level userId (stable UUID).
  /// Falls back to the Central UUID only if sender_id is missing (rare edge
  /// case for very old clients).
  String _resolveSenderPeerId(Map<String, dynamic> json, UUID centralUuid) {
    final senderId = json['sender_id'] as String?;
    if (senderId != null && senderId.isNotEmpty) {
      return senderId;
    }
    return centralUuid.toString();
  }

  void _handleReceivedMessage(Map<String, dynamic> json, String fromPeerId) {
    final messageId = json['message_id'] as String? ?? '';

    // Deduplicate — BLE transport can retransmit the same write.
    // Uses a capacity-bounded LRU cache (no timers, no memory leaks).
    if (messageId.isNotEmpty) {
      if (!_seenMessageIds.tryAdd(messageId)) {
        Logger.info('BleService: Duplicate message ignored: $messageId', 'BLE');
        return;
      }
    }

    // Mesh routing: check if this message is addressed to us
    final destinationId = json['destination_id'] as String?;
    final ownUserId = _gattServer.ownUserId;
    final isForUs = destinationId == null ||
        destinationId.isEmpty ||
        destinationId == ownUserId;

    if (isForUs) {
      // E2EE decryption: if v == 1, decrypt ciphertext using the active session.
      // v == 0 (or absent) = plaintext / old client — deliver as-is.
      final enc = encryptionService;
      final encPayload = enc?.parseEncryptedFields(json);

      String content;
      String? replyToId = json['reply_to_id'] as String?;

      if (encPayload != null && enc != null) {
        // Decrypt the inner envelope asynchronously, then emit.
        enc.decrypt(fromPeerId, encPayload).then((plaintextBytes) {
          if (plaintextBytes == null) {
            // Decryption failed — drop the message (auth error / no session).
            Logger.warning(
              'E2EE decrypt failed for message from ${fromPeerId.substring(0, min(8, fromPeerId.length))} — dropped',
              'E2EE',
            );
            return;
          }
          try {
            final inner =
                jsonDecode(utf8.decode(plaintextBytes)) as Map<String, dynamic>;
            final decryptedContent = inner['content'] as String? ?? '';
            final decryptedReplyTo = inner['reply_to_id'] as String?;
            final messageType =
                MessageType.values[json['message_type'] as int? ?? 0];
            final message = ReceivedMessage(
              fromPeerId: fromPeerId,
              messageId: messageId,
              type: messageType,
              content: decryptedContent,
              timestamp: DateTime.now(),
              replyToId: decryptedReplyTo,
              isEncrypted: true,
            );
            _messageReceivedController.add(message);
            Logger.info(
              'BleService: Decrypted message from '
                  '${fromPeerId.substring(0, min(8, fromPeerId.length))} 🔒',
              'E2EE',
            );
          } catch (e) {
            Logger.error('E2EE inner envelope parse failed', e, null, 'E2EE');
          }
        });
        return; // Async path — return early; emission happens in the callback above.
      }

      // Plaintext path (no encryption or old client)
      content = json['content'] as String? ?? '';
      final message = ReceivedMessage(
        fromPeerId: fromPeerId,
        messageId: messageId,
        type: MessageType.values[json['message_type'] as int? ?? 0],
        content: content,
        timestamp: DateTime.now(),
        replyToId: replyToId,
        isEncrypted: false,
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

  // ── Noise_XK handshake dispatch ───────────────────────────────────────────

  /// Route incoming Noise_XK handshake messages to [EncryptionService].
  ///
  /// Wire JSON:
  ///   { "type": "noise_hs", "step": 1|2|3, "payload": "<base64>", "sender_id": "..." }
  void _handleNoiseHandshake(Map<String, dynamic> json, String fromPeerId) {
    final step = json['step'] as int?;
    final payloadB64 = json['payload'] as String?;
    if (step == null || payloadB64 == null) {
      Logger.warning('Malformed noise_hs message from $fromPeerId', 'E2EE');
      return;
    }
    _noiseHandshakeController.add(NoiseHandshakeReceived(
      fromPeerId: fromPeerId,
      step: step,
      payload: Uint8List.fromList(base64.decode(payloadB64)),
    ));
  }

  @override
  Stream<NoiseHandshakeReceived> get noiseHandshakeStream =>
      _noiseHandshakeController.stream;

  /// Send an outbound Noise handshake message to a peer via BLE fff3.
  ///
  /// Called by TransportManager to send an outbound Noise_XK handshake step
  /// to a BLE peer. [peerId] must be the BLE peripheral UUID (TransportManager
  /// resolves canonical userId -> BLE UUID before calling this).
  @override
  Future<void> sendHandshakeMessage(
      String peerId, int step, Uint8List payload) async {
    // Clear dead-peer status so connection attempts aren't silently blocked.
    _connectionManager.clearDeadStatus(peerId);

    var conn = _connectionManager.getConnection(peerId);
    if (conn == null || !conn.canSendMessages) {
      final peripheral = _connectionManager.getPeripheral(peerId);
      Logger.debug(
        'sendHandshakeMessage step $step: no active connection to $peerId, '
        'peripheral=${peripheral != null ? "found" : "null"}',
        'E2EE',
      );
      if (peripheral != null) {
        conn = await _connectionManager.connect(peerId, peripheral);
      }
    }
    // The responder may not yet have a connection back to the initiator.
    // Subscribe to connection events and wait for the peer to connect,
    // instead of polling with fixed delays.
    if (conn == null || !conn.canSendMessages) {
      _scanner.triggerImmediateScan();
      _connectionManager.clearDeadStatus(peerId);

      final connCompleter = Completer<void>();
      StreamSubscription<String>? connSub;
      connSub = _connectionManager.onConnected
          .where((id) => id == peerId)
          .listen((_) {
        if (!connCompleter.isCompleted) connCompleter.complete();
        connSub?.cancel();
      });

      try {
        await connCompleter.future.timeout(const Duration(seconds: 15));
        conn = _connectionManager.getConnection(peerId);
      } on TimeoutException {
        Logger.warning(
          'sendHandshakeMessage step $step: peer $peerId not connectable '
          'after 15s — trying reverse path',
          'E2EE',
        );
      } finally {
        connSub.cancel();
      }
    }
    if (conn == null || !conn.canSendMessages) {
      // Direct outbound connection unavailable. Try bidirectional path: if
      // the peer connected to OUR GATT server as a Central and subscribed to
      // fff3 notify, we can push the handshake via fff3. Falls back to fff5.
      final hsJson = <String, dynamic>{
        'type': 'noise_hs',
        'step': step,
        'payload': base64.encode(payload),
        'sender_id': _gattServer.ownUserId,
      };
      final hsData = Uint8List.fromList(utf8.encode(jsonEncode(hsJson)));

      // Try fff3 bidirectional first, falls back to fff5 reverse-path.
      final sent = await _gattServer.sendToCentralViaFff3(peerId, hsData);
      if (sent) {
        Logger.info(
          'Handshake step $step sent via GATT notify to $peerId',
          'E2EE',
        );
        return;
      }

      Logger.warning(
        'Cannot send handshake step $step — peer $peerId not connected '
        '(no outbound connection, no fff3/fff5 path)',
        'E2EE',
      );
      return;
    }
    final json = <String, dynamic>{
      'type': 'noise_hs',
      'step': step,
      'payload': base64.encode(payload),
      'sender_id': _gattServer.ownUserId,
    };
    final data = Uint8List.fromList(utf8.encode(jsonEncode(json)));
    Logger.info(
      'sendHandshakeMessage step $step: writing ${data.length}B via fff3 to '
      '${peerId.substring(0, min(8, peerId.length))}',
      'E2EE',
    );
    final sent = await _writeQueue
        .enqueue(
      peerId: peerId,
      peripheral: conn.peripheral,
      characteristic: conn.messagingChar!,
      data: data,
      priority: WritePriority.userMessage,
    )
        .catchError((Object e) {
      Logger.error('Handshake write failed for $peerId', e, null, 'E2EE');
      return false;
    });
    Logger.info(
      'sendHandshakeMessage step $step: write result=$sent for '
      '${peerId.substring(0, min(8, peerId.length))}',
      'E2EE',
    );
  }

  @override
  String? resolveToPeripheralId(String peerId) {
    // PeerRegistry handles Central → Peripheral resolution at a higher level.
    // This BLE-level method no longer maintains its own mapping.
    return null;
  }

  /// Returns the app userId for a given BLE peripheral UUID, or null if
  /// the mapping hasn't been established yet (peer profile not yet read).
  String? _getAppUserIdForPeer(String blePeerId) {
    return _visiblePeers[blePeerId]?.userId;
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

  @override
  void suppressMeshRelay() {
    _meshRelay.suppressBroadcasts();
    // Flush any pending mesh relay writes from the GATT queue so the
    // hardware prepare queue is clear for critical signals.
    _writeQueue.cancelPriority(WritePriority.meshRelay);
  }

  @override
  void resumeMeshRelay() {
    _meshRelay.resumeBroadcasts();
  }

  /// Called by MeshRelayService when a relayed peer is discovered via mesh.
  void _onRelayedPeerDiscovered(RelayedPeerResult result) {
    final peer = result.peer;
    _visiblePeers[peer.peerId] = peer;
    _peerTimeoutTimers[peer.peerId]?.cancel();
    _peerTimeoutTimers[peer.peerId] = Timer(
      config.peerLostTimeout,
      () => _onPeerLost(peer.peerId),
    );

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
    // Embed our X25519 public key in the profile so peers can store it
    // for Noise_XK handshake initiation when they open a chat with us.
    final myPublicKeyHex = encryptionService?.localPublicKeyHex;
    if (myPublicKeyHex == null) {
      Logger.warning(
          'broadcastProfile: E2EE public key not ready — profile will NOT include pk',
          'E2EE');
    } else {
      Logger.debug(
          'broadcastProfile: embedding pk ${myPublicKeyHex.substring(0, 8)}…',
          'E2EE');
    }
    final payloadWithKey = myPublicKeyHex != null
        ? BroadcastPayload(
            userId: payload.userId,
            name: payload.name,
            age: payload.age,
            bio: payload.bio,
            position: payload.position,
            interests: payload.interests,
            thumbnailBytes: payload.thumbnailBytes,
            thumbnailsList: payload.thumbnailsList,
            publicKeyHex: myPublicKeyHex,
          )
        : payload;
    await _gattServer.broadcastProfile(payloadWithKey);
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
  void _onScannerPeerDiscovered(
      String peerId, String name, int? age, int rssi, Peripheral peripheral) {
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
      userId: existing?.userId,
      age: age ?? existing?.age,
      bio: existing?.bio,
      thumbnailBytes: existing?.thumbnailBytes,
      rssi: rssi,
      timestamp: DateTime.now(),
      // Preserve the E2EE public key fetched during the previous profile read.
      // Without this, every scan cycle would overwrite _visiblePeers with a
      // peer that has publicKeyHex = null, breaking key storage in TransportManager.
      publicKeyHex: existing?.publicKeyHex,
    );
    _emitPeer(peer);
  }

  /// Called by BleScanner when a discovered peer needs its profile read.
  /// Do NOT refresh the peer timeout here — scan results may come from iOS
  /// Core Bluetooth cache long after a peer has left range. The timeout is
  /// only refreshed in [_onProfileReadResult] after a confirmed GATT read.
  void _onScannerPeerNeedsProfile(String peerId, Peripheral peripheral) {
    _profileReader.readProfile(peerId, peripheral);
  }

  /// Called by ProfileReader when a profile is read from a peer.
  Future<void> _onProfileReadResult(ProfileReadResult result) async {
    final peerId = result.peerId;
    final json = result.profileJson;
    final existingPeer = _visiblePeers[peerId];
    if (existingPeer == null) return;

    _refreshPeerTimeout(peerId);

    final userId = json['userId'] as String?;

    // Extract E2EE public key now; store it AFTER _emitPeer so that
    // TransportManager._migrateIfNeeded (triggered by _emitPeer) sets
    // _bleIdForCanonical before peerKeyStoredStream fires.
    final peerPublicKeyHex = json['pk'] as String?;

    // If this peer was previously tracked under a different BLE UUID
    // (e.g. MAC rotation), emit PeerIdChanged so consumers can update
    // their BLE connection caches.
    if (userId != null && userId.isNotEmpty) {
      // Check if another BLE UUID in _visiblePeers has the same userId
      // (MAC rotation scenario).
      for (final entry in _visiblePeers.entries) {
        if (entry.key != peerId && entry.value.userId == userId) {
          Logger.info(
            'BleService: userId $userId rotated BLE UUID '
                '${entry.key} → $peerId, retiring stale entry',
            'BLE',
          );
          _peerIdChangedController.add(PeerIdChanged(
            oldPeerId: entry.key,
            newPeerId: peerId,
            userId: userId,
          ));
          _onPeerLost(entry.key);
          break;
        }
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
    // IMPORTANT: userId MUST be included — when the first successful GATT
    // profile read resolves the userId (previously null from scan-only), we
    // must emit even if name/age/bio happen to match the advertisement data.
    // Without this, the peer stays userId=null in the stream and never reaches
    // TransportManager, appearing as "Unknown" in the UI.
    final unchanged = userId == existingPeer.userId &&
        newName == existingPeer.name &&
        newAge == existingPeer.age &&
        newBio == existingPeer.bio &&
        newPosition == existingPeer.position &&
        newInterests == existingPeer.interests &&
        newPhotoCount == existingPeer.fullPhotoCount;

    if (unchanged) return;

    final updatedPeer = DiscoveredPeer(
      peerId: peerId,
      name: newName,
      userId: userId,
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
      // Include E2EE public key so TransportManager stores it under the
      // canonical peer ID (after _migrateIfNeeded resolves BLE UUID → LAN UUID).
      publicKeyHex: peerPublicKeyHex?.length == 64 ? peerPublicKeyHex : null,
    );

    _emitPeer(updatedPeer);

    // Store the peer's E2EE public key directly — the DiscoveredPeer relay
    // path (peer.publicKeyHex → TransportManager) can be null if the key is
    // absent from the profile, but we always have the raw JSON here.
    if (peerPublicKeyHex != null && peerPublicKeyHex.length == 64) {
      encryptionService?.storePeerPublicKey(peerId, peerPublicKeyHex);
    }

    // Record the profile version from the GATT read so the scanner can
    // skip future reads when the advertised version hasn't changed.
    final profileVersion = json['pv'] as int?;
    if (profileVersion != null) {
      _scanner.recordProfileVersion(peerId, profileVersion);
    }

    Logger.info(
      'BleService: Updated profile for "${updatedPeer.name}"'
      '${peerPublicKeyHex != null ? " (pk=${peerPublicKeyHex.substring(0, 8)}…)" : ""}'
      '${profileVersion != null ? " (pv=$profileVersion)" : ""}',
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
  /// Routes to the appropriate handler based on the characteristic UUID.
  void _onCharacteristicNotified(GATTCharacteristicNotifiedEventArgs args) {
    final peerId = args.peripheral.uuid.toString();
    final charUuid = args.characteristic.uuid;
    if (charUuid == _thumbnailCharUuid) {
      _profileReader.handleThumbnailChunk(peerId, args.value);
    } else if (charUuid == _fullPhotosCharUuid) {
      _profileReader.handleFullPhotosChunk(peerId, args.value);
    } else if (charUuid == _messagingCharUuid) {
      // fff3 bidirectional messaging: the remote Peripheral pushed a message
      // back to us (Central) via fff3 notify. This eliminates the need for a
      // separate reverse GATT connection for bidirectional communication.
      Logger.info(
        'BleService: Received fff3 notify (bidirectional) from '
        '${peerId.substring(0, min(8, peerId.length))} '
        '(${args.value.length}B)',
        'BLE',
      );
      _onFff3Notification(peerId, Uint8List.fromList(args.value));
    } else if (charUuid == _reversePathCharUuid) {
      // Reverse-path (legacy): the remote Peripheral pushed data back to us
      // via fff5 notify. Used for cross-platform handshake responses.
      _onReversePathNotification(peerId, Uint8List.fromList(args.value));
    }
  }

  /// Process an fff3 notification received from a Peripheral (bidirectional path).
  ///
  /// Uses the same dispatch logic as _onMessageWriteReceived but the sender
  /// is identified by their Peripheral UUID (which we connected to as Central).
  void _onFff3Notification(String peerId, Uint8List data) {
    try {
      // Binary photo chunks use the same dispatch as write-received.
      if (data.isNotEmpty && (data[0] == 0x02 || data[0] == 0x03)) {
        if (data[0] == 0x02) {
          _photoTransfer.handleBinaryPhotoChunk(data, peerId);
        } else {
          _photoTransfer.handleBinaryThumbnailChunk(data, peerId);
        }
        return;
      }

      final jsonStr = utf8.decode(data);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final type = json['type'] as String? ?? 'message';

      _refreshPeerTimeout(peerId);

      Logger.info(
        'BleService: Received fff3-notify $type from '
        '${peerId.substring(0, min(8, peerId.length))}',
        'BLE',
      );

      if (type == 'noise_hs') {
        _handleNoiseHandshake(json, peerId);
      } else if (type == 'drop_anchor') {
        _handleDropAnchor(peerId);
      } else if (type == 'reaction') {
        _handleReaction(json, peerId);
      } else {
        _handleReceivedMessage(json, peerId);
      }
    } catch (e) {
      Logger.error(
          'BleService: fff3 notification processing failed', e, null, 'BLE');
    }
  }

  /// Process a reverse-path fff3 notification received from a Peripheral.
  ///
  /// The sender is identified by their Peripheral UUID (which we connected to
  /// as Central), not a Central UUID. This is the same peerId used in our
  /// ConnectionManager and _visiblePeers mappings.
  void _onReversePathNotification(String peerId, Uint8List data) {
    try {
      final jsonStr = utf8.decode(data);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final type = json['type'] as String? ?? 'message';

      _refreshPeerTimeout(peerId);

      Logger.info(
        'BleService: Received reverse-path $type from '
        '${peerId.substring(0, min(8, peerId.length))}',
        'BLE',
      );

      if (type == 'noise_hs') {
        _handleNoiseHandshake(json, peerId);
      } else {
        _handleReceivedMessage(json, peerId);
      }
    } catch (e) {
      Logger.error(
          'BleService: Reverse-path notification failed', e, null, 'BLE');
    }
  }

  @override
  Future<bool> fetchFullProfilePhotos(String peerId) async {
    return _profileReader.fetchFullProfilePhotos(peerId);
  }

  /// Register a Central connection as a known peer when we learn their userId
  /// from a message's sender_id field. This handles the case where a peer
  /// sends us a message before we've scanned and profile-read them (common on
  /// Android where GATT reads are less reliable).
  ///
  /// Emits a minimal DiscoveredPeer through the normal stream so
  /// TransportManager/PeerRegistry maps Central UUID → userId. This ensures
  /// reply messages route correctly even if GATT profile reading hasn't
  /// completed yet.
  void _registerCentralAsPeer(
      String centralId, String userId, String? senderName) {
    // Check if we already have this Central UUID mapped to the correct userId.
    final existing = _visiblePeers[centralId];
    if (existing != null && existing.userId == userId) return;

    // Check if we already have this userId via a different BLE UUID (peripheral scan).
    final hasViaPeripheral = _visiblePeers.values.any(
      (p) => p.userId == userId && p.peerId != centralId,
    );
    if (hasViaPeripheral) return;

    Logger.info(
      'BleService: Registering Central $centralId as userId '
      '${userId.substring(0, min(8, userId.length))}',
      'BLE',
    );

    // Create or update the _visiblePeers entry with the Central UUID as key.
    final peer = DiscoveredPeer(
      peerId: centralId,
      name: senderName ?? existing?.name ?? 'Anchor User',
      userId: userId,
      age: existing?.age,
      bio: existing?.bio,
      thumbnailBytes: existing?.thumbnailBytes,
      rssi: existing?.rssi,
      timestamp: DateTime.now(),
      publicKeyHex: existing?.publicKeyHex,
    );
    _emitPeer(peer);
  }

  void _emitPeer(DiscoveredPeer peer) {
    final isNew = !_visiblePeers.containsKey(peer.peerId);
    _visiblePeers[peer.peerId] = peer;

    // Only emit to the stream once we have a userId from a successful GATT
    // profile read. Peers without a userId are kept in _visiblePeers (so
    // _onProfileReadResult can find them) but must NOT reach TransportManager
    // or the UI — otherwise they appear as "Unknown" with the raw BLE UUID
    // as their canonical ID, causing messages to route to the wrong device.
    if (peer.userId != null) {
      _peerDiscoveredController.add(peer);
    }
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

    final ownId = _gattServer.ownUserId;
    Logger.info(
      'BleService: [SEND] type=${payload.type.name} '
      'msgId=${payload.messageId.substring(0, min(8, payload.messageId.length))} '
      'from=${ownId.substring(0, min(8, ownId.length))} '
      'to=${peerId.substring(0, min(8, peerId.length))} '
      '(connected=${_connectionManager.isConnected(peerId)}, '
      'canSend=${_connectionManager.canSendTo(peerId)})',
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
        if (_meshRelay.enabled &&
            _connectionManager.activeConnectionCount > 0) {
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

      final data = await _serializeMessagePayloadEncrypted(
        payload,
        peerId: peerId,
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
        Logger.info(
          'BleService: [SEND OK] ${payload.type.name} '
          '${payload.messageId.substring(0, min(8, payload.messageId.length))} '
          'to ${peerId.substring(0, min(8, peerId.length))} (${data.length}B)',
          'BLE',
        );
        _connectionManager.touchPeer(peerId);
        _refreshPeerTimeout(peerId);
      } else {
        Logger.warning(
          'BleService: [SEND FAIL] ${payload.type.name} '
          '${payload.messageId.substring(0, min(8, payload.messageId.length))} '
          'to ${peerId.substring(0, min(8, peerId.length))} — write queue rejected',
          'BLE',
        );
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
      final ownName = _gattServer.pendingPayload?.name;
      final destinationUserId = _getAppUserIdForPeer(peerId);
      final anchorPayload = <String, dynamic>{
        'type': 'drop_anchor',
        'sender_id': ownUserId,
        if (ownName != null && ownName.isNotEmpty) 'sender_name': ownName,
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
        if (_meshRelay.enabled &&
            _connectionManager.activeConnectionCount > 0) {
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
      final ownName = _gattServer.pendingPayload?.name;
      final payload = <String, dynamic>{
        'type': 'reaction',
        'sender_id': ownUserId,
        if (ownName != null && ownName.isNotEmpty) 'sender_name': ownName,
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

  /// Serialize a [MessagePayload] to bytes for writing to fff3.
  ///
  /// When an E2EE session exists for [peerId] (and [encryptionService] is
  /// injected), the message content is encrypted with XChaCha20-Poly1305.
  /// The outer JSON carries `v:1, n:<nonce>, c:<ciphertext>` and the
  /// plaintext `content` field is OMITTED.
  ///
  /// Old clients (no E2EE) omit `v` and carry plaintext `content` as before.
  /// Synchronous serialization (used for mesh relay path — no E2EE for relayed
  /// messages since we don't know the final hop's session state).
  Uint8List _serializeMessagePayload(MessagePayload payload,
      {String? destinationUserId}) {
    final ownUserId = _gattServer.ownUserId;
    final ownName = _gattServer.pendingPayload?.name;
    final json = <String, dynamic>{
      'type': 'message',
      'sender_id': ownUserId,
      // Include sender name so the receiver can display it immediately even
      // before GATT profile reading completes (common on Android where GATT
      // reads are less reliable).
      if (ownName != null && ownName.isNotEmpty) 'sender_name': ownName,
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

  /// Async serialization with optional E2EE encryption.
  ///
  /// When [EncryptionService] has an active session for [peerId], the message
  /// content is encrypted with XChaCha20-Poly1305 before serialisation.
  /// Outer JSON: `{ ..., "v":1, "n":"<nonce>", "c":"<ciphertext>" }`.
  /// Plaintext `content` is OMITTED from the outer JSON when encrypted.
  ///
  /// Fallback: if encryption fails or no session exists, sends unencrypted
  /// with `"v":0` (or omits `v`) so old clients still understand the message.
  Future<Uint8List> _serializeMessagePayloadEncrypted(
    MessagePayload payload, {
    required String peerId,
    String? destinationUserId,
  }) async {
    final ownUserId = _gattServer.ownUserId;
    final enc = encryptionService;

    // Attempt to encrypt if we have an active E2EE session
    if (enc != null && enc.hasSession(peerId)) {
      // Build the inner plaintext envelope (the part we want to keep secret)
      final innerMap = <String, dynamic>{
        'content': payload.content,
        if (payload.replyToId != null) 'reply_to_id': payload.replyToId,
      };
      final innerBytes = Uint8List.fromList(utf8.encode(jsonEncode(innerMap)));

      final encrypted = await enc.encrypt(peerId, innerBytes);
      if (encrypted != null) {
        final ownName = _gattServer.pendingPayload?.name;
        final json = <String, dynamic>{
          'type': 'message',
          'sender_id': ownUserId,
          if (ownName != null && ownName.isNotEmpty) 'sender_name': ownName,
          'message_type': payload.type.index,
          'message_id': payload.messageId,
          'timestamp': DateTime.now().toIso8601String(),
          ...enc.encryptedFields(encrypted), // adds v, n, c
        };
        if (_meshRelay.enabled) {
          json['origin_id'] = ownUserId;
          json['destination_id'] = destinationUserId ?? '';
          json['ttl'] = config.meshTtl;
          json['relay_path'] = <String>[ownUserId];
        }
        return Uint8List.fromList(utf8.encode(jsonEncode(json)));
      }
    }

    // No session or encryption failed — fall back to plaintext
    return _serializeMessagePayload(payload,
        destinationUserId: destinationUserId);
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
    if (_visiblePeers.containsKey(peerId)) return true;
    // Also check by userId — peerId might be a BLE UUID while _visiblePeers
    // is keyed by Central UUID (or vice versa after _registerCentralAsPeer).
    return _visiblePeers.values.any((p) => p.userId == peerId);
  }

  @override
  String? getPeerIdForUserId(String userId) {
    for (final entry in _visiblePeers.entries) {
      if (entry.value.userId == userId) return entry.key;
    }
    return null;
  }

  @override
  List<String> get visiblePeerIds => _visiblePeers.keys.toList();

  @override
  Future<void> setBatterySaverMode(bool enabled) async {
    _scanner.setBatterySaverMode(enabled);
    Logger.info(
        'BleService: Battery saver ${enabled ? 'enabled' : 'disabled'}', 'BLE');
  }
}

/// Capacity-bounded message dedup using a [LinkedHashSet] as an LRU cache.
///
/// Replaces fire-and-forget [Future.delayed] eviction with deterministic
/// capacity-based eviction: when full, the oldest entry is removed.
/// No timers, no memory leaks, no risk of post-dispose callbacks.
class _BoundedDedup {
  _BoundedDedup(this.capacity);

  final int capacity;
  final _cache = <String>{}; // insertion-ordered LinkedHashSet

  /// Returns true if [id] is NEW (not seen before). Adds it to the cache.
  /// Returns false if [id] was already seen (duplicate).
  bool tryAdd(String id) {
    if (_cache.contains(id)) return false;
    if (_cache.length >= capacity) {
      _cache.remove(_cache.first); // evict oldest
    }
    _cache.add(id);
    return true;
  }
}
