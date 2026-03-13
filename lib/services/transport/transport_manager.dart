import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:wifi_aware_p2p/wifi_aware_p2p.dart' as wa;

import '../../core/utils/logger.dart';
import '../ble/ble_models.dart' as ble;
import '../ble/ble_service_interface.dart';
import '../wifi_aware/wifi_aware_transport_service.dart';
import 'transport_enums.dart';

/// Unified transport manager that abstracts over Wi-Fi Aware (primary) and
/// BLE (fallback), presenting a single interface to blocs.
///
/// ## Platform Behaviour
///
/// **Android**: Wi-Fi Aware is used as the primary transport when available.
/// No pairing required — discovery works automatically.
///
/// **iOS**: Wi-Fi Aware is disabled. Apple requires per-device pairing via
/// DeviceDiscoveryUI before publish/subscribe works, making it impractical
/// for discovering 100+ users on a cruise. iOS uses BLE for discovery and
/// Multipeer Connectivity (via flutter_nearby_connections_plus) for high-speed
/// photo transfer instead.
///
/// ## Per-Peer Routing
///
/// Each peer is associated with the transport that discovered it.
/// Messages are routed through the same transport that discovered the peer.
/// This prevents cross-transport ID confusion (Wi-Fi Aware peer IDs ≠ BLE
/// device IDs).
///
/// ## Stream Architecture
///
/// When transport switches, the active source streams are swapped.
/// StreamControllers use broadcast() so blocs can subscribe at any time.
/// Only ONE transport emits at a time — never merged simultaneously to
/// avoid duplicate peer discoveries.
class TransportManager {
  TransportManager({
    required WifiAwareTransportService wifiAwareService,
    required BleServiceInterface bleService,
  })  : _wifiAwareService = wifiAwareService,
        _bleService = bleService {
    // Immediately subscribe to BLE streams so peer discovery works
    // even before initialize() is called (BleConnectionBloc starts BLE
    // independently).
    _subscribeToBle();
    Logger.info('TransportManager: BLE stream forwarding active', 'Transport');
  }

  final WifiAwareTransportService _wifiAwareService;
  final BleServiceInterface _bleService;

  TransportType _activeTransport = TransportType.ble;
  bool _initialized = false;
  final Map<String, TransportType> _peerTransport = {};

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
  final _activeTransportController =
      StreamController<TransportType>.broadcast();

  // Active source subscriptions (swapped on transport change)
  final List<StreamSubscription> _activeSubscriptions = [];

  // Availability subscription
  StreamSubscription<bool>? _availabilitySub;

  // ==================== Public Getters ====================

  TransportType get activeTransport => _activeTransport;
  Stream<TransportType> get activeTransportStream =>
      _activeTransportController.stream;

  // ==================== Lifecycle ====================

  /// Initialize Wi-Fi Aware transport (optional upgrade from BLE).
  ///
  /// BLE forwarding is already active from construction. This method attempts
  /// to start Wi-Fi Aware as the primary transport. Safe to call multiple
  /// times — subsequent calls are no-ops.
  ///
  /// **Android only**: Wi-Fi Aware is attempted as primary transport.
  /// **iOS**: Skipped — Apple requires per-device pairing via DeviceDiscoveryUI,
  /// making it impractical for 100+ users. iOS uses BLE + Multipeer Connectivity.
  ///
  /// Called from [ProfileBloc] when the profile is first broadcast, since
  /// Wi-Fi Aware publishing requires profile metadata.
  Future<void> initialize({
    required String ownUserId,
    required ble.BroadcastPayload profile,
  }) async {
    if (_initialized) return;
    _initialized = true;

    // BLE is already initialized and started by BleConnectionBloc — don't
    // re-initialize here.

    // Wi-Fi Aware is Android-only. On iOS, Apple's DeviceDiscoveryUI requires
    // manual per-device pairing before publish/subscribe works — impractical
    // for discovering many users. iOS uses BLE + Multipeer Connectivity instead.
    if (Platform.isIOS) {
      Logger.info(
        'TransportManager: iOS — using BLE + Multipeer Connectivity '
        '(Wi-Fi Aware disabled, requires per-device pairing)',
        'Transport',
      );
      return;
    }

    // Android: try Wi-Fi Aware as primary transport
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

    if (wifiAwareAvailable) {
      _switchTo(TransportType.wifiAware);
      Logger.info(
        'TransportManager: Wi-Fi Aware is primary transport',
        'Transport',
      );
    } else {
      Logger.info(
        'TransportManager: BLE is primary transport (Wi-Fi Aware unavailable)',
        'Transport',
      );
    }

    // Listen for Wi-Fi Aware availability changes — auto-switch
    _availabilitySub =
        _wifiAwareService.availabilityStream.listen((available) {
      if (available && _activeTransport == TransportType.ble) {
        Logger.info(
          'TransportManager: Wi-Fi Aware became available, switching',
          'Transport',
        );
        _switchTo(TransportType.wifiAware);
      } else if (!available && _activeTransport == TransportType.wifiAware) {
        Logger.info(
          'TransportManager: Wi-Fi Aware lost, falling back to BLE',
          'Transport',
        );
        _switchTo(TransportType.ble);
      }
    });
  }

