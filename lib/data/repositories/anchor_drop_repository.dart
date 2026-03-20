import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../local_database/database.dart';

/// Repository for tracking sent and received ⚓ anchor drops
class AnchorDropRepository {
  AnchorDropRepository(this._db);

  final AppDatabase _db;
  static const _uuid = Uuid();

  /// Record a sent or received anchor drop
  Future<void> recordDrop({
    required String peerId,
    required String peerName,
    required AnchorDropDirection direction,
    AnchorDropStatus status = AnchorDropStatus.delivered,
  }) async {
    await _db.into(_db.anchorDrops).insert(
          AnchorDropsCompanion.insert(
            id: _uuid.v4(),
            peerId: peerId,
            peerName: peerName,
            direction: direction,
            droppedAt: DateTime.now(),
            status: Value(status),
          ),
        );
  }

  /// Mark a pending anchor drop as delivered.
  Future<void> markDelivered(String dropId) async {
    await (_db.update(_db.anchorDrops)..where((t) => t.id.equals(dropId)))
        .write(const AnchorDropsCompanion(
            status: Value(AnchorDropStatus.delivered)));
  }

  /// Get all pending (undelivered) sent anchor drops for a specific peer,
  /// within the last [hours] (default 24h — stale drops are not useful).
  Future<List<AnchorDropEntry>> getPendingDropsForPeer(
    String peerId, {
    int hours = 24,
  }) async {
    final cutoff = DateTime.now().subtract(Duration(hours: hours));
    return (_db.select(_db.anchorDrops)
          ..where((t) =>
              t.peerId.equals(peerId) &
              t.direction.equals(AnchorDropDirection.sent.name) &
              t.status.equals(AnchorDropStatus.pending.name) &
              t.droppedAt.isBiggerOrEqualValue(cutoff)))
        .get();
  }

  /// Expire all pending anchor drops older than [hours].
  Future<void> expireStalePendingDrops({int hours = 24}) async {
    final cutoff = DateTime.now().subtract(Duration(hours: hours));
    await (_db.delete(_db.anchorDrops)
          ..where((t) =>
              t.status.equals(AnchorDropStatus.pending.name) &
              t.droppedAt.isSmallerThanValue(cutoff)))
        .go();
  }

  /// Returns true if we've already dropped anchor on this peer today
  Future<bool> hasDroppedToPeerToday(String peerId) async {
    final today = DateTime.now();
    final startOfDay = DateTime(today.year, today.month, today.day);
    final result = await (_db.select(_db.anchorDrops)
          ..where(
            (t) =>
                t.peerId.equals(peerId) &
                t.direction.equals(AnchorDropDirection.sent.name) &
                t.droppedAt.isBiggerOrEqualValue(startOfDay),
          )
          ..limit(1))
        .getSingleOrNull();
    return result != null;
  }

  /// Returns the number of anchors dropped (sent) today
  Future<int> getTodaySentCount() async {
    final today = DateTime.now();
    final startOfDay = DateTime(today.year, today.month, today.day);
    final rows = await (_db.select(_db.anchorDrops)
          ..where(
            (t) =>
                t.direction.equals(AnchorDropDirection.sent.name) &
                t.droppedAt.isBiggerOrEqualValue(startOfDay),
          ))
        .get();
    return rows.length;
  }

  /// Returns the most recent drops (sent + received), newest first
  Future<List<AnchorDropEntry>> getRecentDrops({int limit = 50}) async {
    return (_db.select(_db.anchorDrops)
          ..orderBy([(t) => OrderingTerm.desc(t.droppedAt)])
          ..limit(limit))
        .get();
  }

  /// Returns peer IDs that we sent an anchor drop to within the last [hours].
  /// Used to restore the ⚓ badge on the discovery grid after app restart.
  Future<Set<String>> getSentPeerIdsSince({int hours = 24}) async {
    final cutoff = DateTime.now().subtract(Duration(hours: hours));
    final rows = await (_db.select(_db.anchorDrops)
          ..where(
            (t) =>
                t.direction.equals(AnchorDropDirection.sent.name) &
                t.droppedAt.isBiggerOrEqualValue(cutoff),
          ))
        .get();
    return rows.map((r) => r.peerId).toSet();
  }

  /// Returns received anchor drops, newest first, deduplicated by peerId
  /// (keeps the most recent drop per peer).
  Future<List<AnchorDropEntry>> getReceivedDrops({int limit = 50}) async {
    return (_db.select(_db.anchorDrops)
          ..where(
              (t) => t.direction.equals(AnchorDropDirection.received.name))
          ..orderBy([(t) => OrderingTerm.desc(t.droppedAt)])
          ..limit(limit))
        .get();
  }
}
