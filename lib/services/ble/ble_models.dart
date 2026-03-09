import 'dart:typed_data';

import 'package:equatable/equatable.dart';

/// BLE service status
enum BleStatus {
  /// Bluetooth is disabled on the device
  disabled,

  /// Required permissions not granted
  noPermission,

  /// Ready to scan/advertise
  ready,

  /// Actively scanning for peers
  scanning,

  /// Actively advertising our profile
  advertising,

  /// Both scanning and advertising
  active,

  /// Service error
  error,
}

/// Profile payload broadcast over BLE (written to fff1 + fff2 characteristics).
///
/// Only compact, ID-mapped fields are included in the BLE broadcast to keep
/// the payload small and avoid transmitting arbitrary free text over the mesh.
/// [bio] is carried for completeness but is intentionally omitted from the
/// JSON serialised to fff1; extended profile data is fetched on-demand via fff4.
///
/// [thumbnailBytes] is the primary photo thumbnail (≤30 KB JPEG), written to
/// fff2. It must pass NSFW detection before being set here.
class BroadcastPayload extends Equatable {
  const BroadcastPayload({
    required this.userId,
    required this.name,
    this.age,
    this.bio,
    this.position,
    this.interests,
    this.thumbnailBytes,
    this.thumbnailsList,
  });

  final String userId;
  final String name;
  final int? age;
  final String? bio;
  /// Position preference ID (see ProfileConstants.positionMap). null = not shared.
  final int? position;
  /// Comma-separated interest IDs (see ProfileConstants.encodeInterests). null = not shared.
  final String? interests;
  final Uint8List? thumbnailBytes;
  /// All profile photo thumbnails in display order (up to 4).
  /// When set, [thumbnailBytes] should be the first element.
  final List<Uint8List>? thumbnailsList;

  /// Serialize to bytes for BLE transmission
  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'name': name,
      'age': age,
      'bio': bio,
      if (position != null) 'position': position,
      if (interests != null && interests!.isNotEmpty) 'interests': interests,
      'thumbnailBytes': thumbnailBytes?.toList(),
    };
  }

  /// Deserialize from BLE transmission
  factory BroadcastPayload.fromJson(Map<String, dynamic> json) {
    return BroadcastPayload(
      userId: json['userId'] as String,
      name: json['name'] as String,
      age: json['age'] as int?,
      bio: json['bio'] as String?,
      position: json['position'] as int?,
      interests: json['interests'] as String?,
      thumbnailBytes: json['thumbnailBytes'] != null
          ? Uint8List.fromList(List<int>.from(json['thumbnailBytes']))
          : null,
    );
  }

  @override
  List<Object?> get props => [userId, name, age, bio, position, interests, thumbnailBytes, thumbnailsList];
}

/// A peer discovered via BLE scan and profile read (fff1 + fff2).
///
/// [isRelayed] is true when this peer was discovered through a mesh relay
/// node rather than a direct GATT connection. Relayed peers cannot receive
/// full photo transfers; only direct peers can.
///
/// [rssi] is the raw Received Signal Strength Indicator in dBm.
/// Negative values closer to 0 indicate a stronger signal (e.g. -40 dBm is
/// closer than -80 dBm). Used to sort the discovery grid by proximity.
class DiscoveredPeer extends Equatable {
  const DiscoveredPeer({
    required this.peerId,
    required this.name,
    this.age,
    this.bio,
    this.position,
    this.interests,
    this.thumbnailBytes,
    this.photoThumbnails,
    this.rssi,
    required this.timestamp,
    this.isRelayed = false,
    this.hopCount = 0,
    this.fullPhotoCount = 0,
  });

  final String peerId;
  final String name;
  final int? age;
  final String? bio;
  /// Position preference ID received from peer's profile. null = not shared.
  final int? position;
  /// Comma-separated interest IDs received from peer. null = not shared.
  final String? interests;
  final Uint8List? thumbnailBytes;
  /// All profile photo thumbnails in display order (up to 4).
  final List<Uint8List>? photoThumbnails;
  final int? rssi; // Signal strength
  final DateTime timestamp;
  /// True when this peer was discovered via mesh relay rather than direct BLE.
  final bool isRelayed;
  /// Number of relay hops from the origin device (0 = direct).
  final int hopCount;
  /// Total number of profile photos available from the peer via fff4.
  /// 0 = unknown, 1 = primary only, >1 = multiple photos available.
  final int fullPhotoCount;

