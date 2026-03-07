import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/utils/logger.dart';
import 'ble_models.dart';
import 'ble_service_interface.dart';

// ==================== Events ====================

abstract class BleConnectionEvent extends Equatable {
  const BleConnectionEvent();

  @override
  List<Object?> get props => [];
}

/// Initialize BLE and check permissions
class InitializeBleConnection extends BleConnectionEvent {
  const InitializeBleConnection();
}

/// Request permissions if needed
class RequestBlePermissions extends BleConnectionEvent {
  const RequestBlePermissions();
}

/// Start BLE service (scanning + broadcasting)
class StartBleService extends BleConnectionEvent {
  const StartBleService();
}

/// Stop BLE service
class StopBleService extends BleConnectionEvent {
  const StopBleService();
}

/// App moved to foreground - aggressive scanning
class AppResumed extends BleConnectionEvent {
  const AppResumed();
}

/// App moved to background - reduce scanning
class AppPaused extends BleConnectionEvent {
  const AppPaused();
}

/// Toggle whether this device is visible to others (scanning + broadcasting)
class SetVisibility extends BleConnectionEvent {
  const SetVisibility(this.visible);
  final bool visible;

  @override
  List<Object?> get props => [visible];
}

/// Toggle battery saver mode (reduces scan frequency)
class SetBatterySaver extends BleConnectionEvent {
  const SetBatterySaver(this.enabled);
  final bool enabled;

  @override
  List<Object?> get props => [enabled];
}

/// Toggle mesh relay (message forwarding through intermediate devices)
class SetMeshRelay extends BleConnectionEvent {
  const SetMeshRelay(this.enabled);
  final bool enabled;

  @override
  List<Object?> get props => [enabled];
}

/// BLE status changed (internal)
class _BleStatusChanged extends BleConnectionEvent {
  const _BleStatusChanged(this.status);
  final BleStatus status;

  @override
  List<Object?> get props => [status];
}

// ==================== State ====================

enum BleConnectionStatus {
  /// Initial state, not checked yet
  initial,

  /// Checking Bluetooth availability
  checking,

  /// Bluetooth not available on device
  unavailable,

  /// Bluetooth is off
  disabled,

  /// Permissions not granted
  noPermission,

  /// Ready but not started
  ready,

  /// Starting up
  starting,

  /// Active and running
  active,

  /// Error state
  error,
}

class BleConnectionState extends Equatable {
  const BleConnectionState({
    this.status = BleConnectionStatus.initial,
    this.isBluetoothAvailable = false,
    this.isBluetoothEnabled = false,
    this.hasPermissions = false,
    this.isScanning = false,
    this.isBroadcasting = false,
    this.isInForeground = true,
    this.isVisible = true,
    this.isBatterySaver = false,
    this.isMeshRelay = true,
    this.errorMessage,
  });

  final BleConnectionStatus status;
  final bool isBluetoothAvailable;
  final bool isBluetoothEnabled;
  final bool hasPermissions;
  final bool isScanning;
  final bool isBroadcasting;
  final bool isInForeground;
  final bool isVisible;
  final bool isBatterySaver;
  final bool isMeshRelay;
  final String? errorMessage;

  /// Whether BLE is ready to use
  bool get isReady =>
      status == BleConnectionStatus.ready ||
      status == BleConnectionStatus.active;

  /// Whether we need to show permission request
  bool get needsPermission =>
      isBluetoothAvailable && isBluetoothEnabled && !hasPermissions;

  /// Whether we need to ask user to enable Bluetooth
  bool get needsBluetoothEnabled => isBluetoothAvailable && !isBluetoothEnabled;

  /// User-friendly status message
  String get statusMessage {
    switch (status) {
      case BleConnectionStatus.initial:
      case BleConnectionStatus.checking:
        return 'Checking Bluetooth...';
      case BleConnectionStatus.unavailable:
        return 'Bluetooth not available';
      case BleConnectionStatus.disabled:
        return 'Please enable Bluetooth';
      case BleConnectionStatus.noPermission:
        return 'Bluetooth permission needed';
      case BleConnectionStatus.ready:
        return 'Ready to discover';
      case BleConnectionStatus.starting:
        return 'Starting...';
      case BleConnectionStatus.active:
        if (isScanning && isBroadcasting) {
          return 'Discovering & broadcasting';
        } else if (isScanning) {
          return 'Discovering nearby';
        } else if (isBroadcasting) {
          return 'Broadcasting profile';
        }
        return 'Active';
      case BleConnectionStatus.error:
        return errorMessage ?? 'Error';
    }
  }

