import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/utils/logger.dart';
import '../../../services/ble/ble.dart' as ble;
import '../../../services/database_service.dart';
import '../../../services/image_service.dart';
import 'profile_event.dart';
import 'profile_state.dart';

class ProfileBloc extends Bloc<ProfileEvent, ProfileState> {
  ProfileBloc({
    required DatabaseService databaseService,
    required ImageService imageService,
    required ble.BleServiceInterface bleService,
  })  : _databaseService = databaseService,
        _imageService = imageService,
        _bleService = bleService,
        super(const ProfileState()) {
    on<LoadProfile>(_onLoadProfile);
    on<CreateProfile>(_onCreateProfile);
    on<UpdateProfile>(_onUpdateProfile);
    on<AddPhoto>(_onAddPhoto);
    on<RemovePhoto>(_onRemovePhoto);
    on<ReorderPhotos>(_onReorderPhotos);
    on<SetPrimaryPhoto>(_onSetPrimaryPhoto);
    on<PickPhotoFromGallery>(_onPickPhotoFromGallery);
    on<PickPhotoFromCamera>(_onPickPhotoFromCamera);
    on<BroadcastProfile>(_onBroadcastProfile);
    on<ClearError>(_onClearError);
  }

  final DatabaseService _databaseService;
  final ImageService _imageService;
  final ble.BleServiceInterface _bleService;

  Future<void> _onLoadProfile(
    LoadProfile event,
    Emitter<ProfileState> emit,
  ) async {
    emit(state.copyWith(status: ProfileStatus.loading));

    try {
      final profile = await _databaseService.profileRepository.getProfile();

      if (profile == null) {
        emit(state.copyWith(status: ProfileStatus.noProfile));
        return;
      }

      final photos = await _databaseService.profileRepository.getPhotos(profile.id);
      final photoList = photos.map((p) => ProfilePhoto.fromEntry(p)).toList();

      emit(state.copyWith(
        status: ProfileStatus.loaded,
        profileId: profile.id,
        name: profile.name,
        age: profile.age,
        bio: profile.bio,
        photos: photoList,
      ));
    } catch (e) {
      Logger.error('Failed to load profile', e, null, 'ProfileBloc');
      emit(state.copyWith(
        status: ProfileStatus.error,
        errorMessage: 'Failed to load profile',
      ));
    }
  }

  Future<void> _onCreateProfile(
    CreateProfile event,
    Emitter<ProfileState> emit,
  ) async {
    if (event.name.trim().isEmpty) {
      emit(state.copyWith(errorMessage: 'Name is required'));
      return;
    }

    emit(state.copyWith(status: ProfileStatus.saving));

    try {
      final profile = await _databaseService.profileRepository.createProfile(
        name: event.name.trim(),
        age: event.age,
        bio: event.bio?.trim(),
      );

      emit(state.copyWith(
        status: ProfileStatus.saved,
        profileId: profile.id,
        name: profile.name,
        age: profile.age,
        bio: profile.bio,
        photos: [],
      ));

      Logger.info('Profile created: ${profile.id}', 'ProfileBloc');

      // Broadcast profile via BLE
      add(const BroadcastProfile());
    } catch (e) {
      Logger.error('Failed to create profile', e, null, 'ProfileBloc');
      emit(state.copyWith(
        status: ProfileStatus.error,
        errorMessage: 'Failed to create profile',
      ));
    }
  }

  Future<void> _onUpdateProfile(
    UpdateProfile event,
    Emitter<ProfileState> emit,
  ) async {
    if (state.profileId == null) {
      emit(state.copyWith(errorMessage: 'No profile to update'));
      return;
    }

    emit(state.copyWith(status: ProfileStatus.saving));

    try {
      await _databaseService.profileRepository.updateProfile(
        id: state.profileId!,
        name: event.name?.trim(),
        age: event.age,
        bio: event.bio?.trim(),
      );

      emit(state.copyWith(
        status: ProfileStatus.saved,
        name: event.name?.trim() ?? state.name,
        age: event.age ?? state.age,
        bio: event.bio?.trim() ?? state.bio,
      ));

      Logger.info('Profile updated', 'ProfileBloc');

      // Broadcast updated profile via BLE
      add(const BroadcastProfile());
    } catch (e) {
      Logger.error('Failed to update profile', e, null, 'ProfileBloc');
      emit(state.copyWith(
        status: ProfileStatus.error,
        errorMessage: 'Failed to update profile',
      ));
    }
  }

  Future<void> _onAddPhoto(
    AddPhoto event,
    Emitter<ProfileState> emit,
  ) async {
    if (state.profileId == null) {
      emit(state.copyWith(errorMessage: 'Create profile first'));
      return;
    }

    if (!state.canAddMorePhotos) {
      emit(state.copyWith(errorMessage: 'Maximum ${ProfileState.maxPhotos} photos allowed'));
      return;
    }

    emit(state.copyWith(isProcessingPhoto: true));

    try {
      // Process image (compress + generate thumbnail)
      final processed = await _imageService.processImage(event.imageFile);

      // Save to database
      final isPrimary = state.photos.isEmpty;
      final photo = await _databaseService.profileRepository.addPhoto(
        userId: state.profileId!,
        photoPath: processed.photoPath,
        thumbnailPath: processed.thumbnailPath,
        isPrimary: isPrimary,
      );

      final newPhoto = ProfilePhoto.fromEntry(photo);
      final updatedPhotos = [...state.photos, newPhoto];

      emit(state.copyWith(
        status: ProfileStatus.loaded,
        photos: updatedPhotos,
        isProcessingPhoto: false,
      ));

      Logger.info('Photo added: ${photo.id}', 'ProfileBloc');
    } catch (e) {
      Logger.error('Failed to add photo', e, null, 'ProfileBloc');
      emit(state.copyWith(
        isProcessingPhoto: false,
        errorMessage: 'Failed to add photo',
      ));
    }
  }

