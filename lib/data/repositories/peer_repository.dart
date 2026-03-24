import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/data/local_database/database.dart';
import 'package:drift/drift.dart';

/// Repository for managing discovered peers and blocking logic.
///
/// All methods take [peerId] which is the peer's stable app-level userId
/// (canonical UUID). Transport-specific IDs are resolved upstream.
class PeerRepository {
  PeerRepository(this._db);

  final AppDatabase _db;

  // ==================== Peer CRUD ====================

  /// Get all discovered peers (excluding blocked)
  Future<List<DiscoveredPeerEntry>> getAllPeers(
      {bool includeBlocked = false,}) async {
    final query = _db.select(_db.discoveredPeers);
    if (!includeBlocked) {
      query.where((t) => t.isBlocked.equals(false));
    }
    query.orderBy([(t) => OrderingTerm.desc(t.lastSeenAt)]);
    return query.get();
  }

  /// Get a peer by ID (peerId = stable app-level userId).
  Future<DiscoveredPeerEntry?> getPeerById(String peerId) async {
    return (_db.select(_db.discoveredPeers)
          ..where((t) => t.peerId.equals(peerId)))
        .getSingleOrNull();
  }

  /// Get peers seen within a time window
  Future<List<DiscoveredPeerEntry>> getRecentPeers(Duration window) async {
    final cutoff = DateTime.now().subtract(window);
    return (_db.select(_db.discoveredPeers)
          ..where((t) =>
              t.lastSeenAt.isBiggerOrEqualValue(cutoff) &
              t.isBlocked.equals(false),)
          ..orderBy([(t) => OrderingTerm.desc(t.lastSeenAt)]))
        .get();
  }

  /// Upsert a discovered peer (insert or update if exists).
  ///
  /// [peerId] is the peer's stable app-level userId (canonical UUID).
  /// No public-key dedup — alias table prevents duplicate rows upstream.
  /// Upsert a discovered peer (insert or update if exists).
  ///
  /// [peerId] is the peer's stable app-level userId (canonical UUID).
  /// [transportId] / [transportType] are the original transport-level ID and
  /// type (e.g. BLE UUID / "ble"). When provided, a PeerAliases row is
  /// persisted after the peer row is guaranteed to exist, satisfying the FK.
  Future<DiscoveredPeerEntry> upsertPeer({
    required String peerId,
    required String name,
    int? age,
    String? bio,
    int? position,
    String? interests,
    Uint8List? thumbnailData,
    int? rssi,
    String? publicKeyHex,
    String? transportId,
    String? transportType,
  }) async {
    final now = DateTime.now();

    // Check if peer exists (by peerId)
    final existing = await getPeerById(peerId);

    DiscoveredPeerEntry result;

    if (existing != null) {
      // Update existing peer
      final companion = DiscoveredPeersCompanion(
        name: Value(name),
        // Only overwrite when we actually have a new value — don't let stale
        // advertisement scans wipe richer data from the GATT profile read.
        age: age != null ? Value(age) : const Value.absent(),
        bio: bio != null ? Value(bio) : const Value.absent(),
        position: position != null ? Value(position) : const Value.absent(),
        interests: interests != null ? Value(interests) : const Value.absent(),
        thumbnailData:
            thumbnailData != null ? Value(thumbnailData) : const Value.absent(),
        lastSeenAt: Value(now),
        rssi: rssi != null ? Value(rssi) : const Value.absent(),
        publicKeyHex: publicKeyHex != null
            ? Value(publicKeyHex)
            : const Value.absent(),
      );

      await (_db.update(_db.discoveredPeers)
            ..where((t) => t.peerId.equals(peerId)))
          .write(companion);

      result = DiscoveredPeerEntry(
        peerId: peerId,
        name: name,
        age: age ?? existing.age,
        bio: bio ?? existing.bio,
        position: position ?? existing.position,
        interests: interests ?? existing.interests,
        thumbnailData: thumbnailData ?? existing.thumbnailData,
        lastSeenAt: now,
        rssi: rssi ?? existing.rssi,
        isBlocked: existing.isBlocked,
        publicKeyHex: publicKeyHex ?? existing.publicKeyHex,
        ed25519PublicKeyHex: existing.ed25519PublicKeyHex,
      );
    } else {
      // Insert new peer
      final entry = DiscoveredPeersCompanion.insert(
        peerId: peerId,
        name: name,
        age: Value(age),
        bio: Value(bio),
        position: Value(position),
        interests: Value(interests),
        thumbnailData: Value(thumbnailData),
        lastSeenAt: now,
        rssi: Value(rssi),
        isBlocked: const Value(false),
        publicKeyHex: Value(publicKeyHex),
      );

      await _db.into(_db.discoveredPeers).insertOnConflictUpdate(entry);

      result = DiscoveredPeerEntry(
        peerId: peerId,
        name: name,
        age: age,
        bio: bio,
        position: position,
        interests: interests,
        thumbnailData: thumbnailData,
        lastSeenAt: now,
        rssi: rssi,
        isBlocked: false,
        publicKeyHex: publicKeyHex,
      );
    }

    // ── Persist transport alias (peer row guaranteed to exist) ──
    if (transportId != null && transportType != null) {
      await registerAlias(transportId, peerId, transportType);
    }

    // ── Diagnostic: warn if another peerId shares the same public key ──
    // This should never happen with alias-based resolution, but if it does
    // it means PeerRegistry returned different canonical IDs for the same
    // physical person. Log loudly so it's visible in debug output.
    if (publicKeyHex != null && publicKeyHex.isNotEmpty) {
      final dupes = await (_db.select(_db.discoveredPeers)
            ..where((t) =>
                t.publicKeyHex.equals(publicKeyHex) &
                t.peerId.isNotValue(peerId),))
          .get();
      if (dupes.isNotEmpty) {
        Logger.warning(
          'PeerRepository: duplicate public key detected! '
          'peerId=$peerId shares key ${publicKeyHex.substring(0, 8)}… with '
          '${dupes.map((d) => d.peerId).join(', ')} — alias resolution may have a bug',
          'DB',
        );
      }
    }

    return result;
  }

