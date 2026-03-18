import 'dart:io';

import 'package:equatable/equatable.dart';

abstract class ProfileEvent extends Equatable {
  const ProfileEvent();

  @override
  List<Object?> get props => [];
}

/// Load the user's profile from database
class LoadProfile extends ProfileEvent {
  const LoadProfile();
}

/// Create a new profile
class CreateProfile extends ProfileEvent {
  const CreateProfile({
    required this.name,
    this.age,
    this.bio,
    this.position,
    this.interests = const [],
  });

  final String name;
  final int? age;
  final String? bio;
  /// Position preference ID (see ProfileConstants.positionMap). null = not set.
  final int? position;
  /// Selected interest IDs (see ProfileConstants.interestMap).
  final List<int> interests;

  @override
  List<Object?> get props => [name, age, bio, position, interests];
}

/// Update profile information
class UpdateProfile extends ProfileEvent {
  const UpdateProfile({
    this.name,
    this.age,
    this.bio,
    this.position,
    this.clearPosition = false,
    this.interests,
  });

  final String? name;
  final int? age;
  final String? bio;
  /// New position ID, or null to leave unchanged (use clearPosition to unset).
  final int? position;
  /// Set true to explicitly clear the position field to null.
  final bool clearPosition;
  /// New interests list, or null to leave unchanged. Pass [] to clear.
  final List<int>? interests;

  @override
  List<Object?> get props => [name, age, bio, position, clearPosition, interests];
}

/// Add a photo from file
class AddPhoto extends ProfileEvent {
  const AddPhoto(this.imageFile);
  final File imageFile;

  @override
  List<Object?> get props => [imageFile.path];
}

/// Remove a photo by ID
class RemovePhoto extends ProfileEvent {
  const RemovePhoto(this.photoId);
  final String photoId;

  @override
  List<Object?> get props => [photoId];
}

/// Reorder photos
class ReorderPhotos extends ProfileEvent {
  const ReorderPhotos(this.photoIds);
  final List<String> photoIds;

  @override
  List<Object?> get props => [photoIds];
}

/// Set a photo as primary
class SetPrimaryPhoto extends ProfileEvent {
  const SetPrimaryPhoto(this.photoId);
  final String photoId;

  @override
  List<Object?> get props => [photoId];
}

/// Pick photo from gallery
class PickPhotoFromGallery extends ProfileEvent {
  const PickPhotoFromGallery();
}

/// Pick photo from camera
class PickPhotoFromCamera extends ProfileEvent {
  const PickPhotoFromCamera();
}

/// Clear any error message
class ClearError extends ProfileEvent {
  const ClearError();
}

/// Broadcast profile via BLE
class BroadcastProfile extends ProfileEvent {
  const BroadcastProfile();
}

/// Dismiss the NSFW-blocked warning dialog and clear [ProfileState.nsfwBlockedPhotoId].
class DismissNsfwWarning extends ProfileEvent {
  const DismissNsfwWarning();
}

/// Debug-only: auto-create a complete profile with random data and a
/// placeholder photo so the developer can skip the 7-step setup flow.
class QuickSetupProfile extends ProfileEvent {
  const QuickSetupProfile();
}
