import 'package:anchor/data/local_database/database.dart';
import 'package:drift/drift.dart' show Value;

/// Abstract interface for [ProfileRepository].
///
/// Consumers should depend on this interface rather than the concrete
/// implementation so that repositories can be easily swapped for testing
/// or alternative storage backends.
abstract class ProfileRepositoryInterface {
  // ==================== Profile CRUD ====================

  Future<UserProfileEntry?> getProfile();

  Future<UserProfileEntry?> getProfileById(String id);

  Future<UserProfileEntry> createProfile({
    required String name,
    int? age,
    String? bio,
    int? position,
    String? interests,
  });

  Future<void> updateProfile({
    required String id,
    String? name,
    int? age,
    String? bio,
    Value<int?> position = const Value.absent(),
    Value<String?> interests = const Value.absent(),
  });

  Future<void> deleteProfile(String id);

  Stream<UserProfileEntry?> watchProfile();

  // ==================== Photos CRUD ====================

  Future<List<UserPhotoEntry>> getPhotos(String userId);

  Future<UserPhotoEntry?> getPrimaryPhoto(String userId);

  Future<UserPhotoEntry> addPhoto({
    required String userId,
    required String photoPath,
    required String thumbnailPath,
    bool isPrimary = false,
  });

  Future<void> setPrimaryPhoto(String userId, String photoId);

  Future<void> reorderPhotos(String userId, List<String> photoIds);

  Future<void> deletePhoto(String photoId);

  Future<void> deleteAllPhotos(String userId);

  Stream<List<UserPhotoEntry>> watchPhotos(String userId);

  Future<int> getPhotoCount(String userId);
}
