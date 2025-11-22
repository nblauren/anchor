import 'dart:io';

import 'package:equatable/equatable.dart';

abstract class ProfileEvent extends Equatable {
  const ProfileEvent();

  @override
  List<Object?> get props => [];
}

/// Load the user's profile
class LoadProfile extends ProfileEvent {
  const LoadProfile();
}

/// Update profile name
class UpdateName extends ProfileEvent {
  const UpdateName(this.name);
  final String name;

  @override
  List<Object?> get props => [name];
}

/// Update profile age
class UpdateAge extends ProfileEvent {
  const UpdateAge(this.age);
  final int age;

  @override
  List<Object?> get props => [age];
}

/// Update profile bio
class UpdateBio extends ProfileEvent {
  const UpdateBio(this.bio);
  final String bio;

  @override
  List<Object?> get props => [bio];
}

/// Add a photo to profile
class AddPhoto extends ProfileEvent {
  const AddPhoto(this.photoFile);
  final File photoFile;

  @override
  List<Object?> get props => [photoFile];
}

/// Remove a photo from profile
class RemovePhoto extends ProfileEvent {
  const RemovePhoto(this.photoIndex);
  final int photoIndex;

  @override
  List<Object?> get props => [photoIndex];
}

/// Update interests
class UpdateInterests extends ProfileEvent {
  const UpdateInterests(this.interests);
  final List<String> interests;

  @override
  List<Object?> get props => [interests];
}

/// Save the profile
class SaveProfile extends ProfileEvent {
  const SaveProfile();
}

/// Create initial profile during setup
class CreateProfile extends ProfileEvent {
  const CreateProfile({
    required this.name,
    required this.age,
    this.bio,
    this.photoFiles = const [],
    this.interests = const [],
  });

  final String name;
  final int age;
  final String? bio;
  final List<File> photoFiles;
  final List<String> interests;

  @override
  List<Object?> get props => [name, age, bio, photoFiles, interests];
}