  BleConnectionState copyWith({
    BleConnectionStatus? status,
    bool? isBluetoothAvailable,
    bool? isBluetoothEnabled,
    bool? hasPermissions,
    bool? isScanning,
    bool? isBroadcasting,
    bool? isInForeground,
    bool? isVisible,
    bool? isBatterySaver,
    bool? isMeshRelay,
    String? errorMessage,
  }) {
    return BleConnectionState(
      status: status ?? this.status,
      isBluetoothAvailable: isBluetoothAvailable ?? this.isBluetoothAvailable,
      isBluetoothEnabled: isBluetoothEnabled ?? this.isBluetoothEnabled,
      hasPermissions: hasPermissions ?? this.hasPermissions,
      isScanning: isScanning ?? this.isScanning,
      isBroadcasting: isBroadcasting ?? this.isBroadcasting,
      isInForeground: isInForeground ?? this.isInForeground,
      isVisible: isVisible ?? this.isVisible,
      isBatterySaver: isBatterySaver ?? this.isBatterySaver,
      isMeshRelay: isMeshRelay ?? this.isMeshRelay,
      errorMessage: errorMessage,
    );
  }

  @override
  List<Object?> get props => [
        status,
        isBluetoothAvailable,
        isBluetoothEnabled,
        hasPermissions,
        isScanning,
        isBroadcasting,
        isInForeground,
        isVisible,
        isBatterySaver,
        isMeshRelay,
        errorMessage,
      ];
}

// ==================== Bloc ====================

class BleConnectionBloc extends Bloc<BleConnectionEvent, BleConnectionState> {
  BleConnectionBloc({
    required BleServiceInterface bleService,
  })  : _bleService = bleService,
        super(const BleConnectionState()) {
    on<InitializeBleConnection>(_onInitialize);
    on<RequestBlePermissions>(_onRequestPermissions);
    on<StartBleService>(_onStart);
    on<StopBleService>(_onStop);
    on<AppResumed>(_onAppResumed);
    on<AppPaused>(_onAppPaused);
    on<SetVisibility>(_onSetVisibility);
    on<SetBatterySaver>(_onSetBatterySaver);
    on<SetMeshRelay>(_onSetMeshRelay);
    on<_BleStatusChanged>(_onStatusChanged);

    // Listen to BLE status changes
    _statusSubscription = _bleService.statusStream.listen((status) {
      add(_BleStatusChanged(status));
    });
  }

  final BleServiceInterface _bleService;
  StreamSubscription<BleStatus>? _statusSubscription;

  static const _prefVisible = 'ble_visible';
  static const _prefBatterySaver = 'ble_battery_saver';
  static const _prefMeshRelay = 'ble_mesh_relay';

  Future<void> _onInitialize(
    InitializeBleConnection event,
    Emitter<BleConnectionState> emit,
  ) async {
    emit(state.copyWith(status: BleConnectionStatus.checking));

    // Load persisted settings
    final prefs = await SharedPreferences.getInstance();
    final isVisible = prefs.getBool(_prefVisible) ?? true;
    final isBatterySaver = prefs.getBool(_prefBatterySaver) ?? false;
    final isMeshRelay = prefs.getBool(_prefMeshRelay) ?? true;
    emit(state.copyWith(
        isVisible: isVisible,
        isBatterySaver: isBatterySaver,
        isMeshRelay: isMeshRelay));
    if (isBatterySaver) await _bleService.setBatterySaverMode(true);
    if (!isMeshRelay) await _bleService.setMeshRelayMode(false);

    try {
      final available = await _bleService.isBluetoothAvailable();
      if (!available) {
        emit(state.copyWith(
          status: BleConnectionStatus.unavailable,
          isBluetoothAvailable: false,
        ));
        return;
      }

      final enabled = await _bleService.isBluetoothEnabled();
      if (!enabled) {
        emit(state.copyWith(
          status: BleConnectionStatus.disabled,
          isBluetoothAvailable: true,
          isBluetoothEnabled: false,
        ));
        return;
      }

      final hasPerms = await _bleService.hasPermissions();
      if (!hasPerms) {
        emit(state.copyWith(
          status: BleConnectionStatus.noPermission,
          isBluetoothAvailable: true,
          isBluetoothEnabled: true,
          hasPermissions: false,
        ));
        return;
      }

      // Initialize BLE service
      await _bleService.initialize();

      emit(state.copyWith(
        status: BleConnectionStatus.ready,
        isBluetoothAvailable: true,
        isBluetoothEnabled: true,
        hasPermissions: true,
      ));

      Logger.info('BleConnectionBloc: Initialized successfully', 'BLE');

      // Auto-start if in foreground and visible
      if (state.isInForeground && state.isVisible) {
        add(const StartBleService());
      }
    } catch (e) {
      Logger.error('BleConnectionBloc: Initialization failed', e, null, 'BLE');
      emit(state.copyWith(
        status: BleConnectionStatus.error,
        errorMessage: 'Failed to initialize: $e',
      ));
    }
  }

