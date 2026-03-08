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
  }) async {
    await _db.into(_db.anchorDrops).insert(
          AnchorDropsCompanion.insert(
            id: _uuid.v4(),
            peerId: peerId,
            peerName: peerName,
            direction: direction,
            droppedAt: DateTime.now(),
          ),
        );
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
}
