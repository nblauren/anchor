import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:wifi_aware_p2p/wifi_aware_p2p.dart' as wa;

import '../../core/utils/logger.dart';
import '../ble/ble_models.dart' as ble;
import '../ble/ble_service_interface.dart';
import '../lan/lan.dart';
import '../wifi_aware/wifi_aware_transport_service.dart';
import 'transport_enums.dart';

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
  })  : _lanService = lanService,
        _wifiAwareService = wifiAwareService,
        _bleService = bleService {
    // Immediately subscribe to BLE streams so peer discovery works
    // even before initialize() is called (BleConnectionBloc starts BLE
    // independently).
    _subscribeToBle();
    Logger.info('TransportManager: BLE stream forwarding active', 'Transport');
  }

  final LanTransportService _lanService;
  final WifiAwareTransportService _wifiAwareService;
  final BleServiceInterface _bleService;

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

    // BLE is already initialized and started by BleConnectionBloc — don't
    // re-initialize here.

    // Try LAN first — works on both iOS and Android wherever a local network
    // interface is available (e.g. ship Wi-Fi).
    bool lanAvailable = false;
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
        final lostPeerIds =
            _removeTransportFromAllPeers(TransportType.lan);
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
      await _lanService.start();
    }
    if (_wifiAwareSubscribed) {
      await _wifiAwareService.start();
    }
    // BLE start is handled by BleConnectionBloc — don't double-start here.
  }

  Future<void> stop() async {
    await _lanService.stop();
    await _wifiAwareService.stop();
    await _bleService.stop();
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

  // ==================== Unified Send Operations ====================

  Future<void> broadcastProfile(ble.BroadcastPayload payload) async {
    // Always broadcast on BLE for maximum compatibility
    await _bleService.broadcastProfile(payload);

    // Update LAN profile if subscribed
    if (_lanSubscribed) {
      await _lanService.updateProfile(payload);
    }

    // Also publish on Wi-Fi Aware if subscribed
    if (_wifiAwareSubscribed) {
      await _wifiAwareService.updateProfile(payload);
    }
  }

  Future<bool> sendMessage(String peerId, ble.MessagePayload payload) async {
    final transport = _peerBestTransport[peerId] ?? _activeTransport;

    if (transport == TransportType.lan) {
      final success = await _lanService.sendMessage(peerId, payload);
      if (success) return true;
      Logger.warning(
        'TransportManager: LAN send failed, trying next transport',
        'Transport',
      );
    }

    if (transport == TransportType.wifiAware) {
      final success = await _wifiAwareService.sendMessage(peerId, payload);
      if (success) return true;
      // Fall back to BLE if Wi-Fi Aware send fails
      Logger.warning(
        'TransportManager: Wi-Fi Aware send failed, trying BLE',
        'Transport',
      );
    }

    return _bleService.sendMessage(_bleIdForCanonical[peerId] ?? peerId, payload);
  }

  Future<bool> sendPhoto(
    String peerId,
    Uint8List photoData,
    String messageId, {
    String? photoId,
  }) async {
    final transport = _peerBestTransport[peerId] ?? _activeTransport;

    if (transport == TransportType.lan) {
      final success = await _lanService.sendPhoto(
        peerId,
        photoData,
        messageId,
        photoId: photoId,
      );
      if (success) return true;
      Logger.warning(
        'TransportManager: LAN photo send failed, trying next transport',
        'Transport',
      );
    }

    if (transport == TransportType.wifiAware) {
      final success = await _wifiAwareService.sendPhoto(
        peerId,
        photoData,
        messageId,
        photoId: photoId,
      );
      if (success) return true;
      Logger.warning(
        'TransportManager: Wi-Fi Aware photo send failed, trying BLE',
        'Transport',
      );
    }

    final bleId = _bleIdForCanonical[peerId] ?? peerId;
    return _bleService.sendPhoto(bleId, photoData, messageId, photoId: photoId);
  }

  Future<bool> sendPhotoPreview({
    required String peerId,
    required String messageId,
    required String photoId,
    required Uint8List thumbnailBytes,
    required int originalSize,
  }) async {
    final transport = _peerBestTransport[peerId] ?? _activeTransport;

    if (transport == TransportType.lan) {
      final success = await _lanService.sendPhotoPreview(
        peerId: peerId,
        messageId: messageId,
        photoId: photoId,
        thumbnailBytes: thumbnailBytes,
        originalSize: originalSize,
      );
      if (success) return true;
    }

    if (transport == TransportType.wifiAware) {
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
    final transport = _peerBestTransport[peerId] ?? _activeTransport;

    if (transport == TransportType.lan) {
      final success = await _lanService.sendPhotoRequest(
        peerId: peerId,
        messageId: messageId,
        photoId: photoId,
      );
      if (success) return true;
    }

    if (transport == TransportType.wifiAware) {
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
    final transport = _peerBestTransport[peerId] ?? _activeTransport;

    if (transport == TransportType.lan) {
      final success = await _lanService.sendDropAnchor(peerId);
      if (success) return true;
    }

    if (transport == TransportType.wifiAware) {
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
    final transport = _peerBestTransport[peerId] ?? _activeTransport;

    if (transport == TransportType.lan) {
      final success = await _lanService.sendReaction(
        peerId: peerId,
        messageId: messageId,
        emoji: emoji,
        action: action,
      );
      if (success) return true;
    }

    if (transport == TransportType.wifiAware) {
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
      _bleService.peerDiscoveredStream.listen((peer) {
        // Suppress peers whose GATT profile hasn't been read yet (userId=null).
        if (peer.userId == null) return;

        _addPeerTransport(peer.peerId, TransportType.ble);
        if (_migrateIfNeeded(peer.peerId, peer.userId)) {
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
      _bleService.photoReceivedStream.listen((photo) {
        final canonical = _peerIdAlias[photo.fromPeerId] ?? photo.fromPeerId;
        _photoReceivedController.add(canonical == photo.fromPeerId
            ? photo
            : ble.ReceivedPhoto(
                fromPeerId: canonical,
                messageId: photo.messageId,
                photoBytes: photo.photoBytes,
                timestamp: photo.timestamp,
                photoId: photo.photoId,
              ));
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
        _peerIdChangedController.add(change);
      }),
    ]);
  }

  void _subscribeToLanAdditive() {
    if (_lanSubscribed) return;
    _lanSubscribed = true;

    _lanSubscriptions.addAll([
      _lanService.peerDiscoveredStream.listen((peer) {
        _addPeerTransport(peer.peerId, TransportType.lan);
        if (_migrateIfNeeded(peer.peerId, peer.userId)) {
          _peerDiscoveredController.add(peer);
        }
      }),
      _lanService.peerLostStream.listen((peerId) {
        final fullyLost = _removePeerTransport(peerId, TransportType.lan);
        if (fullyLost) {
          _peerLostController.add(peerId);
        }
      }),
      _lanService.messageReceivedStream.listen(
        _messageReceivedController.add,
      ),
      _lanService.photoPreviewReceivedStream.listen(
        _photoPreviewReceivedController.add,
      ),
      _lanService.photoRequestReceivedStream.listen(
        _photoRequestReceivedController.add,
      ),
      _lanService.photoProgressStream.listen(
        _photoProgressController.add,
      ),
      _lanService.photoReceivedStream.listen(
        _photoReceivedController.add,
      ),
      _lanService.anchorDropReceivedStream.listen(
        _anchorDropReceivedController.add,
      ),
      _lanService.reactionReceivedStream.listen(
        _reactionReceivedController.add,
      ),
    ]);
  }

  void _unsubscribeFromLan() {
    for (final sub in _lanSubscriptions) {
      sub.cancel();
    }
    _lanSubscriptions.clear();
    _lanSubscribed = false;
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
      _wifiAwareService.messageReceivedStream.listen(
        _messageReceivedController.add,
      ),
      _wifiAwareService.photoPreviewReceivedStream.listen(
        _photoPreviewReceivedController.add,
      ),
      _wifiAwareService.photoRequestReceivedStream.listen(
        _photoRequestReceivedController.add,
      ),
      _wifiAwareService.photoProgressStream.listen(
        _photoProgressController.add,
      ),
      _wifiAwareService.photoReceivedStream.listen(
        _photoReceivedController.add,
      ),
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
        Logger.debug(
          'TransportManager: suppressed $newPeerId → alias to $oldPeerId',
          'Transport',
        );
        return false;
      }

      // New transport is equal or higher priority — migrate.
      _peerIdChangedController.add(ble.PeerIdChanged(
        oldPeerId: oldPeerId,
        newPeerId: newPeerId,
        userId: userId,
      ));
      Logger.info(
        'TransportManager: migrated $oldPeerId → $newPeerId (userId=$userId)',
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
