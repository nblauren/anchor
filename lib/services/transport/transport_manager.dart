import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anchor/core/constants/app_constants.dart';
import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/services/ble/binary_message_codec.dart';
import 'package:anchor/services/ble/ble_models.dart' as ble;
import 'package:anchor/services/ble/ble_service_interface.dart';
import 'package:anchor/services/encryption/encryption.dart';
import 'package:anchor/services/lan/lan.dart';
import 'package:anchor/services/mesh/mesh.dart';
import 'package:anchor/services/nearby/nearby.dart';
import 'package:anchor/services/transport/transport_enums.dart';
import 'package:anchor/services/transport/transport_health_tracker.dart';
import 'package:anchor/services/wifi_aware/wifi_aware_transport_service.dart';
import 'package:wifi_aware_p2p/wifi_aware_p2p.dart' as wa;

/// Unified transport manager that abstracts over LAN, Wi-Fi Aware, and BLE,
/// presenting a single interface to blocs.
///
/// ## Multi-Transport Architecture
///
/// All transports run concurrently. Each peer tracks which transports can
/// reach it, and the manager automatically picks the best one. When a
/// higher-priority transport drops, the peer seamlessly falls back to the
/// next best transport without vanishing from the UI.
///
/// ## PeerRegistry Integration
///
/// All peer identity resolution is delegated to [PeerRegistry]. The old
/// `_userIdToCurrentPeerId`, `_peerIdAlias`, and `_bleIdForCanonical` maps
/// are replaced by PeerRegistry's unified identity model.
///
/// ## MessageRouter Integration
///
/// All incoming messages pass through [MessageRouter] for cross-transport
/// deduplication before reaching the application layer.
class TransportManager {
  TransportManager({
    required LanTransportService lanService,
    required WifiAwareTransportService wifiAwareService,
    required BleServiceInterface bleService,
    required PeerRegistry peerRegistry,
    required MessageRouter messageRouter,
    EncryptionService? encryptionService,
    TransportHealthTracker? healthTracker,
    HighSpeedTransferService? highSpeedTransferService,
    GossipSyncService? gossipSyncService,
  })  : _lanService = lanService,
        _wifiAwareService = wifiAwareService,
        _bleService = bleService,
        _peerRegistry = peerRegistry,
        _messageRouter = messageRouter,
        _encryptionService = encryptionService,
        _healthTracker = healthTracker,
        _highSpeedService = highSpeedTransferService,
        _gossipSync = gossipSyncService {
    // Immediately subscribe to BLE streams so peer discovery works
    // even before initialize() is called (BleConnectionBloc starts BLE
    // independently).
    _subscribeToBle();
    _subscribeToHandshakeRouting();
    _subscribeToPeerRegistryChanges();
    _wireGossipSync();
    _subscribeToMeshRelay();

    // Wire high-density peer count so relay uses probabilistic forwarding
    // when many peers are visible (prevents network flooding).
    _messageRouter.getVisiblePeerCount =
        () => _peerRegistry.allCanonicalIds.length;

    Logger.info('TransportManager: BLE stream forwarding active', 'Transport');
  }

  final LanTransportService _lanService;
  final WifiAwareTransportService _wifiAwareService;
  final BleServiceInterface _bleService;
  final PeerRegistry _peerRegistry;
  final MessageRouter _messageRouter;
  final EncryptionService? _encryptionService;
  final TransportHealthTracker? _healthTracker;
  final HighSpeedTransferService? _highSpeedService;
  final GossipSyncService? _gossipSync;

  /// Stores ownUserId from initialize() for Wi-Fi Direct sender ID.
  String? _ownUserId;

  // Battery-aware transport policy: maps TransportType → minimum battery level.
  // Populated by [setBatteryPolicy]. When a transport's minimum exceeds the
  // current battery level, that transport is skipped during sends.
  final Map<TransportType, int> _minBatteryForTransport = {};
  int _currentBatteryLevel = 100;

  // Magic byte prepended to encrypted photo payloads.
  // JPEG starts with 0xFF 0xD8, PNG with 0x89 — 0x01 is unambiguous.
  // Encryption constants moved to message_envelope.dart (shared utility).

  TransportType _activeTransport = TransportType.ble;
  bool _initialized = false;

  // ── Subscription lists (per-transport) ──────────────────────────────────

  final List<StreamSubscription<dynamic>> _bleSubscriptions = [];
  final List<StreamSubscription<dynamic>> _lanSubscriptions = [];
  final List<StreamSubscription<dynamic>> _wifiAwareSubscriptions = [];
  bool _lanSubscribed = false;
  bool _wifiAwareSubscribed = false;

  // Unified stream controllers
  final _peerDiscoveredController =
      StreamController<ble.DiscoveredPeer>.broadcast();
  final _peerLostController = StreamController<String>.broadcast();
  final _messageReceivedController =
      StreamController<ble.ReceivedMessage>.broadcast();
  final _photoPreviewReceivedController =
      StreamController<ble.ReceivedPhotoPreview>.broadcast();
  final _photoRequestReceivedController =
      StreamController<ble.ReceivedPhotoRequest>.broadcast();
  final _photoProgressController =
      StreamController<ble.PhotoTransferProgress>.broadcast();
  final _photoReceivedController =
      StreamController<ble.ReceivedPhoto>.broadcast();
  final _anchorDropReceivedController =
      StreamController<ble.AnchorDropReceived>.broadcast();
  final _reactionReceivedController =
      StreamController<ble.ReactionReceived>.broadcast();
  final _peerIdChangedController =
      StreamController<ble.PeerIdChanged>.broadcast();
  final _activeTransportController =
      StreamController<TransportType>.broadcast();
  final _peerTransportChangedController =
      StreamController<PeerTransportChanged>.broadcast();

  // Availability subscriptions
  StreamSubscription<bool>? _availabilityLanSub;
  StreamSubscription<bool>? _availabilitySub;
  StreamSubscription<PeerIdChangedEvent>? _peerRegistrySub;
  StreamSubscription<RelayRequest>? _relaySub;

  // ==================== Public Getters ====================

  TransportType get activeTransport => _activeTransport;
  Stream<TransportType> get activeTransportStream =>
      _activeTransportController.stream;

  Stream<PeerTransportChanged> get peerTransportChangedStream =>
      _peerTransportChangedController.stream;

  /// Returns the best transport currently available for [peerId], or null
  /// if the peer is not tracked.
  TransportType? transportForPeer(String peerId) =>
      _peerRegistry.bestTransportFor(peerId);

  /// Returns the BLE device ID for [userId], or [userId] unchanged if no
  /// BLE transport is registered. Used for BLE sends when the caller has
  /// the canonical userId but needs the transport-level BLE UUID.
  String bleIdForPeer(String userId) =>
      _peerRegistry.bleIdFor(userId) ?? userId;

  /// Maps a transport-level ID (BLE UUID, LAN peer ID, etc.) back to the
  /// canonical userId used in conversations and UI. Returns [transportId]
  /// unchanged if there is no mapping (e.g. unregistered peer).
  String canonicalIdForBle(String transportId) =>
      _peerRegistry.resolveCanonical(transportId) ?? transportId;

  // ==================== Lifecycle ====================