  Future<void> _onRemovePhoto(
    RemovePhoto event,
    Emitter<ProfileState> emit,
  ) async {
    try {
      final photoToRemove = state.photos.firstWhere((p) => p.id == event.photoId);

      // Delete from database
      await _databaseService.profileRepository.deletePhoto(event.photoId);

      // Delete files
      await _imageService.deleteImage(
        photoToRemove.photoPath,
        photoToRemove.thumbnailPath,
      );

      // Update state
      final updatedPhotos = state.photos.where((p) => p.id != event.photoId).toList();

      // Reload photos to get updated primary status
      if (state.profileId != null) {
        final photos = await _databaseService.profileRepository.getPhotos(state.profileId!);
        final photoList = photos.map((p) => ProfilePhoto.fromEntry(p)).toList();
        emit(state.copyWith(photos: photoList));
      } else {
        emit(state.copyWith(photos: updatedPhotos));
      }

      Logger.info('Photo removed: ${event.photoId}', 'ProfileBloc');
    } catch (e) {
      Logger.error('Failed to remove photo', e, null, 'ProfileBloc');
      emit(state.copyWith(errorMessage: 'Failed to remove photo'));
    }
  }

  Future<void> _onReorderPhotos(
    ReorderPhotos event,
    Emitter<ProfileState> emit,
  ) async {
    if (state.profileId == null) return;

    try {
      await _databaseService.profileRepository.reorderPhotos(
        state.profileId!,
        event.photoIds,
      );

      // Reload photos to get updated order
      final photos = await _databaseService.profileRepository.getPhotos(state.profileId!);
      final photoList = photos.map((p) => ProfilePhoto.fromEntry(p)).toList();

      emit(state.copyWith(photos: photoList));

      Logger.info('Photos reordered', 'ProfileBloc');
    } catch (e) {
      Logger.error('Failed to reorder photos', e, null, 'ProfileBloc');
      emit(state.copyWith(errorMessage: 'Failed to reorder photos'));
    }
  }

  Future<void> _onSetPrimaryPhoto(
    SetPrimaryPhoto event,
    Emitter<ProfileState> emit,
  ) async {
    if (state.profileId == null) return;

    try {
      await _databaseService.profileRepository.setPrimaryPhoto(
        state.profileId!,
        event.photoId,
      );

      // Reload photos to get updated primary status
      final photos = await _databaseService.profileRepository.getPhotos(state.profileId!);
      final photoList = photos.map((p) => ProfilePhoto.fromEntry(p)).toList();

      emit(state.copyWith(photos: photoList));

      Logger.info('Primary photo set: ${event.photoId}', 'ProfileBloc');

      // Rebroadcast with new primary photo thumbnail
      add(const BroadcastProfile());
    } catch (e) {
      Logger.error('Failed to set primary photo', e, null, 'ProfileBloc');
      emit(state.copyWith(errorMessage: 'Failed to set primary photo'));
    }
  }

  Future<void> _onPickPhotoFromGallery(
    PickPhotoFromGallery event,
    Emitter<ProfileState> emit,
  ) async {
    try {
      final file = await _imageService.pickFromGallery();
      if (file != null) {
        add(AddPhoto(file));
      }
    } catch (e) {
      Logger.error('Failed to pick photo from gallery', e, null, 'ProfileBloc');
      emit(state.copyWith(errorMessage: 'Failed to pick photo'));
    }
  }

  Future<void> _onPickPhotoFromCamera(
    PickPhotoFromCamera event,
    Emitter<ProfileState> emit,
  ) async {
    try {
      final file = await _imageService.pickFromCamera();
      if (file != null) {
        add(AddPhoto(file));
      }
    } catch (e) {
      Logger.error('Failed to pick photo from camera', e, null, 'ProfileBloc');
      emit(state.copyWith(errorMessage: 'Failed to take photo'));
    }
  }

  /// Broadcast profile via BLE
  Future<void> _onBroadcastProfile(
    BroadcastProfile event,
    Emitter<ProfileState> emit,
  ) async {
    if (state.profileId == null || state.name == null) {
      Logger.warning('Cannot broadcast - no profile', 'ProfileBloc');
      return;
    }

    try {
      // Get primary photo thumbnail for broadcasting
      Uint8List? thumbnailBytes;
      final primaryPhoto = state.primaryPhoto;
      if (primaryPhoto != null) {
        final thumbnailFile = File(primaryPhoto.thumbnailPath);
        if (await thumbnailFile.exists()) {
          thumbnailBytes = await thumbnailFile.readAsBytes();
        }
      }

      // Create broadcast payload
      final payload = ble.BroadcastPayload(
        userId: state.profileId!,
        name: state.name!,
        age: state.age,
        bio: state.bio,
        thumbnailBytes: thumbnailBytes,
      );

      // Broadcast via BLE
      await _bleService.broadcastProfile(payload);

      Logger.info('Profile broadcast via BLE', 'ProfileBloc');
    } catch (e) {
      Logger.error('Failed to broadcast profile', e, null, 'ProfileBloc');
      // Don't emit error - broadcasting failure shouldn't block user
    }
  }

  void _onClearError(
    ClearError event,
    Emitter<ProfileState> emit,
  ) {
    emit(state.copyWith(errorMessage: null));
  }
}
