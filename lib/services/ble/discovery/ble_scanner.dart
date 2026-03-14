import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import '../../../core/utils/logger.dart';
import '../ble_config.dart';
import '../ble_models.dart';
import '../connection/connection_manager.dart';

/// Callback signature for when a scan result needs profile reading.
typedef OnPeerNeedsProfile = void Function(String peerId, Peripheral peripheral);

/// Manages BLE scan lifecycle with density-adaptive timing and deduplication.
///
/// Extracted from the monolithic BLE service (now [BleFacade]) to:
/// - Separate scan lifecycle from connection/profile logic
/// - Centralize scan dedup and rate limiting
/// - Make scan timing independently testable
///
/// The scanner does NOT connect to peers or read profiles — it emits
/// [onPeerDiscovered] for the BLE service to process and calls
/// [onPeerNeedsProfile] to request a background profile read.
class BleScanner {
  BleScanner({
    required CentralManager central,
    required ConnectionManager connectionManager,
    required BleConfig config,
  })  : _central = central,
        _connectionManager = connectionManager,
        _config = config;

  final CentralManager _central;
  final ConnectionManager _connectionManager;
  final BleConfig _config;

  // ==================== Scan State ====================

  bool _isScanning = false;
  Timer? _scanRestartTimer;
  DateTime? _lastImmediateScanAt;
  StreamSubscription? _discoveredSubscription;

  /// Whether currently scanning.
  bool get isScanning => _isScanning;

  // ==================== Scan Timing ====================

  static const _normalScanDuration = Duration(seconds: 5);
  static const _normalScanPause = Duration(seconds: 15);
  static const _batteryScanDuration = Duration(seconds: 2);
  static const _batteryScanPause = Duration(seconds: 30);

  Duration _scanDuration = _normalScanDuration;
  Duration _scanPause = _normalScanPause;
  bool _explicitBatterySaver = false;

  // ==================== Scan Dedup ====================

  /// Per-peer last-seen RSSI — for dedup threshold.
  final Map<String, int> _lastRssi = {};

  /// Per-peer last-emit time — for dedup window.
  final Map<String, DateTime> _lastEmit = {};

  // ==================== Service UUID ====================

  static final _serviceUuid =
      UUID.fromString('0000fff0-0000-1000-8000-00805f9b34fb');

  // ==================== Callbacks ====================

  /// Called when a peer is discovered (after dedup). The BLE service
  /// uses this to emit a [DiscoveredPeer] to the UI.
  ///
  /// Parameters: (peerId, name, age, rssi, peripheral)
  void Function(String peerId, String name, int? age, int rssi,
      Peripheral peripheral)? onPeerDiscovered;

  /// Called when a discovered peer needs its profile read via GATT.
  /// The BLE service delegates this to ConnectionManager + profile reading.
  OnPeerNeedsProfile? onPeerNeedsProfile;

  // ==================== Public API ====================

  /// Start periodic BLE scanning.
  Future<void> start() async {
    if (_isScanning) return;

    Logger.info('BleScanner: Starting periodic scan...', 'BLE');

    _isScanning = true;

    // Listen for discovered peripherals
    await _discoveredSubscription?.cancel();
    _discoveredSubscription = _central.discovered.listen(_onDeviceDiscovered);

    // Start first scan cycle
    _runScanCycle();
  }

  /// Stop scanning.
  Future<void> stop() async {
    if (!_isScanning) return;

    Logger.info('BleScanner: Stopping scan...', 'BLE');

    _isScanning = false;
    _scanRestartTimer?.cancel();
    _scanRestartTimer = null;

    try {
      await _central.stopDiscovery();
      await _discoveredSubscription?.cancel();
      _discoveredSubscription = null;
    } catch (e) {
      Logger.error('BleScanner: Scan stop failed', e, null, 'BLE');
    }
  }

  /// Cancel any active scan pause and start a new scan cycle immediately.
  /// Called when we need to discover a peer we know is in range (e.g. they
  /// sent us a message but we haven't scanned their advertisement yet).
  void triggerImmediateScan() {
    if (!_isScanning) return;

    // Don't trigger too frequently — at most once every 3 seconds
    final now = DateTime.now();
    if (_lastImmediateScanAt != null &&
        now.difference(_lastImmediateScanAt!) < const Duration(seconds: 3)) {
      return;
    }
    _lastImmediateScanAt = now;

    Logger.info('BleScanner: Triggering immediate scan cycle', 'BLE');
    _scanRestartTimer?.cancel();
    try {
      _central.stopDiscovery().catchError((_) {});
    } catch (_) {}
    _runScanCycle();
  }

  /// Enable or disable battery saver mode (reduces scan frequency).
  void setBatterySaverMode(bool enabled) {
    _explicitBatterySaver = enabled;
    _recalculateTiming();
  }

  /// Recalculate scan timing based on peer density.
  /// Call after the visible peer count changes.
  void updateDensity(int visiblePeerCount) {
    _recalculateTiming(visiblePeerCount: visiblePeerCount);
  }

  /// Clear scan dedup state for a peer (e.g. when peer is lost).
  void clearPeer(String peerId) {
    _lastEmit.remove(peerId);
    _lastRssi.remove(peerId);
  }

  /// Clear all state. Called on BLE service stop.
  void clear() {
    _lastEmit.clear();
    _lastRssi.clear();
    _lastImmediateScanAt = null;
  }

  /// Dispose resources.
  Future<void> dispose() async {
    await stop();
    clear();
  }

  // ==================== Internal ====================

  void _runScanCycle() async {
    if (!_isScanning) return;

    try {
      Logger.info('BleScanner: Scan cycle starting...', 'BLE');

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
      Logger.error('BleScanner: Scan cycle failed', e, null, 'BLE');

      if (_isScanning) {
        _scanRestartTimer?.cancel();
        _scanRestartTimer = Timer(_scanPause, _runScanCycle);
      }
    }
  }

  void _onDeviceDiscovered(DiscoveredEventArgs event) {
    final peripheral = event.peripheral;
    final deviceId = peripheral.uuid.toString();
    final adv = event.advertisement;
    final rssi = event.rssi;
    final now = DateTime.now();

    // Skip peers recently marked as gone
    if (_connectionManager.isDeadPeer(deviceId)) {
      return;
    }

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

    final name = decoded?.name ?? 'Anchor User';
    final age = decoded?.age;

    // Register the peripheral for later on-demand connection
    _connectionManager.registerPeripheral(deviceId, peripheral);

    // Notify the BLE service about the discovery
    onPeerDiscovered?.call(deviceId, name, age, rssi, peripheral);

    // Request profile read in the background
    onPeerNeedsProfile?.call(deviceId, peripheral);
  }

  /// Decode local name "A:<name>:<age>"
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

  void _recalculateTiming({int? visiblePeerCount}) {
    if (_explicitBatterySaver) {
      _scanDuration = _batteryScanDuration;
      _scanPause = _batteryScanPause;
      return;
    }
    final isHighDensity =
        (visiblePeerCount ?? 0) >= _config.highDensityPeerThreshold;
    if (isHighDensity) {
      _scanDuration = _batteryScanDuration;
      _scanPause = _config.highDensityScanPause;
    } else {
      _scanDuration = _normalScanDuration;
      _scanPause = _config.normalScanPause;
    }
  }
}
