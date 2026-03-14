import 'package:anchor/data/local_database/database.dart';
import 'package:anchor/data/repositories/anchor_drop_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late AnchorDropRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = AnchorDropRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  // ── recordDrop ────────────────────────────────────────────────────────────

  group('recordDrop', () {
    test('inserts a new drop entry', () async {
      await repo.recordDrop(
        peerId: 'peer-1',
        peerName: 'Alice',
        direction: AnchorDropDirection.sent,
      );

      final drops = await repo.getRecentDrops();
      expect(drops.length, 1);
      expect(drops.first.peerId, 'peer-1');
      expect(drops.first.peerName, 'Alice');
      expect(drops.first.direction, AnchorDropDirection.sent);
    });

    test('multiple drops produce multiple entries', () async {
      await repo.recordDrop(
          peerId: 'p1', peerName: 'A', direction: AnchorDropDirection.sent);
      await repo.recordDrop(
          peerId: 'p2', peerName: 'B', direction: AnchorDropDirection.received);
      await repo.recordDrop(
          peerId: 'p3', peerName: 'C', direction: AnchorDropDirection.sent);

      final drops = await repo.getRecentDrops();
      expect(drops.length, 3);
    });
  });

  // ── hasDroppedToPeerToday ─────────────────────────────────────────────────

  group('hasDroppedToPeerToday', () {
    test('returns true after sending a drop today', () async {
      await repo.recordDrop(
        peerId: 'peer-1',
        peerName: 'Alice',
        direction: AnchorDropDirection.sent,
      );

      expect(await repo.hasDroppedToPeerToday('peer-1'), isTrue);
    });

    test('returns false when never dropped on peer', () async {
      expect(await repo.hasDroppedToPeerToday('unknown-peer'), isFalse);
    });

    test('returns false for received drops (not sent)', () async {
      await repo.recordDrop(
        peerId: 'peer-1',
        peerName: 'Alice',
        direction: AnchorDropDirection.received, // received, not sent
      );

      // hasDroppedToPeerToday only checks SENT drops
      expect(await repo.hasDroppedToPeerToday('peer-1'), isFalse);
    });

    test('returns false for a different peer', () async {
      await repo.recordDrop(
          peerId: 'peer-1', peerName: 'Alice', direction: AnchorDropDirection.sent);

      expect(await repo.hasDroppedToPeerToday('peer-2'), isFalse);
    });
  });

  // ── getSentPeerIdsSince ───────────────────────────────────────────────────

  group('getSentPeerIdsSince', () {
    test('returns peer IDs of sent drops within window', () async {
      await repo.recordDrop(
          peerId: 'p1', peerName: 'A', direction: AnchorDropDirection.sent);
      await repo.recordDrop(
          peerId: 'p2', peerName: 'B', direction: AnchorDropDirection.sent);

      final ids = await repo.getSentPeerIdsSince(hours: 24);
      expect(ids, containsAll(['p1', 'p2']));
    });

    test('excludes received drops', () async {
      await repo.recordDrop(
          peerId: 'p-sent', peerName: 'S', direction: AnchorDropDirection.sent);
      await repo.recordDrop(
          peerId: 'p-recv', peerName: 'R', direction: AnchorDropDirection.received);

      final ids = await repo.getSentPeerIdsSince(hours: 24);
      expect(ids, contains('p-sent'));
      expect(ids, isNot(contains('p-recv')));
    });

    test('returns empty set when no drops recorded', () async {
      final ids = await repo.getSentPeerIdsSince(hours: 24);
      expect(ids, isEmpty);
    });

    test('deduplicates multiple drops to same peer', () async {
      // Dropped to same peer twice
      await repo.recordDrop(
          peerId: 'p1', peerName: 'A', direction: AnchorDropDirection.sent);
      await repo.recordDrop(
          peerId: 'p1', peerName: 'A', direction: AnchorDropDirection.sent);

      final ids = await repo.getSentPeerIdsSince(hours: 24);
      expect(ids.length, 1);
      expect(ids.contains('p1'), isTrue);
    });
  });

  // ── getTodaySentCount ─────────────────────────────────────────────────────

  group('getTodaySentCount', () {
    test('returns 0 when no drops today', () async {
      expect(await repo.getTodaySentCount(), 0);
    });

    test('increments with each sent drop', () async {
      await repo.recordDrop(
          peerId: 'p1', peerName: 'A', direction: AnchorDropDirection.sent);
      expect(await repo.getTodaySentCount(), 1);

      await repo.recordDrop(
          peerId: 'p2', peerName: 'B', direction: AnchorDropDirection.sent);
      expect(await repo.getTodaySentCount(), 2);
    });

    test('does not count received drops', () async {
      await repo.recordDrop(
          peerId: 'p1', peerName: 'A', direction: AnchorDropDirection.received);
      await repo.recordDrop(
          peerId: 'p2', peerName: 'B', direction: AnchorDropDirection.sent);

      expect(await repo.getTodaySentCount(), 1);
    });
  });

  // ── getRecentDrops ────────────────────────────────────────────────────────

  group('getRecentDrops', () {
    test('returns drops in descending time order', () async {
      // Use explicit timestamps to guarantee ordering irrespective of wall clock
      final now = DateTime.now();
      await db.into(db.anchorDrops).insert(AnchorDropsCompanion.insert(
            id: 'id-1',
            peerId: 'p1',
            peerName: 'A',
            direction: AnchorDropDirection.sent,
            droppedAt: now.subtract(const Duration(minutes: 2)),
          ));
      await db.into(db.anchorDrops).insert(AnchorDropsCompanion.insert(
            id: 'id-2',
            peerId: 'p2',
            peerName: 'B',
            direction: AnchorDropDirection.sent,
            droppedAt: now.subtract(const Duration(minutes: 1)),
          ));
      await db.into(db.anchorDrops).insert(AnchorDropsCompanion.insert(
            id: 'id-3',
            peerId: 'p3',
            peerName: 'C',
            direction: AnchorDropDirection.sent,
            droppedAt: now,
          ));

      final drops = await repo.getRecentDrops();
      // Most recent first
      expect(drops.first.peerId, 'p3');
      expect(drops.last.peerId, 'p1');
    });

    test('respects the limit parameter', () async {
      for (var i = 0; i < 10; i++) {
        await repo.recordDrop(
            peerId: 'p$i',
            peerName: 'User $i',
            direction: AnchorDropDirection.sent);
      }

      final limited = await repo.getRecentDrops(limit: 3);
      expect(limited.length, 3);
    });
  });

  // ── getReceivedDrops ──────────────────────────────────────────────────────

  group('getReceivedDrops', () {
    test('only returns received drops', () async {
      await repo.recordDrop(
          peerId: 'p-sent', peerName: 'Sender', direction: AnchorDropDirection.sent);
      await repo.recordDrop(
          peerId: 'p-recv', peerName: 'Receiver', direction: AnchorDropDirection.received);

      final received = await repo.getReceivedDrops();
      expect(received.length, 1);
      expect(received.first.peerId, 'p-recv');
      expect(received.first.direction, AnchorDropDirection.received);
    });

    test('returns empty when no received drops', () async {
      await repo.recordDrop(
          peerId: 'p1', peerName: 'A', direction: AnchorDropDirection.sent);
      expect(await repo.getReceivedDrops(), isEmpty);
    });
  });
}
