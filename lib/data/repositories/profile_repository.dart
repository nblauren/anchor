import 'dart:convert';

import 'package:drift/drift.dart';

import '../local_database/database.dart';
import '../models/user_profile.dart';

/// Repository for managing user profiles in local database
class ProfileRepository {
  ProfileRepository(this._database);

  final AppDatabase _database;

  /// Get the current user's own profile
  Future<UserProfile?> getOwnProfile() async {
    final result = await (_database.select(_database.userProfiles)
          ..where((tbl) => tbl.isOwnProfile.equals(true)))
        .getSingleOrNull();

    if (result == null) return null;
    return _mapToModel(result);
  }

  /// Save or update the user's own profile
  Future<void> saveOwnProfile(UserProfile profile) async {
    final companion = UserProfilesCompanion(
      id: Value(profile.id),
      name: Value(profile.name),
      age: Value(profile.age),
      bio: Value(profile.bio),
      photoUrls: Value(jsonEncode(profile.photoUrls)),
      interests: Value(jsonEncode(profile.interests)),
      createdAt: Value(profile.createdAt),
      updatedAt: Value(profile.updatedAt),
      isOwnProfile: const Value(true),
      lastSeenAt: Value(profile.lastSeenAt),
      bleIdentifier: Value(profile.bleIdentifier),
    );

    await _database.into(_database.userProfiles).insertOnConflictUpdate(companion);
  }

  /// Get a discovered user's profile by ID
  Future<UserProfile?> getProfileById(String id) async {
    final result = await (_database.select(_database.userProfiles)
          ..where((tbl) => tbl.id.equals(id)))
        .getSingleOrNull();

    if (result == null) return null;
    return _mapToModel(result);
  }

  /// Save a discovered user's profile
  Future<void> saveDiscoveredProfile(UserProfile profile) async {
    final companion = UserProfilesCompanion(
      id: Value(profile.id),
      name: Value(profile.name),
      age: Value(profile.age),
      bio: Value(profile.bio),
      photoUrls: Value(jsonEncode(profile.photoUrls)),
      interests: Value(jsonEncode(profile.interests)),
      createdAt: Value(profile.createdAt),
      updatedAt: Value(profile.updatedAt),
      isOwnProfile: const Value(false),
      lastSeenAt: Value(profile.lastSeenAt),
      bleIdentifier: Value(profile.bleIdentifier),
    );

    await _database.into(_database.userProfiles).insertOnConflictUpdate(companion);
  }

  /// Get all discovered profiles
  Future<List<UserProfile>> getAllDiscoveredProfiles() async {
    final results = await (_database.select(_database.userProfiles)
          ..where((tbl) => tbl.isOwnProfile.equals(false))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.lastSeenAt)]))
        .get();

    return results.map(_mapToModel).toList();
  }

  /// Delete a profile by ID
  Future<void> deleteProfile(String id) async {
    await (_database.delete(_database.userProfiles)
          ..where((tbl) => tbl.id.equals(id)))
        .go();
  }

  /// Update last seen timestamp for a profile
  Future<void> updateLastSeen(String id, DateTime timestamp) async {
    await (_database.update(_database.userProfiles)
          ..where((tbl) => tbl.id.equals(id)))
        .write(UserProfilesCompanion(lastSeenAt: Value(timestamp)));
  }

  UserProfile _mapToModel(dynamic row) {
    return UserProfile(
      id: row.id,
      name: row.name,
      age: row.age,
      bio: row.bio,
      photoUrls: List<String>.from(jsonDecode(row.photoUrls)),
      interests: List<String>.from(jsonDecode(row.interests)),
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      isOwnProfile: row.isOwnProfile,
      lastSeenAt: row.lastSeenAt,
      bleIdentifier: row.bleIdentifier,
    );
  }
}
