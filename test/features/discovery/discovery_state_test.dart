import 'package:anchor/features/discovery/bloc/discovery_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_fixtures.dart';

void main() {
  // ── visiblePeers basic filtering ──────────────────────────────────────────

  group('DiscoveryState.visiblePeers', () {
    test('excludes blocked peers', () {
      final state = DiscoveryState(peers: [
        TestFixtures.makePeer(peerId: 'p1', isBlocked: false),
        TestFixtures.makePeer(peerId: 'p2', isBlocked: true),
        TestFixtures.makePeer(peerId: 'p3', isBlocked: false),
      ]);

      expect(state.visiblePeers.map((p) => p.peerId), containsAll(['p1', 'p3']));
      expect(state.visiblePeers.map((p) => p.peerId), isNot(contains('p2')));
    });

    test('deduplicates peers by peerId, keeping first occurrence', () {
      final state = DiscoveryState(peers: [
        TestFixtures.makePeer(peerId: 'p1', name: 'Alice'),
        TestFixtures.makePeer(peerId: 'p1', name: 'Alice-duplicate'),
      ]);

      final visible = state.visiblePeers;
      expect(visible.length, 1);
      expect(visible.first.name, 'Alice');
    });

    test('returns empty list when all peers are blocked', () {
      final state = DiscoveryState(peers: [
        TestFixtures.makePeer(peerId: 'p1', isBlocked: true),
        TestFixtures.makePeer(peerId: 'p2', isBlocked: true),
      ]);
      expect(state.visiblePeers, isEmpty);
    });

    // ── Online/offline ordering ─────────────────────────────────────────────

    test('puts online peers before offline peers', () {
      final state = DiscoveryState(peers: [
        TestFixtures.makePeer(peerId: 'offline', isOnline: false, rssi: -40),
        TestFixtures.makePeer(peerId: 'online', isOnline: true, rssi: -80),
      ]);

      final visible = state.visiblePeers;
      expect(visible.first.peerId, 'online');
      expect(visible.last.peerId, 'offline');
    });

    // ── RSSI bucket sorting ─────────────────────────────────────────────────

    test('sorts online peers by RSSI bucket, stronger signal first', () {
      final state = DiscoveryState(peers: [
        TestFixtures.makePeer(peerId: 'far', rssi: -80),
        TestFixtures.makePeer(peerId: 'close', rssi: -40),
        TestFixtures.makePeer(peerId: 'mid', rssi: -60),
      ]);

      final ids = state.visiblePeers.map((p) => p.peerId).toList();
      expect(ids, ['close', 'mid', 'far']);
    });

    test('peers within same 10dBm bucket stay in insertion order (stable sort)', () {
      // -60 and -65 fall in the same bucket (-60 ~/ 10 = -6)
      final state = DiscoveryState(peers: [
        TestFixtures.makePeer(peerId: 'first', rssi: -60),
        TestFixtures.makePeer(peerId: 'second', rssi: -65),
      ]);

      final ids = state.visiblePeers.map((p) => p.peerId).toList();
      // Both in bucket -6, insertion order preserved
      expect(ids, ['first', 'second']);
    });

    test('peer with null RSSI treated as -100 (far away) among online peers', () {
      final state = DiscoveryState(peers: [
        TestFixtures.makePeer(peerId: 'strong', rssi: -60),
        TestFixtures.makePeer(peerId: 'no-rssi', rssi: null),
      ]);

      final ids = state.visiblePeers.map((p) => p.peerId).toList();
      expect(ids.first, 'strong');
      expect(ids.last, 'no-rssi');
    });
  });

  // ── Position filter ───────────────────────────────────────────────────────

  group('DiscoveryState position filter', () {
    test('empty filter shows all peers (including those without position)', () {
      final state = DiscoveryState(
        peers: [
          TestFixtures.makePeer(peerId: 'p1', position: 1),
          TestFixtures.makePeer(peerId: 'p2', position: null),
        ],
        filterPositionIds: const {},
      );

      expect(state.visiblePeers.length, 2);
    });

    test('with filter: shows peers with matching position', () {
      final state = DiscoveryState(
        peers: [
          TestFixtures.makePeer(peerId: 'top', position: 1),
          TestFixtures.makePeer(peerId: 'bottom', position: 2),
          TestFixtures.makePeer(peerId: 'versatile', position: 3),
        ],
        filterPositionIds: const {1},
      );

      final ids = state.visiblePeers.map((p) => p.peerId).toSet();
      expect(ids, {'top'});
    });

    test('filter passes through peers with null position (not shared)', () {
      // Peers who didn't share their position shouldn't be excluded
      final state = DiscoveryState(
        peers: [
          TestFixtures.makePeer(peerId: 'filtered-out', position: 2),
          TestFixtures.makePeer(peerId: 'no-position', position: null),
        ],
        filterPositionIds: const {1},
      );

      final ids = state.visiblePeers.map((p) => p.peerId).toSet();
      // Position 2 filtered out, no-position passes through
      expect(ids, {'no-position'});
    });

    test('multiple position IDs in filter = OR logic', () {
      final state = DiscoveryState(
        peers: [
          TestFixtures.makePeer(peerId: 'top', position: 1),
          TestFixtures.makePeer(peerId: 'bottom', position: 2),
          TestFixtures.makePeer(peerId: 'other', position: 5),
        ],
        filterPositionIds: const {1, 2},
      );

      final ids = state.visiblePeers.map((p) => p.peerId).toSet();
      expect(ids, {'top', 'bottom'});
    });
  });

  // ── Interest filter ───────────────────────────────────────────────────────

  group('DiscoveryState interest filter', () {
    test('empty filter shows all peers', () {
      final state = DiscoveryState(
        peers: [
          TestFixtures.makePeer(peerId: 'p1', interests: '0,3'),
          TestFixtures.makePeer(peerId: 'p2', interests: null),
        ],
        filterInterestIds: const {},
      );

      expect(state.visiblePeers.length, 2);
    });

    test('with filter: shows peers sharing at least one interest', () {
      final state = DiscoveryState(
        peers: [
          TestFixtures.makePeer(peerId: 'hiking', interests: '0,3'),    // 0 = hiking
          TestFixtures.makePeer(peerId: 'fitness', interests: '7'),     // no match
          TestFixtures.makePeer(peerId: 'music', interests: '0,5'),    // 0 = match
        ],
        filterInterestIds: const {0},
      );

      final ids = state.visiblePeers.map((p) => p.peerId).toSet();
      expect(ids, {'hiking', 'music'});
    });

    test('peer with no interests shares nothing — passes through (not excluded)', () {
      // Peers without interests set shouldn't be excluded
      final state = DiscoveryState(
        peers: [
          TestFixtures.makePeer(peerId: 'no-interests', interests: null),
          TestFixtures.makePeer(peerId: 'wrong-interest', interests: '5'),
        ],
        filterInterestIds: const {0},
      );

      final ids = state.visiblePeers.map((p) => p.peerId).toSet();
      expect(ids, {'no-interests'});
    });
  });

  // ── Combined filters ──────────────────────────────────────────────────────

  group('DiscoveryState combined filters', () {
    test('both filters must be satisfied', () {
      final state = DiscoveryState(
        peers: [
          // Has right position but wrong interest
          TestFixtures.makePeer(peerId: 'pos-only', position: 1, interests: '5'),
          // Has right interest but wrong position
          TestFixtures.makePeer(peerId: 'int-only', position: 2, interests: '0'),
          // Has both matching
          TestFixtures.makePeer(peerId: 'both', position: 1, interests: '0,3'),
          // Neither
          TestFixtures.makePeer(peerId: 'neither', position: 2, interests: '5'),
        ],
        filterPositionIds: const {1},
        filterInterestIds: const {0},
      );

      final ids = state.visiblePeers.map((p) => p.peerId).toSet();
      // 'pos-only' has position=1 (passes) but interest 5 (fails)
      // 'int-only' has position=2 (fails filter 1), interest 0 (passes filter 2)
      // 'both' passes both
      // peers without interests pass interest filter even when filter is active
      expect(ids.contains('both'), isTrue);
    });
  });

  // ── hasActiveFilters ──────────────────────────────────────────────────────

  group('DiscoveryState.hasActiveFilters', () {
    test('false when both filters empty', () {
      final state = DiscoveryState();
      expect(state.hasActiveFilters, isFalse);
    });

    test('true when position filter set', () {
      final state = DiscoveryState(filterPositionIds: const {1});
      expect(state.hasActiveFilters, isTrue);
    });

    test('true when interest filter set', () {
      final state = DiscoveryState(filterInterestIds: const {3});
      expect(state.hasActiveFilters, isTrue);
    });
  });

  // ── peerCount / hasPeers ──────────────────────────────────────────────────

  group('DiscoveryState.peerCount', () {
    test('counts only non-blocked visible peers', () {
      final state = DiscoveryState(peers: [
        TestFixtures.makePeer(peerId: 'p1'),
        TestFixtures.makePeer(peerId: 'p2', isBlocked: true),
        TestFixtures.makePeer(peerId: 'p3'),
      ]);
      expect(state.peerCount, 2);
      expect(state.hasPeers, isTrue);
    });

    test('hasPeers is false when no visible peers', () {
      expect(const DiscoveryState().hasPeers, isFalse);
    });
  });

  // ── copyWith ─────────────────────────────────────────────────────────────

  group('DiscoveryState.copyWith', () {
    test('explicit null clears incomingAnchorDropName', () {
      final state = DiscoveryState(incomingAnchorDropName: 'Alex ⚓');
      final cleared = state.copyWith(incomingAnchorDropName: null);
      expect(cleared.incomingAnchorDropName, isNull);
    });

    test('sentinel preserves incomingAnchorDropName when not passed', () {
      final state = DiscoveryState(incomingAnchorDropName: 'Alex ⚓');
      final updated = state.copyWith(isScanning: true);
      expect(updated.incomingAnchorDropName, 'Alex ⚓');
    });

    test('preserves all unmodified fields', () {
      final now = DateTime(2024, 6, 1);
      final state = DiscoveryState(
        status: DiscoveryStatus.loaded,
        lastRefreshed: now,
        isScanning: true,
        droppedAnchorPeerIds: const {'p1'},
      );

      final copied = state.copyWith(isScanning: false);

      expect(copied.status, DiscoveryStatus.loaded);
      expect(copied.lastRefreshed, now);
      expect(copied.isScanning, isFalse);
      expect(copied.droppedAnchorPeerIds, {'p1'});
    });
  });
}