  /// Initialize higher-bandwidth transports (optional upgrade from BLE).
  ///
  /// BLE forwarding is already active from construction. This method attempts
  /// to start LAN and Wi-Fi Aware as higher-priority transports. Safe to call
  /// multiple times — subsequent calls are no-ops.
  Future<void> initialize({
    required String ownUserId,
    required ble.BroadcastPayload profile,
  }) async {
    if (_initialized) return;
    _initialized = true;
    _ownUserId = ownUserId;
    _messageRouter.setOwnUserId(ownUserId);

    // Start gossip sync — periodic GCS broadcast to connected peers
    _gossipSync?.start();

    // BLE is already initialized and started by BleConnectionBloc — don't
    // re-initialize here.

    // Try LAN first — works on both iOS and Android wherever a local network
    // interface is available (e.g. ship Wi-Fi).
    var lanAvailable = false;
    if (AppConstants.enableLanTransport) {
      try {
        final available = await _lanService.isAvailable;
        Logger.info(
          'TransportManager: LAN isAvailable=$available',
          'Transport',
        );
        if (available) {
          await _lanService.initialize(ownUserId: ownUserId, profile: profile);
          await _lanService.start();
          lanAvailable = true;
        }
      } on Exception catch (e) {
        Logger.warning('TransportManager: LAN init failed: $e', 'Transport');
      }

      if (lanAvailable) {
        _subscribeToLanAdditive();
        _activeTransport = TransportType.lan;
        _activeTransportController.add(_activeTransport);
        Logger.info('TransportManager: LAN is primary transport', 'Transport');
      }

      // Listen for LAN availability changes — additive subscribe/unsubscribe
      _availabilityLanSub = _lanService.availabilityStream.listen((available) {
        if (available && !_lanSubscribed) {
          Logger.info(
            'TransportManager: LAN became available, adding subscriptions',
            'Transport',
          );
          _subscribeToLanAdditive();
          _activeTransport = TransportType.lan;
          _activeTransportController.add(_activeTransport);
        } else if (!available && _lanSubscribed) {
          Logger.info(
            'TransportManager: LAN lost, removing LAN subscriptions',
            'Transport',
          );
          _unsubscribeFromLan();
          _removeLanTransportFromAllPeers();
          // Recompute global best
          _activeTransport = _wifiAwareSubscribed
              ? TransportType.wifiAware
              : TransportType.ble;
          _activeTransportController.add(_activeTransport);
        }
      });
    } else {
      Logger.info('TransportManager: LAN transport disabled by AppConstants', 'Transport');
    }

    // Wi-Fi Aware is Android-only.
    if (Platform.isIOS) {
      Logger.info(
        'TransportManager: iOS — Wi-Fi Aware disabled (requires per-device pairing)',
        'Transport',
      );
      if (!lanAvailable) {
        Logger.info(
          'TransportManager: BLE is primary transport (LAN unavailable on iOS)',
          'Transport',
        );
      }
      return;
    }

    // Android: try Wi-Fi Aware as secondary transport
    var wifiAwareAvailable = false;
    try {
      final supported = await wa.WifiAwareP2P.isSupported();
      Logger.info(
        'TransportManager: Wi-Fi Aware isSupported=$supported',
        'Transport',
      );
      if (supported) {
        final available = await wa.WifiAwareP2P.isAvailable();
        Logger.info(
          'TransportManager: Wi-Fi Aware isAvailable=$available',
          'Transport',
        );
        if (available) {
          await _wifiAwareService.initialize(
            ownUserId: ownUserId,
            profile: profile,
          );
          wifiAwareAvailable = true;
        }
      }
    } on Exception catch (e) {
      Logger.warning(
        'TransportManager: Wi-Fi Aware init failed: $e',
        'Transport',
      );
    }

    if (wifiAwareAvailable && !lanAvailable) {
      _subscribeToWifiAwareAdditive();
      _activeTransport = TransportType.wifiAware;
      _activeTransportController.add(_activeTransport);
      Logger.info(
        'TransportManager: Wi-Fi Aware is primary transport',
        'Transport',
      );
    } else if (wifiAwareAvailable && lanAvailable) {
      // LAN is primary but also subscribe to Wi-Fi Aware additively
      _subscribeToWifiAwareAdditive();
    } else if (!lanAvailable) {
      Logger.info(
        'TransportManager: BLE is primary transport (LAN and Wi-Fi Aware unavailable)',
        'Transport',
      );
    }

    // Listen for Wi-Fi Aware availability changes — additive
    _availabilitySub =
        _wifiAwareService.availabilityStream.listen((available) {
      if (available && !_wifiAwareSubscribed) {
        Logger.info(
          'TransportManager: Wi-Fi Aware became available, adding subscriptions',
          'Transport',
        );
        _subscribeToWifiAwareAdditive();
        if (_activeTransport == TransportType.ble) {
          _activeTransport = TransportType.wifiAware;
          _activeTransportController.add(_activeTransport);
        }
      } else if (!available && _wifiAwareSubscribed) {
        Logger.info(
          'TransportManager: Wi-Fi Aware lost, removing subscriptions',
          'Transport',
        );
        _unsubscribeFromWifiAware();
        _removeWifiAwareTransportFromAllPeers();
        if (_activeTransport == TransportType.wifiAware) {
          _activeTransport =
              _lanSubscribed ? TransportType.lan : TransportType.ble;
          _activeTransportController.add(_activeTransport);
        }
      }
    });
  }

  Future<void> start() async {
    if (_lanSubscribed) {
      try {
        await _lanService.start();
      } on Exception catch (e) {
        Logger.warning('TransportManager: LAN start failed: $e', 'Transport');
      }
    }
    if (_wifiAwareSubscribed) {
      // Fire-and-forget: don't block BLE advertising if Wi-Fi Aware hangs.
      unawaited(_wifiAwareService.start().catchError((Object e) {
        Logger.warning(
          'TransportManager: Wi-Fi Aware start failed: $e',
          'Transport',
        );
      }),);
    }
    // BLE start is handled by BleConnectionBloc — don't double-start here.
  }

  Future<void> stop() async {
    _gossipSync?.stop();
    await _lanService.stop();
    await _wifiAwareService.stop();
    await _bleService.stop();

    // Clear PeerRegistry so stale BLE UUIDs from the previous session
    // don't cause messages to route to the wrong peer after restart.
    _peerRegistry.clear();
  }

  /// Clear stale ID alias maps without stopping transports.
  ///
  /// Called when the BLE adapter restarts (e.g. Bluetooth toggled off/on)
  /// so that stale Central/Peripheral UUID mappings from the previous
  /// session don't cause messages to route to the wrong peer.
  void clearIdMaps() {
    _peerRegistry.clear();
    Logger.info('TransportManager: cleared PeerRegistry', 'Transport');
  }

  /// Push the current set of blocked peer IDs to the BLE transport layer.
  ///
  /// Messages from blocked peers are rejected at the BLE level before
  /// consuming queue space or processing time.
  void updateBlockedPeerIds(Set<String> blockedIds) {
    _bleService.updateBlockedPeerIds(blockedIds);
  }

  Future<void> dispose() async {
    await _availabilityLanSub?.cancel();
    await _availabilitySub?.cancel();
    await _peerRegistrySub?.cancel();
    await _relaySub?.cancel();

    for (final sub in _bleSubscriptions) {
      await sub.cancel();
    }
    _bleSubscriptions.clear();
    _unsubscribeFromLan();
    _unsubscribeFromWifiAware();

    await _lanService.dispose();
    await _wifiAwareService.dispose();
    await _bleService.dispose();

    await _peerDiscoveredController.close();
    await _peerLostController.close();
    await _messageReceivedController.close();
    await _photoPreviewReceivedController.close();
    await _photoRequestReceivedController.close();
    await _photoProgressController.close();
    await _photoReceivedController.close();
    await _anchorDropReceivedController.close();
    await _reactionReceivedController.close();
    await _activeTransportController.close();
    await _peerTransportChangedController.close();
    await _peerIdChangedController.close();
  }

  // ==================== Unified Streams ====================

  Stream<ble.DiscoveredPeer> get peerDiscoveredStream =>
      _peerDiscoveredController.stream;

  Stream<String> get peerLostStream => _peerLostController.stream;

  Stream<ble.ReceivedMessage> get messageReceivedStream =>
      _messageReceivedController.stream;

  Stream<ble.ReceivedPhotoPreview> get photoPreviewReceivedStream =>
      _photoPreviewReceivedController.stream;