  Future<void> _onRequestPermissions(
    RequestBlePermissions event,
    Emitter<BleConnectionState> emit,
  ) async {
    try {
      final granted = await _bleService.requestPermissions();
      emit(state.copyWith(hasPermissions: granted));

      if (granted) {
        // Re-initialize after permissions granted
        add(const InitializeBleConnection());
      }
    } catch (e) {
      Logger.error('BleConnectionBloc: Permission request failed', e, null, 'BLE');
    }
  }

  Future<void> _onStart(
    StartBleService event,
    Emitter<BleConnectionState> emit,
  ) async {
    if (!state.isReady && state.status != BleConnectionStatus.ready) {
      Logger.warning('BleConnectionBloc: Cannot start - not ready', 'BLE');
      return;
    }

    emit(state.copyWith(status: BleConnectionStatus.starting));

    try {
      await _bleService.start();
      emit(state.copyWith(
        status: BleConnectionStatus.active,
        isScanning: _bleService.isScanning,
        isBroadcasting: _bleService.isBroadcasting,
      ));
      Logger.info('BleConnectionBloc: Started', 'BLE');
    } catch (e) {
      Logger.error('BleConnectionBloc: Start failed', e, null, 'BLE');
      emit(state.copyWith(
        status: BleConnectionStatus.error,
        errorMessage: 'Failed to start',
      ));
    }
  }

  Future<void> _onStop(
    StopBleService event,
    Emitter<BleConnectionState> emit,
  ) async {
    try {
      await _bleService.stop();
      emit(state.copyWith(
        status: BleConnectionStatus.ready,
        isScanning: false,
        isBroadcasting: false,
      ));
      Logger.info('BleConnectionBloc: Stopped', 'BLE');
    } catch (e) {
      Logger.error('BleConnectionBloc: Stop failed', e, null, 'BLE');
    }
  }

  Future<void> _onAppResumed(
    AppResumed event,
    Emitter<BleConnectionState> emit,
  ) async {
    emit(state.copyWith(isInForeground: true));

    // Start scanning if we're ready
    if (state.status == BleConnectionStatus.ready) {
      add(const StartBleService());
    } else if (state.status == BleConnectionStatus.active) {
      // Already active, trigger immediate scan
      try {
        await _bleService.startScanning();
        Logger.info('BleConnectionBloc: Resumed - triggered scan', 'BLE');
      } catch (e) {
        Logger.warning('BleConnectionBloc: Resume scan failed: $e', 'BLE');
      }
    }
  }

  Future<void> _onAppPaused(
    AppPaused event,
    Emitter<BleConnectionState> emit,
  ) async {
    emit(state.copyWith(isInForeground: false));

    // Keep running in background but at reduced rate
    // (The platform handles actual background behavior)
    Logger.info('BleConnectionBloc: App paused - background mode', 'BLE');
  }

  Future<void> _onSetVisibility(
    SetVisibility event,
    Emitter<BleConnectionState> emit,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefVisible, event.visible);
    emit(state.copyWith(isVisible: event.visible));

    if (event.visible) {
      if (state.isReady || state.status == BleConnectionStatus.active) {
        add(const StartBleService());
      }
    } else {
      add(const StopBleService());
    }
    Logger.info('BLE visibility set to ${event.visible}', 'BLE');
  }

  Future<void> _onSetBatterySaver(
    SetBatterySaver event,
    Emitter<BleConnectionState> emit,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefBatterySaver, event.enabled);
    await _bleService.setBatterySaverMode(event.enabled);
    emit(state.copyWith(isBatterySaver: event.enabled));
    Logger.info('Battery saver set to ${event.enabled}', 'BLE');
  }

  Future<void> _onSetMeshRelay(
    SetMeshRelay event,
    Emitter<BleConnectionState> emit,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefMeshRelay, event.enabled);
    await _bleService.setMeshRelayMode(event.enabled);
    emit(state.copyWith(isMeshRelay: event.enabled));
    Logger.info('Mesh relay set to ${event.enabled}', 'BLE');
  }

  void _onStatusChanged(
    _BleStatusChanged event,
    Emitter<BleConnectionState> emit,
  ) {
    emit(state.copyWith(
      isScanning: _bleService.isScanning,
      isBroadcasting: _bleService.isBroadcasting,
    ));
  }

  @override
  Future<void> close() {
    _statusSubscription?.cancel();
    return super.close();
  }
}