  /// Estimated distance based on RSSI
  String? get distanceEstimate {
    if (rssi == null) return null;
    if (rssi! >= -50) return 'Very close';
    if (rssi! >= -60) return 'Nearby';
    if (rssi! >= -70) return 'In range';
    return 'Far away';
  }

  /// Signal quality description
  String? get signalQuality {
    if (rssi == null) return null;
    if (rssi! >= -50) return 'Excellent';
    if (rssi! >= -60) return 'Good';
    if (rssi! >= -70) return 'Fair';
    return 'Weak';
  }

  DiscoveredPeer copyWith({
    String? peerId,
    String? name,
    int? age,
    String? bio,
    int? position,
    String? interests,
    Uint8List? thumbnailBytes,
    List<Uint8List>? photoThumbnails,
    int? rssi,
    DateTime? timestamp,
    bool? isRelayed,
    int? hopCount,
    int? fullPhotoCount,
  }) {
    return DiscoveredPeer(
      peerId: peerId ?? this.peerId,
      name: name ?? this.name,
      age: age ?? this.age,
      bio: bio ?? this.bio,
      position: position ?? this.position,
      interests: interests ?? this.interests,
      thumbnailBytes: thumbnailBytes ?? this.thumbnailBytes,
      photoThumbnails: photoThumbnails ?? this.photoThumbnails,
      rssi: rssi ?? this.rssi,
      timestamp: timestamp ?? this.timestamp,
      isRelayed: isRelayed ?? this.isRelayed,
      hopCount: hopCount ?? this.hopCount,
      fullPhotoCount: fullPhotoCount ?? this.fullPhotoCount,
    );
  }

  @override
  List<Object?> get props => [
        peerId, name, age, bio, position, interests,
        thumbnailBytes, photoThumbnails,
        rssi, timestamp, isRelayed, hopCount, fullPhotoCount,
      ];
}

/// Message type for BLE transmission
enum MessageType {
  text,
  photo,
  typing,
  read,
  /// Small thumbnail + metadata sent before the receiver consents to the full photo.
  photoPreview,
  /// Receiver's consent request — triggers the sender to start the full transfer.
  photoRequest,
}

/// Payload for sending a message
class MessagePayload extends Equatable {
  const MessagePayload({
    required this.messageId,
    required this.type,
    required this.content,
  });

  final String messageId;
  final MessageType type;
  final String content; // Text content or photo metadata

  Map<String, dynamic> toJson() {
    return {
      'messageId': messageId,
      'type': type.name,
      'content': content,
    };
  }

  factory MessagePayload.fromJson(Map<String, dynamic> json) {
    return MessagePayload(
      messageId: json['messageId'] as String,
      type: MessageType.values.byName(json['type'] as String),
      content: json['content'] as String,
    );
  }

  @override
  List<Object?> get props => [messageId, type, content];
}

/// Received message from a peer
class ReceivedMessage extends Equatable {
  const ReceivedMessage({
    required this.fromPeerId,
    required this.messageId,
    required this.type,
    required this.content,
    required this.timestamp,
  });

  final String fromPeerId;
  final String messageId;
  final MessageType type;
  final String content;
  final DateTime timestamp;

  @override
  List<Object?> get props => [fromPeerId, messageId, type, content, timestamp];
}

/// Photo transfer status
enum PhotoTransferStatus {
  starting,
  inProgress,
  completed,
  failed,
  cancelled,
}

/// Progress of photo transfer
class PhotoTransferProgress extends Equatable {
  const PhotoTransferProgress({
    required this.messageId,
    required this.peerId,
    required this.progress,
    required this.status,
    this.errorMessage,
  });

