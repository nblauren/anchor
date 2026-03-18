import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:drift/drift.dart' show Value;
import 'package:path_provider/path_provider.dart';

import '../../../core/constants/profile_constants.dart';
import '../../../core/utils/logger.dart';
import '../../../services/database_service.dart';
import '../../../services/image_service.dart' show ImageService, resolvePhotoPath;
import '../../../services/nsfw_detection_service.dart';
import '../../../services/profile_broadcast_service.dart';
import 'profile_event.dart';
import 'profile_state.dart';

/// Manages the device owner's profile.
///
/// Responsibilities:
///   - Load, create, and update the local profile (stored via Drift).
///   - Photo management: add, remove, reorder, set primary (up to 4 photos).
///   - NSFW gate: the primary thumbnail is screened by [NsfwDetectionService]
///     before being allowed into the BLE broadcast. If blocked, the state
///     carries [ProfileState.nsfwBlockedPhotoId] and the photo is never
///     written to the fff2 characteristic.
///   - Position and interests are stored as integer IDs (see
///     [ProfileConstants]) — never as free text — to keep the BLE payload
///     compact and prevent injection of arbitrary strings into the mesh.
///   - Triggers [BleServiceInterface.broadcastProfile] whenever the profile
///     is saved or the primary photo changes.
class ProfileBloc extends Bloc<ProfileEvent, ProfileState> {
  ProfileBloc({
    required DatabaseService databaseService,
    required ImageService imageService,
    required NsfwDetectionService nsfwDetectionService,
    required ProfileBroadcastService profileBroadcastService,
  })  : _databaseService = databaseService,
        _imageService = imageService,
        _nsfwService = nsfwDetectionService,
        _profileBroadcastService = profileBroadcastService,
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
    on<DismissNsfwWarning>(_onDismissNsfwWarning);
    on<QuickSetupProfile>(_onQuickSetupProfile);
  }

  final DatabaseService _databaseService;
  final ImageService _imageService;
  final NsfwDetectionService _nsfwService;
  final ProfileBroadcastService _profileBroadcastService;

  /// Runs NSFW check on [absolutePath]. If the photo fails the check, emits
  /// [ProfileState.nsfwBlockedPhotoId] = [photoId] and returns false.
  /// Returns true if the photo is safe to broadcast as primary.
  Future<bool> _passesNsfwCheck(
    String absolutePath,
    String photoId,
    Emitter<ProfileState> emit,
  ) async {
    try {
      final result = await _nsfwService.analyzeImage(absolutePath);
      if (!result.isSafe) {
        Logger.warning(
          'NSFW check blocked photo $photoId (confidence=${result.confidence})',
          'ProfileBloc',
        );
        emit(state.copyWith(
          isProcessingPhoto: false,
          nsfwBlockedPhotoId: photoId,
        ));
        return false;
      }
      return true;
    } catch (e) {
      // On detection error, allow the photo — don't block on service failure.
      Logger.error('NSFW detection failed, allowing photo', e, null, 'ProfileBloc');
      return true;
    }
  }

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
        position: profile.position,
        interestIds: ProfileConstants.parseInterests(profile.interests),
        photos: photoList,
      ));

      // Broadcast profile via BLE so this device is discoverable
      add(const BroadcastProfile());
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
        position: event.position,
        interests: ProfileConstants.encodeInterests(event.interests),
      );

      emit(state.copyWith(
        status: ProfileStatus.saved,
        profileId: profile.id,
        name: profile.name,
        age: profile.age,
        bio: profile.bio,
        position: profile.position,
        interestIds: ProfileConstants.parseInterests(profile.interests),
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
      // Build position Value — explicit clear vs. no-op vs. new value.
      final Value<int?> positionValue = event.clearPosition
          ? const Value(null)
          : event.position != null
              ? Value(event.position)
              : const Value.absent();

      // Build interests Value — null list = no-op, empty = clear.
      final Value<String?> interestsValue = event.interests != null
          ? Value(ProfileConstants.encodeInterests(event.interests!))
          : const Value.absent();

      await _databaseService.profileRepository.updateProfile(
        id: state.profileId!,
        name: event.name?.trim(),
        age: event.age,
        bio: event.bio?.trim(),
        position: positionValue,
        interests: interestsValue,
      );

      // Compute updated state values
      final newPosition = event.clearPosition
          ? null
          : (event.position ?? state.position);
      final newInterestIds = event.interests ?? state.interestIds;

      emit(state.copyWith(
        status: ProfileStatus.saved,
        name: event.name?.trim() ?? state.name,
        age: event.age ?? state.age,
        bio: event.bio?.trim() ?? state.bio,
        position: newPosition,
        interestIds: newInterestIds,
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

      // This will be the first (primary) photo — run NSFW check before broadcasting.
      final willBePrimary = state.photos.isEmpty;
      bool isPrimary = willBePrimary;

      if (willBePrimary) {
        final absolutePath = await resolvePhotoPath(processed.photoPath) ?? processed.photoPath;
        final safe = await _passesNsfwCheck(absolutePath, 'new_primary', emit);
        if (!safe) {
          // Save as non-primary secondary so the photo is not lost.
          isPrimary = false;
        }
      }

      // Save to database
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
        // Preserve nsfwBlockedPhotoId if it was set in _passesNsfwCheck above;
        // use the real DB photo.id now that we have it.
        nsfwBlockedPhotoId: (!isPrimary && willBePrimary) ? photo.id : null,
      ));

      Logger.info('Photo added: ${photo.id} (primary=$isPrimary)', 'ProfileBloc');

      // Only rebroadcast when the new photo is actually primary.
      if (isPrimary) {
        add(const BroadcastProfile());
      }
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
      // Detect whether the effective primary photo is changing.
      final currentFirstId = state.sortedPhotos.isNotEmpty ? state.sortedPhotos.first.id : null;
      final newFirstId = event.photoIds.isNotEmpty ? event.photoIds.first : null;
      final primaryChanging = newFirstId != null && newFirstId != currentFirstId;

      if (primaryChanging) {
        emit(state.copyWith(isProcessingPhoto: true));

        // Find the photo object for the new position-0 entry.
        final newPrimaryPhoto = state.photos.firstWhere((p) => p.id == newFirstId);
        final absolutePath =
            await resolvePhotoPath(newPrimaryPhoto.photoPath) ?? newPrimaryPhoto.photoPath;

        final safe = await _passesNsfwCheck(absolutePath, newFirstId, emit);
        if (!safe) {
          // _passesNsfwCheck already emitted the blocked state; abort reorder.
          return;
        }

        emit(state.copyWith(isProcessingPhoto: false));
      }

      await _databaseService.profileRepository.reorderPhotos(
        state.profileId!,
        event.photoIds,
      );

      // Sync the isPrimary DB flag to match the new order.
      if (newFirstId != null) {
        await _databaseService.profileRepository.setPrimaryPhoto(
          state.profileId!,
          newFirstId,
        );
      }

      // Reload photos to get updated order and primary flag.
      final photos = await _databaseService.profileRepository.getPhotos(state.profileId!);
      final photoList = photos.map((p) => ProfilePhoto.fromEntry(p)).toList();

      emit(state.copyWith(photos: photoList));

      Logger.info('Photos reordered', 'ProfileBloc');

      // Rebroadcast whenever order changes (new primary thumbnail may differ).
      add(const BroadcastProfile());
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

    // No-op if already primary.
    if (state.sortedPhotos.isNotEmpty && state.sortedPhotos.first.id == event.photoId) {
      return;
    }

    emit(state.copyWith(isProcessingPhoto: true));

    try {
      final photo = state.photos.firstWhere((p) => p.id == event.photoId);
      final absolutePath = await resolvePhotoPath(photo.photoPath) ?? photo.photoPath;

      final safe = await _passesNsfwCheck(absolutePath, event.photoId, emit);
      if (!safe) {
        // _passesNsfwCheck already emitted the blocked state.
        return;
      }

      await _databaseService.profileRepository.setPrimaryPhoto(
        state.profileId!,
        event.photoId,
      );

      // Reload photos to get updated primary status
      final photos = await _databaseService.profileRepository.getPhotos(state.profileId!);
      final photoList = photos.map((p) => ProfilePhoto.fromEntry(p)).toList();

      emit(state.copyWith(photos: photoList, isProcessingPhoto: false));

      Logger.info('Primary photo set: ${event.photoId}', 'ProfileBloc');

      // Rebroadcast with new primary photo thumbnail
      add(const BroadcastProfile());
    } catch (e) {
      Logger.error('Failed to set primary photo', e, null, 'ProfileBloc');
      emit(state.copyWith(
        isProcessingPhoto: false,
        errorMessage: 'Failed to set primary photo',
      ));
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
    await _profileBroadcastService.broadcast(state);
  }

  /// Debug-only: create a complete profile with random data and a placeholder
  /// solid-color image so the developer can skip the full setup flow.
  Future<void> _onQuickSetupProfile(
    QuickSetupProfile event,
    Emitter<ProfileState> emit,
  ) async {
    if (!kDebugMode) return;

    emit(state.copyWith(status: ProfileStatus.saving));

    try {
      final rng = Random();

      const names = ['Alex', 'Jordan', 'Sam', 'Riley', 'Casey', 'Drew', 'Morgan', 'Kai'];
      const bios = [
        'Just here for a good time',
        'Love the ocean and good company',
        'First cruise, looking to meet new people',
        'Dance floor enthusiast',
        'Adventure seeker and cocktail lover',
      ];

      final name = names[rng.nextInt(names.length)];
      final age = 21 + rng.nextInt(20); // 21–40
      final bio = bios[rng.nextInt(bios.length)];
      final position = rng.nextInt(ProfileConstants.maxPositionId + 1);

      // Pick 2–5 random interests
      final allInterestIds = ProfileConstants.interestMap.keys.toList()..shuffle(rng);
      final interestCount = 2 + rng.nextInt(4);
      final interests = allInterestIds.take(interestCount).toList();

      // Create profile
      final profile = await _databaseService.profileRepository.createProfile(
        name: name,
        age: age,
        bio: bio,
        position: position,
        interests: ProfileConstants.encodeInterests(interests),
      );

      // Generate a solid-color placeholder image (200x200 PNG)
      final color = ui.Color.fromARGB(
        255,
        100 + rng.nextInt(156),
        100 + rng.nextInt(156),
        100 + rng.nextInt(156),
      );
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 200, 200),
        ui.Paint()..color = color,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(200, 200);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final pngBytes = byteData!.buffer.asUint8List();

      // Save to file
      final docsDir = await getApplicationDocumentsDirectory();
      final photoDir = Directory('${docsDir.path}/profile_photos');
      if (!photoDir.existsSync()) photoDir.createSync(recursive: true);
      final photoFile = File('${photoDir.path}/quick_setup.png');
      await photoFile.writeAsBytes(pngBytes);

      // Store relative path (consistent with ImageService convention)
      const relativePath = 'profile_photos/quick_setup.png';

      // Add photo to DB
      final photo = await _databaseService.profileRepository.addPhoto(
        userId: profile.id,
        photoPath: relativePath,
        thumbnailPath: relativePath, // same file for thumbnail in debug
        isPrimary: true,
      );

      final newPhoto = ProfilePhoto.fromEntry(photo);

      emit(state.copyWith(
        status: ProfileStatus.saved,
        profileId: profile.id,
        name: profile.name,
        age: profile.age,
        bio: profile.bio,
        position: profile.position,
        interestIds: ProfileConstants.parseInterests(profile.interests),
        photos: [newPhoto],
      ));

      Logger.info('Quick setup profile created: ${profile.id}', 'ProfileBloc');

      add(const BroadcastProfile());
    } catch (e) {
      Logger.error('Quick setup failed', e, null, 'ProfileBloc');
      emit(state.copyWith(
        status: ProfileStatus.error,
        errorMessage: 'Quick setup failed',
      ));
    }
  }

  void _onClearError(
    ClearError event,
    Emitter<ProfileState> emit,
  ) {
    emit(state.copyWith(errorMessage: null));
  }

  void _onDismissNsfwWarning(
    DismissNsfwWarning event,
    Emitter<ProfileState> emit,
  ) {
    emit(state.copyWith(clearNsfwBlock: true));
  }
}
