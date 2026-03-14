import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

/// All per-peer BLE connection state consolidated in a single record.
///
/// Previously this state was scattered across 8+ separate maps in
/// [BleFacade]. Consolidating it here ensures that
/// cleanup on disconnect is atomic (remove one entry, not 16).
class PeerConnection {
  PeerConnection({
    required this.peerId,
    required this.peripheral,
    this.profileChar,
    this.thumbnailChar,
    this.messagingChar,
    this.fullPhotosChar,
    this.maxWriteLength = 182,
  }) : lastActivity = DateTime.now();

  final String peerId;
  final Peripheral peripheral;

  /// fff1 — profile metadata (READ)
  GATTCharacteristic? profileChar;

  /// fff2 — primary thumbnail (READ, NOTIFY)
  GATTCharacteristic? thumbnailChar;

  /// fff3 — messaging (WRITE, NOTIFY)
  GATTCharacteristic? messagingChar;

  /// fff4 — full photo set, on-demand (READ, NOTIFY)
  GATTCharacteristic? fullPhotosChar;

  /// Maximum safe write length negotiated for this connection.
  /// Defaults to iOS conservative minimum (ATT MTU 185 - 3 = 182).
  int maxWriteLength;

  /// Timestamp of last successful GATT interaction (for LRU eviction).
  DateTime lastActivity;

  /// Number of consecutive GATT connection failures.
  /// After 2 failures the peer is considered unreachable.
  int consecutiveFailures = 0;

  /// Whether this connection is currently alive.
  bool isConnected = true;

  /// Whether this peer has a usable messaging characteristic cached.
  bool get canSendMessages => isConnected && messagingChar != null;

  /// Update the LRU timestamp after a successful GATT interaction.
  void touch() => lastActivity = DateTime.now();

  /// Record a connection failure and return the new failure count.
  int recordFailure() => ++consecutiveFailures;

  /// Reset failure count after a successful connection.
  void resetFailures() => consecutiveFailures = 0;

  /// Mark the connection as dead and clear characteristic caches.
  void markDisconnected() {
    isConnected = false;
    profileChar = null;
    thumbnailChar = null;
    messagingChar = null;
    fullPhotosChar = null;
  }
}
