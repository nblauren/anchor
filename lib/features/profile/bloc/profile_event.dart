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
  });

  final String name;
  final int? age;
  final String? bio;

  @override
  List<Object?> get props => [name, age, bio];
}

/// Update profile information
class UpdateProfile extends ProfileEvent {
  const UpdateProfile({
    this.name,
    this.age,
    this.bio,
  });

  final String? name;
  final int? age;
  final String? bio;

  @override
  List<Object?> get props => [name, age, bio];
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
