/// BLE service module for direct peer-to-peer communication
///
/// This module provides:
/// - [BleServiceInterface] - Abstract interface for BLE operations
/// - [MockBleService] - Mock implementation for testing
/// - [FlutterBluePlusBleService] - Production implementation using flutter_blue_plus
/// - [BleStatusBloc] - Bloc for tracking BLE status and permissions
/// - [BleConnectionBloc] - Bloc for managing BLE lifecycle
/// - [BleConfig] - Configuration for service selection
/// - [PhotoChunker] - Utilities for chunking photos for BLE transfer
/// - Data models for BLE communication
library;

export 'ble_config.dart';
export 'ble_connection_bloc.dart';
export 'ble_models.dart';
export 'ble_service_interface.dart';
export 'ble_status_bloc.dart' hide RequestBlePermissions;
export 'flutter_blue_plus_ble_service.dart';
export 'mock_ble_service.dart';
export 'photo_chunker.dart';