  final String messageId;
  final String peerId;
  final double progress; // 0.0 to 1.0
  final PhotoTransferStatus status;
  final String? errorMessage;

  /// Progress percentage (0-100)
  int get progressPercent => (progress * 100).round();

  /// Whether transfer is complete
  bool get isComplete => status == PhotoTransferStatus.completed;

  /// Whether transfer failed
  bool get isFailed => status == PhotoTransferStatus.failed;

  PhotoTransferProgress copyWith({
    String? messageId,
    String? peerId,
    double? progress,
    PhotoTransferStatus? status,
    String? errorMessage,
  }) {
    return PhotoTransferProgress(
      messageId: messageId ?? this.messageId,
      peerId: peerId ?? this.peerId,
      progress: progress ?? this.progress,
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  @override
  List<Object?> get props => [messageId, peerId, progress, status, errorMessage];
}

/// Received photo from a peer
class ReceivedPhoto extends Equatable {
  const ReceivedPhoto({
    required this.fromPeerId,
    required this.messageId,
    required this.photoBytes,
    required this.timestamp,
  });

  final String fromPeerId;
  final String messageId;
  final Uint8List photoBytes;
  final DateTime timestamp;

  /// Photo size in bytes
  int get sizeInBytes => photoBytes.length;

  /// Photo size formatted
  String get formattedSize {
    if (sizeInBytes < 1024) return '$sizeInBytes B';
    if (sizeInBytes < 1024 * 1024) {
      return '${(sizeInBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeInBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  List<Object?> get props => [fromPeerId, messageId, photoBytes, timestamp];
}

/// BLE error types
enum BleErrorType {
  bluetoothDisabled,
  permissionDenied,
  connectionFailed,
  sendFailed,
  timeout,
  unknown,
}

/// Received anchor drop signal from a peer
class AnchorDropReceived extends Equatable {
  const AnchorDropReceived({
    required this.fromPeerId,
    required this.timestamp,
  });

  final String fromPeerId;
  final DateTime timestamp;

  @override
  List<Object?> get props => [fromPeerId, timestamp];
}

/// A photo preview received from a peer — thumbnail bytes + metadata.
/// Full photo is NOT included; receiver must send a [ReceivedPhotoRequest]
/// to trigger the actual transfer.
class ReceivedPhotoPreview extends Equatable {
  const ReceivedPhotoPreview({
    required this.fromPeerId,
    required this.messageId,
    required this.photoId,
    required this.thumbnailBytes,
    required this.originalSize,
    required this.timestamp,
  });

  final String fromPeerId;
  /// Message ID for this preview packet (stored in DB).
  final String messageId;
  /// UUID shared between preview and the subsequent full-photo transfer.
  final String photoId;
  final Uint8List thumbnailBytes;
  /// Original full-photo size in bytes (used for the "Photo (2.1 MB)" label).
  final int originalSize;
  final DateTime timestamp;

  /// Formatted original size string (e.g. "2.1 MB").
  String get formattedOriginalSize {
    if (originalSize < 1024) return '$originalSize B';
    if (originalSize < 1024 * 1024) {
      return '${(originalSize / 1024).toStringAsFixed(1)} KB';
    }
    return '${(originalSize / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  List<Object?> get props =>
      [fromPeerId, messageId, photoId, thumbnailBytes, originalSize, timestamp];
}

/// Consent message from receiver → sender: "please send me the full photo".
class ReceivedPhotoRequest extends Equatable {
  const ReceivedPhotoRequest({
    required this.fromPeerId,
    required this.messageId,
    required this.photoId,
    required this.timestamp,
  });

  final String fromPeerId;
  final String messageId;
  final String photoId;
  final DateTime timestamp;

  @override
  List<Object?> get props => [fromPeerId, messageId, photoId, timestamp];
}

/// BLE error
class BleError extends Equatable {
  const BleError({
    required this.type,
    required this.message,
    this.originalError,
  });

  final BleErrorType type;
  final String message;
  final Object? originalError;

  @override
  List<Object?> get props => [type, message, originalError];
}
