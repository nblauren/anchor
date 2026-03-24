import 'package:anchor/core/constants/profile_constants.dart';
import 'package:anchor/data/local_database/database.dart';
import 'package:equatable/equatable.dart';

enum ProfileStatus {
  initial,
  loading,
  loaded,
  saving,
  saved,
  error,
  noProfile,
}

/// Represents a photo in the profile
class ProfilePhoto extends Equatable {
  const ProfilePhoto({
    required this.id,
    required this.photoPath,
    required this.thumbnailPath,
    required this.isPrimary,
    required this.orderIndex,
  });

  final String id;
  final String photoPath;
  final String thumbnailPath;
  final bool isPrimary;
  final int orderIndex;

  factory ProfilePhoto.fromEntry(UserPhotoEntry entry) {
    return ProfilePhoto(
      id: entry.id,
      photoPath: entry.photoPath,
      thumbnailPath: entry.thumbnailPath,
      isPrimary: entry.isPrimary,
      orderIndex: entry.orderIndex,
    );
  }

  @override
  List<Object?> get props => [id, photoPath, thumbnailPath, isPrimary, orderIndex];
}

class ProfileState extends Equatable {
  const ProfileState({
    this.status = ProfileStatus.initial,
    this.profileId,
    this.name,
    this.age,
    this.bio,
    this.position,
    this.interestIds = const [],
    this.photos = const [],
    this.errorMessage,
    this.isProcessingPhoto = false,
    this.nsfwBlockedPhotoId,
  });

  final ProfileStatus status;
  final String? profileId;
  final String? name;
  final int? age;
  final String? bio;
  /// Position preference ID. null = not set.
  final int? position;
  /// Selected interest IDs (sorted). Empty = none set.
  final List<int> interestIds;
  final List<ProfilePhoto> photos;
  final String? errorMessage;
  final bool isProcessingPhoto;
  /// Non-null when a photo failed the sensitive-content check.
  final String? nsfwBlockedPhotoId;

  /// Human-readable position label, or null when not set.
  String? get positionLabel => ProfileConstants.positionLabel(position);

  /// Human-readable interest labels (decoded from IDs).
  List<String> get interestLabels =>
      interestIds.map((id) => ProfileConstants.interestMap[id] ?? '').where((s) => s.isNotEmpty).toList();

  /// Whether a profile exists
  bool get hasProfile => profileId != null;

  /// Whether the profile is valid for creation/saving
  bool get isValid => name != null && name!.trim().isNotEmpty;

  /// Whether the profile has at least one photo
  bool get hasPhotos => photos.isNotEmpty;

  /// Get the primary photo
  ProfilePhoto? get primaryPhoto {
    try {
      return photos.firstWhere((p) => p.isPrimary);
    } catch (_) {
      return photos.isNotEmpty ? photos.first : null;
    }
  }

  /// Get sorted photos by order index
  List<ProfilePhoto> get sortedPhotos {
    final sorted = List<ProfilePhoto>.from(photos)
      ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    return sorted;
  }

  /// Maximum photos allowed
  static const int maxPhotos = 4;

  /// Whether more photos can be added
  bool get canAddMorePhotos => photos.length < maxPhotos;

  ProfileState copyWith({
    ProfileStatus? status,
    String? profileId,
    String? name,
    int? age,
    String? bio,
    // Use Object? sentinel to allow explicitly setting position to null.
    Object? position = _sentinel,
    List<int>? interestIds,
    List<ProfilePhoto>? photos,
    String? errorMessage,
    bool? isProcessingPhoto,
    String? nsfwBlockedPhotoId,
    bool clearNsfwBlock = false,
  }) {
    return ProfileState(
      status: status ?? this.status,
      profileId: profileId ?? this.profileId,
      name: name ?? this.name,
      age: age ?? this.age,
      bio: bio ?? this.bio,
      position: position == _sentinel ? this.position : position as int?,
      interestIds: interestIds ?? this.interestIds,
      photos: photos ?? this.photos,
      errorMessage: errorMessage,
      isProcessingPhoto: isProcessingPhoto ?? this.isProcessingPhoto,
      nsfwBlockedPhotoId:
          clearNsfwBlock ? null : (nsfwBlockedPhotoId ?? this.nsfwBlockedPhotoId),
    );
  }

  @override
  List<Object?> get props => [
        status,
        profileId,
        name,
        age,
        bio,
        position,
        interestIds,
        photos,
        errorMessage,
        isProcessingPhoto,
        nsfwBlockedPhotoId,
      ];
}

/// Sentinel value for copyWith to distinguish "not provided" from explicit null.
const _sentinel = Object();