  Stream<ble.ReceivedPhotoRequest> get photoRequestReceivedStream =>
      _photoRequestReceivedController.stream;

  Stream<ble.PhotoTransferProgress> get photoProgressStream =>
      _photoProgressController.stream;

  Stream<ble.ReceivedPhoto> get photoReceivedStream =>
      _photoReceivedController.stream;

  Stream<ble.AnchorDropReceived> get anchorDropReceivedStream =>
      _anchorDropReceivedController.stream;

  Stream<ble.ReactionReceived> get reactionReceivedStream =>
      _reactionReceivedController.stream;

  Stream<ble.PeerIdChanged> get peerIdChangedStream =>
      _peerIdChangedController.stream;

  // ==================== E2EE Helpers ====================

  /// Returns the peer ID that EncryptionService uses as session key.
  /// Sessions are keyed by canonical peerId (= conversation ID), so this
  /// is now an identity function — kept for call-site clarity.
  String _encPeerId(String canonicalPeerId) => canonicalPeerId;

  /// Encrypts [payload] content using the shared [MessageEnvelope] utility.
  /// Returns a new [MessagePayload] with encrypted content JSON, or the
  /// original payload unchanged if no session exists or encryption fails.
  Future<ble.MessagePayload> _encryptMessagePayload(
    String canonicalPeerId,
    ble.MessagePayload payload,
  ) async {
    final enc = _encryptionService;
    if (enc == null) return payload;

    final envelope = await encryptMessageContent(
      peerId: _encPeerId(canonicalPeerId),
      content: payload.content,
      replyToId: payload.replyToId,
      encService: enc,
    );
    if (envelope == null) return payload;

    return ble.MessagePayload(
      messageId: payload.messageId,
      type: payload.type,
      // replyToId is inside the ciphertext; outer field cleared to avoid leakage.
      content: jsonEncode(envelope.toJsonFields()),
    );
  }

  /// Decrypts an incoming [ReceivedMessage] using the shared [MessageEnvelope]
  /// utility. Returns the message unchanged if not encrypted or decryption fails.
  Future<ble.ReceivedMessage> _decryptReceivedMessage(
    ble.ReceivedMessage msg,
  ) async {
    final enc = _encryptionService;
    if (enc == null) return msg;

    final parsed = tryParseEncryptedContent(msg.content);
    if (parsed == null) return msg;

    final decrypted = await decryptMessageContent(
      peerId: _encPeerId(msg.fromPeerId),
      json: parsed,
      encService: enc,
    );
    if (decrypted == null) {
      Logger.warning(
        'E2EE: message decrypt failed from ${msg.fromPeerId.substring(0, 8)} — dropped',
        'E2EE',
      );
      return msg;
    }

    return ble.ReceivedMessage(
      fromPeerId: msg.fromPeerId,
      messageId: msg.messageId,
      type: msg.type,
      content: decrypted.content,
      timestamp: msg.timestamp,
      replyToId: decrypted.replyToId,
      isEncrypted: true,
    );
  }

  /// Encrypts [bytes] using the shared [MessageEnvelope] photo utility.
  /// Decrypts photo bytes using the shared [MessageEnvelope] photo utility.
  Future<Uint8List> _decryptPhotoBytes(
    String fromPeerId,
    Uint8List bytes,
  ) async {
    final enc = _encryptionService;
    if (enc == null) return bytes;
    return decryptPhotoBytes(
      peerId: _encPeerId(fromPeerId),
      bytes: bytes,
      encService: enc,
    );
  }

  // ==================== Unified Send Operations ====================

  Future<void> broadcastProfile(ble.BroadcastPayload payload) async {
    // Inject our E2EE public key into the payload so every transport
    // (LAN beacon, Wi-Fi Aware) carries it.  BleService already injects
    // it internally, so the BLE path is unaffected even if it's set twice.
    final enc = _encryptionService;
    final pkHex = enc?.localPublicKeyHex;
    final spkHex = enc?.localEd25519PublicKeyHex;
    var enriched = payload;
    if (pkHex != null && enriched.publicKeyHex == null) {
      enriched = enriched.copyWith(publicKeyHex: pkHex);
    }
    if (spkHex != null && enriched.signingPublicKeyHex == null) {
      enriched = enriched.copyWith(signingPublicKeyHex: spkHex);
    }

    // Always broadcast on BLE for maximum compatibility
    await _bleService.broadcastProfile(enriched);

    // Update LAN profile if subscribed
    if (_lanSubscribed) {
      await _lanService.updateProfile(enriched);
    }

    // Also publish on Wi-Fi Aware if subscribed
    if (_wifiAwareSubscribed) {
      await _wifiAwareService.updateProfile(enriched);
    }
  }

  Future<bool> sendMessage(String peerId, ble.MessagePayload payload) async {
    final transports = _peerRegistry.transportsFor(peerId);
    final bleId = _peerRegistry.bleIdFor(peerId) ?? peerId;

    // Mark message as seen in MessageRouter dedup to prevent echo
    _messageRouter.markSeen(payload.messageId);

    // Cache serialized bytes for gossip fulfillment
    final ownId = _ownUserId;
    if (ownId != null && payload.messageId.isNotEmpty) {
      final serialized = BinaryMessageCodec.encodeMessage(
        senderId: ownId,
        messageId: payload.messageId,
        messageType: payload.type,
        content: payload.content,
        replyToId: payload.replyToId,
        destinationUserId: peerId,
      );
      _gossipSync?.cacheMessage(payload.messageId, serialized);
    }

    // Try LAN if peer is reachable via LAN.
    if (transports.contains(TransportType.lan) && _isTransportAllowed(TransportType.lan)) {
      final sw = Stopwatch()..start();
      final encPayload = await _encryptMessagePayload(peerId, payload);
      final success = await _lanService.sendMessage(peerId, encPayload);
      sw.stop();
      _healthTracker?.recordSendResult(peerId, TransportType.lan,
          success: success, rttMs: sw.elapsedMilliseconds,);
      if (success) return true;
      Logger.warning(
        'TransportManager: LAN send failed, trying next transport',
        'Transport',
      );
    }

    // Try Wi-Fi Aware if peer is reachable via Wi-Fi Aware.
    if (transports.contains(TransportType.wifiAware) && _isTransportAllowed(TransportType.wifiAware)) {
      final sw = Stopwatch()..start();
      final encPayload = await _encryptMessagePayload(peerId, payload);
      final success = await _wifiAwareService.sendMessage(peerId, encPayload);
      sw.stop();
      _healthTracker?.recordSendResult(peerId, TransportType.wifiAware,
          success: success, rttMs: sw.elapsedMilliseconds,);
      if (success) return true;
      Logger.warning(
        'TransportManager: Wi-Fi Aware send failed, trying BLE',
        'Transport',
      );
    }

    // BLE fallback — verify the BLE ID is still connected before sending.
    // A stale BLE ID (from pre-migration) could route to the wrong device.
    if (!_bleService.isPeerReachable(bleId)) {
      Logger.warning(
        'TransportManager: BLE fallback skipped — peer $bleId not reachable',
        'Transport',
      );
      return false;
    }

    // BLE handles its own E2EE inside BleFacade — don't double-encrypt.
    final sw = Stopwatch()..start();
    final success = await _bleService.sendMessage(bleId, payload);
    sw.stop();
    _healthTracker?.recordSendResult(peerId, TransportType.ble,
        success: success, rttMs: sw.elapsedMilliseconds,);
    return success;
  }

