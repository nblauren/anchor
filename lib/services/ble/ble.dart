/// BLE service module for mesh networking
///
/// This module provides:
/// - [BleServiceInterface] - Abstract interface for BLE operations
/// - [MockBleService] - Mock implementation for testing
/// - [BridgefyBleService] - Production implementation using Bridgefy SDK
/// - [BleStatusBloc] - Bloc for tracking BLE status and permissions
/// - [BleConnectionBloc] - Bloc for managing BLE lifecycle
/// - [BleConfig] - Configuration for service selection
/// - [PhotoChunker] - Utilities for chunking photos for BLE transfer
/// - Data models for BLE communication

export 'ble_config.dart';
export 'ble_connection_bloc.dart';
export 'ble_models.dart';
export 'ble_service_interface.dart';
export 'ble_status_bloc.dart';
export 'bridgefy_ble_service.dart';
export 'mock_ble_service.dart';
export 'photo_chunker.dart';
