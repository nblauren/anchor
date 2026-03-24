import 'dart:typed_data';

import 'package:anchor/services/ble/ble_models.dart' as ble;

/// Abstract interface for Wi-Fi Aware peer-to-peer transport.
///
/// Wraps the `wifi_aware_p2p` plugin and maps its types to Anchor's existing
/// BLE model types so that consumers (blocs) don't need to know which
/// transport is active.
///
/// Implementations:
///   - [WifiAwareTransportServiceImpl] — production, uses wifi_aware_p2p.
///   - [MockWifiAwareTransportService] — test double.
abstract class WifiAwareTransportService {
  // ==================== Lifecycle ====================

  /// Initialize the service with the user's own ID and profile.
  Future<void> initialize({
    required String ownUserId,
    required ble.BroadcastPayload profile,
  });

  /// Start publishing and subscribing.
  Future<void> start();

  /// Stop publishing and subscribing.
  Future<void> stop();

  /// Dispose all resources.
  Future<void> dispose();

  // ==================== Status ====================

  /// Whether the device hardware supports Wi-Fi Aware.
  Future<bool> get isSupported;

  /// Whether Wi-Fi Aware is currently available (hardware + OS state).
  Future<bool> get isAvailable;

  /// Stream of availability changes (e.g. Wi-Fi toggled off).
  Stream<bool> get availabilityStream;

  // ==================== Discovery ====================

  /// Stream of discovered peers, mapped to Anchor's [ble.DiscoveredPeer].
  Stream<ble.DiscoveredPeer> get peerDiscoveredStream;

  /// Stream of lost peer IDs.
  Stream<String> get peerLostStream;

  // ==================== Profile ====================

  /// Update the published service info with new profile data.
  Future<void> updateProfile(ble.BroadcastPayload payload);

  // ==================== Messaging ====================

  /// Send a message to a peer. Returns true on success.
  Future<bool> sendMessage(String peerId, ble.MessagePayload payload);

  /// Stream of received messages.
  Stream<ble.ReceivedMessage> get messageReceivedStream;

  // ==================== Photo Transfer ====================

  /// Send a full photo to a peer via DataConnection. Returns true on success.
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

  // ==================== Pairing ====================

  /// Whether there are any paired Wi-Fi Aware devices (iOS only).
  /// On Android, always returns true (pairing not required).
  Future<bool> hasPairedDevices();

  /// Request pairing with a nearby device (iOS only).
  /// Presents the system DeviceDiscoveryUI sheet.
  /// Returns true if a device was paired successfully.
  Future<bool> requestPairing();

  // ==================== Utilities ====================

  /// Whether a peer is currently reachable.
  bool isPeerReachable(String peerId);

  /// Distance to a peer in millimetres (Wi-Fi Aware ranging), or null.
  int? getDistanceMm(String peerId);
}