  Future<bool> sendPhoto(
    String peerId,
    Uint8List photoData,
    String messageId, {
    String? photoId,
  }) async {
    final transports = _peerRegistry.transportsFor(peerId);
    final bleId = _peerRegistry.bleIdFor(peerId) ?? peerId;

    // Try LAN if peer is reachable via LAN.
    if (transports.contains(TransportType.lan) && _isTransportAllowed(TransportType.lan)) {
      final sw = Stopwatch()..start();
      final success = await _lanService.sendPhoto(
        peerId,
        photoData,
        messageId,
        photoId: photoId,
      );
      sw.stop();
      _healthTracker?.recordSendResult(peerId, TransportType.lan,
          success: success, rttMs: sw.elapsedMilliseconds,);
      if (success) return true;
      Logger.warning(
        'TransportManager: LAN photo send failed, trying next transport',
        'Transport',
      );
    }

    // Try Wi-Fi Aware if peer is reachable via Wi-Fi Aware.
    if (transports.contains(TransportType.wifiAware) && _isTransportAllowed(TransportType.wifiAware)) {
      final sw = Stopwatch()..start();
      final success = await _wifiAwareService.sendPhoto(
        peerId,
        photoData,
        messageId,
        photoId: photoId,
      );
      sw.stop();
      _healthTracker?.recordSendResult(peerId, TransportType.wifiAware,
          success: success, rttMs: sw.elapsedMilliseconds,);
      if (success) return true;
      Logger.warning(
        'TransportManager: Wi-Fi Aware photo send failed, trying next transport',
        'Transport',
      );
    }

    // Wi-Fi Direct: try before BLE for large payloads (photos).
    if (_isTransportAllowed(TransportType.wifiDirect)) {
      final wifiDirectSuccess = await _sendPhotoViaWifiDirect(
        peerId, photoData, messageId, photoId: photoId,
      );
      if (wifiDirectSuccess) return true;
    }

    // BLE fallback — verify the BLE ID is still connected before sending.
    if (!_bleService.isPeerReachable(bleId)) {
      Logger.warning(
        'TransportManager: BLE photo fallback skipped — peer $bleId not reachable',
        'Transport',
      );
      return false;
    }

    // BLE photo transfer: BLE's sendPhoto handles its own E2EE internally
    // (via PhotoTransferHandler._encryptionService), so do NOT encrypt here.
    final sw = Stopwatch()..start();
    final success = await _bleService.sendPhoto(
        bleId, photoData, messageId, photoId: photoId,);
    sw.stop();
    _healthTracker?.recordSendResult(peerId, TransportType.ble,
        success: success, rttMs: sw.elapsedMilliseconds,);
    return success;
  }

  Future<bool> sendPhotoPreview({
    required String peerId,
    required String messageId,
    required String photoId,
    required Uint8List thumbnailBytes,
    required int originalSize,
  }) async {
    final transports = _peerRegistry.transportsFor(peerId);
    final bleId = _peerRegistry.bleIdFor(peerId) ?? peerId;

    if (transports.contains(TransportType.lan) && _isTransportAllowed(TransportType.lan)) {
      final success = await _lanService.sendPhotoPreview(
        peerId: peerId,
        messageId: messageId,
        photoId: photoId,
        thumbnailBytes: thumbnailBytes,
        originalSize: originalSize,
      );
      if (success) return true;
    }

    if (transports.contains(TransportType.wifiAware) && _isTransportAllowed(TransportType.wifiAware)) {
      final success = await _wifiAwareService.sendPhotoPreview(
        peerId: peerId,
        messageId: messageId,
        photoId: photoId,
        thumbnailBytes: thumbnailBytes,
        originalSize: originalSize,
      );
      if (success) return true;
    }

    return _bleService.sendPhotoPreview(
      peerId: bleId,
      messageId: messageId,
      photoId: photoId,
      thumbnailBytes: thumbnailBytes,
      originalSize: originalSize,
    );
  }

  Future<bool> sendPhotoRequest({
    required String peerId,
    required String messageId,
    required String photoId,
  }) async {
    final transports = _peerRegistry.transportsFor(peerId);
    final bleId = _peerRegistry.bleIdFor(peerId) ?? peerId;

    if (transports.contains(TransportType.lan) && _isTransportAllowed(TransportType.lan)) {
      final success = await _lanService.sendPhotoRequest(
        peerId: peerId,
        messageId: messageId,
        photoId: photoId,
      );
      if (success) return true;
    }

    if (transports.contains(TransportType.wifiAware) && _isTransportAllowed(TransportType.wifiAware)) {
      final success = await _wifiAwareService.sendPhotoRequest(
        peerId: peerId,
        messageId: messageId,
        photoId: photoId,
      );
      if (success) return true;
    }

    return _bleService.sendPhotoRequest(
      peerId: bleId,
      messageId: messageId,
      photoId: photoId,
    );
  }

  Future<bool> sendDropAnchor(String peerId) async {
    final transports = _peerRegistry.transportsFor(peerId);
    final bleId = _peerRegistry.bleIdFor(peerId) ?? peerId;

    if (transports.contains(TransportType.lan) && _isTransportAllowed(TransportType.lan)) {
      final success = await _lanService.sendDropAnchor(peerId);
      if (success) return true;
    }

    if (transports.contains(TransportType.wifiAware) && _isTransportAllowed(TransportType.wifiAware)) {
      final success = await _wifiAwareService.sendDropAnchor(peerId);
      if (success) return true;
    }

    return _bleService.sendDropAnchor(bleId);
  }

  Future<bool> sendReaction({
    required String peerId,
    required String messageId,
    required String emoji,
    required String action,
  }) async {
    final transports = _peerRegistry.transportsFor(peerId);
    final bleId = _peerRegistry.bleIdFor(peerId) ?? peerId;

    if (transports.contains(TransportType.lan) && _isTransportAllowed(TransportType.lan)) {
      final success = await _lanService.sendReaction(
        peerId: peerId,
        messageId: messageId,
        emoji: emoji,
        action: action,
      );
      if (success) return true;
    }

    if (transports.contains(TransportType.wifiAware) && _isTransportAllowed(TransportType.wifiAware)) {
      final success = await _wifiAwareService.sendReaction(
        peerId: peerId,
        messageId: messageId,
        emoji: emoji,
        action: action,
      );
      if (success) return true;
    }

    return _bleService.sendReaction(
      peerId: bleId,
      messageId: messageId,
      emoji: emoji,
      action: action,
    );
  }

  // ==================== BLE-Specific (still needed) ====================

  ble.BleStatus get bleStatus => _bleService.status;
  Stream<ble.BleStatus> get bleStatusStream => _bleService.statusStream;

  Future<bool> isBluetoothAvailable() => _bleService.isBluetoothAvailable();
  Future<bool> isBluetoothEnabled() => _bleService.isBluetoothEnabled();
  Future<bool> requestPermissions() => _bleService.requestPermissions();
  Future<bool> hasPermissions() => _bleService.hasPermissions();

  Future<void> startScanning() => _bleService.startScanning();
  Future<void> stopScanning() => _bleService.stopScanning();
  Future<void> setBatterySaverMode({required bool enabled}) =>
      _bleService.setBatterySaverMode(enabled: enabled);

  bool isPeerReachable(String peerId) {
    final transports = _peerRegistry.transportsFor(peerId);
    final bleId = _peerRegistry.bleIdFor(peerId) ?? peerId;

    for (final t in transports) {
      switch (t) {
        case TransportType.lan:
          if (_lanService.isPeerReachable(peerId)) return true;
        case TransportType.wifiAware:
          if (_wifiAwareService.isPeerReachable(peerId)) return true;
        case TransportType.ble:
        case TransportType.wifiDirect:
          if (_bleService.isPeerReachable(bleId)) return true;
      }
    }
    // Fallback: check BLE directly
    return _bleService.isPeerReachable(bleId);
  }

  /// Fetch all full-size profile photos for a peer (BLE only — uses fff4).
  Future<bool> fetchFullProfilePhotos(String peerId) =>
      _bleService.fetchFullProfilePhotos(peerId);

