import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../../core/constants/app_constants.dart';

part 'database.g.dart';

// ==================== Enums ====================

/// Content type for messages
enum MessageContentType {
  text,
  photo,
  /// Thumbnail preview sent before receiver consents to the full download.
  /// textContent stores JSON: {"photo_id":"<uuid>","original_size":<bytes>}
  /// photoPath stores the local path to the saved thumbnail file.
  photoPreview,
}

/// Message delivery status
enum MessageStatus {
  pending,
  sent,
  delivered,
  read,
  failed,
}

/// Direction of an anchor drop
enum AnchorDropDirection { sent, received }

// ==================== Tables ====================

/// Local user's own profile
@DataClassName('UserProfileEntry')
class UserProfiles extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get age => integer().nullable()();
  TextColumn get bio => text().nullable()();
  /// Sexual position preference stored as a compact integer ID (see ProfileConstants.positionMap).
  /// null = not set.
  IntColumn get position => integer().nullable()();
  /// Comma-separated interest IDs (e.g. "0,3,7"). null / empty = not set.
  /// See ProfileConstants.interestMap and encodeInterests / parseInterests.
  TextColumn get interests => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Local user's photos
@DataClassName('UserPhotoEntry')
class UserPhotos extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text().references(UserProfiles, #id)();
  TextColumn get photoPath => text()();
  TextColumn get thumbnailPath => text()();
  BoolColumn get isPrimary => boolean().withDefault(const Constant(false))();
  IntColumn get orderIndex => integer()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Nearby users found via BLE
@DataClassName('DiscoveredPeerEntry')
class DiscoveredPeers extends Table {
  TextColumn get peerId => text()();
  /// Stable application-level user ID from the peer's BLE profile.
  /// Used to deduplicate when BLE MAC rotation assigns a new peerId.
  TextColumn get userId => text().nullable()();
  TextColumn get name => text()();
  IntColumn get age => integer().nullable()();
  TextColumn get bio => text().nullable()();
  BlobColumn get thumbnailData => blob().nullable()();
  DateTimeColumn get lastSeenAt => dateTime()();
  IntColumn get rssi => integer().nullable()();
  BoolColumn get isBlocked => boolean().withDefault(const Constant(false))();
  /// Position ID received from peer's BLE profile characteristic. null = not shared.
  IntColumn get position => integer().nullable()();
  /// Comma-separated interest IDs received from peer. null / empty = not shared.
  TextColumn get interests => text().nullable()();

  @override
  Set<Column> get primaryKey => {peerId};
}

/// Chat conversations
@DataClassName('ConversationEntry')
class Conversations extends Table {
  TextColumn get id => text()();
  TextColumn get peerId => text().references(DiscoveredPeers, #peerId)();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Chat messages
@DataClassName('MessageEntry')
class Messages extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId => text().references(Conversations, #id)();
  TextColumn get senderId => text()();
  TextColumn get contentType => textEnum<MessageContentType>()();
  TextColumn get textContent => text().nullable()();
  TextColumn get photoPath => text().nullable()();
  TextColumn get status => textEnum<MessageStatus>()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Anchor drops — tracks sent and received ⚓ drops per peer
@DataClassName('AnchorDropEntry')
class AnchorDrops extends Table {
  TextColumn get id => text()();
  TextColumn get peerId => text()();
  TextColumn get peerName => text()();
  TextColumn get direction => textEnum<AnchorDropDirection>()();
  DateTimeColumn get droppedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Blocked users
@DataClassName('BlockedUserEntry')
class BlockedUsers extends Table {
  TextColumn get peerId => text()();
  DateTimeColumn get blockedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {peerId};
}

// ==================== Database ====================

@DriftDatabase(tables: [
  UserProfiles,
  UserPhotos,
  DiscoveredPeers,
  Conversations,
  Messages,
  AnchorDrops,
  BlockedUsers,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  // For testing
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
      },
      onUpgrade: (Migrator m, int from, int to) async {
        if (from < 2) {
          // Migration from v1 to v2: complete schema change
          await m.deleteTable('user_profiles');
          await m.deleteTable('chat_messages');
          await m.deleteTable('conversations');
          await m.createAll();
        }
        if (from < 3) {
          // Migration from v2 to v3: add anchor_drops table
          await m.createTable(anchorDrops);
        }
        if (from < 4) {
          // Migration from v3 to v4: add position + interests to own profile and peers
          await m.addColumn(userProfiles, userProfiles.position);
          await m.addColumn(userProfiles, userProfiles.interests);
          await m.addColumn(discoveredPeers, discoveredPeers.position);
          await m.addColumn(discoveredPeers, discoveredPeers.interests);
        }
        if (from < 5) {
          // Migration from v4 to v5: add userId to discovered_peers for MAC rotation dedup
          await m.addColumn(discoveredPeers, discoveredPeers.userId);
        }
      },
      beforeOpen: (details) async {
        // Enable foreign keys
        await customStatement('PRAGMA foreign_keys = ON');
      },
    );
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, AppConstants.databaseName));
    return NativeDatabase.createInBackground(file);
  });
}
