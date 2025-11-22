import 'package:equatable/equatable.dart';

import '../../../data/models/user_profile.dart';

enum ProfileStatus {
  initial,
  loading,
  loaded,
  saving,
  saved,
  error,
  noProfile,
}

class ProfileState extends Equatable {
  const ProfileState({
    this.status = ProfileStatus.initial,
    this.profile,
    this.errorMessage,
    this.hasUnsavedChanges = false,
  });

  final ProfileStatus status;
  final UserProfile? profile;
  final String? errorMessage;
  final bool hasUnsavedChanges;

  /// Whether the profile setup is complete
  bool get isProfileComplete =>
      profile != null &&
      profile!.name.isNotEmpty &&
      profile!.age >= 18 &&
      profile!.photoUrls.isNotEmpty;

  ProfileState copyWith({
    ProfileStatus? status,
    UserProfile? profile,
    String? errorMessage,
    bool? hasUnsavedChanges,
  }) {
    return ProfileState(
      status: status ?? this.status,
      profile: profile ?? this.profile,
      errorMessage: errorMessage,
      hasUnsavedChanges: hasUnsavedChanges ?? this.hasUnsavedChanges,
    );
  }

  @override
  List<Object?> get props => [status, profile, errorMessage, hasUnsavedChanges];
}