  /// Cancel an ongoing photo transfer.
  Future<void> cancelPhotoTransfer(String messageId) =>
      _bleService.cancelPhotoTransfer(messageId);

  // BLE service interface passthrough for blocs that need it
  BleServiceInterface get bleService => _bleService;

  // ==================== Wi-Fi Direct Photo Transfer ====================

  /// Send a photo via Wi-Fi Direct (Nearby Connections / Multipeer).
  ///
  /// Encrypts with E2EE if a session exists, sends via HighSpeedTransferService,
  /// and signals the receiver to start browsing via BLE.
  Future<bool> _sendPhotoViaWifiDirect(
    String peerId,
    Uint8List photoData,
    String messageId, {
    String? photoId,
  }) async {
    final hsService = _highSpeedService;
    if (hsService == null) return false;

    try {
      final available = await hsService.isAvailable;
      if (!available) return false;

      Logger.info('TransportManager: Attempting Wi-Fi Direct photo transfer', 'Transport');

      final transferId = photoId ?? messageId;
      final sw = Stopwatch()..start();

      // Completer is resolved when sendPayload confirms native advertising
      // is active. We send the BLE signal to the receiver ONLY after this —
      // no guessing with delays, no race condition.
      final advertisingReady = Completer<void>();

      final sendFuture = hsService.sendPayload(
        transferId: transferId,
        peerId: peerId,
        data: photoData,
        timeout: const Duration(seconds: 30),
        onAdvertising: () {
          if (!advertisingReady.isCompleted) advertisingReady.complete();
        },
      );

      // Wait for confirmed advertising before telling the receiver to browse.
      // Timeout after 5s in case sendPayload fails before calling onAdvertising.
      try {
        await advertisingReady.future.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        Logger.warning(
          'TransportManager: Advertising ready timeout — sending BLE signal anyway',
          'Transport',
        );
      }

      // Tell receiver to start browsing for us.
      // Suppress mesh relay writes first — mesh broadcastNeighborList()
      // floods the iOS prepare queue with simultaneous writes to all peers,
      // causing CBATTError 9 for this critical signal even after 4 retries.
      final ownId = _ownUserId;
      if (ownId != null) {
        _bleService.suppressMeshRelay();
        try {
          await sendMessage(
            peerId,
            ble.MessagePayload(
              messageId: transferId,
              type: ble.MessageType.wifiTransferReady,
              content: jsonEncode({
                'transfer_id': transferId,
                'sender_nearby_id': ownId,
              }),
            ),
          );
        } finally {
          _bleService.resumeMeshRelay();
        }
      }

      final success = await sendFuture;
      sw.stop();
      _healthTracker?.recordSendResult(peerId, TransportType.wifiDirect,
          success: success, rttMs: sw.elapsedMilliseconds,);

      if (success) {
        Logger.info('TransportManager: Wi-Fi Direct transfer succeeded', 'Transport');
      } else {
        Logger.warning(
          'TransportManager: Wi-Fi Direct failed, falling back to BLE',
          'Transport',
        );
      }
      return success;
    } on Exception catch (e) {
      Logger.warning('TransportManager: Wi-Fi Direct error: $e', 'Transport');
      return false;
    }
  }

  // ==================== Battery-Aware Transport Policy ====================

  void setBatteryPolicy(int batteryLevel) {
    _currentBatteryLevel = batteryLevel;
    _minBatteryForTransport.clear();

    _minBatteryForTransport[TransportType.lan] =
        AppConstants.batteryCriticalThreshold;
    _minBatteryForTransport[TransportType.wifiAware] =
        AppConstants.batteryCriticalThreshold;
    _minBatteryForTransport[TransportType.wifiDirect] =
        AppConstants.batteryLowThreshold;

    Logger.debug(
      'TransportManager: Battery policy updated for level=$batteryLevel%',
      'Transport',
    );
  }

  bool _isTransportAllowed(TransportType transport) {
    final minLevel = _minBatteryForTransport[transport];
    if (minLevel == null) return true;
    return _currentBatteryLevel >= minLevel;
  }

  // ==================== PeerRegistry Change Listener ====================

  /// Subscribe to PeerRegistry's peerIdChanged stream so we forward
  /// transport-level ID changes to consumers that track transport state.
  ///
  /// Since the canonical ID is now always the userId (stable), these events
  /// signal transport-level changes (e.g., BLE MAC rotation) — the userId
  /// itself never changes, so no conversation or E2EE session migration is
  /// needed.
  void _subscribeToPeerRegistryChanges() {
    _peerRegistrySub = _peerRegistry.peerIdChangedStream.listen((event) {
      // Forward to blocs that track transport-level state changes.
      if (event.userId != null) {
        _peerIdChangedController.add(ble.PeerIdChanged(
          oldPeerId: event.oldCanonicalId,
          newPeerId: event.newCanonicalId,
          userId: event.userId!,
        ),);
      }

      // Emit transport change event.
      final bestTransport = _peerRegistry.bestTransportFor(
        event.userId ?? event.newCanonicalId,
      );
      _peerTransportChangedController.add(PeerTransportChanged(
        peerId: event.userId ?? event.newCanonicalId,
        oldTransport: null,
        newTransport: bestTransport ?? TransportType.ble,
      ),);

      Logger.info(
        'TransportManager: PeerRegistry transport ID changed '
        '${event.oldCanonicalId} → ${event.newCanonicalId} '
        '(userId=${event.userId})',
        'Transport',
      );
    });
  }

  // ==================== Transport Removal Helpers ====================

  /// Remove a transport from all peers via PeerRegistry and emit
  /// peerLost for any peers with no remaining transports.
  void _removeLanTransportFromAllPeers() {
    for (final identity in _peerRegistry.allPeers.toList()) {
      final lanId = identity.transportIds[TransportType.lan];
      if (lanId != null) {
        final result = _peerRegistry.removeTransport(lanId, TransportType.lan);
        if (result != null && _peerRegistry.getByCanonical(result) == null) {
          _peerLostController.add(result);
        }
      }
    }
  }

  void _removeWifiAwareTransportFromAllPeers() {
    for (final identity in _peerRegistry.allPeers.toList()) {
      final waId = identity.transportIds[TransportType.wifiAware];
      if (waId != null) {
        final result = _peerRegistry.removeTransport(waId, TransportType.wifiAware);
        if (result != null && _peerRegistry.getByCanonical(result) == null) {
          _peerLostController.add(result);
        }
      }
    }
  }

  // ==================== Gossip Sync Wiring ====================

  /// Wire GossipSyncService callbacks so it can send gossip payloads
  /// over the best available transport for each peer.
  void _wireGossipSync() {
    final gossip = _gossipSync;
    if (gossip == null) return;

    gossip
      ..onSendGossip = (peerId, payload) {
        final ownId = _ownUserId;
        if (ownId == null) return;

        // Convert the JSON-style gossip payload to binary
        final gcsBase64 = payload['gcs'] as String?;
        final n = payload['n'] as int?;
        if (gcsBase64 == null || n == null) return;

        final gcsBytes = base64Decode(gcsBase64);
        final binaryData = BinaryMessageCodec.encodeGossipSync(
          senderId: ownId,
          gcsBytes: Uint8List.fromList(gcsBytes),
          messageCount: n,
        );

        // Send via best transport for this peer
        _sendRawBytes(peerId, binaryData);
      }

      ..onMissingMessages = (peerId, missingIds, originalN) {
        final ownId = _ownUserId;
        if (ownId == null) return;

        // Convert string indices back to int for the binary codec
        final indices = missingIds
            .map(int.tryParse)
            .whereType<int>()
            .toList();
        if (indices.isEmpty) return;

        final binaryData = BinaryMessageCodec.encodeGossipRequest(
          senderId: ownId,
          recipientId: peerId,
          missingIndices: indices,
          originalN: originalN,
        );

        _sendRawBytes(peerId, binaryData);
      }

      ..onResendMessage = _sendRawBytes;
  }

