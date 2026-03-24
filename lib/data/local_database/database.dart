import 'dart:io';

import 'package:anchor/core/constants/app_constants.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
///
/// Lifecycle: pending → queued → sent → delivered → read
///   - pending: saved to DB, not yet attempted
///   - queued: scheduled for cross-session delivery (store-and-forward)
///   - sent: successfully transmitted to the peer's transport
///   - delivered: peer acknowledged receipt
///   - read: peer opened the conversation and viewed the message
///   - failed: delivery permanently failed (max retries exceeded)
enum MessageStatus {
  pending,
  queued,
  sent,
  delivered,
  read,
  failed,
}

/// Direction of an anchor drop
enum AnchorDropDirection { sent, received }

/// Delivery status of a sent anchor drop
enum AnchorDropStatus { pending, delivered }

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

/// Nearby users found via BLE, LAN, or Wi-Fi Aware.
///
/// [peerId] stores the peer's stable app-level userId (generated at profile
/// creation). This is the canonical identity that never changes regardless of
/// transport, BLE MAC rotation, or session restarts.
@DataClassName('DiscoveredPeerEntry')
class DiscoveredPeers extends Table {
  /// Canonical peer identity — the peer's app-level userId (stable UUID).
  TextColumn get peerId => text()();
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
  /// X25519 public key (32 bytes, hex-encoded, 64 chars) for E2EE.
  TextColumn get publicKeyHex => text().nullable()();
  /// Ed25519 signing public key (hex) for mesh announcement verification.
  TextColumn get ed25519PublicKeyHex => text().nullable()();

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
  /// Cross-session retry counter (incremented by StoreAndForwardService).
  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  /// Timestamp of the last cross-session delivery attempt. null = never retried.
  DateTimeColumn get lastAttemptAt => dateTime().nullable()();
  /// ID of the message being replied to. null = not a reply.
  TextColumn get replyToMessageId => text().nullable()();

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
  TextColumn get status =>
      textEnum<AnchorDropStatus>().withDefault(Constant(AnchorDropStatus.delivered.name))();

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

// PeerPublicKeys table removed — public keys are now stored directly on
// DiscoveredPeers (publicKeyHex + ed25519PublicKeyHex columns).

/// Maps transport-level IDs (BLE UUID, LAN session ID, etc.) to the
/// canonical peerId (DiscoveredPeers.peerId). This prevents duplicate
/// peer rows when iOS rotates BLE Peripheral UUIDs.
@DataClassName('PeerAliasEntry')
class PeerAliases extends Table {
  /// Transport-specific ID (BLE UUID, LAN ID, Wi-Fi Aware ID, etc.)
  TextColumn get transportId => text()();

  /// Canonical peer identity — FK to DiscoveredPeers.peerId.
  /// Safe because registerAlias is called inside upsertPeer() after the
  /// peer row is guaranteed to exist.
  TextColumn get canonicalPeerId =>
      text().references(DiscoveredPeers, #peerId)();

  /// Transport type: "ble", "lan", "wifiAware"
  TextColumn get transportType => text()();

  /// When this alias was first recorded
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {transportId};
}

/// Emoji reactions on messages
@DataClassName('ReactionEntry')
class MessageReactions extends Table {
  TextColumn get id => text()();
  TextColumn get messageId => text().references(Messages, #id)();
  TextColumn get senderId => text()();
  TextColumn get emoji => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Persisted E2EE sessions so the Noise handshake isn't required on every
/// app restart. Sessions expire after 24 hours (enforced by EncryptionService).
@DataClassName('PersistedNoiseSession')
class NoiseSessions extends Table {
  /// Canonical peer ID (same key used in EncryptionService._sessions).
  TextColumn get peerId => text()();

  /// 32-byte send key (hex-encoded).
  TextColumn get sendKeyHex => text()();

  /// 32-byte receive key (hex-encoded).
  TextColumn get receiveKeyHex => text()();

  /// When the session was established.
  DateTimeColumn get establishedAt => dateTime()();

  /// Number of messages sent with this session (for rekey tracking).
  IntColumn get messageCount => integer().withDefault(const Constant(0))();

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
  MessageReactions,
  NoiseSessions,
  PeerAliases,
],)
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
          await m.createTable(noiseSessions);
        }
        if (from < 4) {
          // v3 had peer_aliases without FK; v4 adds FK to discovered_peers.
          // Pre-production — safe to drop and recreate.
          await m.deleteTable('peer_aliases');
          await m.createTable(peerAliases);
        }
        if (from < 5) {
          await customStatement(
            "ALTER TABLE anchor_drops ADD COLUMN status TEXT NOT NULL DEFAULT 'delivered'",
          );
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
