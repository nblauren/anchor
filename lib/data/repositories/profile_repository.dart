import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../local_database/database.dart';

/// Repository for managing local user profile and photos
class ProfileRepository {
  ProfileRepository(this._db);

  final AppDatabase _db;
  static const _uuid = Uuid();

  // ==================== Profile CRUD ====================

  /// Get the local user's profile (there should only be one)
  Future<UserProfileEntry?> getProfile() async {
    return await (_db.select(_db.userProfiles)..limit(1)).getSingleOrNull();
  }

  /// Get profile by ID
  Future<UserProfileEntry?> getProfileById(String id) async {
    return await (_db.select(_db.userProfiles)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// Create a new profile
  Future<UserProfileEntry> createProfile({
    required String name,
    int? age,
    String? bio,
  }) async {
    final now = DateTime.now();
    final id = _uuid.v4();

    final entry = UserProfilesCompanion.insert(
      id: id,
      name: name,
      age: Value(age),
      bio: Value(bio),
      createdAt: now,
      updatedAt: now,
    );

    await _db.into(_db.userProfiles).insert(entry);

    return UserProfileEntry(
      id: id,
      name: name,
      age: age,
      bio: bio,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Update the profile
  Future<void> updateProfile({
    required String id,
    String? name,
    int? age,
    String? bio,
  }) async {
    final companion = UserProfilesCompanion(
      name: name != null ? Value(name) : const Value.absent(),
      age: age != null ? Value(age) : const Value.absent(),
      bio: bio != null ? Value(bio) : const Value.absent(),
      updatedAt: Value(DateTime.now()),
    );

    await (_db.update(_db.userProfiles)..where((t) => t.id.equals(id)))
        .write(companion);
  }

  /// Delete the profile and all associated photos
  Future<void> deleteProfile(String id) async {
    await _db.transaction(() async {
      // Delete photos first (foreign key constraint)
      await (_db.delete(_db.userPhotos)..where((t) => t.userId.equals(id)))
          .go();
      // Delete profile
      await (_db.delete(_db.userProfiles)..where((t) => t.id.equals(id))).go();
    });
  }

  /// Watch profile changes
  Stream<UserProfileEntry?> watchProfile() {
    return (_db.select(_db.userProfiles)..limit(1)).watchSingleOrNull();
  }

  // ==================== Photos CRUD ====================

  /// Get all photos for a user, ordered by order_index
  Future<List<UserPhotoEntry>> getPhotos(String userId) async {
    return await (_db.select(_db.userPhotos)
          ..where((t) => t.userId.equals(userId))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
  }

  /// Get the primary photo for a user
  Future<UserPhotoEntry?> getPrimaryPhoto(String userId) async {
    return await (_db.select(_db.userPhotos)
          ..where((t) => t.userId.equals(userId) & t.isPrimary.equals(true)))
        .getSingleOrNull();
  }

  /// Add a new photo
  Future<UserPhotoEntry> addPhoto({
    required String userId,
    required String photoPath,
    required String thumbnailPath,
    bool isPrimary = false,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now();

    // Get the next order index
    final photos = await getPhotos(userId);
    final orderIndex = photos.isEmpty ? 0 : photos.last.orderIndex + 1;

    // If this is the first photo or marked as primary, make it primary
    final shouldBePrimary = isPrimary || photos.isEmpty;

    // If setting as primary, unset any existing primary
    if (shouldBePrimary) {
      await (_db.update(_db.userPhotos)
            ..where((t) => t.userId.equals(userId) & t.isPrimary.equals(true)))
          .write(const UserPhotosCompanion(isPrimary: Value(false)));
    }

    final entry = UserPhotosCompanion.insert(
      id: id,
      userId: userId,
      photoPath: photoPath,
      thumbnailPath: thumbnailPath,
      isPrimary: Value(shouldBePrimary),
      orderIndex: orderIndex,
      createdAt: now,
    );

    await _db.into(_db.userPhotos).insert(entry);

    return UserPhotoEntry(
      id: id,
      userId: userId,
      photoPath: photoPath,
      thumbnailPath: thumbnailPath,
      isPrimary: shouldBePrimary,
      orderIndex: orderIndex,
      createdAt: now,
    );
  }

  /// Set a photo as primary
  Future<void> setPrimaryPhoto(String userId, String photoId) async {
    await _db.transaction(() async {
      // Unset current primary
      await (_db.update(_db.userPhotos)
            ..where((t) => t.userId.equals(userId) & t.isPrimary.equals(true)))
          .write(const UserPhotosCompanion(isPrimary: Value(false)));

      // Set new primary
      await (_db.update(_db.userPhotos)..where((t) => t.id.equals(photoId)))
          .write(const UserPhotosCompanion(isPrimary: Value(true)));
    });
  }

  /// Update photo order
  Future<void> reorderPhotos(String userId, List<String> photoIds) async {
    await _db.transaction(() async {
      for (var i = 0; i < photoIds.length; i++) {
        await (_db.update(_db.userPhotos)
              ..where((t) => t.id.equals(photoIds[i])))
            .write(UserPhotosCompanion(orderIndex: Value(i)));
      }
    });
  }

  /// Delete a photo
  Future<void> deletePhoto(String photoId) async {
    final photo = await (_db.select(_db.userPhotos)
          ..where((t) => t.id.equals(photoId)))
        .getSingleOrNull();

    if (photo == null) return;

    await (_db.delete(_db.userPhotos)..where((t) => t.id.equals(photoId))).go();

    // If the deleted photo was primary, set the first remaining photo as primary
    if (photo.isPrimary) {
      final remainingPhotos = await getPhotos(photo.userId);
      if (remainingPhotos.isNotEmpty) {
        await setPrimaryPhoto(photo.userId, remainingPhotos.first.id);
      }
    }
  }

  /// Delete all photos for a user
  Future<void> deleteAllPhotos(String userId) async {
    await (_db.delete(_db.userPhotos)..where((t) => t.userId.equals(userId)))
        .go();
  }

  /// Watch photos for a user
  Stream<List<UserPhotoEntry>> watchPhotos(String userId) {
    return (_db.select(_db.userPhotos)
          ..where((t) => t.userId.equals(userId))
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .watch();
  }

  /// Get photo count for a user
  Future<int> getPhotoCount(String userId) async {
    final count = _db.userPhotos.id.count();
    final query = _db.selectOnly(_db.userPhotos)
      ..where(_db.userPhotos.userId.equals(userId))
      ..addColumns([count]);
    final result = await query.getSingle();
    return result.read(count) ?? 0;
  }
}