  /// Update peer's last seen time and RSSI
  Future<void> updatePeerPresence(String peerId, {int? rssi}) async {
    await (_db.update(_db.discoveredPeers)
          ..where((t) => t.peerId.equals(peerId)))
        .write(DiscoveredPeersCompanion(
      lastSeenAt: Value(DateTime.now()),
      rssi: rssi != null ? Value(rssi) : const Value.absent(),
    ),);
  }

  /// Delete a peer and their conversations/messages/aliases
  Future<void> deletePeer(String peerId) async {
    await _db.transaction(() async {
      // Delete messages in conversations with this peer
      final conversations = await (_db.select(_db.conversations)
            ..where((t) => t.peerId.equals(peerId)))
          .get();

      for (final conv in conversations) {
        await (_db.delete(_db.messages)
              ..where((t) => t.conversationId.equals(conv.id)))
            .go();
      }

      // Delete conversations
      await (_db.delete(_db.conversations)
            ..where((t) => t.peerId.equals(peerId)))
          .go();

      // Delete from blocked users if present
      await (_db.delete(_db.blockedUsers)
            ..where((t) => t.peerId.equals(peerId)))
          .go();

      // Delete aliases pointing to this peer
      await (_db.delete(_db.peerAliases)
            ..where((t) => t.canonicalPeerId.equals(peerId)))
          .go();

      // Delete peer
      await (_db.delete(_db.discoveredPeers)
            ..where((t) => t.peerId.equals(peerId)))
          .go();
    });
  }

  /// Watch all peers (excluding blocked)
  Stream<List<DiscoveredPeerEntry>> watchPeers({bool includeBlocked = false}) {
    final query = _db.select(_db.discoveredPeers);
    if (!includeBlocked) {
      query.where((t) => t.isBlocked.equals(false));
    }
    query.orderBy([(t) => OrderingTerm.desc(t.lastSeenAt)]);
    return query.watch();
  }

  // ==================== Blocking Logic ====================

  /// Block a peer
  Future<void> blockPeer(String peerId) async {
    await _db.transaction(() async {
      // Add to blocked users table
      await _db.into(_db.blockedUsers).insertOnConflictUpdate(
            BlockedUsersCompanion.insert(
              peerId: peerId,
              blockedAt: DateTime.now(),
            ),
          );

      // Update peer's blocked status
      await (_db.update(_db.discoveredPeers)
            ..where((t) => t.peerId.equals(peerId)))
          .write(const DiscoveredPeersCompanion(isBlocked: Value(true)));
    });
  }

  /// Unblock a peer
  Future<void> unblockPeer(String peerId) async {
    await _db.transaction(() async {
      // Remove from blocked users table
      await (_db.delete(_db.blockedUsers)
            ..where((t) => t.peerId.equals(peerId)))
          .go();

      // Update peer's blocked status
      await (_db.update(_db.discoveredPeers)
            ..where((t) => t.peerId.equals(peerId)))
          .write(const DiscoveredPeersCompanion(isBlocked: Value(false)));
    });
  }

