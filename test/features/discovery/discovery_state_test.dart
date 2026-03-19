import 'package:anchor/features/discovery/bloc/discovery_state.dart';
import 'package:anchor/services/transport/transport_enums.dart';
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

    test('preserves insertion order among online peers', () {
      final state = DiscoveryState(peers: [
        TestFixtures.makePeer(peerId: 'far', rssi: -80),
        TestFixtures.makePeer(peerId: 'close', rssi: -40),
        TestFixtures.makePeer(peerId: 'mid', rssi: -60),
      ]);

      final ids = state.visiblePeers.map((p) => p.peerId).toList();
      // Insertion order preserved — no RSSI sorting in visiblePeers
      expect(ids, ['far', 'close', 'mid']);
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
    test('explicit null clears errorMessage', () {
      const state = DiscoveryState(errorMessage: 'some error');
      final cleared = state.copyWith(errorMessage: null);
      expect(cleared.errorMessage, isNull);
    });

    test('preserves all unmodified fields', () {
      final now = DateTime(2024, 6, 1);
      final state = DiscoveryState(
        status: DiscoveryStatus.loaded,
        lastRefreshed: now,
        isScanning: true,
      );

      final copied = state.copyWith(isScanning: false);

      expect(copied.status, DiscoveryStatus.loaded);
      expect(copied.lastRefreshed, now);
      expect(copied.isScanning, isFalse);
    });

    test('updates activeTransport', () {
      const state = DiscoveryState();
      final updated = state.copyWith(activeTransport: TransportType.lan);
      expect(updated.activeTransport, TransportType.lan);
    });
  });
}
