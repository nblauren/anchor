import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wifi_aware_p2p/wifi_aware_p2p.dart' as wa;

import '../../core/constants/app_constants.dart';
import '../../core/utils/logger.dart';
import '../ble/ble_models.dart' as ble;
import '../ble/ble_service_interface.dart';
import '../encryption/encryption.dart';
import '../lan/lan.dart';
import '../nearby/nearby.dart';
import '../wifi_aware/wifi_aware_transport_service.dart';
import 'transport_enums.dart';
import 'transport_health_tracker.dart';

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
/// ## Per-Peer Routing
///
/// Each peer is associated with a *set* of available transports. The best
/// transport is recomputed whenever the set changes, and a
/// [PeerTransportChanged] event is emitted when the best changes.
///
/// ## Stream Architecture
///
/// BLE subscriptions are set up in the constructor and never cancelled until
/// dispose. LAN and Wi-Fi Aware subscriptions are additive — set up when the
/// transport becomes available, cancelled when it drops. Events from all
/// transports are merged into unified broadcast StreamControllers.
class TransportManager {
  TransportManager({
    required LanTransportService lanService,
    required WifiAwareTransportService wifiAwareService,
    required BleServiceInterface bleService,
    EncryptionService? encryptionService,
    TransportHealthTracker? healthTracker,
    HighSpeedTransferService? highSpeedTransferService,
  })  : _lanService = lanService,
        _wifiAwareService = wifiAwareService,
        _bleService = bleService,
        _encryptionService = encryptionService,
        _healthTracker = healthTracker,
        _highSpeedService = highSpeedTransferService {
    // Immediately subscribe to BLE streams so peer discovery works
    // even before initialize() is called (BleConnectionBloc starts BLE
    // independently).
    _subscribeToBle();
    _subscribeToHandshakeRouting();
    Logger.info('TransportManager: BLE stream forwarding active', 'Transport');
  }

  final LanTransportService _lanService;
  final WifiAwareTransportService _wifiAwareService;
  final BleServiceInterface _bleService;
  final EncryptionService? _encryptionService;
  final TransportHealthTracker? _healthTracker;
  final HighSpeedTransferService? _highSpeedService;

  /// Stores ownUserId from initialize() for Wi-Fi Direct sender ID.
  String? _ownUserId;

  // Battery-aware transport policy: maps TransportType → minimum battery level.
  // Populated by [setBatteryPolicy]. When a transport's minimum exceeds the
  // current battery level, that transport is skipped during sends.
  final Map<TransportType, int> _minBatteryForTransport = {};
  int _currentBatteryLevel = 100;

  // Magic byte prepended to encrypted photo payloads.
  // JPEG starts with 0xFF 0xD8, PNG with 0x89 — 0x01 is unambiguous.
  static const _kEncMagic = 0x01;
  static const _kNonceLen = 24;

  TransportType _activeTransport = TransportType.ble;
  bool _initialized = false;

  // ── Per-peer multi-transport tracking ───────────────────────────────────

  /// All transports currently available for each peer.
  final Map<String, Set<TransportType>> _peerTransports = {};

  /// The best (highest priority) transport for each peer — derived from
  /// [_peerTransports].
  final Map<String, TransportType> _peerBestTransport = {};

  // userId → canonical peerId for the current session.
  // Survives transport switches — used to emit PeerIdChanged when the same
  // person is rediscovered on a different transport (e.g. LAN → BLE fallback).
  final Map<String, String> _userIdToCurrentPeerId = {};
  // Suppressed BLE peerId → canonical (LAN/Wi-Fi Aware) peerId.
  // Used to translate incoming BLE events so they route to the right
  // conversation in the DB.
  final Map<String, String> _peerIdAlias = {};
  // Canonical (LAN/Wi-Fi Aware) peerId → BLE peerId.
  // Reverse of _peerIdAlias — used when a LAN send fails and we fall back to
  // BLE.  Without this, the BLE service receives a LAN session UUID it doesn't
  // recognise and resorts to mesh relay instead of a direct connection.
  final Map<String, String> _bleIdForCanonical = {};

  // ── Subscription lists (per-transport) ──────────────────────────────────

  final List<StreamSubscription> _bleSubscriptions = [];
  final List<StreamSubscription> _lanSubscriptions = [];
  final List<StreamSubscription> _wifiAwareSubscriptions = [];
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

  // ==================== Public Getters ====================

  TransportType get activeTransport => _activeTransport;
  Stream<TransportType> get activeTransportStream =>
      _activeTransportController.stream;

  Stream<PeerTransportChanged> get peerTransportChangedStream =>
      _peerTransportChangedController.stream;

  /// Returns the best transport currently available for [peerId], or null
  /// if the peer is not tracked.
  TransportType? transportForPeer(String peerId) => _peerBestTransport[peerId];

  /// Returns the BLE device ID for [canonicalPeerId], or [canonicalPeerId]
  /// unchanged if no BLE alias is known (BLE-only peer, or mapping not yet set).
  /// Used for BLE fallback sends when LAN/Wi-Fi Aware is unavailable.
  String bleIdForPeer(String canonicalPeerId) =>
      _bleIdForCanonical[canonicalPeerId] ?? canonicalPeerId;

  /// Maps a BLE device ID back to the canonical (LAN/Wi-Fi Aware) peerId used
  /// in conversations and UI.  Returns [blePeerId] unchanged if there is no
  /// alias (i.e. the peer was discovered via BLE only).
  String canonicalIdForBle(String blePeerId) =>
      _peerIdAlias[blePeerId] ?? blePeerId;

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