  Future<void> start() async {
    if (_activeTransport == TransportType.wifiAware) {
      await _wifiAwareService.start();
    }
    // BLE start is handled by BleConnectionBloc — don't double-start here.
  }

  Future<void> stop() async {
    await _wifiAwareService.stop();
    await _bleService.stop();
  }

  Future<void> dispose() async {
    await _availabilitySub?.cancel();
    _cancelActiveSubscriptions();

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
    await _activeTransportController.close();
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

  // ==================== Unified Send Operations ====================

  Future<void> broadcastProfile(ble.BroadcastPayload payload) async {
    // Always broadcast on BLE for maximum compatibility
    await _bleService.broadcastProfile(payload);

    // Also publish on Wi-Fi Aware if active
    if (_activeTransport == TransportType.wifiAware) {
      await _wifiAwareService.updateProfile(payload);
    }
  }

  Future<bool> sendMessage(String peerId, ble.MessagePayload payload) async {
    final transport = _peerTransport[peerId] ?? _activeTransport;

    if (transport == TransportType.wifiAware) {
      final success = await _wifiAwareService.sendMessage(peerId, payload);
      if (success) return true;
      // Fall back to BLE if Wi-Fi Aware send fails
      Logger.warning(
        'TransportManager: Wi-Fi Aware send failed, trying BLE',
        'Transport',
      );
    }

    return _bleService.sendMessage(peerId, payload);
  }

  Future<bool> sendPhoto(
    String peerId,
    Uint8List photoData,
    String messageId, {
    String? photoId,
  }) async {
    final transport = _peerTransport[peerId] ?? _activeTransport;

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

    return _bleService.sendPhoto(peerId, photoData, messageId, photoId: photoId);
  }

  Future<bool> sendPhotoPreview({
    required String peerId,
    required String messageId,
    required String photoId,
    required Uint8List thumbnailBytes,
    required int originalSize,
  }) async {
    final transport = _peerTransport[peerId] ?? _activeTransport;

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

    return _bleService.sendPhotoPreview(
      peerId: peerId,
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
    final transport = _peerTransport[peerId] ?? _activeTransport;

    if (transport == TransportType.wifiAware) {
      final success = await _wifiAwareService.sendPhotoRequest(
        peerId: peerId,
        messageId: messageId,
        photoId: photoId,
      );
      if (success) return true;
    }

    return _bleService.sendPhotoRequest(
      peerId: peerId,
      messageId: messageId,
      photoId: photoId,
    );
  }

  Future<bool> sendDropAnchor(String peerId) async {
    final transport = _peerTransport[peerId] ?? _activeTransport;

    if (transport == TransportType.wifiAware) {
      final success = await _wifiAwareService.sendDropAnchor(peerId);
      if (success) return true;
    }

    return _bleService.sendDropAnchor(peerId);
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
    final transport = _peerTransport[peerId] ?? _activeTransport;
    if (transport == TransportType.wifiAware) {
      return _wifiAwareService.isPeerReachable(peerId);
    }
    return _bleService.isPeerReachable(peerId);
  }

  /// Fetch all full-size profile photos for a peer (BLE only — uses fff4).
  Future<bool> fetchFullProfilePhotos(String peerId) =>
      _bleService.fetchFullProfilePhotos(peerId);

  /// Cancel an ongoing photo transfer.
  Future<void> cancelPhotoTransfer(String messageId) =>
      _bleService.cancelPhotoTransfer(messageId);

  // BLE service interface passthrough for blocs that need it
  BleServiceInterface get bleService => _bleService;

  // ==================== Private ====================

  void _switchTo(TransportType transport) {
    _cancelActiveSubscriptions();
    _activeTransport = transport;
    _peerTransport.clear();

    if (transport == TransportType.wifiAware) {
      _subscribeToWifiAware();
    } else {
      _subscribeToBle();
    }

    _activeTransportController.add(transport);
  }

  void _subscribeToWifiAware() {
    _activeSubscriptions.addAll([
      _wifiAwareService.peerDiscoveredStream.listen((peer) {
        _peerTransport[peer.peerId] = TransportType.wifiAware;
        _peerDiscoveredController.add(peer);
      }),
      _wifiAwareService.peerLostStream.listen((peerId) {
        _peerTransport.remove(peerId);
        _peerLostController.add(peerId);
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
    ]);

    // Also subscribe to BLE for peers not reachable via Wi-Fi Aware.
    // BLE peers are tagged with TransportType.ble in _peerTransport.
    _activeSubscriptions.addAll([
      _bleService.peerDiscoveredStream.listen((peer) {
        // Only emit BLE peers that haven't already been seen via Wi-Fi Aware
        if (!_peerTransport.containsKey(peer.peerId)) {
          _peerTransport[peer.peerId] = TransportType.ble;
          _peerDiscoveredController.add(peer);
        }
      }),
      _bleService.peerLostStream.listen((peerId) {
        if (_peerTransport[peerId] == TransportType.ble) {
          _peerTransport.remove(peerId);
          _peerLostController.add(peerId);
        }
      }),
      _bleService.messageReceivedStream.listen(
        _messageReceivedController.add,
      ),
      _bleService.photoPreviewReceivedStream.listen(
        _photoPreviewReceivedController.add,
      ),
      _bleService.photoRequestReceivedStream.listen(
        _photoRequestReceivedController.add,
      ),
      _bleService.photoProgressStream.listen(
        _photoProgressController.add,
      ),
      _bleService.photoReceivedStream.listen(
        _photoReceivedController.add,
      ),
      _bleService.anchorDropReceivedStream.listen(
        _anchorDropReceivedController.add,
      ),
    ]);
  }

  void _subscribeToBle() {
    _activeSubscriptions.addAll([
      _bleService.peerDiscoveredStream.listen((peer) {
        _peerTransport[peer.peerId] = TransportType.ble;
        _peerDiscoveredController.add(peer);
      }),
      _bleService.peerLostStream.listen((peerId) {
        _peerTransport.remove(peerId);
        _peerLostController.add(peerId);
      }),
      _bleService.messageReceivedStream.listen(
        _messageReceivedController.add,
      ),
      _bleService.photoPreviewReceivedStream.listen(
        _photoPreviewReceivedController.add,
      ),
      _bleService.photoRequestReceivedStream.listen(
        _photoRequestReceivedController.add,
      ),
      _bleService.photoProgressStream.listen(
        _photoProgressController.add,
      ),
      _bleService.photoReceivedStream.listen(
        _photoReceivedController.add,
      ),
      _bleService.anchorDropReceivedStream.listen(
        _anchorDropReceivedController.add,
      ),
    ]);
  }

  void _cancelActiveSubscriptions() {
    for (final sub in _activeSubscriptions) {
      sub.cancel();
    }
    _activeSubscriptions.clear();
  }
}
