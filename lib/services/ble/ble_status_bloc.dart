import 'dart:async';

import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/services/ble/ble_models.dart';
import 'package:anchor/services/ble/ble_service_interface.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

// ==================== Events ====================

abstract class BleStatusEvent extends Equatable {
  const BleStatusEvent();

  @override
  List<Object?> get props => [];
}

/// Initialize BLE service
class InitializeBle extends BleStatusEvent {
  const InitializeBle();
}

/// Request BLE permissions
class RequestBlePermissions extends BleStatusEvent {
  const RequestBlePermissions();
}

/// Start BLE service (scanning + advertising)
class StartBle extends BleStatusEvent {
  const StartBle();
}

/// Stop BLE service
class StopBle extends BleStatusEvent {
  const StopBle();
}

/// BLE status changed (internal)
class BleStatusChanged extends BleStatusEvent {
  const BleStatusChanged(this.status);
  final BleStatus status;

  @override
  List<Object?> get props => [status];
}

/// Check Bluetooth availability
class CheckBluetoothAvailability extends BleStatusEvent {
  const CheckBluetoothAvailability();
}

/// Battery level changed (for adaptive scanning)
class BatteryLevelChanged extends BleStatusEvent {
  const BatteryLevelChanged(this.level);
  final int level; // 0-100

  @override
  List<Object?> get props => [level];
}

// ==================== State ====================

enum BleInitStatus {
  uninitialized,
  initializing,
  initialized,
  error,
}

class BleStatusState extends Equatable {
  const BleStatusState({
    this.initStatus = BleInitStatus.uninitialized,
    this.bleStatus = BleStatus.disabled,
    this.isBluetoothAvailable = false,
    this.isBluetoothEnabled = false,
    this.hasPermissions = false,
    this.batteryLevel = 100,
    this.errorMessage,
    this.isScanning = false,
    this.isBroadcasting = false,
  });

  final BleInitStatus initStatus;
  final BleStatus bleStatus;
  final bool isBluetoothAvailable;
  final bool isBluetoothEnabled;
  final bool hasPermissions;
  final int batteryLevel;
  final String? errorMessage;
  final bool isScanning;
  final bool isBroadcasting;

  /// Whether BLE is ready to use
  bool get isReady =>
      initStatus == BleInitStatus.initialized &&
      isBluetoothAvailable &&
      isBluetoothEnabled &&
      hasPermissions;

  /// Whether we should show a permission request
  bool get shouldRequestPermissions =>
      isBluetoothAvailable && isBluetoothEnabled && !hasPermissions;

  /// Whether we should show "enable Bluetooth" prompt
  bool get shouldEnableBluetooth => isBluetoothAvailable && !isBluetoothEnabled;

  /// Whether battery is low (for adaptive scanning)
  bool get isBatteryLow => batteryLevel < 20;

  /// Whether battery is critical
  bool get isBatteryCritical => batteryLevel < 10;

  /// Suggested scan interval based on battery
  Duration get adaptiveScanInterval {
    if (isBatteryCritical) return const Duration(minutes: 5);
    if (isBatteryLow) return const Duration(minutes: 2);
    return const Duration(seconds: 30);
  }

  /// User-friendly status message
  String get statusMessage {
    if (!isBluetoothAvailable) return 'Bluetooth not available';
    if (!isBluetoothEnabled) return 'Bluetooth is off';
    if (!hasPermissions) return 'Permissions required';
    if (initStatus == BleInitStatus.error) return errorMessage ?? 'Error';
    if (initStatus == BleInitStatus.initializing) return 'Starting...';

    switch (bleStatus) {
      case BleStatus.disabled:
        return 'Disabled';
      case BleStatus.noPermission:
        return 'No permission';
      case BleStatus.ready:
        return 'Ready';
      case BleStatus.scanning:
        return 'Scanning...';
      case BleStatus.advertising:
        return 'Broadcasting...';
      case BleStatus.active:
        return 'Active';
      case BleStatus.error:
        return 'Error';
    }
  }

  BleStatusState copyWith({
    BleInitStatus? initStatus,
    BleStatus? bleStatus,
    bool? isBluetoothAvailable,
    bool? isBluetoothEnabled,
    bool? hasPermissions,
    int? batteryLevel,
    String? errorMessage,
    bool? isScanning,
    bool? isBroadcasting,
  }) {
    return BleStatusState(
      initStatus: initStatus ?? this.initStatus,
      bleStatus: bleStatus ?? this.bleStatus,
      isBluetoothAvailable: isBluetoothAvailable ?? this.isBluetoothAvailable,
      isBluetoothEnabled: isBluetoothEnabled ?? this.isBluetoothEnabled,
      hasPermissions: hasPermissions ?? this.hasPermissions,
      batteryLevel: batteryLevel ?? this.batteryLevel,
      errorMessage: errorMessage,
      isScanning: isScanning ?? this.isScanning,
      isBroadcasting: isBroadcasting ?? this.isBroadcasting,
    );
  }

  @override
  List<Object?> get props => [
        initStatus,
        bleStatus,
        isBluetoothAvailable,
        isBluetoothEnabled,
        hasPermissions,
        batteryLevel,
        errorMessage,
        isScanning,
        isBroadcasting,
      ];
}

// ==================== Bloc ====================

