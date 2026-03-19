import 'package:anchor/services/encryption/rate_limiter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HandshakeRateLimiter', () {
    late HandshakeRateLimiter limiter;

    setUp(() {
      limiter = HandshakeRateLimiter();
    });

    group('per-peer limit', () {
      test('allows up to 10 attempts per peer', () {
        for (var i = 0; i < 10; i++) {
          expect(limiter.tryAcquire('peer-a'), isTrue,
              reason: 'Attempt ${i + 1} should be allowed');
        }
      });

      test('blocks 11th attempt for same peer', () {
        for (var i = 0; i < 10; i++) {
          limiter.tryAcquire('peer-a');
        }
        expect(limiter.tryAcquire('peer-a'), isFalse);
      });

      test('different peers have independent limits', () {
        for (var i = 0; i < 10; i++) {
          limiter.tryAcquire('peer-a');
        }
        // peer-a is exhausted, but peer-b should still be allowed.
        expect(limiter.tryAcquire('peer-b'), isTrue);
      });
    });

    group('global limit', () {
      test('allows up to 30 attempts globally', () {
        for (var i = 0; i < 30; i++) {
          // Use a different peer each time to avoid per-peer limit.
          expect(limiter.tryAcquire('peer-$i'), isTrue,
              reason: 'Global attempt ${i + 1} should be allowed');
        }
      });

      test('blocks 31st attempt globally', () {
        for (var i = 0; i < 30; i++) {
          limiter.tryAcquire('peer-$i');
        }
        expect(limiter.tryAcquire('peer-new'), isFalse);
      });
    });

    group('isAllowed (non-recording check)', () {
      test('returns true when under limit', () {
        expect(limiter.isAllowed('peer-a'), isTrue);
      });

      test('does not consume an attempt', () {
        limiter.isAllowed('peer-a');
        limiter.isAllowed('peer-a');
        limiter.isAllowed('peer-a');
        // Still should allow 10 actual attempts.
        for (var i = 0; i < 10; i++) {
          expect(limiter.tryAcquire('peer-a'), isTrue);
        }
      });

      test('returns false when per-peer limit exhausted', () {
        for (var i = 0; i < 10; i++) {
          limiter.tryAcquire('peer-a');
        }
        expect(limiter.isAllowed('peer-a'), isFalse);
      });

      test('returns false when global limit exhausted', () {
        for (var i = 0; i < 30; i++) {
          limiter.tryAcquire('peer-$i');
        }
        expect(limiter.isAllowed('peer-new'), isFalse);
      });
    });

    group('remainingForPeer', () {
      test('starts at 10 (per-peer is the bottleneck)', () {
        expect(limiter.remainingForPeer('peer-a'), 10);
      });

      test('decrements with each attempt', () {
        limiter.tryAcquire('peer-a');
        limiter.tryAcquire('peer-a');
        expect(limiter.remainingForPeer('peer-a'), 8);
      });

      test('reports global limit when it is the bottleneck', () {
        // Fill global with 28 attempts (different peers).
        for (var i = 0; i < 28; i++) {
          limiter.tryAcquire('peer-$i');
        }
        // Global remaining = 2, peer-new remaining = 10. Min = 2.
        expect(limiter.remainingForPeer('peer-new'), 2);
      });

      test('returns 0 when exhausted', () {
        for (var i = 0; i < 10; i++) {
          limiter.tryAcquire('peer-a');
        }
        expect(limiter.remainingForPeer('peer-a'), 0);
      });
    });

    group('clear', () {
      test('resets all state', () {
        for (var i = 0; i < 10; i++) {
          limiter.tryAcquire('peer-a');
        }
        expect(limiter.tryAcquire('peer-a'), isFalse);

        limiter.clear();

        expect(limiter.tryAcquire('peer-a'), isTrue);
        expect(limiter.remainingForPeer('peer-a'), 9);
      });
    });

    group('custom limits', () {
      test('respects custom per-peer limit', () {
        final custom = HandshakeRateLimiter(
          maxPerPeerPerMinute: 3,
          maxGlobalPerMinute: 100,
        );
        expect(custom.tryAcquire('peer-a'), isTrue);
        expect(custom.tryAcquire('peer-a'), isTrue);
        expect(custom.tryAcquire('peer-a'), isTrue);
        expect(custom.tryAcquire('peer-a'), isFalse);
      });

      test('respects custom global limit', () {
        final custom = HandshakeRateLimiter(
          maxPerPeerPerMinute: 100,
          maxGlobalPerMinute: 5,
        );
        for (var i = 0; i < 5; i++) {
          expect(custom.tryAcquire('peer-$i'), isTrue);
        }
        expect(custom.tryAcquire('peer-5'), isFalse);
      });
    });

    group('rejected attempts are not recorded', () {
      test('failed tryAcquire does not consume a slot', () {
        for (var i = 0; i < 10; i++) {
          limiter.tryAcquire('peer-a');
        }
        // This should be rejected but NOT recorded.
        limiter.tryAcquire('peer-a');
        limiter.tryAcquire('peer-a');

        // After clearing, peer-a should have 10 slots again.
        limiter.clear();
        for (var i = 0; i < 10; i++) {
          expect(limiter.tryAcquire('peer-a'), isTrue);
        }
      });
    });
  });
}