    // BLE is already initialized and started by BleConnectionBloc — don't
    // re-initialize here.

    // Try LAN first — works on both iOS and Android wherever a local network
    // interface is available (e.g. ship Wi-Fi).
    bool lanAvailable = false;
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
      } catch (e) {
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
          final lostPeerIds = _removeTransportFromAllPeers(TransportType.lan);
          for (final peerId in lostPeerIds) {
            _peerLostController.add(peerId);
          }
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
    bool wifiAwareAvailable = false;
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
    } catch (e) {
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
        final lostPeerIds =
            _removeTransportFromAllPeers(TransportType.wifiAware);
        for (final peerId in lostPeerIds) {
          _peerLostController.add(peerId);
        }
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
      } catch (e) {
        Logger.warning('TransportManager: LAN start failed: $e', 'Transport');
      }
    }
    if (_wifiAwareSubscribed) {
      // Fire-and-forget: don't block BLE advertising if Wi-Fi Aware hangs.
      // Wi-Fi Aware startSession() can block indefinitely on some Android
      // devices, which would prevent broadcastProfile() from ever being called.
      unawaited(_wifiAwareService.start().catchError((e) {
        Logger.warning(
          'TransportManager: Wi-Fi Aware start failed: $e',
          'Transport',
        );
      }));
    }
    // BLE start is handled by BleConnectionBloc — don't double-start here.
  }

  Future<void> stop() async {
    await _lanService.stop();
    await _wifiAwareService.stop();
    await _bleService.stop();

    // Clear in-memory ID maps so stale BLE UUIDs from the previous session
    // don't cause messages to route to the wrong peer after restart.
    // iOS may assign different Central/Peripheral UUIDs across sessions.
    _peerIdAlias.clear();
    _bleIdForCanonical.clear();
    _userIdToCurrentPeerId.clear();
    _peerTransports.clear();
    _peerBestTransport.clear();
  }

  /// Clear stale ID alias maps without stopping transports.
  ///
  /// Called when the BLE adapter restarts (e.g. Bluetooth toggled off/on)
  /// so that stale Central/Peripheral UUID mappings from the previous
  /// session don't cause messages to route to the wrong peer.
  void clearIdMaps() {
    _peerIdAlias.clear();
    _bleIdForCanonical.clear();
    _userIdToCurrentPeerId.clear();
    _peerTransports.clear();
    _peerBestTransport.clear();
    Logger.info('TransportManager: cleared all ID maps', 'Transport');
  }

  Future<void> dispose() async {
    await _availabilityLanSub?.cancel();
    await _availabilitySub?.cancel();

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

  /// Encrypts [payload] for LAN / Wi-Fi Aware sends.
  /// Returns a new [MessagePayload] where [content] carries the encrypted
  /// envelope JSON: {"v":1,"n":"<b64 nonce>","c":"<b64 ciphertext>"}.
  /// Inner plaintext: {"content":"...","reply_to_id":...}.
  /// Returns [payload] unchanged if no session exists or encryption fails.
  Future<ble.MessagePayload> _encryptMessagePayload(
    String canonicalPeerId,
    ble.MessagePayload payload,
  ) async {
    final enc = _encryptionService;
    if (enc == null) return payload;
    final encPeerId = _encPeerId(canonicalPeerId);
    if (!enc.hasSession(encPeerId)) return payload;

    final inner = jsonEncode({
      'content': payload.content,
      if (payload.replyToId != null) 'reply_to_id': payload.replyToId,
    });
    final encPayload = await enc.encrypt(encPeerId, utf8.encode(inner));
    if (encPayload == null) return payload;

    return ble.MessagePayload(
      messageId: payload.messageId,
      type: payload.type,
      // replyToId is inside the ciphertext; outer field cleared to avoid leakage.
      content: jsonEncode({
        'v': 1,
        'n': base64.encode(encPayload.nonce),
        'c': base64.encode(encPayload.ciphertext),
      }),
    );
  }

  /// Decrypts an incoming [ReceivedMessage] from LAN / Wi-Fi Aware.
  /// Returns the message unchanged if not encrypted or decryption fails.
  Future<ble.ReceivedMessage> _decryptReceivedMessage(
    ble.ReceivedMessage msg,
  ) async {
    final enc = _encryptionService;
    if (enc == null) return msg;

    final content = msg.content;
    if (content.isEmpty || !content.startsWith('{')) return msg;

    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(content) as Map<String, dynamic>;
    } catch (_) {
      return msg;
    }
    if (parsed['v'] != 1) return msg;

    final nStr = parsed['n'] as String?;
    final cStr = parsed['c'] as String?;
    if (nStr == null || cStr == null) return msg;

    final encPayload = EncryptedPayload(
      nonce: Uint8List.fromList(base64.decode(nStr)),
      ciphertext: Uint8List.fromList(base64.decode(cStr)),
    );

    final plaintextBytes =
        await enc.decrypt(_encPeerId(msg.fromPeerId), encPayload);
    if (plaintextBytes == null) {
      Logger.warning(
        'E2EE: message decrypt failed from ${msg.fromPeerId.substring(0, 8)} — dropped',
        'E2EE',
      );
      return msg;
    }

    final inner =
        jsonDecode(utf8.decode(plaintextBytes)) as Map<String, dynamic>;
    return ble.ReceivedMessage(
      fromPeerId: msg.fromPeerId,
      messageId: msg.messageId,
      type: msg.type,
      content: inner['content'] as String? ?? '',
      timestamp: msg.timestamp,
      replyToId: inner['reply_to_id'] as String?,
      isEncrypted: true,
    );
  }

  /// Encrypts [bytes] before sending over any transport.
  /// Wire format: [0x01] + 24-byte nonce + ciphertext.
  /// Returns [bytes] unchanged if no session exists or encryption fails.
  Future<Uint8List> _encryptPhotoBytes(
    String canonicalPeerId,
    Uint8List bytes,
  ) async {
    final enc = _encryptionService;
    if (enc == null) return bytes;
    final encPeerId = _encPeerId(canonicalPeerId);
    if (!enc.hasSession(encPeerId)) return bytes;

    final encPayload = await enc.encryptBytes(encPeerId, bytes);
    if (encPayload == null) return bytes;

    return Uint8List.fromList(
        [_kEncMagic, ...encPayload.nonce, ...encPayload.ciphertext]);
  }

  /// Decrypts photo bytes if they carry the [_kEncMagic] header byte.
  /// Returns [bytes] unchanged if not encrypted or decryption fails.
  Future<Uint8List> _decryptPhotoBytes(
    String fromPeerId,
    Uint8List bytes,
  ) async {
    if (bytes.isEmpty || bytes[0] != _kEncMagic) return bytes;

    final enc = _encryptionService;
    if (enc == null) return bytes;

    // Minimum valid encrypted payload: 1 (magic) + 24 (nonce) + 16 (tag) = 41 bytes
    if (bytes.length < 41) {
      Logger.warning(
          'E2EE: encrypted photo too short from $fromPeerId', 'E2EE');
      return bytes;
    }

    final encPayload = EncryptedPayload(
      nonce: bytes.sublist(1, 1 + _kNonceLen),
      ciphertext: bytes.sublist(1 + _kNonceLen),
    );

    final plaintext =
        await enc.decryptBytes(_encPeerId(fromPeerId), encPayload);
    if (plaintext == null) {
      Logger.warning(
          'E2EE: photo decrypt failed from $fromPeerId — kept encrypted',
          'E2EE');
      return bytes;
    }
    return plaintext;
  }

  // ==================== Unified Send Operations ====================

  Future<void> broadcastProfile(ble.BroadcastPayload payload) async {
    // Inject our E2EE public key into the payload so every transport
    // (LAN beacon, Wi-Fi Aware) carries it.  BleService already injects
    // it internally, so the BLE path is unaffected even if it's set twice.
    final enc = _encryptionService;
    final pkHex = enc?.localPublicKeyHex;
    final payloadWithKey = (pkHex != null && payload.publicKeyHex == null)
        ? payload.copyWith(publicKeyHex: pkHex)
        : payload;

    // Always broadcast on BLE for maximum compatibility
    await _bleService.broadcastProfile(payloadWithKey);

    // Update LAN profile if subscribed
    if (_lanSubscribed) {
      await _lanService.updateProfile(payloadWithKey);
    }

    // Also publish on Wi-Fi Aware if subscribed
    if (_wifiAwareSubscribed) {
      await _wifiAwareService.updateProfile(payloadWithKey);
    }
  }

  Future<bool> sendMessage(String peerId, ble.MessagePayload payload) async {
    final available = _peerTransports[peerId] ?? {};

    // Try LAN if peer is reachable via LAN.
    if (available.contains(TransportType.lan) && _isTransportAllowed(TransportType.lan)) {
      final sw = Stopwatch()..start();
      final encPayload = await _encryptMessagePayload(peerId, payload);
      final success = await _lanService.sendMessage(peerId, encPayload);
      sw.stop();
      _healthTracker?.recordSendResult(peerId, TransportType.lan,
          success: success, rttMs: sw.elapsedMilliseconds);
      if (success) return true;
      Logger.warning(
        'TransportManager: LAN send failed, trying next transport',
        'Transport',
      );
    }

    // Try Wi-Fi Aware if peer is reachable via Wi-Fi Aware.
    if (available.contains(TransportType.wifiAware) && _isTransportAllowed(TransportType.wifiAware)) {
      final sw = Stopwatch()..start();
      final encPayload = await _encryptMessagePayload(peerId, payload);
      final success = await _wifiAwareService.sendMessage(peerId, encPayload);
      sw.stop();
      _healthTracker?.recordSendResult(peerId, TransportType.wifiAware,
          success: success, rttMs: sw.elapsedMilliseconds);
      if (success) return true;
      Logger.warning(
        'TransportManager: Wi-Fi Aware send failed, trying BLE',
        'Transport',
      );
    }

    // BLE handles its own E2EE inside BleFacade — don't double-encrypt.
    final sw = Stopwatch()..start();
    final success = await _bleService.sendMessage(
        _bleIdForCanonical[peerId] ?? peerId, payload);
    sw.stop();
    _healthTracker?.recordSendResult(peerId, TransportType.ble,
        success: success, rttMs: sw.elapsedMilliseconds);
    return success;
  }

  Future<bool> sendPhoto(
    String peerId,
    Uint8List photoData,
    String messageId, {
    String? photoId,
  }) async {
    final available = _peerTransports[peerId] ?? {};

    // Try LAN if peer is reachable via LAN.
    if (available.contains(TransportType.lan) && _isTransportAllowed(TransportType.lan)) {
      final sw = Stopwatch()..start();
      final encBytes = await _encryptPhotoBytes(peerId, photoData);
      final success = await _lanService.sendPhoto(
        peerId,
        encBytes,
        messageId,
        photoId: photoId,
      );
      sw.stop();
      _healthTracker?.recordSendResult(peerId, TransportType.lan,
          success: success, rttMs: sw.elapsedMilliseconds);
      if (success) return true;
      Logger.warning(
        'TransportManager: LAN photo send failed, trying next transport',
        'Transport',
      );
    }

    // Try Wi-Fi Aware if peer is reachable via Wi-Fi Aware.
    if (available.contains(TransportType.wifiAware) && _isTransportAllowed(TransportType.wifiAware)) {
      final sw = Stopwatch()..start();
      final encBytes = await _encryptPhotoBytes(peerId, photoData);
      final success = await _wifiAwareService.sendPhoto(
        peerId,
        encBytes,
        messageId,
        photoId: photoId,
      );
      sw.stop();
      _healthTracker?.recordSendResult(peerId, TransportType.wifiAware,
          success: success, rttMs: sw.elapsedMilliseconds);
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

    // BLE photo transfer: BLE's sendPhoto handles its own E2EE internally
    // (via PhotoTransferHandler._encryptionService), so do NOT encrypt here.
    final bleId = _bleIdForCanonical[peerId] ?? peerId;
    final sw = Stopwatch()..start();
    final success = await _bleService.sendPhoto(
        bleId, photoData, messageId, photoId: photoId);
    sw.stop();
    _healthTracker?.recordSendResult(peerId, TransportType.ble,
        success: success, rttMs: sw.elapsedMilliseconds);
    return success;
  }

  Future<bool> sendPhotoPreview({
    required String peerId,
    required String messageId,
    required String photoId,
    required Uint8List thumbnailBytes,
    required int originalSize,
  }) async {
    final available = _peerTransports[peerId] ?? {};

    if (available.contains(TransportType.lan) && _isTransportAllowed(TransportType.lan)) {
      final success = await _lanService.sendPhotoPreview(
        peerId: peerId,
        messageId: messageId,
        photoId: photoId,
        thumbnailBytes: thumbnailBytes,
        originalSize: originalSize,
      );
      if (success) return true;
    }

    if (available.contains(TransportType.wifiAware) && _isTransportAllowed(TransportType.wifiAware)) {
      final success = await _wifiAwareService.sendPhotoPreview(
        peerId: peerId,
        messageId: messageId,
        photoId: photoId,
        thumbnailBytes: thumbnailBytes,
        originalSize: originalSize,
      );
      if (success) return true;
    }

    final bleId = _bleIdForCanonical[peerId] ?? peerId;
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
    final available = _peerTransports[peerId] ?? {};

    if (available.contains(TransportType.lan) && _isTransportAllowed(TransportType.lan)) {
      final success = await _lanService.sendPhotoRequest(
        peerId: peerId,
        messageId: messageId,
        photoId: photoId,
      );
      if (success) return true;
    }

    if (available.contains(TransportType.wifiAware) && _isTransportAllowed(TransportType.wifiAware)) {
      final success = await _wifiAwareService.sendPhotoRequest(
        peerId: peerId,
        messageId: messageId,
        photoId: photoId,
      );
      if (success) return true;
    }

    final bleId = _bleIdForCanonical[peerId] ?? peerId;
    return _bleService.sendPhotoRequest(
      peerId: bleId,
      messageId: messageId,
      photoId: photoId,
    );
  }

  Future<bool> sendDropAnchor(String peerId) async {
    final available = _peerTransports[peerId] ?? {};

    if (available.contains(TransportType.lan) && _isTransportAllowed(TransportType.lan)) {
      final success = await _lanService.sendDropAnchor(peerId);
      if (success) return true;
    }

    if (available.contains(TransportType.wifiAware) && _isTransportAllowed(TransportType.wifiAware)) {
      final success = await _wifiAwareService.sendDropAnchor(peerId);
      if (success) return true;
    }

    return _bleService.sendDropAnchor(_bleIdForCanonical[peerId] ?? peerId);
  }

  Future<bool> sendReaction({
    required String peerId,
    required String messageId,
    required String emoji,
    required String action,
  }) async {
    final available = _peerTransports[peerId] ?? {};

    if (available.contains(TransportType.lan) && _isTransportAllowed(TransportType.lan)) {
      final success = await _lanService.sendReaction(
        peerId: peerId,
        messageId: messageId,
        emoji: emoji,
        action: action,
      );
      if (success) return true;
    }

    if (available.contains(TransportType.wifiAware) && _isTransportAllowed(TransportType.wifiAware)) {
      final success = await _wifiAwareService.sendReaction(
        peerId: peerId,
        messageId: messageId,
        emoji: emoji,
        action: action,
      );
      if (success) return true;
    }

    final bleId = _bleIdForCanonical[peerId] ?? peerId;
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
  Future<void> setBatterySaverMode(bool enabled) =>
      _bleService.setBatterySaverMode(enabled);

  bool isPeerReachable(String peerId) {
    final transports = _peerTransports[peerId];
    if (transports != null) {
      for (final t in transports) {
        switch (t) {
          case TransportType.lan:
            if (_lanService.isPeerReachable(peerId)) return true;
          case TransportType.wifiAware:
            if (_wifiAwareService.isPeerReachable(peerId)) return true;
          case TransportType.ble:
          case TransportType.wifiDirect:
            final bleId = _bleIdForCanonical[peerId] ?? peerId;
            if (_bleService.isPeerReachable(bleId)) return true;
        }
      }
    }
    // Fallback: check BLE directly
    return _bleService.isPeerReachable(_bleIdForCanonical[peerId] ?? peerId);
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

      // Encrypt for E2EE before sending.
      Uint8List wifiBytes = photoData;
      final enc = _encryptionService;
      final encPeerId = _encPeerId(peerId);
      if (enc != null && enc.hasSession(encPeerId)) {
        final encPayload = await enc.encryptBytes(encPeerId, photoData);
        if (encPayload != null) {
          wifiBytes = Uint8List.fromList(
              [_kEncMagic, ...encPayload.nonce, ...encPayload.ciphertext]);
        }
      }

      final transferId = photoId ?? messageId;
      final sw = Stopwatch()..start();

      final sendFuture = hsService.sendPayload(
        transferId: transferId,
        peerId: peerId,
        data: wifiBytes,
        timeout: const Duration(seconds: 15),
      );

      // Tiny delay to ensure advertising is started before the BLE signal.
      await Future.delayed(const Duration(milliseconds: 200));

      // Tell receiver to start browsing for us.
      final ownId = _ownUserId;
      if (ownId != null) {
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
      }

      final success = await sendFuture;
      sw.stop();
      _healthTracker?.recordSendResult(peerId, TransportType.wifiDirect,
          success: success, rttMs: sw.elapsedMilliseconds);

      if (success) {
        Logger.info('TransportManager: Wi-Fi Direct transfer succeeded', 'Transport');
      } else {
        Logger.warning(
          'TransportManager: Wi-Fi Direct failed, falling back to BLE',
          'Transport',
        );
      }
      return success;
    } catch (e) {
      Logger.warning('TransportManager: Wi-Fi Direct error: $e', 'Transport');
      return false;
    }
  }

  // ==================== Battery-Aware Transport Policy ====================

  /// Update battery-aware transport policy based on current battery level.
  ///
  /// - `< 10%`: Disable LAN + Wi-Fi Aware + Wi-Fi Direct (BLE only)
  /// - `< 20%`: Disable Wi-Fi Direct for photos
  /// - `>= 20%`: All transports available
  void setBatteryPolicy(int batteryLevel) {
    _currentBatteryLevel = batteryLevel;
    _minBatteryForTransport.clear();

    // LAN and Wi-Fi Aware require more power
    _minBatteryForTransport[TransportType.lan] =
        AppConstants.batteryCriticalThreshold;
    _minBatteryForTransport[TransportType.wifiAware] =
        AppConstants.batteryCriticalThreshold;
    // Wi-Fi Direct is power-hungry for photo transfers
    _minBatteryForTransport[TransportType.wifiDirect] =
        AppConstants.batteryLowThreshold;

    Logger.debug(
      'TransportManager: Battery policy updated for level=$batteryLevel%',
      'Transport',
    );
  }

  /// Check whether a transport is allowed under the current battery policy.
  bool _isTransportAllowed(TransportType transport) {
    final minLevel = _minBatteryForTransport[transport];
    if (minLevel == null) return true; // No restriction (e.g. BLE)
    return _currentBatteryLevel >= minLevel;
  }

  // ==================== Per-Peer Transport Helpers ====================

  /// Add a transport to a peer's available set. Recomputes best transport
  /// and emits [PeerTransportChanged] if the best changed.
  void _addPeerTransport(String peerId, TransportType transport) {
    final set = _peerTransports.putIfAbsent(peerId, () => {});
    set.add(transport);
    _recomputeBestTransport(peerId);
  }

  /// Remove a transport from a peer's available set. Returns true if the
  /// peer has NO remaining transports (fully lost).
  bool _removePeerTransport(String peerId, TransportType transport) {
    final set = _peerTransports[peerId];
    if (set == null) return true;
    set.remove(transport);
    if (set.isEmpty) {
      _peerTransports.remove(peerId);
      _peerBestTransport.remove(peerId);
      return true;
    }
    _recomputeBestTransport(peerId);
    return false;
  }

  /// Remove a transport from ALL peers. Returns list of peerIds that have
  /// no remaining transports (fully lost).
  List<String> _removeTransportFromAllPeers(TransportType transport) {
    final fullyLost = <String>[];
    final peerIds = List<String>.from(_peerTransports.keys);
    for (final peerId in peerIds) {
      if (_removePeerTransport(peerId, transport)) {
        fullyLost.add(peerId);
      }
    }
    return fullyLost;
  }

  /// Recompute best transport for a peer. Emits [PeerTransportChanged] if
  /// the best changed.
  void _recomputeBestTransport(String peerId) {
    final set = _peerTransports[peerId];
    if (set == null || set.isEmpty) return;

    TransportType best = TransportType.ble;
    int bestPriority = _transportPriority(TransportType.ble);
    for (final t in set) {
      final p = _transportPriority(t);
      if (p < bestPriority) {
        best = t;
        bestPriority = p;
      }
    }

    final old = _peerBestTransport[peerId];
    if (old != best) {
      _peerBestTransport[peerId] = best;
      _peerTransportChangedController.add(PeerTransportChanged(
        peerId: peerId,
        oldTransport: old,
        newTransport: best,
      ));
      Logger.debug(
        'TransportManager: peer $peerId transport ${old?.name ?? 'none'} → ${best.name}',
        'Transport',
      );
    }
  }

  // ==================== Transport Subscriptions ====================

  void _subscribeToBle() {
    _bleSubscriptions.addAll([
      _bleService.peerDiscoveredStream.listen((peer) async {
        // Suppress peers whose GATT profile hasn't been read yet (userId=null).
        if (peer.userId == null) return;

        _addPeerTransport(peer.peerId, TransportType.ble);
        final emitted = _migrateIfNeeded(peer.peerId, peer.userId);
        // Store E2EE key under the canonical ID (which _migrateIfNeeded just
        // resolved). For BLE-only peers canonical == peer.peerId.
        // Await the DB write so the key is persisted before the peer is
        // emitted to the UI — prevents the race where initiateHandshake runs
        // before peer_public_keys is populated.
        if (peer.publicKeyHex != null) {
          final canonical = _peerIdAlias[peer.peerId] ?? peer.peerId;
          await _encryptionService?.storePeerPublicKey(canonical, peer.publicKeyHex!);
        }
        if (emitted) {
          _peerDiscoveredController.add(peer);
        }
      }),
      _bleService.peerLostStream.listen((peerId) {
        // If this BLE peer was aliased to a LAN peer, forward the lost signal
        // using the canonical peerId so DiscoveryBloc marks the right entry.
        final canonical = _peerIdAlias.remove(peerId) ?? peerId;
        final fullyLost = _removePeerTransport(
          canonical != peerId ? canonical : peerId,
          TransportType.ble,
        );
        if (fullyLost) {
          _peerLostController.add(canonical);
        }
      }),
      _bleService.messageReceivedStream.listen((msg) {
        final canonical = _peerIdAlias[msg.fromPeerId] ?? msg.fromPeerId;
        _messageReceivedController.add(canonical == msg.fromPeerId
            ? msg
            : ble.ReceivedMessage(
                fromPeerId: canonical,
                messageId: msg.messageId,
                type: msg.type,
                content: msg.content,
                timestamp: msg.timestamp,
                replyToId: msg.replyToId,
              ));
      }),
      _bleService.photoPreviewReceivedStream.listen((preview) {
        final canonical =
            _peerIdAlias[preview.fromPeerId] ?? preview.fromPeerId;
        _photoPreviewReceivedController.add(canonical == preview.fromPeerId
            ? preview
            : ble.ReceivedPhotoPreview(
                fromPeerId: canonical,
                messageId: preview.messageId,
                photoId: preview.photoId,
                thumbnailBytes: preview.thumbnailBytes,
                originalSize: preview.originalSize,
                timestamp: preview.timestamp,
              ));
      }),
      _bleService.photoRequestReceivedStream.listen((req) {
        final canonical = _peerIdAlias[req.fromPeerId] ?? req.fromPeerId;
        _photoRequestReceivedController.add(canonical == req.fromPeerId
            ? req
            : ble.ReceivedPhotoRequest(
                fromPeerId: canonical,
                messageId: req.messageId,
                photoId: req.photoId,
                timestamp: req.timestamp,
              ));
      }),
      _bleService.photoProgressStream.listen((progress) {
        final canonical = _peerIdAlias[progress.peerId] ?? progress.peerId;
        _photoProgressController.add(canonical == progress.peerId
            ? progress
            : progress.copyWith(peerId: canonical));
      }),
      _bleService.photoReceivedStream.listen((photo) async {
        final canonical = _peerIdAlias[photo.fromPeerId] ?? photo.fromPeerId;
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
        final canonical = _peerIdAlias[drop.fromPeerId] ?? drop.fromPeerId;
        _anchorDropReceivedController.add(canonical == drop.fromPeerId
            ? drop
            : ble.AnchorDropReceived(
                fromPeerId: canonical,
                timestamp: drop.timestamp,
              ));
      }),
      _bleService.reactionReceivedStream.listen((reaction) {
        final canonical =
            _peerIdAlias[reaction.fromPeerId] ?? reaction.fromPeerId;
        _reactionReceivedController.add(canonical == reaction.fromPeerId
            ? reaction
            : ble.ReactionReceived(
                fromPeerId: canonical,
                messageId: reaction.messageId,
                emoji: reaction.emoji,
                action: reaction.action,
                timestamp: reaction.timestamp,
              ));
      }),
      _bleService.peerIdChangedStream.listen((change) {
        // Update transport mapping for the new peerId
        final transports = _peerTransports.remove(change.oldPeerId);
        if (transports != null) {
          _peerTransports[change.newPeerId] = transports;
        }
        final best = _peerBestTransport.remove(change.oldPeerId);
        if (best != null) {
          _peerBestTransport[change.newPeerId] = best;
        }
        // Update incoming alias if the old BLE peerId was aliased
        final aliasTarget = _peerIdAlias.remove(change.oldPeerId);
        if (aliasTarget != null) {
          _peerIdAlias[change.newPeerId] = aliasTarget;
          _bleIdForCanonical[aliasTarget] = change.newPeerId;
        }
        // Migrate any E2EE session or pending handshake keyed by the old peerId
        // (covers the BLE Central UUID → Peripheral UUID race on iOS).
        _encryptionService?.migratePeerId(change.oldPeerId, change.newPeerId);
        _peerIdChangedController.add(change);
      }),
    ]);
  }

  void _subscribeToLanAdditive() {
    if (_lanSubscribed) return;
    _lanSubscribed = true;

    _lanSubscriptions.addAll([
      _lanService.peerDiscoveredStream.listen((peer) async {
        _addPeerTransport(peer.peerId, TransportType.lan);
        final emitted = _migrateIfNeeded(peer.peerId, peer.userId);
        // LAN peers carry publicKeyHex in the beacon — store under canonical ID.
        if (peer.publicKeyHex != null) {
          await _encryptionService?.storePeerPublicKey(peer.peerId, peer.publicKeyHex!);
        }
        if (emitted) {
          _peerDiscoveredController.add(peer);
        }
      }),
      _lanService.peerLostStream.listen((peerId) {
        final fullyLost = _removePeerTransport(peerId, TransportType.lan);
        if (fullyLost) {
          _peerLostController.add(peerId);
        }
      }),
      _lanService.messageReceivedStream.listen((msg) async {
        _messageReceivedController.add(await _decryptReceivedMessage(msg));
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
      _lanService.photoReceivedStream.listen((photo) async {
        final dec = await _decryptPhotoBytes(photo.fromPeerId, photo.photoBytes);
        _photoReceivedController.add(dec == photo.photoBytes
            ? photo
            : ble.ReceivedPhoto(
                fromPeerId: photo.fromPeerId,
                messageId: photo.messageId,
                photoBytes: dec,
                timestamp: photo.timestamp,
                photoId: photo.photoId,
              ));
      }),
      _lanService.anchorDropReceivedStream.listen(
        _anchorDropReceivedController.add,
      ),
      _lanService.reactionReceivedStream.listen(
        _reactionReceivedController.add,
      ),
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

    // Incoming from BLE: translate BLE UUID → canonical ID before processing.
    _bleSubscriptions.add(
      _bleService.noiseHandshakeStream.listen(_processIncomingHandshake),
    );

    // Outbound from EncryptionService: route to the correct transport.
    _bleSubscriptions.add(
      enc.outboundHandshakeStream.listen(_routeOutboundHandshake),
    );
  }

  /// Route an incoming handshake frame to EncryptionService, translating
  /// the transport-level peer ID to the canonical conversation ID first.
  void _processIncomingHandshake(ble.NoiseHandshakeReceived msg) {
    final enc = _encryptionService;
    if (enc == null) return;
    final rawId = msg.fromPeerId;
    // Translate BLE UUID → canonical (LAN UUID for dual-transport peers).
    var canonicalId = _peerIdAlias[rawId] ?? rawId;
    // If the peerId is a BLE Central UUID (not found in _peerTransports), try
    // to resolve it to a known Peripheral UUID via BleService's userId mapping.
    // This is critical for cross-platform (Android → iOS) where the Central
    // UUID ≠ Peripheral UUID and the incoming handshake msg arrives before
    // the scanner has established the Peripheral connection.
    if (!_peerTransports.containsKey(canonicalId)) {
      final resolvedPeerId = _bleService.resolveToPeripheralId(canonicalId);
      if (resolvedPeerId != null && resolvedPeerId != canonicalId) {
        final finalCanonical = _peerIdAlias[resolvedPeerId] ?? resolvedPeerId;
        Logger.debug(
          'TransportManager: handshake peerId resolved $canonicalId → $finalCanonical',
          'Transport',
        );
        canonicalId = finalCanonical;
      }
    }

    // For steps 2 and 3, verify the resolved ID matches a pending handshake.
    // If not, the peerId may have been migrated (Central→Peripheral or
    // transport upgrade) — try the raw BLE ID and common aliases as fallback.
    if (msg.step >= 2 && !enc.hasPendingHandshake(canonicalId)) {
      // Try the raw BLE ID directly
      if (enc.hasPendingHandshake(rawId)) {
        Logger.info(
          'TransportManager: handshake step ${msg.step} — canonical '
          '$canonicalId has no pending, falling back to raw $rawId',
          'Transport',
        );
        canonicalId = rawId;
      } else {
        // Try reverse: maybe the pending handshake is under the BLE ID that
        // maps to this canonical via _bleIdForCanonical
        final bleId = _bleIdForCanonical[canonicalId];
        if (bleId != null && enc.hasPendingHandshake(bleId)) {
          Logger.info(
            'TransportManager: handshake step ${msg.step} — falling back to '
            'bleId $bleId for canonical $canonicalId',
            'Transport',
          );
          canonicalId = bleId;
        }
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
              'E2EE session established with $canonicalId', 'Transport');
        }
        if (result.hasError) {
          Logger.warning(
              'Handshake error from $canonicalId: ${result.error}', 'Transport');
        }
      },
      onError: (Object e) =>
          Logger.error('Noise handshake processing failed', e, null, 'Transport'),
    );
  }

  /// Route an outbound handshake message to the appropriate transport.
  ///
  /// [msg.peerId] is the canonical peer ID (conversation ID). Tries
  /// transports in priority order (LAN → BLE) with fallback.
  Future<void> _routeOutboundHandshake(HandshakeMessageOut msg) async {
    final canonicalId = msg.peerId;
    final available = _peerTransports[canonicalId] ?? {};
    final bleId = _bleIdForCanonical[canonicalId] ?? canonicalId;
    Logger.debug(
      'routeOutboundHandshake step ${msg.step}: canonical=$canonicalId, '
      'bleId=$bleId, transports=${available.map((t) => t.name).join(', ')}',
      'Transport',
    );

    if (available.contains(TransportType.lan) && _isTransportAllowed(TransportType.lan)) {
      final ok = await _lanService
          .sendHandshakeMessage(canonicalId, msg.step, msg.payload);
      if (ok) return;
      Logger.warning(
          'LAN handshake send failed for $canonicalId step ${msg.step}, trying BLE',
          'Transport');
    }

    // BLE fallback — resolve canonical → BLE UUID.
    try {
      await _bleService.sendHandshakeMessage(bleId, msg.step, msg.payload);
    } catch (e) {
      Logger.error('BLE handshake send failed for $bleId', e, null, 'Transport');
    }
  }

  void _subscribeToWifiAwareAdditive() {
    if (_wifiAwareSubscribed) return;
    _wifiAwareSubscribed = true;

    _wifiAwareSubscriptions.addAll([
      _wifiAwareService.peerDiscoveredStream.listen((peer) {
        _addPeerTransport(peer.peerId, TransportType.wifiAware);
        if (_migrateIfNeeded(peer.peerId, peer.userId)) {
          _peerDiscoveredController.add(peer);
        }
      }),
      _wifiAwareService.peerLostStream.listen((peerId) {
        final fullyLost =
            _removePeerTransport(peerId, TransportType.wifiAware);
        if (fullyLost) {
          _peerLostController.add(peerId);
        }
      }),
      _wifiAwareService.messageReceivedStream.listen((msg) async {
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
      _wifiAwareService.photoReceivedStream.listen((photo) async {
        final dec = await _decryptPhotoBytes(photo.fromPeerId, photo.photoBytes);
        _photoReceivedController.add(dec == photo.photoBytes
            ? photo
            : ble.ReceivedPhoto(
                fromPeerId: photo.fromPeerId,
                messageId: photo.messageId,
                photoBytes: dec,
                timestamp: photo.timestamp,
                photoId: photo.photoId,
              ));
      }),
      _wifiAwareService.anchorDropReceivedStream.listen(
        _anchorDropReceivedController.add,
      ),
      _wifiAwareService.reactionReceivedStream.listen(
        _reactionReceivedController.add,
      ),
    ]);
  }

  void _unsubscribeFromWifiAware() {
    for (final sub in _wifiAwareSubscriptions) {
      sub.cancel();
    }
    _wifiAwareSubscriptions.clear();
    _wifiAwareSubscribed = false;
  }

  // ==================== Cross-Transport Migration ====================

  /// Check whether [newPeerId] should replace an existing peerId for the same
  /// user. Returns true if the peer should be emitted to listeners, false if
  /// it should be suppressed (the existing transport has higher priority).
  ///
  /// Only migrates when the new transport is strictly higher priority than the
  /// old one. This prevents BLE re-discoveries from downgrading a peer that is
  /// already reachable via LAN.
  bool _migrateIfNeeded(String newPeerId, String? userId) {
    if (userId == null) return true;
    final oldPeerId = _userIdToCurrentPeerId[userId];
    if (oldPeerId != null && oldPeerId != newPeerId) {
      final oldPriority =
          _transportPriority(_peerBestTransport[oldPeerId] ?? _activeTransport);
      final newPriority =
          _transportPriority(_peerBestTransport[newPeerId] ?? _activeTransport);

      if (oldPriority < newPriority) {
        // Existing transport is higher priority (e.g. LAN vs BLE) — suppress.
        // Record alias so incoming events (messages, photos) from newPeerId
        // are routed to oldPeerId's conversation in the DB.
        _peerIdAlias[newPeerId] = oldPeerId;
        // Record reverse so outgoing BLE fallback uses the real BLE peerId
        // instead of the LAN session UUID (which BLE can't route directly).
        _bleIdForCanonical[oldPeerId] = newPeerId;
        // Merge the suppressed peer's transports into the canonical peer so
        // BLE fallback is available under the canonical ID.
        final suppTransports = _peerTransports.remove(newPeerId) ?? {};
        final canonTransports = _peerTransports.putIfAbsent(oldPeerId, () => {});
        canonTransports.addAll(suppTransports);
        _peerBestTransport.remove(newPeerId);
        _recomputeBestTransport(oldPeerId);
        Logger.debug(
          'TransportManager: suppressed $newPeerId → alias to $oldPeerId, '
          'transports=${canonTransports.map((t) => t.name).join(', ')}',
          'Transport',
        );
        return false;
      }

      // New transport is equal or higher priority — migrate.
      // Merge transport sets: the new canonical ID should know about ALL
      // transports the old ID had (e.g. BLE) plus whatever the new ID has.
      final oldTransports = _peerTransports.remove(oldPeerId) ?? {};
      final newTransports = _peerTransports.putIfAbsent(newPeerId, () => {});
      newTransports.addAll(oldTransports);
      _peerBestTransport.remove(oldPeerId);
      _recomputeBestTransport(newPeerId);

      // Record reverse alias so outgoing BLE fallback uses the correct BLE
      // peerId.  Only needed when the new canonical is NOT itself a BLE UUID
      // (e.g. canonical is a LAN/Wi-Fi Aware session ID and we need to
      // remember the BLE UUID for fallback writes).
      //
      // When the new canonical IS a BLE UUID (the new peer's transport set
      // includes BLE — i.e. it was discovered via BLE scanning), the new
      // canonical can be used directly and mapping to the OLD stale UUID
      // would route messages to the wrong device (MAC rotation).
      if (newTransports.contains(TransportType.ble)) {
        _bleIdForCanonical.remove(newPeerId);
      } else {
        _bleIdForCanonical[newPeerId] = oldPeerId;
      }

      // Migrate any E2EE session or pending handshake to the new canonical peerId.
      _encryptionService?.migratePeerId(oldPeerId, newPeerId);
      _peerIdChangedController.add(ble.PeerIdChanged(
        oldPeerId: oldPeerId,
        newPeerId: newPeerId,
        userId: userId,
      ));
      Logger.info(
        'TransportManager: migrated $oldPeerId → $newPeerId (userId=$userId), '
        'transports=${newTransports.map((t) => t.name).join(', ')}',
        'Transport',
      );
    }
    _userIdToCurrentPeerId[userId] = newPeerId;
    return true;
  }

  /// Lower number = higher priority.
  int _transportPriority(TransportType t) {
    switch (t) {
      case TransportType.lan:
        return 0;
      case TransportType.wifiAware:
        return 1;
      case TransportType.wifiDirect:
        return 2;
      case TransportType.ble:
        return 3;
    }
  }
}
