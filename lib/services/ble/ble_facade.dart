import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:anchor/core/constants/message_keys.dart';
import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/services/ble/binary_message_codec.dart';
import 'package:anchor/services/ble/ble_config.dart';
import 'package:anchor/services/ble/ble_models.dart';
import 'package:anchor/services/ble/ble_service_interface.dart';
import 'package:anchor/services/ble/connection/connection_manager.dart';
import 'package:anchor/services/ble/discovery/ble_scanner.dart';
import 'package:anchor/services/ble/discovery/profile_reader.dart';
import 'package:anchor/services/ble/gatt/gatt_server.dart';
import 'package:anchor/services/ble/gatt/gatt_write_queue.dart';
import 'package:anchor/services/ble/mesh/mesh_relay_service.dart';
import 'package:anchor/services/ble/transfer/photo_transfer_handler.dart';
import 'package:anchor/services/encryption/encryption.dart';
import 'package:anchor/services/mesh/gossip_sync_service.dart';
import 'package:anchor/services/mesh/mesh_packet.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    this.gossipSyncService,
  });

  final BleConfig config;

  /// Optional E2EE service.  When provided, messages are encrypted with
  /// Noise_XK / XChaCha20-Poly1305.  When null, encryption is skipped
  /// (backward-compatible plaintext mode).
  final EncryptionService? encryptionService;

  /// Optional gossip sync service for GCS-based message reconciliation.
  final GossipSyncService? gossipSyncService;

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

  // UUIDs — centralized in BleUuids (ble_config.dart)
  static final _thumbnailCharUuid = BleUuids.thumbnailChar;
  static final _messagingCharUuid = BleUuids.messagingChar;
  static final _fullPhotosCharUuid = BleUuids.fullPhotosChar;
  static final _reversePathCharUuid = BleUuids.reversePathChar;

  // Status
  BleStatus _status = BleStatus.disabled;
  bool _isInitialized = false;

  /// Cached set of blocked peer IDs.  Checked at the transport layer to
  /// reject messages from blocked peers before they consume BLE bandwidth
  /// or queue space.  Updated by the presentation layer (SettingsBloc /
  /// DiscoveryBloc) whenever the block list changes.
  final Set<String> _blockedPeerIds = {};

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
  StreamSubscription<BluetoothLowEnergyStateChangedEventArgs>? _centralStateSubscription;
  StreamSubscription<GATTCharacteristicNotifiedEventArgs>? _charNotifiedSubscription;

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
      _profileReader
        ..loadPersistedSizes()
        ..onProfileRead = _onProfileReadResult
        ..onThumbnailAssembled = _onThumbnailAssembled
        ..onPhotosAssembled = _onPhotosAssembled
        ..onFullPhotosAssembled = _onFullPhotosAssembled;

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
      // Ed25519 announce signing: wire EncryptionService sign/verify into mesh relay
      _meshRelay.signData = (data) async =>
          await encryptionService?.sign(data);
      _meshRelay.verifySignature = (data, sig, pk) async =>
          await encryptionService?.verify(data, sig, pk) ?? false;

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
    } on Exception catch (e) {
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
    } on Exception catch (e) {
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
      case BluetoothLowEnergyState.poweredOff:
        _setStatus(BleStatus.disabled);
      case BluetoothLowEnergyState.unauthorized:
        _setStatus(BleStatus.noPermission);
      case BluetoothLowEnergyState.unsupported:
        _setStatus(BleStatus.disabled);
      case BluetoothLowEnergyState.unknown:
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

      // ── Binary MeshPacket (version byte 0x01) ─────────────────────────
      // First byte != '{' (0x7B) and is 0x01 → binary MeshPacket wire format.
      if (BinaryMessageCodec.isBinary(data) && data[0] == 0x01) {
        _handleBinaryPacket(data, centralId, centralUuid);
        return;
      }

      // ── Legacy JSON payload (text messages, photo_start, etc.) ─────────
      final jsonStr = utf8.decode(data);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;

      final fromPeerId = _resolveSenderPeerId(json, centralUuid);
      final type = json[MessageKeys.type] as String? ?? MessageTypes.message;

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
        final senderName = json[MessageKeys.senderName] as String?;
        _registerCentralAsPeer(centralId, fromPeerId, senderName);
      }

      // Transport-layer block filtering: reject messages from blocked peers
      // before they consume queue space or processing time.
      if (_blockedPeerIds.contains(fromPeerId) ||
          _blockedPeerIds.contains(centralId)) {
        Logger.debug(
          'BLE: Rejected message from blocked peer $fromPeerId (type=$type)',
          'BLE',
        );
        return;
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

      if (type == MessageTypes.profileRequest) {
        _handleProfileRequest(centralId);
      } else if (type == MessageTypes.profileData) {
        _handleProfileData(json, centralId);
      } else if (type == MessageTypes.photoStart) {
        _photoTransfer.handlePhotoStart(json, fromPeerId, centralId: centralId);
      } else if (type == MessageTypes.photoChunk) {
        _photoTransfer.handleReceivedPhotoChunk(json, fromPeerId);
      } else if (type == MessageTypes.photoPreview) {
        _photoTransfer.handlePhotoPreviewStart(json, fromPeerId, centralId: centralId);
      } else if (type == MessageTypes.photoRequest) {
        _photoTransfer.handlePhotoRequest(json, fromPeerId);
      } else if (type == MessageTypes.peerAnnounce) {
        _meshRelay.handlePeerAnnounce(json, fromPeerId);
      } else if (type == MessageTypes.neighborList) {
        _meshRelay.handleNeighborList(json);
        // Reverse profile exchange: neighbor_list is the "I'm an Anchor peer"
        // signal sent after connection is stable. Safe to request profile here
        // — the handshake hasn't started yet or is already complete.
        _requestProfileFromCentralIfNeeded(centralId);
      } else if (type == MessageTypes.noiseHandshake) {
        _handleNoiseHandshake(json, fromPeerId);
      } else if (type == MessageTypes.dropAnchor) {
        _handleDropAnchor(fromPeerId);
      } else if (type == MessageTypes.reaction) {
        _handleReaction(json, fromPeerId);
      } else {
        _handleReceivedMessage(json, fromPeerId);
      }
    } on Exception catch (e) {
      Logger.error('BleService: Write receive failed', e, null, 'BLE');
    }
  }

  /// Handle an incoming binary MeshPacket (version byte 0x01).
  ///
  /// Decodes the packet, resolves sender identity, applies block filtering,
  /// and dispatches to the appropriate handler based on [PacketType].
  void _handleBinaryPacket(Uint8List data, String centralId, UUID centralUuid) {
    final decoded = BinaryMessageCodec.decode(data);
    if (decoded == null) {
      Logger.warning('BLE: Failed to decode binary MeshPacket (${data.length}B)', 'BLE');
      return;
    }

    final packet = decoded.packet;

    // Resolve the Central UUID to the peer ID we use for E2EE sessions and
    // _visiblePeers. On iOS, a device's Central UUID differs from its
    // Peripheral UUID (which is how we originally discovered and keyed them).
    // Without this resolution, enc.decrypt(centralId) finds no session and
    // silently drops the message.
    //
    // Resolution order:
    //   1. _visiblePeers[centralId] exists → Central is already keyed (Android
    //      or pre-registered via _registerCentralAsPeer)
    //   2. Look up userId from _visiblePeers keyed by centralId, then find
    //      the Peripheral UUID entry with the same userId
    //   3. Fall back to centralId (first message before profile read)
    final fromPeerId = _resolveIncomingPeerId(
      centralId,
      truncatedSenderId: packet.senderId,
    );

    // Ed25519 signature verification (non-blocking, graceful degradation).
    // If the packet has a signature, attempt to verify it using the sender's
    // stored Ed25519 public key. Failures are logged but the packet is still
    // processed to avoid breaking connectivity during rollout.
    if (packet.signature != null && encryptionService != null) {
      final parts = MeshPacket.extractSignature(data);
      if (parts != null) {
        encryptionService!
            .verifyFromPeer(fromPeerId, parts.unsigned, parts.signature)
            .then((valid) {
          if (!valid) {
            Logger.warning(
              'BLE: Ed25519 signature verification failed for packet from '
              '${centralId.substring(0, min(8, centralId.length))}',
              'BLE',
            );
          } else {
            Logger.debug(
              'BLE: Ed25519 signature verified for packet from '
              '${centralId.substring(0, min(8, centralId.length))}',
              'BLE',
            );
          }
        }, onError: (Object e) {
          Logger.debug(
            'BLE: Ed25519 verification error: $e',
            'BLE',
          );
        },);
      }
    }

    Logger.info(
      'BleService: [RECV] binary type=${packet.type.name} from '
      'central=${centralId.substring(0, min(8, centralId.length))} '
      '(${data.length}B)',
      'BLE',
    );

    // Block filtering
    if (_blockedPeerIds.contains(fromPeerId) ||
        _blockedPeerIds.contains(centralId)) {
      Logger.debug(
        'BLE: Rejected binary packet from blocked peer $fromPeerId',
        'BLE',
      );
      return;
    }

    _refreshPeerTimeout(centralId);

    // Cache raw bytes for gossip fulfillment (relayable types only)
    if (packet.messageId.isNotEmpty) {
      gossipSyncService?.cacheMessage(packet.messageId, data);
    }

    switch (packet.type) {
      case PacketType.message:
        _handleBinaryChatMessage(packet, fromPeerId);
      case PacketType.handshake:
        final hs = BinaryMessageCodec.decodeHandshakePayload(packet);
        if (hs != null) {
          _handleBinaryHandshake(hs, fromPeerId);
        }
      case PacketType.anchorDrop:
        _handleDropAnchor(fromPeerId);
      case PacketType.reaction:
        final reaction = BinaryMessageCodec.decodeReactionPayload(packet);
        if (reaction != null) {
          _handleBinaryReaction(reaction, fromPeerId, packet.timestamp);
        }
      case PacketType.peerAnnounce:
      case PacketType.neighborList:
        // Mesh control messages — keep as JSON in payload for now
        try {
          final json = jsonDecode(utf8.decode(packet.payload)) as Map<String, dynamic>;
          if (packet.type == PacketType.peerAnnounce) {
            _meshRelay.handlePeerAnnounce(json, fromPeerId);
          } else {
            _meshRelay.handleNeighborList(json);
          }
        } on Exception {
          Logger.warning('BLE: Failed to parse mesh payload from binary packet', 'BLE');
        }
      case PacketType.gossipSync:
        _handleGossipSync(packet, fromPeerId);
      case PacketType.gossipRequest:
        _handleGossipRequest(packet, fromPeerId);
      case PacketType.ack:
      case PacketType.photoPreview:
      case PacketType.photoRequest:
      case PacketType.photoData:
      case PacketType.wifiTransferReady:
      case PacketType.readReceipt:
        Logger.debug('BLE: Unhandled binary packet type: ${packet.type.name}', 'BLE');
    }
  }

  /// Handle a binary-encoded chat message.
  void _handleBinaryChatMessage(MeshPacket packet, String fromPeerId) {
    final chat = BinaryMessageCodec.decodeChatPayload(packet);
    if (chat == null) {
      Logger.warning('BLE: Failed to decode binary chat payload', 'BLE');
      return;
    }

    final messageId = packet.messageId;

    // Deduplicate
    if (messageId.isNotEmpty) {
      if (!_seenMessageIds.tryAdd(messageId)) {
        Logger.info('BleService: Duplicate binary message ignored: $messageId', 'BLE');
        return;
      }
    }

    // If the binary payload carries the full sender userId (bit2 flag),
    // always use it as the canonical peer ID — it's the authoritative identity.
    // This definitively resolves the sender even when _resolveIncomingPeerId
    // returned a wrong/stale ID or the raw Central UUID.
    var resolvedPeerId = fromPeerId;
    final senderUserId = chat.senderUserId;
    if (senderUserId != null && senderUserId.isNotEmpty) {
      resolvedPeerId = senderUserId;
      // Register the mapping so future packets (reactions, drops) from this
      // Central UUID also resolve correctly.
      _registerCentralAsPeer(fromPeerId, senderUserId, chat.senderName);
    }

    // Check if message is for us (using truncated IDs)
    final ownUserId = _gattServer.ownUserId;
    final ownTruncated = MeshPacket.truncateIdSync(ownUserId);
    final isForUs = packet.isBroadcast || packet.recipientId == ownTruncated;

    if (isForUs) {
      if (chat.isEncrypted && chat.nonce != null && chat.ciphertext != null) {
        // Encrypted path
        final enc = encryptionService;
        if (enc != null) {
          final encPayload = EncryptedPayload(
            nonce: chat.nonce!,
            ciphertext: chat.ciphertext!,
          );
          enc.decrypt(resolvedPeerId, encPayload).then((plaintextBytes) {
            if (plaintextBytes == null) {
              Logger.warning(
                'E2EE binary decrypt failed for ${resolvedPeerId.substring(0, min(8, resolvedPeerId.length))}',
                'E2EE',
              );
              return;
            }
            try {
              final inner =
                  jsonDecode(utf8.decode(plaintextBytes)) as Map<String, dynamic>;
              final message = ReceivedMessage(
                fromPeerId: resolvedPeerId,
                messageId: messageId,
                type: chat.messageType,
                content: inner[MessageKeys.content] as String? ?? '',
                timestamp: packet.timestamp,
                replyToId: inner[MessageKeys.replyToId] as String?,
                isEncrypted: true,
              );
              _messageReceivedController.add(message);
            } on Exception catch (e) {
              Logger.error('E2EE binary inner envelope parse failed', e, null, 'E2EE');
            }
          });
          return;
        }
      }

      // Plaintext path
      final message = ReceivedMessage(
        fromPeerId: resolvedPeerId,
        messageId: messageId,
        type: chat.messageType,
        content: chat.content ?? '',
        timestamp: packet.timestamp,
        replyToId: chat.replyToId,
      );
      _messageReceivedController.add(message);
    } else {
      // Not for us — relay via mesh (full binary path, no JSON conversion).
      _meshRelay.maybeRelayBinaryPacket(packet, resolvedPeerId);
    }
  }

  /// Handle a binary-encoded handshake message.
  ///
  /// Emits on [noiseHandshakeStream] so TransportManager can resolve the
  /// BLE Central UUID → canonical userId before calling EncryptionService.
  /// This avoids the ID mismatch where _pending stores under canonical ID
  /// but the Central UUID differs (especially on iOS where Central ≠ Peripheral).
  void _handleBinaryHandshake(DecodedHandshake hs, String fromPeerId) {
    Logger.info(
      'E2EE: Binary handshake step ${hs.step} from '
      '${fromPeerId.substring(0, min(8, fromPeerId.length))}',
      'E2EE',
    );

    // Route through noiseHandshakeStream → TransportManager for canonical
    // ID resolution, just like JSON handshakes (line 861).
    // TransportManager resolves Central UUID → canonical userId via
    // PeerRegistry, then calls enc.processHandshakeMessage(canonicalId).
    // Outbound replies are routed via enc.outboundHandshakeStream →
    // TransportManager._routeOutboundHandshake.
    _noiseHandshakeController.add(NoiseHandshakeReceived(
      fromPeerId: fromPeerId,
      step: hs.step,
      payload: hs.payload,
    ),);
  }

  /// Handle a binary-encoded reaction.
  void _handleBinaryReaction(DecodedReaction reaction, String fromPeerId, DateTime timestamp) {
    _reactionReceivedController.add(ReactionReceived(
      fromPeerId: fromPeerId,
      messageId: reaction.targetMessageId,
      emoji: reaction.emoji,
      action: reaction.action,
      timestamp: timestamp,
    ),);
    Logger.info(
      'BleService: Binary reaction ${reaction.emoji} (${reaction.action}) from '
      '${fromPeerId.substring(0, min(8, fromPeerId.length))}',
      'BLE',
    );
  }

  /// Handle an incoming gossip sync (GCS) from a peer. Delegates to
  /// GossipSyncService for set reconciliation.
  void _handleGossipSync(MeshPacket packet, String fromPeerId) {
    final gossipSync = BinaryMessageCodec.decodeGossipSyncPayload(packet);
    if (gossipSync == null) return;

    final gossip = gossipSyncService;
    if (gossip == null) return;

    // Convert back to the Map format GossipSyncService expects
    final payload = {
      MessageKeys.gcs: base64Encode(gossipSync.gcsBytes),
      MessageKeys.gossipCount: gossipSync.messageCount,
    };
    gossip.handleGossipSync(fromPeerId, payload);

    Logger.debug(
      'BLE: Received gossip sync from ${fromPeerId.substring(0, min(8, fromPeerId.length))} '
      '(n=${gossipSync.messageCount})',
      'BLE',
    );
  }

  /// Handle an incoming gossip request from a peer.
  void _handleGossipRequest(MeshPacket packet, String fromPeerId) {
    final gossipReq = BinaryMessageCodec.decodeGossipRequestPayload(packet);
    if (gossipReq == null) return;

    Logger.debug(
      'BLE: Received gossip request from ${fromPeerId.substring(0, min(8, fromPeerId.length))} '
      '(${gossipReq.missingIndices.length} missing, originalN=${gossipReq.originalN})',
      'BLE',
    );

    // Forward to GossipSyncService for fulfillment
    gossipSyncService?.handleGossipRequest(
      fromPeerId,
      gossipReq.missingIndices,
      gossipReq.originalN,
    );
  }

  /// Resolve the sender's canonical peer ID from the payload's sender_id
  /// field. The canonical ID is always the app-level userId (stable UUID).
  /// Falls back to the Central UUID only if sender_id is missing (rare edge
  /// case for very old clients).
  String _resolveSenderPeerId(Map<String, dynamic> json, UUID centralUuid) {
    final senderId = json[MessageKeys.senderId] as String?;
    if (senderId != null && senderId.isNotEmpty) {
      return senderId;
    }
    return centralUuid.toString();
  }

  void _handleReceivedMessage(Map<String, dynamic> json, String fromPeerId) {
    final messageId = json[MessageKeys.messageId] as String? ?? '';

    // Deduplicate — BLE transport can retransmit the same write.
    // Uses a capacity-bounded LRU cache (no timers, no memory leaks).
    if (messageId.isNotEmpty) {
      if (!_seenMessageIds.tryAdd(messageId)) {
        Logger.info('BleService: Duplicate message ignored: $messageId', 'BLE');
        return;
      }
    }

    // Mesh routing: check if this message is addressed to us
    final destinationId = json[MessageKeys.destinationId] as String?;
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
      final replyToId = json[MessageKeys.replyToId] as String?;

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
            final decryptedContent = inner[MessageKeys.content] as String? ?? '';
            final decryptedReplyTo = inner[MessageKeys.replyToId] as String?;
            final messageType =
                MessageType.values[json[MessageKeys.messageType] as int? ?? 0];
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
          } on Exception catch (e) {
            Logger.error('E2EE inner envelope parse failed', e, null, 'E2EE');
          }
        });
        return; // Async path — return early; emission happens in the callback above.
      }

      // Plaintext path (no encryption or old client)
      content = json[MessageKeys.content] as String? ?? '';
      final message = ReceivedMessage(
        fromPeerId: fromPeerId,
        messageId: messageId,
        type: MessageType.values[json[MessageKeys.messageType] as int? ?? 0],
        content: content,
        timestamp: DateTime.now(),
        replyToId: replyToId,
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
    final step = json[MessageKeys.step] as int?;
    final payloadB64 = json[MessageKeys.payload] as String?;
    if (step == null || payloadB64 == null) {
      Logger.warning('Malformed noise_hs message from $fromPeerId', 'E2EE');
      return;
    }
    _noiseHandshakeController.add(NoiseHandshakeReceived(
      fromPeerId: fromPeerId,
      step: step,
      payload: Uint8List.fromList(base64.decode(payloadB64)),
    ),);
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
      String peerId, int step, Uint8List payload,) async {
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
        unawaited(connSub.cancel());
      }
    }
    if (conn == null || !conn.canSendMessages) {
      // Direct outbound connection unavailable. Try bidirectional path: if
      // the peer connected to OUR GATT server as a Central and subscribed to
      // fff3 notify, we can push the handshake via fff3. Falls back to fff5.
      final hsData = BinaryMessageCodec.encodeHandshake(
        senderId: _gattServer.ownUserId,
        step: step,
        handshakePayload: payload,
      );

      // On iOS, Central UUID ≠ Peripheral UUID. peerId is the Peripheral
      // UUID, but GattServer tracks Centrals by Central UUID.
      final centralId = _resolveToCentralId(peerId);
      final targetId = centralId ?? peerId;

      // Try fff3 bidirectional first, falls back to fff5 reverse-path.
      final sent = await _gattServer.sendToCentralViaFff3(targetId, hsData);
      if (sent) {
        Logger.info(
          'Handshake step $step sent via GATT notify to '
          '${targetId.substring(0, min(8, targetId.length))}',
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
    final data = BinaryMessageCodec.encodeHandshake(
      senderId: _gattServer.ownUserId,
      step: step,
      handshakePayload: payload,
    );
    Logger.info(
      'sendHandshakeMessage step $step: writing ${data.length}B binary via fff3 to '
      '${peerId.substring(0, min(8, peerId.length))}',
      'E2EE',
    );
    final sent = await _writeQueue
        .enqueue(
      peerId: peerId,
      peripheral: conn.peripheral,
      characteristic: conn.messagingChar!,
      data: data,
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
  String? resolveToPeripheralId(String centralId) {
    // Check if this centralId has been registered (via _registerCentralAsPeer)
    // with a userId that matches an existing Peripheral entry.
    final directEntry = _visiblePeers[centralId];
    if (directEntry?.userId != null) {
      final userId = directEntry!.userId!;
      // Look for a different BLE UUID (the Peripheral UUID from scanning)
      // that shares this userId.
      for (final entry in _visiblePeers.entries) {
        if (entry.key != centralId && entry.value.userId == userId) {
          return entry.key;
        }
      }
    }
    return null;
  }

  /// Reverse of [resolveToPeripheralId]: given a Peripheral UUID (from
  /// scanning), find the Central UUID that the same physical device used
  /// when it connected to our GATT server. On iOS, these differ.
  String? _resolveToCentralId(String peripheralId) {
    final entry = _visiblePeers[peripheralId];
    final userId = entry?.userId;
    if (userId == null) return null;

    // Look for a DIFFERENT key in _visiblePeers with the same userId —
    // that's the Central UUID registered via _registerCentralAsPeer.
    for (final other in _visiblePeers.entries) {
      if (other.key != peripheralId && other.value.userId == userId) {
        return other.key;
      }
    }
    return null;
  }

  /// Resolve a BLE Central UUID to the peer ID used for E2EE sessions and
  /// _visiblePeers. On iOS, Central UUID ≠ Peripheral UUID, so we need to
  /// map the Central to the Peripheral UUID that was used when the peer was
  /// originally scanned and the E2EE session was established.
  ///
  /// Uses the MeshPacket's truncated sender ID (FNV-1a of the sender's app
  /// userId) to find the matching visible peer entry. This is the most
  /// reliable cross-reference because:
  ///   - The sender encodes their app userId when creating the MeshPacket
  ///   - We learned the peer's app userId during GATT profile reading (fff1)
  ///   - The truncated hash is deterministic and collision-resistant
  ///
  /// Falls back to [centralId] if no match is found.
  String _resolveIncomingPeerId(String centralId,
      {String? truncatedSenderId,}) {
    // Fast path: centralId is already a known peer with an E2EE session.
    if (encryptionService?.hasSession(centralId) ?? false) {
      return centralId;
    }

    // Use the truncated sender ID from the MeshPacket header to find the
    // visible peer whose app userId produces the same hash. This works even
    // when Central UUID ≠ Peripheral UUID (iOS).
    if (truncatedSenderId != null && truncatedSenderId.isNotEmpty) {
      for (final entry in _visiblePeers.entries) {
        final userId = entry.value.userId;
        if (userId != null && userId.isNotEmpty) {
          final truncated = MeshPacket.truncateIdSync(userId);
          if (truncated == truncatedSenderId) {
            // Found the peer — use whichever ID has an active E2EE session.
            if (encryptionService?.hasSession(entry.key) ?? false) {
              Logger.info(
                'BLE: Resolved Central ${centralId.substring(0, min(8, centralId.length))} '
                '→ Peripheral ${entry.key.substring(0, min(8, entry.key.length))} '
                'via truncated sender ID match (userId=${userId.substring(0, min(8, userId.length))})',
                'BLE',
              );
              return entry.key;
            }
            // Also try the userId directly — TransportManager may have
            // established the session under the canonical userId.
            if (encryptionService?.hasSession(userId) ?? false) {
              Logger.info(
                'BLE: Resolved Central ${centralId.substring(0, min(8, centralId.length))} '
                '→ userId ${userId.substring(0, min(8, userId.length))} '
                'via truncated sender ID match',
                'BLE',
              );
              return userId;
            }
            // No session yet but we know which peer this is — return the
            // Peripheral UUID so the message at least routes correctly.
            Logger.debug(
              'BLE: Matched Central ${centralId.substring(0, min(8, centralId.length))} '
              'to peer ${entry.key.substring(0, min(8, entry.key.length))} but no '
              'E2EE session found under any ID',
              'BLE',
            );
            return entry.key;
          }
        }
      }
    }

    // Check _visiblePeers[centralId] for a userId, then look for a sibling
    // entry (different BLE UUID, same userId) that has a session.
    final directEntry = _visiblePeers[centralId];
    if (directEntry?.userId != null) {
      final userId = directEntry!.userId!;
      for (final entry in _visiblePeers.entries) {
        if (entry.key != centralId && entry.value.userId == userId) {
          if (encryptionService?.hasSession(entry.key) ?? false) {
            Logger.info(
              'BLE: Resolved Central ${centralId.substring(0, min(8, centralId.length))} '
              '→ sibling ${entry.key.substring(0, min(8, entry.key.length))} '
              '(shared userId)',
              'BLE',
            );
            return entry.key;
          }
        }
      }
    }

    // Last resort: check E2EE sessions by truncated hash. This handles the
    // case where a peer reconnects with a new Central UUID before their profile
    // has been read — _visiblePeers won't have the entry yet, but we may have
    // a persisted session from a previous connection.
    if (truncatedSenderId != null && truncatedSenderId.isNotEmpty) {
      final enc = encryptionService;
      if (enc != null) {
        final sessionPeerId = enc.findSessionByTruncatedId(truncatedSenderId);
        if (sessionPeerId != null) {
          Logger.info(
            'BLE: Resolved Central ${centralId.substring(0, min(8, centralId.length))} '
            '→ session peer $sessionPeerId via E2EE session truncated ID match',
            'BLE',
          );
          return sessionPeerId;
        }
      }
    }

    return centralId;
  }

  /// Returns the app userId for a given BLE peripheral UUID, or null if
  /// the mapping hasn't been established yet (peer profile not yet read).
  String? _getAppUserIdForPeer(String blePeerId) {
    return _visiblePeers[blePeerId]?.userId;
  }

  // ==================== Mesh Relay (delegated to MeshRelayService) ====================

  @override
  Future<void> setMeshRelayMode({required bool enabled}) async {
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

  @override
  void updateBlockedPeerIds(Set<String> blockedIds) {
    _blockedPeerIds
      ..clear()
      ..addAll(blockedIds);
    Logger.info(
      'BLE block list updated: ${blockedIds.length} blocked peers',
      'BLE',
    );
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
    } on Exception catch (e) {
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
          'E2EE',);
    } else {
      Logger.debug(
          'broadcastProfile: embedding pk ${myPublicKeyHex.substring(0, 8)}…',
          'E2EE',);
    }
    final myEd25519PublicKeyHex = encryptionService?.localEd25519PublicKeyHex;
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
            signingPublicKeyHex: myEd25519PublicKeyHex,
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
      String peerId, String name, int? age, int rssi, Peripheral peripheral,) {
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

    final userId = json[MessageKeys.userId] as String?;

    // Extract E2EE public keys now; store AFTER _emitPeer so that
    // TransportManager._migrateIfNeeded (triggered by _emitPeer) sets
    // _bleIdForCanonical before peerKeyStoredStream fires.
    final peerPublicKeyHex = json[MessageKeys.publicKey] as String?;
    final peerEd25519KeyHex = json[MessageKeys.signingPublicKey] as String?;

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
          ),);
          _onPeerLost(entry.key);
          break;
        }
      }
    }

    // Update the existing peer entry with profile data
    final photoCount = json[MessageKeys.photoCount] as int?;
    final position = json[MessageKeys.position] as int?;
    final interests = json[MessageKeys.interests] as String?;
    final newName = json[MessageKeys.name] as String? ?? existingPeer.name;
    final newAge = json[MessageKeys.age] as int? ?? existingPeer.age;
    final newBio = json[MessageKeys.bio] as String?;
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
      signingPublicKeyHex: peerEd25519KeyHex?.length == 64 ? peerEd25519KeyHex : null,
    );

    _emitPeer(updatedPeer);

    // NOTE: Do NOT call storePeerPublicKey(peerId, ...) here — `peerId` is
    // the BLE peripheral UUID, not the canonical userId. Storing the key
    // under the BLE UUID creates a duplicate discovered_peers row.
    // TransportManager handles storePeerPublicKey under the canonical ID
    // after resolving via PeerRegistry.

    // Record the profile version from the GATT read so the scanner can
    // skip future reads when the advertised version hasn't changed.
    final profileVersion = json[MessageKeys.profileVersion] as int?;
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
      if (data.isEmpty) return;

      // Binary photo chunks use the same dispatch as write-received.
      if (data[0] == 0x02 || data[0] == 0x03) {
        if (data[0] == 0x02) {
          _photoTransfer.handleBinaryPhotoChunk(data, peerId);
        } else {
          _photoTransfer.handleBinaryThumbnailChunk(data, peerId);
        }
        return;
      }

      // Binary MeshPacket (version byte 0x01) — same dispatch as write path.
      // Without this check, binary data falls through to utf8.decode() and crashes.
      if (BinaryMessageCodec.isBinary(data) && data[0] == 0x01) {
        Logger.debug(
          'BleService: [RECV] binary MeshPacket via fff3-notify '
          '(${data.length}B) from ${peerId.substring(0, min(8, peerId.length))}',
          'BLE',
        );
        // Synthesize a UUID from the peerId string for the binary handler.
        // On the notify path the peerId is the Peripheral UUID we connected to.
        final peerUuid = UUID.fromString(peerId);
        _handleBinaryPacket(data, peerId, peerUuid);
        return;
      }

      final jsonStr = utf8.decode(data);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final type = json[MessageKeys.type] as String? ?? MessageTypes.message;

      _refreshPeerTimeout(peerId);

      Logger.info(
        'BleService: Received fff3-notify $type from '
        '${peerId.substring(0, min(8, peerId.length))}',
        'BLE',
      );

      // Route photo-transfer messages to the photo handler — same dispatch
      // as _onMessageWriteReceived. Without these, photo_request/preview/etc.
      // sent via the bidirectional path would be silently dropped.
      if (type == MessageTypes.photoStart) {
        _photoTransfer.handlePhotoStart(json, peerId);
      } else if (type == MessageTypes.photoChunk) {
        _photoTransfer.handleReceivedPhotoChunk(json, peerId);
      } else if (type == MessageTypes.photoPreview) {
        _photoTransfer.handlePhotoPreviewStart(json, peerId);
      } else if (type == MessageTypes.photoRequest) {
        _photoTransfer.handlePhotoRequest(json, peerId);
      } else if (type == MessageTypes.noiseHandshake) {
        _handleNoiseHandshake(json, peerId);
      } else if (type == MessageTypes.dropAnchor) {
        _handleDropAnchor(peerId);
      } else if (type == MessageTypes.reaction) {
        _handleReaction(json, peerId);
      } else if (type == MessageTypes.peerAnnounce) {
        _meshRelay.handlePeerAnnounce(json, peerId);
      } else if (type == MessageTypes.neighborList) {
        _meshRelay.handleNeighborList(json);
      } else if (type == MessageTypes.profileRequest) {
        _handleProfileRequest(peerId);
      } else if (type == MessageTypes.profileData) {
        _handleProfileData(json, peerId);
      } else {
        _handleReceivedMessage(json, peerId);
      }
    } on Exception catch (e) {
      Logger.error(
          'BleService: fff3 notification processing failed', e, null, 'BLE',);
    }
  }

  /// Process a reverse-path fff3 notification received from a Peripheral.
  ///
  /// The sender is identified by their Peripheral UUID (which we connected to
  /// as Central), not a Central UUID. This is the same peerId used in our
  /// ConnectionManager and _visiblePeers mappings.
  void _onReversePathNotification(String peerId, Uint8List data) {
    try {
      if (data.isEmpty) return;

      // Binary MeshPacket on the reverse path — dispatch to binary handler.
      if (BinaryMessageCodec.isBinary(data) && data[0] == 0x01) {
        Logger.debug(
          'BleService: [RECV] binary MeshPacket via reverse-path '
          '(${data.length}B) from ${peerId.substring(0, min(8, peerId.length))}',
          'BLE',
        );
        final peerUuid = UUID.fromString(peerId);
        _handleBinaryPacket(data, peerId, peerUuid);
        return;
      }

      final jsonStr = utf8.decode(data);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final type = json[MessageKeys.type] as String? ?? MessageTypes.message;

      _refreshPeerTimeout(peerId);

      Logger.info(
        'BleService: Received reverse-path $type from '
        '${peerId.substring(0, min(8, peerId.length))}',
        'BLE',
      );

      // Route photo-transfer messages to the photo handler — same as fff3 path.
      if (type == MessageTypes.photoStart) {
        _photoTransfer.handlePhotoStart(json, peerId);
      } else if (type == MessageTypes.photoChunk) {
        _photoTransfer.handleReceivedPhotoChunk(json, peerId);
      } else if (type == MessageTypes.photoPreview) {
        _photoTransfer.handlePhotoPreviewStart(json, peerId);
      } else if (type == MessageTypes.photoRequest) {
        _photoTransfer.handlePhotoRequest(json, peerId);
      } else if (type == MessageTypes.noiseHandshake) {
        _handleNoiseHandshake(json, peerId);
      } else if (type == MessageTypes.dropAnchor) {
        _handleDropAnchor(peerId);
      } else if (type == MessageTypes.reaction) {
        _handleReaction(json, peerId);
      } else {
        _handleReceivedMessage(json, peerId);
      }
    } on Exception catch (e) {
      Logger.error(
          'BleService: Reverse-path notification failed', e, null, 'BLE',);
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
      String centralId, String userId, String? senderName,) {
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

  // ==================== Reverse Profile Exchange ====================
  //
  // When a remote device connects to us as a GATT central (e.g. Android whose
  // advertising never reached iOS), we can't discover them via scanning and
  // therefore can't read their GATT profile. Instead, we exchange profiles
  // over the existing fff3 bidirectional messaging channel.

  /// Track centrals we've already requested profiles from to avoid spam.
  final Set<String> _profileRequestedFromCentral = {};

  /// If the given central has no profile data (no publicKeyHex), send a
  /// profile_request via fff3 so they respond with their profile.
  void _requestProfileFromCentralIfNeeded(String centralId) {
    if (_profileRequestedFromCentral.contains(centralId)) return;

    final existing = _visiblePeers[centralId];
    // Already have full profile data (public key means GATT profile was read)
    if (existing != null && existing.publicKeyHex != null) return;

    _profileRequestedFromCentral.add(centralId);

    final requestJson = jsonEncode({
      MessageKeys.type: MessageTypes.profileRequest,
      MessageKeys.senderId: _gattServer.ownUserId,
    });

    Logger.info(
      'BleService: Requesting profile from central '
      '${centralId.substring(0, min(8, centralId.length))} via fff3',
      'BLE',
    );

    _gattServer.sendToCentralViaFff3(
      centralId,
      Uint8List.fromList(utf8.encode(requestJson)),
    );
  }

  /// Handle an incoming profile_request: respond with our profile data.
  void _handleProfileRequest(String centralId) {
    final payload = _gattServer.pendingPayload;
    if (payload == null) return;

    Logger.info(
      'BleService: Responding to profile_request from '
      '${centralId.substring(0, min(8, centralId.length))}',
      'BLE',
    );

    final responseJson = jsonEncode({
      MessageKeys.type: MessageTypes.profileData,
      MessageKeys.senderId: payload.userId,
      MessageKeys.userId: payload.userId,
      MessageKeys.name: payload.name,
      MessageKeys.age: payload.age,
      MessageKeys.bio: payload.bio,
      MessageKeys.position: payload.position,
      MessageKeys.interests: payload.interests,
      MessageKeys.publicKey: payload.publicKeyHex,
      MessageKeys.signingPublicKey: payload.signingPublicKeyHex,
      MessageKeys.profileVersion: _gattServer.profileVersion,
    });

    _gattServer.sendToCentralViaFff3(
      centralId,
      Uint8List.fromList(utf8.encode(responseJson)),
    );
  }

  /// Handle an incoming profile_data: process it like a GATT profile read.
  void _handleProfileData(Map<String, dynamic> json, String centralId) {
    final userId = json[MessageKeys.userId] as String?;
    final name = json[MessageKeys.name] as String?;

    Logger.info(
      'BleService: Received profile_data from '
      '${centralId.substring(0, min(8, centralId.length))} '
      '— name="$name", userId=${userId != null ? userId.substring(0, min(8, userId.length)) : "null"}',
      'BLE',
    );

    // Process through the same path as a GATT profile read
    _onProfileReadResult(ProfileReadResult(
      peerId: centralId,
      profileJson: json,
    ),);
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
      _profileRequestedFromCentral.remove(peerId);

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

        // Try bidirectional path: if the peer connected to our GATT server
        // as a Central, push the message back via fff3/fff5 GATT notification.
        final centralId = _resolveToCentralId(peerId);
        final targetId = centralId ?? peerId;
        final biData = _serializeMessagePayload(
          payload,
          destinationUserId: destinationUserId,
        );
        final sent = await _gattServer.sendToCentralViaFff3(targetId, biData);
        if (sent) {
          Logger.info(
            'BleService: Message sent via fff3 bidirectional to '
            '${targetId.substring(0, min(8, targetId.length))}',
            'BLE',
          );
          return true;
        }

        Logger.info(
            'BleService: Peer not reachable: $peerId — triggering scan', 'BLE',);
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
          'to ${peerId.substring(0, min(8, peerId.length))} — write queue rejected, '
          'disconnecting stale connection',
          'BLE',
        );
        // Force disconnect so the next send attempt establishes a fresh
        // connection. Without this, a stale connection (where writes time
        // out but iOS hasn't detected the disconnect) blocks all future
        // sends to this peer indefinitely.
        _connectionManager.disconnect(peerId);
      }
      return success;
    } on Exception catch (e) {
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
      final data = BinaryMessageCodec.encodeAnchorDrop(
        senderId: ownUserId,
        senderName: ownName,
        destinationUserId: destinationUserId,
        ttl: config.meshTtl,
        meshEnabled: _meshRelay.enabled,
      );

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
            'BLE',);
        return false;
      }

      final success = await _writeQueue.enqueue(
        peerId: peerId,
        peripheral: conn.peripheral,
        characteristic: conn.messagingChar!,
        data: data,
      );

      if (success) {
        Logger.info('BleService: Anchor drop sent successfully', 'BLE');
      }
      return success;
    } on Exception catch (e) {
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
      final data = BinaryMessageCodec.encodeReaction(
        senderId: ownUserId,
        targetMessageId: messageId,
        emoji: emoji,
        action: action,
      );

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
      );

      if (success) {
        Logger.info('BleService: Reaction sent successfully', 'BLE');
      }
      return success;
    } on Exception catch (e) {
      Logger.error('BleService: Reaction send failed', e, null, 'BLE');
      return false;
    }
  }

  @override
  Future<bool> sendRawBytes(String peerId, Uint8List data) async {
    _ensureInitialized();

    try {
      var conn = _connectionManager.getConnection(peerId);
      if (conn == null || !conn.canSendMessages) {
        final peripheral = _connectionManager.getPeripheral(peerId);
        if (peripheral != null) {
          conn = await _connectionManager.connect(peerId, peripheral);
        }
      }

      if (conn == null || !conn.canSendMessages) return false;

      return _writeQueue.enqueue(
        peerId: peerId,
        peripheral: conn.peripheral,
        characteristic: conn.messagingChar!,
        data: data,
        priority: WritePriority.meshRelay,
      );
    } on Exception catch (e) {
      Logger.error('BleService: sendRawBytes failed', e, null, 'BLE');
      return false;
    }
  }

  @override
  Stream<ReactionReceived> get reactionReceivedStream =>
      _reactionReceivedController.stream;

  void _handleReaction(Map<String, dynamic> json, String fromPeerId) {
    final messageId = json[MessageKeys.messageId] as String?;
    final emoji = json[MessageKeys.emoji] as String?;
    final action = json[MessageKeys.action] as String?;
    final timestampStr = json[MessageKeys.timestamp] as String?;

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

  /// Serialize a [MessagePayload] to binary MeshPacket bytes for writing to fff3.
  ///
  /// Synchronous serialization (used for mesh relay path — no E2EE for relayed
  /// messages since we don't know the final hop's session state).
  Uint8List _serializeMessagePayload(MessagePayload payload,
      {String? destinationUserId,}) {
    final ownUserId = _gattServer.ownUserId;
    final ownName = _gattServer.pendingPayload?.name;
    return BinaryMessageCodec.encodeMessage(
      senderId: ownUserId,
      messageId: payload.messageId,
      messageType: payload.type,
      content: payload.content,
      senderName: ownName,
      replyToId: payload.replyToId,
      destinationUserId: destinationUserId,
      ttl: config.meshTtl,
      meshEnabled: _meshRelay.enabled,
    );
  }

  /// Async serialization with optional E2EE encryption.
  ///
  /// When [EncryptionService] has an active session for [peerId], the message
  /// content is encrypted with XChaCha20-Poly1305 before binary serialisation.
  /// The encrypted flag is set in the MeshPacket header.
  ///
  /// Fallback: if encryption fails or no session exists, sends unencrypted.
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
        MessageKeys.content: payload.content,
        if (payload.replyToId != null) MessageKeys.replyToId: payload.replyToId,
      };
      final innerBytes = Uint8List.fromList(utf8.encode(jsonEncode(innerMap)));

      final encrypted = await enc.encrypt(peerId, innerBytes);
      if (encrypted != null) {
        final ownName = _gattServer.pendingPayload?.name;
        return BinaryMessageCodec.encodeEncryptedMessage(
          senderId: ownUserId,
          messageId: payload.messageId,
          messageType: payload.type,
          nonce: encrypted.nonce,
          ciphertext: encrypted.ciphertext,
          senderName: ownName,
          destinationUserId: destinationUserId,
          ttl: config.meshTtl,
          meshEnabled: _meshRelay.enabled,
        );
      }
    }

    // No session or encryption failed — fall back to plaintext
    return _serializeMessagePayload(payload,
        destinationUserId: destinationUserId,);
  }

  // ==================== Photo Transfer (delegated to PhotoTransferHandler) ====================

  @override
  Future<bool> sendPhoto(String peerId, Uint8List photoData, String messageId,
      {String? photoId,}) {
    _ensureInitialized();
    return _photoTransfer.sendPhoto(peerId, photoData, messageId,
        photoId: photoId,);
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
  }) async {
    _ensureInitialized();

    // Try direct Central→Peripheral GATT write first.
    final directSuccess = await _photoTransfer.sendPhotoRequest(
      peerId: peerId,
      messageId: messageId,
      photoId: photoId,
    );
    if (directSuccess) return true;

    // Direct write failed (no Central connection to this peer).
    // Fall back to bidirectional path: if the peer connected to OUR GATT
    // server as a Central and subscribed to fff3 notify, push the request
    // back via GATT notification. This handles the common case where only
    // ONE device established the Central→Peripheral connection.
    Logger.info(
      'BleService: Direct photo_request write failed for $peerId — '
      'trying fff3 bidirectional fallback',
      'BLE',
    );

    final requestPayload = Uint8List.fromList(utf8.encode(jsonEncode({
      MessageKeys.type: MessageTypes.photoRequest,
      MessageKeys.senderId: _gattServer.ownUserId,
      MessageKeys.messageId: messageId,
      MessageKeys.photoId: photoId,
    }),),);

    // On iOS, Central UUID ≠ Peripheral UUID. peerId is the Peripheral UUID
    // (from scanning), but GattServer tracks Centrals by Central UUID.
    // Resolve: find the Central UUID that shares the same userId as peerId.
    final centralId = _resolveToCentralId(peerId);
    final targetId = centralId ?? peerId;

    final sent = await _gattServer.sendToCentralViaFff3(targetId, requestPayload);
    if (sent) {
      Logger.info(
        'BleService: photo_request sent via fff3 bidirectional to '
        '${targetId.substring(0, min(8, targetId.length))}',
        'BLE',
      );
      return true;
    }

    Logger.info(
      'BleService: photo_request failed — peer $peerId unreachable via '
      'both direct write and fff3 bidirectional',
      'BLE',
    );
    return false;
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
  Future<void> setBatterySaverMode({required bool enabled}) async {
    _scanner.setBatterySaverMode(enabled: enabled);
    Logger.info(
        'BleService: Battery saver ${enabled ? 'enabled' : 'disabled'}', 'BLE',);
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