  // ==================== Mesh Relay Wiring ====================

  /// Subscribe to MessageRouter's relay stream and forward packets to all
  /// connected peers except the original sender.
  ///
  /// High-density mode: when many peers are visible, relay is probabilistic
  /// (65% chance) to prevent network flooding on cruise ships with 50+ people.
  void _subscribeToMeshRelay() {
    _relaySub = _messageRouter.relayStream.listen((relay) {
      // High-density probabilistic relay check
      if (!_messageRouter.shouldRelay()) {
        Logger.debug(
          'Mesh relay: probabilistic skip for ${relay.messageId}',
          'Mesh',
        );
        return;
      }

      // Build the relay MeshPacket and serialize it
      final packet = MeshPacket(
        type: relay.type,
        ttl: relay.ttl,
        flags: relay.flags,
        timestamp: relay.timestamp,
        senderId: MeshPacket.truncateIdSync(relay.senderId),
        recipientId: MeshPacket.truncateIdSync(relay.recipientId),
        payload: relay.payload,
        messageId: relay.messageId,
      );
      final bytes = packet.serialize();

      // Resolve the exclude peer to canonical so we don't relay back to sender
      final excludeCanonical =
          _peerRegistry.resolveCanonical(relay.excludeTransportId) ??
              relay.excludeTransportId;

      var relayCount = 0;
      for (final canonicalId in _peerRegistry.allCanonicalIds) {
        if (canonicalId == excludeCanonical) continue;
        if (canonicalId == _ownUserId) continue;
        _sendRawBytes(canonicalId, bytes);
        relayCount++;
      }

      if (relayCount > 0) {
        Logger.debug(
          'Mesh relay: forwarded ${relay.type.name} (ttl=${relay.ttl}) '
          'to $relayCount peer(s), msgId=${relay.messageId.substring(0, 8)}',
          'Mesh',
        );
      }
    });
  }

  /// Sign [packetBytes] with Ed25519 if an [EncryptionService] is available.
  ///
  /// Returns the signed bytes (with 64-byte signature appended and
  /// [PacketFlags.hasSignature] flag set), or the original bytes if
  /// signing is unavailable or fails.
  Future<Uint8List> _maybeSign(Uint8List packetBytes) async {
    if (_encryptionService == null) return packetBytes;
    final signed = await MeshPacket.signSerialized(
      packetBytes,
      _encryptionService.sign,
    );
    return signed ?? packetBytes;
  }

  /// Send raw binary bytes to a peer via the best available transport.
  ///
  /// Packet bytes are Ed25519-signed before transmission when an
  /// [EncryptionService] is available.
  void _sendRawBytes(String peerId, Uint8List data) {
    _maybeSign(data).then((signedData) {
      final transports = _peerRegistry.transportsFor(peerId);
      final bleId = _peerRegistry.bleIdFor(peerId) ?? peerId;

      // Try LAN first
      if (transports.contains(TransportType.lan) &&
          _isTransportAllowed(TransportType.lan)) {
        _lanService.sendRawBytes(peerId, signedData).then((success) {
          if (!success && _bleService.isPeerReachable(bleId)) {
            _bleService.sendRawBytes(bleId, signedData);
          }
        }, onError: (_) {
          if (_bleService.isPeerReachable(bleId)) {
            _bleService.sendRawBytes(bleId, signedData);
          }
        },);
        return;
      }

      // BLE fallback
      if (_bleService.isPeerReachable(bleId)) {
        _bleService.sendRawBytes(bleId, signedData);
      }
    });
  }

  // ==================== Transport Subscriptions ====================

  void _subscribeToBle() {
    _bleSubscriptions.addAll([
      _bleService.peerDiscoveredStream.listen((peer) async {
        // Suppress peers whose GATT profile hasn't been read yet (userId=null).
        if (peer.userId == null) return;

        // Register transport in PeerRegistry — handles all migration logic.
        final result = _peerRegistry.registerTransport(
          transportId: peer.peerId,
          transport: TransportType.ble,
          userId: peer.userId,
          publicKeyHex: peer.publicKeyHex,
          signingPublicKeyHex: peer.signingPublicKeyHex,
        );

        final canonical = result.canonicalId;

        // Store E2EE key under the canonical ID. Await the DB write so the
        // key is persisted before the peer is emitted to the UI — prevents
        // the race where initiateHandshake runs before peer_public_keys is
        // populated.
        if (peer.publicKeyHex != null) {
          await _encryptionService?.storePeerPublicKey(
            canonical,
            peer.publicKeyHex!,
            ed25519PublicKeyHex: peer.signingPublicKeyHex,
          );
        }

        // Emit peer discovered with canonical ID + original transport ID
        // so DiscoveryBloc can persist the alias inside upsertPeer().
        _peerDiscoveredController.add(
          ble.DiscoveredPeer(
            peerId: canonical,
            name: peer.name,
            bio: peer.bio,
            age: peer.age,
            thumbnailBytes: peer.thumbnailBytes,
            userId: peer.userId,
            publicKeyHex: peer.publicKeyHex,
            signingPublicKeyHex: peer.signingPublicKeyHex,
            interests: peer.interests,
            timestamp: peer.timestamp,
            isRelayed: peer.isRelayed,
            hopCount: peer.hopCount,
            fullPhotoCount: peer.fullPhotoCount,
            rssi: peer.rssi,
            photoThumbnails: peer.photoThumbnails,
            transportId: peer.peerId != canonical ? peer.peerId : null,
            transportType: TransportType.ble.name,
          ),
        );

        // Track peer in gossip sync service
        _gossipSync?.addPeer(canonical);
      }),
      _bleService.peerLostStream.listen((peerId) {
        final canonical = _peerRegistry.resolveCanonical(peerId) ?? peerId;
        final result = _peerRegistry.removeTransport(peerId, TransportType.ble);

        // If removal resulted in a canonical that no longer exists, the peer
        // is fully lost (no remaining transports).
        if (result != null && _peerRegistry.getByCanonical(result) == null) {
          _peerLostController.add(canonical);
          _gossipSync?.removePeer(canonical);
        }
      }),
      _bleService.messageReceivedStream.listen((msg) {
        // Cross-transport dedup via MessageRouter
        final canonical = _peerRegistry.resolveCanonical(msg.fromPeerId) ?? msg.fromPeerId;
        if (_messageRouter.isDuplicate(msg.messageId)) return;
        _messageRouter.markSeen(msg.messageId);

        _messageReceivedController.add(canonical == msg.fromPeerId
            ? msg
            : ble.ReceivedMessage(
                fromPeerId: canonical,
                messageId: msg.messageId,
                type: msg.type,
                content: msg.content,
                timestamp: msg.timestamp,
                replyToId: msg.replyToId,
              ),);
      }),
      _bleService.photoPreviewReceivedStream.listen((preview) {
        final canonical =
            _peerRegistry.resolveCanonical(preview.fromPeerId) ?? preview.fromPeerId;
        _photoPreviewReceivedController.add(canonical == preview.fromPeerId
            ? preview
            : ble.ReceivedPhotoPreview(
                fromPeerId: canonical,
                messageId: preview.messageId,
                photoId: preview.photoId,
                thumbnailBytes: preview.thumbnailBytes,
                originalSize: preview.originalSize,
                timestamp: preview.timestamp,
              ),);
      }),
      _bleService.photoRequestReceivedStream.listen((req) {
        final canonical = _peerRegistry.resolveCanonical(req.fromPeerId) ?? req.fromPeerId;
        _photoRequestReceivedController.add(canonical == req.fromPeerId
            ? req
            : ble.ReceivedPhotoRequest(
                fromPeerId: canonical,
                messageId: req.messageId,
                photoId: req.photoId,
                timestamp: req.timestamp,
              ),);
      }),
      _bleService.photoProgressStream.listen((progress) {
        final canonical = _peerRegistry.resolveCanonical(progress.peerId) ?? progress.peerId;
        _photoProgressController.add(canonical == progress.peerId
            ? progress
            : progress.copyWith(peerId: canonical),);
      }),
      _bleService.photoReceivedStream.listen((photo) async {
        final canonical = _peerRegistry.resolveCanonical(photo.fromPeerId) ?? photo.fromPeerId;
        // BLE photos may be E2EE-encrypted; decrypt using the BLE peer ID
        // (which is the session key in EncryptionService).
        final dec = await _decryptPhotoBytes(photo.fromPeerId, photo.photoBytes);
        _photoReceivedController.add(
          canonical == photo.fromPeerId && dec == photo.photoBytes
              ? photo
              : ble.ReceivedPhoto(
                  fromPeerId: canonical,
                  messageId: photo.messageId,
                  photoBytes: dec,
                  timestamp: photo.timestamp,
                  photoId: photo.photoId,
                ),
        );
      }),
      _bleService.anchorDropReceivedStream.listen((drop) {
        final canonical = _peerRegistry.resolveCanonical(drop.fromPeerId) ?? drop.fromPeerId;
        _anchorDropReceivedController.add(canonical == drop.fromPeerId
            ? drop
            : ble.AnchorDropReceived(
                fromPeerId: canonical,
                timestamp: drop.timestamp,
              ),);
      }),
      _bleService.reactionReceivedStream.listen((reaction) {
        final canonical =
            _peerRegistry.resolveCanonical(reaction.fromPeerId) ?? reaction.fromPeerId;
        // Cross-transport dedup for reactions
        final dedupKey = '${reaction.messageId}:${reaction.emoji}:${reaction.action}';
        if (_messageRouter.isDuplicate(dedupKey)) return;
        _messageRouter.markSeen(dedupKey);

        _reactionReceivedController.add(canonical == reaction.fromPeerId
            ? reaction
            : ble.ReactionReceived(
                fromPeerId: canonical,
                messageId: reaction.messageId,
                emoji: reaction.emoji,
                action: reaction.action,
                timestamp: reaction.timestamp,
              ),);
      }),
      _bleService.peerIdChangedStream.listen((change) {
        // BLE-internal ID change (e.g. Central→Peripheral UUID on iOS).
        // Re-register the new ID in PeerRegistry. The canonical (userId) is
        // unchanged — only the transport-level BLE UUID is updated.
        final userId = _peerRegistry.userIdForCanonical(change.oldPeerId);
        if (userId != null) {
          _peerRegistry.registerTransport(
            transportId: change.newPeerId,
            transport: TransportType.ble,
            userId: userId,
          );
        }

        // Forward to blocs — no E2EE migration needed since sessions are
        // keyed by userId (canonical), which doesn't change.
        _peerIdChangedController.add(change);
      }),
    ]);
  }

