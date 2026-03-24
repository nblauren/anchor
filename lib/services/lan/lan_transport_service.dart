import 'dart:typed_data';

import 'package:anchor/services/ble/ble_models.dart' as ble;

/// Abstract interface for LAN (ship Wi-Fi local network) peer-to-peer transport.
///
/// Uses pure `dart:io` sockets — no additional packages required.
/// LAN is the highest-priority transport when the device has any non-loopback
/// IPv4 interface (i.e. is on a local network). It covers ship-wide reach,
/// uses UDP broadcast for zero-config discovery, and TCP for reliable delivery.
///
/// Implementations:
///   - [LanTransportServiceImpl] — production, uses dart:io sockets.
///   - [MockLanTransportService] — test double.
abstract class LanTransportService {
  // ==================== Lifecycle ====================

  /// Initialize the service with the user's own ID and profile.
  /// Does NOT open sockets — call [start] for that.
  Future<void> initialize({
    required String ownUserId,
    required ble.BroadcastPayload profile,
  });

  /// Open UDP/TCP sockets and start broadcasting beacons.
  Future<void> start();

  /// Stop broadcasting, close sockets, and emit peerLost for all known peers.
  Future<void> stop();

  /// Dispose all resources including stream controllers.
  Future<void> dispose();

  // ==================== Status ====================

  /// Whether the device currently has a non-loopback IPv4 interface.
  Future<bool> get isAvailable;

  /// Stream of availability changes (e.g. Wi-Fi disconnected mid-session).
  Stream<bool> get availabilityStream;

  // ==================== Discovery ====================

  /// Stream of discovered peers on the LAN.
  Stream<ble.DiscoveredPeer> get peerDiscoveredStream;

  /// Stream of lost peer IDs (peer timed out or service stopped).
  Stream<String> get peerLostStream;

  // ==================== Profile ====================

  /// Update the published profile. The next beacon will carry the new data.
  Future<void> updateProfile(ble.BroadcastPayload payload);

  // ==================== Messaging ====================

  /// Send a chat message to a peer. Returns true on success.
  Future<bool> sendMessage(String peerId, ble.MessagePayload payload);

  /// Stream of received chat messages.
  Stream<ble.ReceivedMessage> get messageReceivedStream;

  // ==================== Photo Transfer ====================

  /// Send a full photo to a peer over TCP. Returns true on success.
  Future<bool> sendPhoto(
    String peerId,
    Uint8List photoData,
    String messageId, {
    String? photoId,
  });

  /// Stream of photo transfer progress updates.
  Stream<ble.PhotoTransferProgress> get photoProgressStream;

  /// Stream of fully received photos.
  Stream<ble.ReceivedPhoto> get photoReceivedStream;

  // ==================== Photo Consent Flow ====================

  /// Send a photo preview (thumbnail + metadata) to a peer.
  Future<bool> sendPhotoPreview({
    required String peerId,
    required String messageId,
    required String photoId,
    required Uint8List thumbnailBytes,
    required int originalSize,
  });

  /// Send a photo request (consent) to a peer.
  Future<bool> sendPhotoRequest({
    required String peerId,
    required String messageId,
    required String photoId,
  });

  /// Stream of received photo previews.
  Stream<ble.ReceivedPhotoPreview> get photoPreviewReceivedStream;

  /// Stream of received photo requests.
  Stream<ble.ReceivedPhotoRequest> get photoRequestReceivedStream;

  // ==================== Anchor Drops ====================

  /// Send a drop anchor signal to a peer.
  Future<bool> sendDropAnchor(String peerId);

  /// Stream of received anchor drop signals.
  Stream<ble.AnchorDropReceived> get anchorDropReceivedStream;

  // ==================== Reactions ====================

  /// Send an emoji reaction for a specific message to a peer.
  /// [action] is either "add" or "remove".
  Future<bool> sendReaction({
    required String peerId,
    required String messageId,
    required String emoji,
    required String action,
  });

  /// Stream of received emoji reactions.
  Stream<ble.ReactionReceived> get reactionReceivedStream;

  // ==================== Noise_XK Handshake ====================

  /// Send an outbound Noise_XK handshake step to a LAN peer.
  Future<bool> sendHandshakeMessage(String peerId, int step, Uint8List payload);

  /// Stream of incoming Noise_XK handshake frames received via LAN TCP.
  /// TransportManager subscribes to this and routes to EncryptionService.
  Stream<ble.NoiseHandshakeReceived> get noiseHandshakeStream;

  // ==================== Raw Binary ====================

  /// Send raw binary bytes to a peer (used by gossip sync and other
  /// binary-only protocols that bypass the message codec).
  Future<bool> sendRawBytes(String peerId, Uint8List data);

  // ==================== Utilities ====================

  /// Whether a peer is currently reachable (i.e. has been seen recently).
  bool isPeerReachable(String peerId);
}
