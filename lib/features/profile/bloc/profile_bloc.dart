import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../core/utils/logger.dart';
import '../../../data/models/user_profile.dart';
import '../../../services/database_service.dart';
import '../../../services/image_service.dart';
import 'profile_event.dart';
import 'profile_state.dart';

class ProfileBloc extends Bloc<ProfileEvent, ProfileState> {
  ProfileBloc({
    required DatabaseService databaseService,
    required ImageService imageService,
  })  : _databaseService = databaseService,
        _imageService = imageService,
        super(const ProfileState()) {
    on<LoadProfile>(_onLoadProfile);
    on<UpdateName>(_onUpdateName);
    on<UpdateAge>(_onUpdateAge);
    on<UpdateBio>(_onUpdateBio);
    on<AddPhoto>(_onAddPhoto);
    on<RemovePhoto>(_onRemovePhoto);
    on<UpdateInterests>(_onUpdateInterests);
    on<SaveProfile>(_onSaveProfile);
    on<CreateProfile>(_onCreateProfile);
  }

  final DatabaseService _databaseService;
  final ImageService _imageService;
  final _uuid = const Uuid();

  Future<void> _onLoadProfile(
    LoadProfile event,
    Emitter<ProfileState> emit,
  ) async {
    emit(state.copyWith(status: ProfileStatus.loading));

    try {
      final profile = await _databaseService.profileRepository.getOwnProfile();

      if (profile == null) {
        emit(state.copyWith(status: ProfileStatus.noProfile));
      } else {
        emit(state.copyWith(
          status: ProfileStatus.loaded,
          profile: profile,
        ));
      }
    } catch (e) {
      Logger.error('Failed to load profile', e, null, 'ProfileBloc');
      emit(state.copyWith(
        status: ProfileStatus.error,
        errorMessage: 'Failed to load profile',
      ));
    }
  }

  Future<void> _onUpdateName(
    UpdateName event,
    Emitter<ProfileState> emit,
  ) async {
    if (state.profile == null) return;

    final updatedProfile = state.profile!.copyWith(
      name: event.name,
      updatedAt: DateTime.now(),
    );

    emit(state.copyWith(
      profile: updatedProfile,
      hasUnsavedChanges: true,
    ));
  }

  Future<void> _onUpdateAge(
    UpdateAge event,
    Emitter<ProfileState> emit,
  ) async {
    if (state.profile == null) return;

    final updatedProfile = state.profile!.copyWith(
      age: event.age,
      updatedAt: DateTime.now(),
    );

    emit(state.copyWith(
      profile: updatedProfile,
      hasUnsavedChanges: true,
    ));
  }

  Future<void> _onUpdateBio(
    UpdateBio event,
    Emitter<ProfileState> emit,
  ) async {
    if (state.profile == null) return;

    final updatedProfile = state.profile!.copyWith(
      bio: event.bio,
      updatedAt: DateTime.now(),
    );

    emit(state.copyWith(
      profile: updatedProfile,
      hasUnsavedChanges: true,
    ));
  }

  Future<void> _onAddPhoto(
    AddPhoto event,
    Emitter<ProfileState> emit,
  ) async {
    if (state.profile == null) return;

    try {
      // Compress and save the photo
      final compressed = await _imageService.compressImage(event.photoFile);
      final savedPath = await _imageService.saveImageToLocal(compressed);

      final updatedPhotos = [...state.profile!.photoUrls, savedPath];
      final updatedProfile = state.profile!.copyWith(
        photoUrls: updatedPhotos,
        updatedAt: DateTime.now(),
      );

      emit(state.copyWith(
        profile: updatedProfile,
        hasUnsavedChanges: true,
      ));
    } catch (e) {
      Logger.error('Failed to add photo', e, null, 'ProfileBloc');
      emit(state.copyWith(
        errorMessage: 'Failed to add photo',
      ));
    }
  }

  Future<void> _onRemovePhoto(
    RemovePhoto event,
    Emitter<ProfileState> emit,
  ) async {
    if (state.profile == null) return;

    try {
      final photoToRemove = state.profile!.photoUrls[event.photoIndex];
      await _imageService.deleteImage(photoToRemove);

      final updatedPhotos = [...state.profile!.photoUrls]
        ..removeAt(event.photoIndex);
      final updatedProfile = state.profile!.copyWith(
        photoUrls: updatedPhotos,
        updatedAt: DateTime.now(),
      );

      emit(state.copyWith(
        profile: updatedProfile,
        hasUnsavedChanges: true,
      ));
    } catch (e) {
      Logger.error('Failed to remove photo', e, null, 'ProfileBloc');
      emit(state.copyWith(
        errorMessage: 'Failed to remove photo',
      ));
    }
  }

  Future<void> _onUpdateInterests(
    UpdateInterests event,
    Emitter<ProfileState> emit,
  ) async {
    if (state.profile == null) return;

    final updatedProfile = state.profile!.copyWith(
      interests: event.interests,
      updatedAt: DateTime.now(),
    );

    emit(state.copyWith(
      profile: updatedProfile,
      hasUnsavedChanges: true,
    ));
  }

  Future<void> _onSaveProfile(
    SaveProfile event,
    Emitter<ProfileState> emit,
  ) async {
    if (state.profile == null) return;

    emit(state.copyWith(status: ProfileStatus.saving));

    try {
      await _databaseService.profileRepository.saveOwnProfile(state.profile!);
      emit(state.copyWith(
        status: ProfileStatus.saved,
        hasUnsavedChanges: false,
      ));
    } catch (e) {
      Logger.error('Failed to save profile', e, null, 'ProfileBloc');
      emit(state.copyWith(
        status: ProfileStatus.error,
        errorMessage: 'Failed to save profile',
      ));
    }
  }

  Future<void> _onCreateProfile(
    CreateProfile event,
    Emitter<ProfileState> emit,
  ) async {
    emit(state.copyWith(status: ProfileStatus.saving));

    try {
      // Save photos
      final photoUrls = <String>[];
      for (final photoFile in event.photoFiles) {
        final compressed = await _imageService.compressImage(photoFile);
        final savedPath = await _imageService.saveImageToLocal(compressed);
        photoUrls.add(savedPath);
      }

      // Create profile
      final now = DateTime.now();
      final profile = UserProfile(
        id: _uuid.v4(),
        name: event.name,
        age: event.age,
        bio: event.bio,
        photoUrls: photoUrls,
        interests: event.interests,
        createdAt: now,
        updatedAt: now,
        isOwnProfile: true,
      );

      await _databaseService.profileRepository.saveOwnProfile(profile);

      emit(state.copyWith(
        status: ProfileStatus.saved,
        profile: profile,
        hasUnsavedChanges: false,
      ));
    } catch (e) {
      Logger.error('Failed to create profile', e, null, 'ProfileBloc');
      emit(state.copyWith(
        status: ProfileStatus.error,
        errorMessage: 'Failed to create profile',
      ));
    }
  }
}
