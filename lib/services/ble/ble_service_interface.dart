import 'dart:typed_data';

import 'ble_models.dart';

/// Abstract BLE service interface for offline peer-to-peer communication.
///
/// Implemented by:
///   - [BleFacade] — production, uses the `bluetooth_low_energy`
///     package (central + peripheral in one API, supports both iOS and Android).
///   - [MockBleService] — test double for unit/widget tests without hardware.
///
/// The production service runs [CentralManager] (scan/connect) and
/// [PeripheralManager] (GATT server/advertise) simultaneously, enabling true
/// two-way peer discovery without a central coordinator.
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

  /// Stream of peer IDs that have not been seen for [BleConfig.peerLostTimeout]
  /// (default 2 minutes). The UI should mark these peers as out-of-range.
  Stream<String> get peerLostStream;

  /// Emitted when a known userId appears under a new BLE peripheral UUID
  /// (MAC address rotation). Consumers should migrate conversations and
  /// other data from oldPeerId to newPeerId.
  Stream<PeerIdChanged> get peerIdChangedStream;

  /// Start scanning for nearby peers
  Future<void> startScanning();

  /// Stop scanning
  Future<void> stopScanning();

  /// Whether currently scanning
  bool get isScanning;

  // ==================== Messaging ====================

  /// Send a message to a specific peer.
  ///
  /// Writes a JSON-encoded [MessagePayload] to the fff3 GATT characteristic.
  /// Returns true if the write was acknowledged. There is no store-and-forward
  /// in v1: if the peer is out of range the message is not queued.
  Future<bool> sendMessage(String peerId, MessagePayload payload);

  /// Stream of received messages
  Stream<ReceivedMessage> get messageReceivedStream;

  // ==================== Photo Transfer ====================

  /// Send a photo to a specific peer
  /// Returns true if transfer started successfully
  Future<bool> sendPhoto(String peerId, Uint8List photoData, String messageId, {String? photoId});

  /// Send a photo preview (thumbnail + metadata) to a peer.
  ///
  /// Phase 1 of the consent-based photo flow.  The receiver sees a small
  /// thumbnail and chooses whether to download the full image.
  ///
  /// [photoId] is a UUID that links this preview to the subsequent
  /// full-photo transfer triggered by [sendPhotoRequest].
  /// [thumbnailBytes] must be a compressed JPEG ≤ 15 KB.
  /// [originalSize] is the size of the BLE-compressed photo in bytes.
  Future<bool> sendPhotoPreview({
    required String peerId,
    required String messageId,
    required String photoId,
    required Uint8List thumbnailBytes,
    required int originalSize,
  });

  /// Send a photo-request ("consent") message from receiver to sender.
  ///
  /// Phase 2 of the consent-based photo flow.  The sender will respond by
  /// starting the full binary photo transfer via [sendPhoto].
  Future<bool> sendPhotoRequest({
    required String peerId,
    required String messageId,
    required String photoId,
  });

  /// Stream of received photo previews (thumbnail + metadata).
  Stream<ReceivedPhotoPreview> get photoPreviewReceivedStream;

  /// Stream of received photo-requests (consent grants from receivers).
  Stream<ReceivedPhotoRequest> get photoRequestReceivedStream;

  /// Fetch all full-size profile photo thumbnails from a peer on demand.
  ///
  /// Only works when the peer is in direct BLE range (connected via GATT).
  /// Returns true if the request was queued; photos arrive asynchronously
  /// via [peerDiscoveredStream] as an updated [DiscoveredPeer] with
  /// [DiscoveredPeer.photoThumbnails] populated.
  /// Returns false if the peer is unreachable or has no extra photos.
  Future<bool> fetchFullProfilePhotos(String peerId);

  /// Stream of photo transfer progress updates
  Stream<PhotoTransferProgress> get photoProgressStream;

  /// Stream of received photos
  Stream<ReceivedPhoto> get photoReceivedStream;

  /// Cancel an ongoing photo transfer
  Future<void> cancelPhotoTransfer(String messageId);

  // ==================== Utilities ====================

  /// Enable or disable battery saver mode (reduces scan frequency)
  Future<void> setBatterySaverMode(bool enabled);

  /// Get signal strength to a specific peer (if available)
  int? getSignalStrength(String peerId);

  /// Check if a peer is currently reachable
  bool isPeerReachable(String peerId);

  /// Resolve the BLE peripheral UUID for a given app-level userId, or null
  /// if the mapping hasn't been established yet (peer not yet scanned).
  String? getPeerIdForUserId(String userId);

  /// Get list of currently visible peer IDs
  List<String> get visiblePeerIds;

  // ==================== Drop Anchor ====================

  /// Send a "Drop Anchor" ⚓ signal to a specific peer — a tiny BLE ping
  /// with no heavy payload. Returns true if the signal was sent successfully.
  Future<bool> sendDropAnchor(String peerId);

  /// Stream of received anchor drop signals from peers
  Stream<AnchorDropReceived> get anchorDropReceivedStream;

  // ==================== Reactions ====================

  /// Send an emoji reaction for a specific message to a peer.
  /// [action] is either "add" or "remove".
  /// Returns true if the signal was sent successfully.
  Future<bool> sendReaction({
    required String peerId,
    required String messageId,
    required String emoji,
    required String action,
  });

  /// Stream of received emoji reactions from peers.
  Stream<ReactionReceived> get reactionReceivedStream;

  // ==================== Noise_XK Handshake ====================

  /// Send an outbound Noise_XK handshake step to a BLE peer.
  /// [peerId] must be the BLE peripheral UUID (not a LAN UUID).
  Future<void> sendHandshakeMessage(String peerId, int step, Uint8List payload);

  /// Stream of incoming Noise_XK handshake frames received from BLE peers.
  /// TransportManager subscribes to this and routes to EncryptionService.
  Stream<NoiseHandshakeReceived> get noiseHandshakeStream;

  /// Resolve a BLE Central UUID to the corresponding Peripheral UUID.
  ///
  /// **Deprecated**: With the userId-based canonical identity model, peer IDs
  /// are stable app-level userIds. This method is retained for interface
  /// compatibility but implementations may simply return null.
  ///
  /// On iOS/macOS the Central and Peripheral UUIDs historically differed for
  /// the same device. Returns null if the mapping is unknown or not applicable.
  String? resolveToPeripheralId(String peerId);

  // ==================== Raw Binary ====================

  /// Send raw binary bytes to a peer (used by gossip sync and other
  /// binary-only protocols that bypass the message codec).
  Future<bool> sendRawBytes(String peerId, Uint8List data);

  // ==================== Mesh ====================

  /// Enable or disable mesh relay (message forwarding between devices)
  Future<void> setMeshRelayMode(bool enabled);

  /// Whether mesh relay is currently enabled
  bool get isMeshRelayEnabled;

  /// Number of peers currently visible only via mesh relay (not direct BLE)
  int get meshRelayedPeerCount;

  /// Number of peers whose neighbor lists are known (routing table size)
  int get meshRoutingTableSize;

  /// Temporarily suppress outgoing mesh relay writes and flush any pending
  /// mesh writes from the GATT queue. Used before critical BLE signals
  /// (e.g. wifiTransferReady) to prevent iOS prepare queue saturation.
  void suppressMeshRelay();

  /// Resume outgoing mesh relay writes after [suppressMeshRelay].
  void resumeMeshRelay();

  // ==================== Block List ====================

  /// Update the set of blocked peer IDs for transport-layer filtering.
  ///
  /// Messages from blocked peers are rejected at the BLE transport layer
  /// before consuming queue space or processing time.  Call this whenever
  /// the block list changes (block/unblock events).
  void updateBlockedPeerIds(Set<String> blockedIds);
}
