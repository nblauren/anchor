import 'dart:typed_data';

import 'ble_models.dart';

/// Abstract BLE service interface for peer-to-peer communication
/// Implemented by MockBleService (testing) and FlutterBluePlusBleService (production)
abstract class BleServiceInterface {
  // ==================== Lifecycle ====================

  /// Initialize the BLE service
  Future<void> initialize();

  /// Start the BLE service (scanning + advertising)
  Future<void> start();

  /// Stop the BLE service
  Future<void> stop();

  /// Dispose resources
  Future<void> dispose();

  // ==================== Status ====================

  /// Current BLE status
  BleStatus get status;

  /// Stream of BLE status changes
  Stream<BleStatus> get statusStream;

  /// Check if Bluetooth is available on this device
  Future<bool> isBluetoothAvailable();

  /// Check if Bluetooth is enabled
  Future<bool> isBluetoothEnabled();

  /// Request required permissions (location, Bluetooth, etc.)
  Future<bool> requestPermissions();

  /// Check if all required permissions are granted
  Future<bool> hasPermissions();

  // ==================== Broadcasting ====================

  /// Broadcast own profile to nearby devices
  Future<void> broadcastProfile(BroadcastPayload payload);

  /// Stop broadcasting profile
  Future<void> stopBroadcasting();

  /// Whether currently broadcasting
  bool get isBroadcasting;

  // ==================== Discovery ====================

  /// Stream of discovered peers
  Stream<DiscoveredPeer> get peerDiscoveredStream;

  /// Stream of lost peer IDs (not seen for a while)
  Stream<String> get peerLostStream;

  /// Start scanning for nearby peers
  Future<void> startScanning();

  /// Stop scanning
  Future<void> stopScanning();

  /// Whether currently scanning
  bool get isScanning;

  // ==================== Messaging ====================

  /// Send a message to a specific peer
  /// Returns true if message was queued successfully
  Future<bool> sendMessage(String peerId, MessagePayload payload);

  /// Stream of received messages
  Stream<ReceivedMessage> get messageReceivedStream;

  // ==================== Photo Transfer ====================

  /// Send a photo to a specific peer
  /// Returns true if transfer started successfully
  Future<bool> sendPhoto(String peerId, Uint8List photoData, String messageId);

  /// Stream of photo transfer progress updates
  Stream<PhotoTransferProgress> get photoProgressStream;

  /// Stream of received photos
  Stream<ReceivedPhoto> get photoReceivedStream;

  /// Cancel an ongoing photo transfer
  Future<void> cancelPhotoTransfer(String messageId);

  // ==================== Utilities ====================

  /// Get signal strength to a specific peer (if available)
  int? getSignalStrength(String peerId);

  /// Check if a peer is currently reachable
  bool isPeerReachable(String peerId);

  /// Get list of currently visible peer IDs
  List<String> get visiblePeerIds;
}
