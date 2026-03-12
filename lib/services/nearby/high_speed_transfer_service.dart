import 'dart:typed_data';

import 'nearby_models.dart';

/// Abstract interface for high-speed (Wi-Fi Direct) file transfer.
///
/// BLE handles discovery and text chat. This service activates only when a
/// large payload (photo/video) needs to move between two devices. It uses
/// Nearby Connections (Android) / Multipeer Connectivity (iOS) under the hood.
///
/// Implementations must:
///  - Advertise/discover only during an active transfer (battery-friendly).
///  - Emit progress updates via [transferProgressStream].
///  - Emit received payloads via [payloadReceivedStream].
///  - Clean up connections after each transfer or on [dispose].
abstract class HighSpeedTransferService {
  /// Initialize the service. Call once at app startup.
  Future<void> initialize({required String ownUserId});

  /// Whether the underlying platform supports Nearby / Wi-Fi Direct.
  Future<bool> get isAvailable;

  /// Send [data] to [peerId] over Wi-Fi Direct.
  ///
  /// [transferId] links this transfer to a photo/message ID.
  /// [peerId] is the BLE peer ID of the target device.
  /// Returns `true` if the transfer completed successfully.
  /// Returns `false` on timeout or failure (caller should fall back to BLE).
  Future<bool> sendPayload({
    required String transferId,
    required String peerId,
    required Uint8List data,
    Duration timeout = const Duration(seconds: 15),
  });

  /// Begin listening for an incoming payload identified by [transferId].
  ///
  /// The sender must call [sendPayload] with the same [transferId].
  /// Returns `true` when the payload is fully received (available on
  /// [payloadReceivedStream]).
  Future<bool> receivePayload({
    required String transferId,
    required String peerId,
    Duration timeout = const Duration(seconds: 15),
  });

  /// Cancel an in-progress transfer.
  Future<void> cancelTransfer(String transferId);

  /// Stream of progress updates for active transfers.
  Stream<NearbyTransferProgress> get transferProgressStream;

  /// Stream of completed payloads received from peers.
  Stream<NearbyPayloadReceived> get payloadReceivedStream;

  /// Tear down: disconnect all peers, stop advertising/browsing, close streams.
  Future<void> dispose();
}