  void _subscribeToLanAdditive() {
    if (_lanSubscribed) return;
    _lanSubscribed = true;

    _lanSubscriptions.addAll([
      _lanService.peerDiscoveredStream.listen((peer) async {
        final result = _peerRegistry.registerTransport(
          transportId: peer.peerId,
          transport: TransportType.lan,
          userId: peer.userId,
          publicKeyHex: peer.publicKeyHex,
          signingPublicKeyHex: peer.signingPublicKeyHex,
        );

        final canonical = result.canonicalId;

        // LAN peers carry publicKeyHex in the beacon — store under canonical ID.
        if (peer.publicKeyHex != null) {
          await _encryptionService?.storePeerPublicKey(
            canonical,
            peer.publicKeyHex!,
            ed25519PublicKeyHex: peer.signingPublicKeyHex,
          );
        }

        // Always emit discovered (even for updated — LAN may have fresh profile data).
        _peerDiscoveredController.add(
          ble.DiscoveredPeer(
            peerId: canonical,
            name: peer.name,
            bio: peer.bio,
            age: peer.age,
            thumbnailBytes: peer.thumbnailBytes,
            userId: peer.userId,
            publicKeyHex: peer.publicKeyHex,
            signingPublicKeyHex: peer.signingPublicKeyHex,
            interests: peer.interests,
            timestamp: peer.timestamp,
            rssi: peer.rssi,
            isRelayed: peer.isRelayed,
            hopCount: peer.hopCount,
            fullPhotoCount: peer.fullPhotoCount,
            photoThumbnails: peer.photoThumbnails,
            transportId: peer.peerId != canonical ? peer.peerId : null,
            transportType: TransportType.lan.name,
          ),
        );
      }),
      _lanService.peerLostStream.listen((peerId) {
        final canonical = _peerRegistry.resolveCanonical(peerId) ?? peerId;
        final result = _peerRegistry.removeTransport(peerId, TransportType.lan);
        if (result != null && _peerRegistry.getByCanonical(result) == null) {
          _peerLostController.add(canonical);
        }
      }),
      _lanService.messageReceivedStream.listen((msg) async {
        // Cross-transport dedup
        if (_messageRouter.isDuplicate(msg.messageId)) return;
        _messageRouter.markSeen(msg.messageId);
        // Resolve LAN peer ID to canonical (same as BLE path).
        final canonical =
            _peerRegistry.resolveCanonical(msg.fromPeerId) ?? msg.fromPeerId;
        final resolved = canonical == msg.fromPeerId
            ? msg
            : ble.ReceivedMessage(
                fromPeerId: canonical,
                messageId: msg.messageId,
                type: msg.type,
                content: msg.content,
                timestamp: msg.timestamp,
                replyToId: msg.replyToId,
              );
        _messageReceivedController.add(await _decryptReceivedMessage(resolved));
      }),
      _lanService.photoPreviewReceivedStream.listen(
        _photoPreviewReceivedController.add,
      ),
      _lanService.photoRequestReceivedStream.listen(
        _photoRequestReceivedController.add,
      ),
      _lanService.photoProgressStream.listen(
        _photoProgressController.add,
      ),
      _lanService.photoReceivedStream.listen(_photoReceivedController.add),
      _lanService.anchorDropReceivedStream.listen(
        _anchorDropReceivedController.add,
      ),
      _lanService.reactionReceivedStream.listen((reaction) {
        // Cross-transport dedup for reactions
        final dedupKey = '${reaction.messageId}:${reaction.emoji}:${reaction.action}';
        if (_messageRouter.isDuplicate(dedupKey)) return;
        _messageRouter.markSeen(dedupKey);
        _reactionReceivedController.add(reaction);
      }),
      _lanService.noiseHandshakeStream.listen(_processIncomingHandshake),
    ]);
  }

  void _unsubscribeFromLan() {
    for (final sub in _lanSubscriptions) {
      sub.cancel();
    }
    _lanSubscriptions.clear();
    _lanSubscribed = false;
  }

  // ==================== E2EE Handshake Routing ====================

  /// Set up subscriptions to route Noise_XK handshake messages between
  /// transports and EncryptionService.  Called once from constructor.
  void _subscribeToHandshakeRouting() {
    final enc = _encryptionService;
    if (enc == null) return;

    _bleSubscriptions
      // Incoming from BLE: translate BLE UUID → canonical ID before processing.
      ..add(
        _bleService.noiseHandshakeStream.listen(_processIncomingHandshake),
      )

      // Outbound from EncryptionService: route to the correct transport.
      ..add(
        enc.outboundHandshakeStream.listen(_routeOutboundHandshake),
      );
  }

