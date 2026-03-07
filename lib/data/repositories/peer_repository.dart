import 'package:drift/drift.dart';

import '../local_database/database.dart';

/// Repository for managing discovered peers and blocking logic
class PeerRepository {
  PeerRepository(this._db);

  final AppDatabase _db;

  // ==================== Peer CRUD ====================

  /// Get all discovered peers (excluding blocked)
  Future<List<DiscoveredPeerEntry>> getAllPeers(
      {bool includeBlocked = false}) async {
    final query = _db.select(_db.discoveredPeers);
    if (!includeBlocked) {
      query.where((t) => t.isBlocked.equals(false));
    }
    query.orderBy([(t) => OrderingTerm.desc(t.lastSeenAt)]);
    return await query.get();
  }

  /// Get a peer by ID
  Future<DiscoveredPeerEntry?> getPeerById(String peerId) async {
    return await (_db.select(_db.discoveredPeers)
          ..where((t) => t.peerId.equals(peerId)))
        .getSingleOrNull();
  }

  /// Get peers seen within a time window
  Future<List<DiscoveredPeerEntry>> getRecentPeers(Duration window) async {
    final cutoff = DateTime.now().subtract(window);
    return await (_db.select(_db.discoveredPeers)
          ..where((t) =>
              t.lastSeenAt.isBiggerOrEqualValue(cutoff) &
              t.isBlocked.equals(false))
          ..orderBy([(t) => OrderingTerm.desc(t.lastSeenAt)]))
        .get();
  }

  /// Upsert a discovered peer (insert or update if exists)
  Future<DiscoveredPeerEntry> upsertPeer({
    required String peerId,
    required String name,
    int? age,
    String? bio,
    Uint8List? thumbnailData,
    int? rssi,
  }) async {
    final now = DateTime.now();

    // Check if peer exists
    final existing = await getPeerById(peerId);

    if (existing != null) {
      // Update existing peer
      final companion = DiscoveredPeersCompanion(
        name: Value(name),
        age: Value(age),
        // Only overwrite bio/thumbnail when we actually have a new value.
        // Advertisement scans emit null for both — we must not let them wipe
        // the richer data that the GATT profile read stored previously.
        bio: bio != null ? Value(bio) : const Value.absent(),
        thumbnailData:
            thumbnailData != null ? Value(thumbnailData) : const Value.absent(),
        lastSeenAt: Value(now),
        rssi: rssi != null ? Value(rssi) : const Value.absent(),
      );

      await (_db.update(_db.discoveredPeers)
            ..where((t) => t.peerId.equals(peerId)))
          .write(companion);

      return DiscoveredPeerEntry(
        peerId: peerId,
        name: name,
        age: age,
        // Mirror the DB write: don't overwrite a stored bio/thumbnail with null.
        bio: bio ?? existing.bio,
        thumbnailData: thumbnailData ?? existing.thumbnailData,
        lastSeenAt: now,
        rssi: rssi ?? existing.rssi,
        isBlocked: existing.isBlocked,
      );
    } else {
      // Insert new peer
      final entry = DiscoveredPeersCompanion.insert(
        peerId: peerId,
        name: name,
        age: Value(age),
        bio: Value(bio),
        thumbnailData: Value(thumbnailData),
        lastSeenAt: now,
        rssi: Value(rssi),
        isBlocked: const Value(false),
      );

      await _db.into(_db.discoveredPeers).insert(entry);

      return DiscoveredPeerEntry(
        peerId: peerId,
        name: name,
        age: age,
        bio: bio,
        thumbnailData: thumbnailData,
        lastSeenAt: now,
        rssi: rssi,
        isBlocked: false,
      );
    }
  }

  /// Update peer's last seen time and RSSI
  Future<void> updatePeerPresence(String peerId, {int? rssi}) async {
    await (_db.update(_db.discoveredPeers)
          ..where((t) => t.peerId.equals(peerId)))
        .write(DiscoveredPeersCompanion(
      lastSeenAt: Value(DateTime.now()),
      rssi: rssi != null ? Value(rssi) : const Value.absent(),
    ));
  }

  /// Delete a peer and their conversations/messages
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
    return await (_db.select(_db.blockedUsers)
          ..orderBy([(t) => OrderingTerm.desc(t.blockedAt)]))
        .get();
  }

  /// Get blocked peer details (joins with discovered peers)
  Future<List<DiscoveredPeerEntry>> getBlockedPeerDetails() async {
    return await (_db.select(_db.discoveredPeers)
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
    return await _db.transaction(() async {
      // Find peers to delete
      final peersToDelete = await (_db.select(_db.discoveredPeers)
            ..where((t) =>
                t.lastSeenAt.isSmallerThanValue(cutoff) &
                t.isBlocked.equals(false)))
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
      return await (_db.delete(_db.discoveredPeers)
            ..where((t) =>
                t.lastSeenAt.isSmallerThanValue(cutoff) &
                t.isBlocked.equals(false)))
          .go();
    });
  }

  /// Search peers by name
  Future<List<DiscoveredPeerEntry>> searchPeers(String query) async {
    return await (_db.select(_db.discoveredPeers)
          ..where((t) => t.name.like('%$query%') & t.isBlocked.equals(false))
          ..orderBy([(t) => OrderingTerm.desc(t.lastSeenAt)]))
        .get();
  }
}
