import 'dart:async';

import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/services/ble/ble_config.dart';
import 'package:anchor/services/ble/ble_models.dart';
import 'package:anchor/services/ble/connection/connection_manager.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

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
  StreamSubscription<DiscoveredEventArgs>? _discoveredSubscription;

  /// Whether currently scanning.
  bool get isScanning => _isScanning;

  /// Current dynamic RSSI floor. Peers below this are dropped.
  int get rssiFloor => _rssiFloor;

  // ==================== Scan Timing (Duty Cycling) ====================

  /// Current duty cycle ratio (fraction of period spent scanning).
  double _dutyCycleRatio = 0.33;

  bool _explicitBatterySaver = false;

  /// Temporary override: scan at 100% duty for one cycle (e.g. after
  /// triggerImmediateScan). Resets to normal after one period completes.
  bool _forceFullDutyCycle = false;

  /// Current RSSI floor — peers below this are ignored. Updated by
  /// [_recalculateTiming] based on density and battery mode.
  int _rssiFloor = -90;

  // ==================== Scan Dedup ====================

  /// Per-peer last-seen RSSI — for dedup threshold.
  final Map<String, int> _lastRssi = {};

  /// Per-peer last-emit time — for dedup window.
  final Map<String, DateTime> _lastEmit = {};

  // ==================== Profile Version Tracking ====================

  /// Per-peer last-known profile version from the advertisement local name.
  /// When a scan result carries the same version as the last successful
  /// profile read, the GATT profile read is skipped entirely.
  final Map<String, int> _peerProfileVersions = {};

  // ==================== Service UUID ====================

  static final _serviceUuid = BleUuids.service;

  // ==================== Callbacks ====================

  /// Called when a peer is discovered (after dedup). The BLE service
  /// uses this to emit a [DiscoveredPeer] to the UI.
  ///
  /// Parameters: (peerId, name, age, rssi, peripheral)
  void Function(String peerId, String name, int? age, int rssi,
      Peripheral peripheral,)? onPeerDiscovered;

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
    unawaited(_runScanCycle());
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
    } on Exception catch (e) {
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

    Logger.info('BleScanner: Triggering immediate scan (full duty cycle)', 'BLE');
    _forceFullDutyCycle = true;
    _scanRestartTimer?.cancel();
    try {
      _central.stopDiscovery().catchError((_) {});
    } on Exception catch (_) {}
    _runScanCycle();
  }

  /// Enable or disable battery saver mode (reduces scan frequency).
  void setBatterySaverMode({required bool enabled}) {
    _explicitBatterySaver = enabled;
    _recalculateTiming();
  }

  /// Recalculate scan timing based on peer density.
  /// Call after the visible peer count changes.
  void updateDensity(int visiblePeerCount) {
    _recalculateTiming(visiblePeerCount: visiblePeerCount);
  }

  /// Record the profile version from a successful GATT profile read.
  /// Future scan cycles will skip the profile read if the advertised
  /// version matches.
  void recordProfileVersion(String peerId, int version) {
    _peerProfileVersions[peerId] = version;
  }

  /// Clear scan dedup state for a peer (e.g. when peer is lost).
  void clearPeer(String peerId) {
    _lastEmit.remove(peerId);
    _lastRssi.remove(peerId);
    _peerProfileVersions.remove(peerId);
  }

  /// Clear all state. Called on BLE service stop.
  void clear() {
    _lastEmit.clear();
    _lastRssi.clear();
    _peerProfileVersions.clear();
    _lastImmediateScanAt = null;
  }

  /// Dispose resources.
  Future<void> dispose() async {
    await stop();
    clear();
  }

  // ==================== Internal ====================

  Future<void> _runScanCycle() async {
    if (!_isScanning) return;

    final period = _config.dutyCyclePeriod;
    final ratio = _forceFullDutyCycle ? 1.0 : _dutyCycleRatio;
    _forceFullDutyCycle = false; // reset one-shot override

    final onTime = Duration(
      milliseconds: (period.inMilliseconds * ratio).round(),
    );
    final offTime = Duration(
      milliseconds: (period.inMilliseconds * (1.0 - ratio)).round(),
    );

    try {
      Logger.info(
        'BleScanner: Duty cycle ON=${onTime.inMilliseconds}ms '
        'OFF=${offTime.inMilliseconds}ms (ratio=${ratio.toStringAsFixed(2)})',
        'BLE',
      );

      // Scan WITH the Anchor service UUID filter. This is required because
      // iOS Core Bluetooth does NOT populate advertisement.serviceUUIDs for
      // peripherals when scanning without a filter — causing iOS to silently
      // drop all Anchor devices (both Android and other iOS). With the v2
      // compact local name ("A<version>", 3-4 bytes), the total ad payload
      // is Flags(3) + UUID(18) + Name(2+N) ≈ 26 bytes, well under Android's
      // 31-byte primary AD limit, so the UUID stays in the primary packet.
      await _central.startDiscovery(serviceUUIDs: [_serviceUuid]);

      // Stop after ON time, pause for OFF time, then restart
      _scanRestartTimer?.cancel();
      _scanRestartTimer = Timer(onTime, () async {
        if (!_isScanning) return;
        try {
          await _central.stopDiscovery();
        } on Exception catch (_) {}

        if (_isScanning && offTime > Duration.zero) {
          _scanRestartTimer = Timer(offTime, _runScanCycle);
        } else if (_isScanning) {
          // 0 OFF time = continuous scan (0-peer mode)
          unawaited(_runScanCycle());
        }
      });
    } on Exception catch (e) {
      Logger.error('BleScanner: Scan cycle failed', e, null, 'BLE');

      if (_isScanning) {
        _scanRestartTimer?.cancel();
        _scanRestartTimer = Timer(offTime, _runScanCycle);
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

    // Dynamic RSSI floor — drop peers below the current threshold.
    // The floor is tighter in high-density mode to focus on nearby peers.
    if (rssi < _rssiFloor) {
      return;
    }

    // Check service UUID
    final hasAnchorService = adv.serviceUUIDs.contains(_serviceUuid);

    // Check local name prefix
    final advName = adv.name ?? '';
    final decoded = advName.isNotEmpty ? _decodeLocalName(advName) : null;

    // Not an Anchor device if neither marker is present
    if (!hasAnchorService && decoded == null) return;

    // Dedup: suppress re-emits for the same peer within one scan cycle.
    // Allow through if: (a) first time seeing this peer, (b) >10 seconds
    // since last emit, or (c) RSSI changed by ≥12 dBm (significant
    // proximity change, not normal jitter).
    final isFirstSighting = !_lastEmit.containsKey(deviceId);
    if (!isFirstSighting) {
      final timeSince = now.difference(_lastEmit[deviceId]!);
      final rssiDelta = (_lastRssi[deviceId]! - rssi).abs();
      if (timeSince < const Duration(seconds: 10) && rssiDelta < 12) {
        // Still update RSSI for smoother tracking, but don't re-emit.
        _lastRssi[deviceId] = rssi;
        return;
      }
    }

    _lastRssi[deviceId] = rssi;
    _lastEmit[deviceId] = now;

    final name = decoded?.name ?? 'Anchor User';
    final age = decoded?.age;
    final profileVersion = decoded?.profileVersion;

    // Register the peripheral for later on-demand connection
    _connectionManager.registerPeripheral(deviceId, peripheral);

    // Notify the BLE service about the discovery
    onPeerDiscovered?.call(deviceId, name, age, rssi, peripheral);

    // Skip GATT profile read if the advertised profile version matches
    // the version from the last successful read. This avoids a GATT
    // connection + fff1 read (~200-400B) every scan cycle for unchanged peers.
    if (profileVersion != null &&
        _peerProfileVersions[deviceId] == profileVersion) {
      return;
    }

    // Request profile read in the background
    onPeerNeedsProfile?.call(deviceId, peripheral);
  }

  /// Decode local name.
  ///
  /// **v2 (current)**: "A<profileVersion>" (e.g. "A3", "A17")
  ///   Minimal format that keeps the advertisement under 31 bytes so the
  ///   service UUID stays in the primary AD packet. Name/age come from fff1.
  ///
  /// The legacy v1 format "A:<name>:<age>" is rejected — it leaks identity
  /// in the advertisement and causes the service UUID to overflow into the
  /// scan response, breaking cross-platform discovery.
  ({String name, int? age, int? profileVersion})? _decodeLocalName(
      String advName,) {
    if (!advName.startsWith('A')) return null;

    // Reject legacy v1 format "A:<name>:<age>[:<version>]" — leaks identity.
    if (advName.startsWith('A:')) return null;

    // v2 compact format: "A<profileVersion>" (e.g. "A3", "A17")
    if (advName.length >= 2) {
      final versionStr = advName.substring(1);
      final profileVersion = int.tryParse(versionStr);
      if (profileVersion != null) {
        return (
          name: 'Anchor User', // Real name comes from GATT fff1 read
          age: null,            // Real age comes from GATT fff1 read
          profileVersion: profileVersion,
        );
      }
    }

    return null;
  }

  void _recalculateTiming({int? visiblePeerCount}) {
    final count = visiblePeerCount ?? 0;

    if (_explicitBatterySaver) {
      _dutyCycleRatio = _config.dutyCycleBatterySaver;
      _rssiFloor = _config.rssiFloorNormal;
      return;
    }

    final isHighDensity = count >= _config.highDensityPeerThreshold;

    if (count == 0) {
      // No peers visible — scan continuously (100% duty) to find them fast.
      _dutyCycleRatio = 1.0;
      _rssiFloor = _config.rssiFloorNormal;
    } else if (isHighDensity) {
      _dutyCycleRatio = _config.dutyCycleHighDensity;
      _rssiFloor = _config.rssiFloorHighDensity;
    } else {
      _dutyCycleRatio = _config.dutyCycleNormal;
      _rssiFloor = _config.rssiFloorNormal;
    }
  }
}