  /// Check if a peer is blocked
  Future<bool> isPeerBlocked(String peerId) async {
    final blocked = await (_db.select(_db.blockedUsers)
          ..where((t) => t.peerId.equals(peerId)))
        .getSingleOrNull();
    return blocked != null;
  }

  /// Get all blocked peers
  Future<List<BlockedUserEntry>> getBlockedPeers() async {
    return (_db.select(_db.blockedUsers)
          ..orderBy([(t) => OrderingTerm.desc(t.blockedAt)]))
        .get();
  }

  /// Get blocked peer details (joins with discovered peers)
  Future<List<DiscoveredPeerEntry>> getBlockedPeerDetails() async {
    return (_db.select(_db.discoveredPeers)
          ..where((t) => t.isBlocked.equals(true))
          ..orderBy([(t) => OrderingTerm.desc(t.lastSeenAt)]))
        .get();
  }

  /// Watch blocked peers
  Stream<List<BlockedUserEntry>> watchBlockedPeers() {
    return (_db.select(_db.blockedUsers)
          ..orderBy([(t) => OrderingTerm.desc(t.blockedAt)]))
        .watch();
  }

  // ==================== Utility Methods ====================

  /// Get peer count
  Future<int> getPeerCount({bool includeBlocked = false}) async {
    final count = _db.discoveredPeers.peerId.count();
    final query = _db.selectOnly(_db.discoveredPeers)..addColumns([count]);
    if (!includeBlocked) {
      query.where(_db.discoveredPeers.isBlocked.equals(false));
    }
    final result = await query.getSingle();
    return result.read(count) ?? 0;
  }

  /// Clear all peers older than a duration
  Future<int> clearOldPeers(Duration olderThan) async {
    final cutoff = DateTime.now().subtract(olderThan);
    return _db.transaction(() async {
      // Find peers to delete
      final peersToDelete = await (_db.select(_db.discoveredPeers)
            ..where((t) =>
                t.lastSeenAt.isSmallerThanValue(cutoff) &
                t.isBlocked.equals(false),))
          .get();

      if (peersToDelete.isEmpty) return 0;

      final peerIds = peersToDelete.map((p) => p.peerId).toList();

      // Delete messages in conversations with these peers
      for (final peerId in peerIds) {
        final conversations = await (_db.select(_db.conversations)
              ..where((t) => t.peerId.equals(peerId)))
            .get();
        for (final conv in conversations) {
          await (_db.delete(_db.messages)
                ..where((t) => t.conversationId.equals(conv.id)))
              .go();
        }
        // Delete conversations
        await (_db.delete(_db.conversations)
              ..where((t) => t.peerId.equals(peerId)))
            .go();
      }

      // Now delete the peers
      return (_db.delete(_db.discoveredPeers)
            ..where((t) =>
                t.lastSeenAt.isSmallerThanValue(cutoff) &
                t.isBlocked.equals(false),))
          .go();
    });
  }

  /// Search peers by name
  Future<List<DiscoveredPeerEntry>> searchPeers(String query) async {
    return (_db.select(_db.discoveredPeers)
          ..where((t) => t.name.like('%$query%') & t.isBlocked.equals(false))
          ..orderBy([(t) => OrderingTerm.desc(t.lastSeenAt)]))
        .get();
  }

  // ==================== Peer Aliases ====================

  /// Look up the canonical peerId for a transport-level ID.
  /// Returns null if no alias exists.
  Future<String?> resolveAlias(String transportId) async {
    final row = await (_db.select(_db.peerAliases)
          ..where((t) => t.transportId.equals(transportId)))
        .getSingleOrNull();
    return row?.canonicalPeerId;
  }

  /// Register a transport ID → canonical peerId mapping.
  /// Idempotent (insertOrIgnore).
  Future<void> registerAlias(
    String transportId,
    String canonicalPeerId,
    String transportType,
  ) async {
    await _db.into(_db.peerAliases).insertOnConflictUpdate(
          PeerAliasesCompanion.insert(
            transportId: transportId,
            canonicalPeerId: canonicalPeerId,
            transportType: transportType,
            createdAt: DateTime.now(),
          ),
        );
  }

  /// Get all persisted aliases (for PeerRegistry hydration at startup).
  Future<List<PeerAliasEntry>> getAllAliases() async {
    return _db.select(_db.peerAliases).get();
  }

  /// Delete all aliases pointing to a given canonical peerId.
  Future<void> deleteAliasesForPeer(String canonicalPeerId) async {
    await (_db.delete(_db.peerAliases)
          ..where((t) => t.canonicalPeerId.equals(canonicalPeerId)))
        .go();
  }
}
