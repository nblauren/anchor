import 'dart:typed_data';

import 'package:equatable/equatable.dart';

/// Transport used for a file transfer.
enum TransferTransport {
  /// High-speed Wi-Fi Direct / Nearby Connections transfer.
  wifi,

  /// Fallback: chunked BLE transfer.
  ble,
}

/// Status of a Nearby Connections transfer.
enum NearbyTransferStatus {
  /// Searching for the peer via Nearby.
  discovering,

  /// Nearby connection established, transfer starting.
  connecting,

  /// Bytes in flight.
  transferring,

  /// Transfer complete, file written.
  completed,

  /// Transfer failed or timed out — caller should fall back to BLE.
  failed,

  /// Transfer was cancelled by user.
  cancelled,
}

/// Progress update emitted during a Nearby transfer.
class NearbyTransferProgress extends Equatable {
  const NearbyTransferProgress({
    required this.transferId,
    required this.peerId,
    required this.status,
    required this.progress,
    this.errorMessage,
  });

  /// Unique ID for this transfer (typically the photoId).
  final String transferId;

  /// BLE peerId of the remote device.
  final String peerId;

  /// Current status.
  final NearbyTransferStatus status;

  /// 0.0 – 1.0 progress fraction.
  final double progress;

  /// Human-readable error when [status] == [NearbyTransferStatus.failed].
  final String? errorMessage;

  int get progressPercent => (progress * 100).round();
  bool get isComplete => status == NearbyTransferStatus.completed;
  bool get isFailed => status == NearbyTransferStatus.failed;

  NearbyTransferProgress copyWith({
    String? transferId,
    String? peerId,
    NearbyTransferStatus? status,
    double? progress,
    String? errorMessage,
  }) {
    return NearbyTransferProgress(
      transferId: transferId ?? this.transferId,
      peerId: peerId ?? this.peerId,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  @override
  List<Object?> get props => [transferId, peerId, status, progress, errorMessage];
}

/// A completed payload received from a nearby peer.
class NearbyPayloadReceived extends Equatable {
  const NearbyPayloadReceived({
    required this.transferId,
    required this.fromPeerId,
    required this.data,
    required this.timestamp,
  });

  /// Transfer / photo ID.
  final String transferId;

  /// Sender's BLE peerId.
  final String fromPeerId;

  /// Raw file bytes.
  final Uint8List data;

  final DateTime timestamp;

  int get sizeInBytes => data.length;

  @override
  List<Object?> get props => [transferId, fromPeerId, data, timestamp];
}