class BleStatusBloc extends Bloc<BleStatusEvent, BleStatusState> {
  BleStatusBloc({
    required BleServiceInterface bleService,
  })  : _bleService = bleService,
        super(const BleStatusState()) {
    on<InitializeBle>(_onInitialize);
    on<RequestBlePermissions>(_onRequestPermissions);
    on<StartBle>(_onStart);
    on<StopBle>(_onStop);
    on<BleStatusChanged>(_onStatusChanged);
    on<CheckBluetoothAvailability>(_onCheckAvailability);
    on<BatteryLevelChanged>(_onBatteryLevelChanged);

    // Listen to BLE status changes
    _statusSubscription = _bleService.statusStream.listen((status) {
      add(BleStatusChanged(status));
    });
  }

  final BleServiceInterface _bleService;
  StreamSubscription<BleStatus>? _statusSubscription;

  Future<void> _onInitialize(
    InitializeBle event,
    Emitter<BleStatusState> emit,
  ) async {
    emit(state.copyWith(initStatus: BleInitStatus.initializing));

    try {
      // Check Bluetooth availability
      final available = await _bleService.isBluetoothAvailable();
      final enabled = await _bleService.isBluetoothEnabled();
      final hasPerms = await _bleService.hasPermissions();

      emit(state.copyWith(
        isBluetoothAvailable: available,
        isBluetoothEnabled: enabled,
        hasPermissions: hasPerms,
      ),);

      if (!available) {
        emit(state.copyWith(
          initStatus: BleInitStatus.error,
          errorMessage: 'Bluetooth not available on this device',
        ),);
        return;
      }

      if (!enabled) {
        emit(state.copyWith(
          initStatus: BleInitStatus.error,
          errorMessage: 'Please enable Bluetooth',
        ),);
        return;
      }

      if (!hasPerms) {
        emit(state.copyWith(
          initStatus: BleInitStatus.error,
          errorMessage: 'Bluetooth permissions required',
        ),);
        return;
      }

      // Initialize the service
      await _bleService.initialize();

      emit(state.copyWith(
        initStatus: BleInitStatus.initialized,
        bleStatus: _bleService.status,
      ),);

      Logger.info('BleStatusBloc: Initialized successfully', 'BLE');
    } catch (e) {
      Logger.error('BleStatusBloc: Initialization failed', e, null, 'BLE');
      emit(state.copyWith(
        initStatus: BleInitStatus.error,
        errorMessage: 'Failed to initialize: $e',
      ),);
    }
  }

  Future<void> _onRequestPermissions(
    RequestBlePermissions event,
    Emitter<BleStatusState> emit,
  ) async {
    try {
      final granted = await _bleService.requestPermissions();
      emit(state.copyWith(hasPermissions: granted));

      if (granted && state.initStatus != BleInitStatus.initialized) {
        // Re-initialize if permissions were just granted
        add(const InitializeBle());
      }
    } catch (e) {
      Logger.error('BleStatusBloc: Permission request failed', e, null, 'BLE');
      emit(state.copyWith(
        errorMessage: 'Failed to request permissions',
      ),);
    }
  }

  Future<void> _onStart(
    StartBle event,
    Emitter<BleStatusState> emit,
  ) async {
    if (!state.isReady) {
      Logger.warning('BleStatusBloc: Cannot start - not ready', 'BLE');
      return;
    }

    try {
      await _bleService.start();
      emit(state.copyWith(
        isScanning: _bleService.isScanning,
        isBroadcasting: _bleService.isBroadcasting,
      ),);
    } catch (e) {
      Logger.error('BleStatusBloc: Start failed', e, null, 'BLE');
      emit(state.copyWith(errorMessage: 'Failed to start'));
    }
  }

  Future<void> _onStop(
    StopBle event,
    Emitter<BleStatusState> emit,
  ) async {
    try {
      await _bleService.stop();
      emit(state.copyWith(
        isScanning: false,
        isBroadcasting: false,
      ),);
    } catch (e) {
      Logger.error('BleStatusBloc: Stop failed', e, null, 'BLE');
    }
  }

  void _onStatusChanged(
    BleStatusChanged event,
    Emitter<BleStatusState> emit,
  ) {
    emit(state.copyWith(
      bleStatus: event.status,
      isScanning: _bleService.isScanning,
      isBroadcasting: _bleService.isBroadcasting,
    ),);
  }

  Future<void> _onCheckAvailability(
    CheckBluetoothAvailability event,
    Emitter<BleStatusState> emit,
  ) async {
    final available = await _bleService.isBluetoothAvailable();
    final enabled = await _bleService.isBluetoothEnabled();
    final hasPerms = await _bleService.hasPermissions();

    emit(state.copyWith(
      isBluetoothAvailable: available,
      isBluetoothEnabled: enabled,
      hasPermissions: hasPerms,
    ),);
  }

  void _onBatteryLevelChanged(
    BatteryLevelChanged event,
    Emitter<BleStatusState> emit,
  ) {
    emit(state.copyWith(batteryLevel: event.level));

    // Log warning for low battery
    if (event.level < 20) {
      Logger.warning(
        'BleStatusBloc: Low battery (${event.level}%), reducing scan frequency',
        'BLE',
      );
    }
  }

  @override
  Future<void> close() {
    _statusSubscription?.cancel();
    return super.close();
  }
}