  /// Route an incoming handshake frame to EncryptionService, translating
  /// the transport-level peer ID to the canonical conversation ID first.
  ///
  /// For step 1 (new handshake initiation), any ID is accepted.
  /// For steps 2-3 (continuation), the resolved ID MUST match a pending
  /// handshake — otherwise the message is dropped with a warning. This
  /// prevents cross-routing between concurrent handshakes on different
  /// transports/directions.
  void _processIncomingHandshake(ble.NoiseHandshakeReceived msg) {
    final enc = _encryptionService;
    if (enc == null) return;
    final rawId = msg.fromPeerId;

    // Use PeerRegistry for canonical resolution.
    var canonicalId = _peerRegistry.resolveCanonical(rawId) ?? rawId;

    // If the peerId is a BLE Central UUID (not found in PeerRegistry), try
    // to resolve it to a known Peripheral UUID via BleService's userId mapping.
    if (_peerRegistry.getByCanonical(canonicalId) == null) {
      final resolvedPeerId = _bleService.resolveToPeripheralId(canonicalId);
      if (resolvedPeerId != null && resolvedPeerId != canonicalId) {
        final finalCanonical =
            _peerRegistry.resolveCanonical(resolvedPeerId) ?? resolvedPeerId;
        Logger.debug(
          'TransportManager: handshake peerId resolved $canonicalId → $finalCanonical',
          'Transport',
        );
        canonicalId = finalCanonical;
      }
    }

    // For steps 2 and 3, verify the resolved ID matches a pending handshake.
    // Use a strict search order: canonical → rawId → bleId.
    // Only accept the FIRST match — never fall through to a second candidate,
    // which could be a different concurrent handshake.
    if (msg.step >= 2 && !enc.hasPendingHandshake(canonicalId)) {
      var resolved = false;
      // Try the raw BLE ID directly (Central UUID before registry update)
      if (enc.hasPendingHandshake(rawId)) {
        Logger.info(
          'TransportManager: handshake step ${msg.step} — canonical '
          '$canonicalId has no pending, using raw $rawId',
          'Transport',
        );
        canonicalId = rawId;
        resolved = true;
      }

      if (!resolved) {
        // Try reverse: maybe the pending handshake is under the BLE ID
        final bleId = _peerRegistry.bleIdFor(canonicalId);
        if (bleId != null && enc.hasPendingHandshake(bleId)) {
          Logger.info(
            'TransportManager: handshake step ${msg.step} — using '
            'bleId $bleId for canonical $canonicalId',
            'Transport',
          );
          canonicalId = bleId;
          resolved = true;
        }
      }

      if (!resolved) {
        // No pending handshake found under any known ID — drop the message
        // rather than routing to a potentially wrong session.
        Logger.warning(
          'TransportManager: dropping handshake step ${msg.step} from '
          'raw=$rawId — no matching pending handshake found '
          '(canonical=$canonicalId)',
          'Transport',
        );
        return;
      }
    }

    Logger.debug(
      'TransportManager: processing handshake step ${msg.step} from '
      'raw=$rawId, canonical=$canonicalId, '
      'hasPending=${enc.hasPendingHandshake(canonicalId)}',
      'Transport',
    );

    enc.processHandshakeMessage(canonicalId, msg.step, msg.payload).then(
      (result) {
        if (result.sessionEstablished) {
          Logger.info(
              'E2EE session established with $canonicalId', 'Transport',);
        }
        if (result.hasError) {
          Logger.warning(
              'Handshake error from $canonicalId: ${result.error}', 'Transport',);
        }
      },
      onError: (Object e) =>
          Logger.error('Noise handshake processing failed', e, null, 'Transport'),
    );
  }

  /// Route an outbound handshake message to the appropriate transport.
  Future<void> _routeOutboundHandshake(HandshakeMessageOut msg) async {
    final canonicalId = msg.peerId;
    final transports = _peerRegistry.transportsFor(canonicalId);
    final bleId = _peerRegistry.bleIdFor(canonicalId) ?? canonicalId;
    Logger.debug(
      'routeOutboundHandshake step ${msg.step}: canonical=$canonicalId, '
      'bleId=$bleId, transports=${transports.map((t) => t.name).join(', ')}',
      'Transport',
    );

    if (transports.contains(TransportType.lan) && _isTransportAllowed(TransportType.lan)) {
      final ok = await _lanService
          .sendHandshakeMessage(canonicalId, msg.step, msg.payload);
      if (ok) return;
      Logger.warning(
          'LAN handshake send failed for $canonicalId step ${msg.step}, trying BLE',
          'Transport',);
    }

    // BLE fallback — resolve canonical → BLE UUID.
    // BleFacade.sendHandshakeMessage internally handles retry loops,
    // reverse-path (fff5), and buffered pending handshakes.
    try {
      await _bleService.sendHandshakeMessage(bleId, msg.step, msg.payload);
    } on Exception catch (e) {
      Logger.error(
        'Handshake step ${msg.step} failed for $bleId via all transports',
        e, null, 'Transport',
      );
    }
  }

  void _subscribeToWifiAwareAdditive() {
    if (_wifiAwareSubscribed) return;
    _wifiAwareSubscribed = true;

    _wifiAwareSubscriptions.addAll([
      _wifiAwareService.peerDiscoveredStream.listen((peer) {
        final result = _peerRegistry.registerTransport(
          transportId: peer.peerId,
          transport: TransportType.wifiAware,
          userId: peer.userId,
          publicKeyHex: peer.publicKeyHex,
          signingPublicKeyHex: peer.signingPublicKeyHex,
        );

        final canonical = result.canonicalId;

        _peerDiscoveredController.add(
          ble.DiscoveredPeer(
            peerId: canonical,
            name: peer.name,
            bio: peer.bio,
            age: peer.age,
            thumbnailBytes: peer.thumbnailBytes,
            userId: peer.userId,
            publicKeyHex: peer.publicKeyHex,
            signingPublicKeyHex: peer.signingPublicKeyHex,
            interests: peer.interests,
            timestamp: peer.timestamp,
            rssi: peer.rssi,
            isRelayed: peer.isRelayed,
            hopCount: peer.hopCount,
            fullPhotoCount: peer.fullPhotoCount,
            photoThumbnails: peer.photoThumbnails,
            transportId: peer.peerId != canonical ? peer.peerId : null,
            transportType: TransportType.wifiAware.name,
          ),
        );
      }),
      _wifiAwareService.peerLostStream.listen((peerId) {
        final canonical = _peerRegistry.resolveCanonical(peerId) ?? peerId;
        final result =
            _peerRegistry.removeTransport(peerId, TransportType.wifiAware);
        if (result != null && _peerRegistry.getByCanonical(result) == null) {
          _peerLostController.add(canonical);
        }
      }),
      _wifiAwareService.messageReceivedStream.listen((msg) async {
        // Cross-transport dedup
        if (_messageRouter.isDuplicate(msg.messageId)) return;
        _messageRouter.markSeen(msg.messageId);
        _messageReceivedController.add(await _decryptReceivedMessage(msg));
      }),
      _wifiAwareService.photoPreviewReceivedStream.listen(
        _photoPreviewReceivedController.add,
      ),
      _wifiAwareService.photoRequestReceivedStream.listen(
        _photoRequestReceivedController.add,
      ),
      _wifiAwareService.photoProgressStream.listen(
        _photoProgressController.add,
      ),
      _wifiAwareService.photoReceivedStream.listen(_photoReceivedController.add),
      _wifiAwareService.anchorDropReceivedStream.listen(
        _anchorDropReceivedController.add,
      ),
      _wifiAwareService.reactionReceivedStream.listen((reaction) {
        // Cross-transport dedup for reactions
        final dedupKey = '${reaction.messageId}:${reaction.emoji}:${reaction.action}';
        if (_messageRouter.isDuplicate(dedupKey)) return;
        _messageRouter.markSeen(dedupKey);
        _reactionReceivedController.add(reaction);
      }),
    ]);
  }

  void _unsubscribeFromWifiAware() {
    for (final sub in _wifiAwareSubscriptions) {
      sub.cancel();
    }
    _wifiAwareSubscriptions.clear();
    _wifiAwareSubscribed = false;
  }
}
