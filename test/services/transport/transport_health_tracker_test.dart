import 'package:anchor/services/transport/transport_enums.dart';
import 'package:anchor/services/transport/transport_health_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late TransportHealthTracker tracker;

  setUp(() {
    tracker = TransportHealthTracker();
  });

  tearDown(() async {
    await tracker.dispose();
  });

  group('TransportHealthTracker', () {
    test('recordSendResult tracks success count and rate', () {
      tracker
        ..recordSendResult('peer-1', TransportType.ble,
            success: true, rttMs: 50,)
        ..recordSendResult('peer-1', TransportType.ble,
            success: true, rttMs: 100,)
        ..recordSendResult('peer-1', TransportType.ble,
            success: false, rttMs: 0,);

      final health = tracker.healthFor('peer-1', TransportType.ble);
      expect(health, isNotNull);
      expect(health!.totalSends, 3);
      expect(health.successfulSends, 2);
      expect(health.successRate, closeTo(0.667, 0.01));
    });

    test('avgRtt is computed from successful sends only', () {
      tracker
        ..recordSendResult('peer-1', TransportType.lan,
            success: true, rttMs: 50,)
        ..recordSendResult('peer-1', TransportType.lan,
            success: true, rttMs: 150,)
        ..recordSendResult('peer-1', TransportType.lan,
            success: false, rttMs: 0,);

      final health = tracker.healthFor('peer-1', TransportType.lan);
      expect(health!.avgRttMs, closeTo(100.0, 0.1));
    });

    test('lastRtt updates on successful sends only', () {
      tracker
        ..recordSendResult('peer-1', TransportType.ble,
            success: true, rttMs: 50,)
        ..recordSendResult('peer-1', TransportType.ble,
            success: false, rttMs: 0,);

      final health = tracker.healthFor('peer-1', TransportType.ble);
      expect(health!.lastRttMs, 50);
    });

    test('healthFor returns null for untracked peer/transport', () {
      expect(tracker.healthFor('unknown', TransportType.ble), isNull);
    });

    test('healthForPeer returns all transports for a peer', () {
      tracker
        ..recordSendResult('peer-1', TransportType.ble,
            success: true, rttMs: 50,)
        ..recordSendResult('peer-1', TransportType.lan,
            success: true, rttMs: 10,);

      final map = tracker.healthForPeer('peer-1');
      expect(map.length, 2);
      expect(map.containsKey(TransportType.ble), true);
      expect(map.containsKey(TransportType.lan), true);
    });

    test('healthStream emits summary after each record', () async {
      final summaries = <TransportHealthSummary>[];
      final sub = tracker.healthStream.listen(summaries.add);

      tracker
        ..recordSendResult('peer-1', TransportType.ble,
            success: true, rttMs: 50,)
        ..recordSendResult('peer-1', TransportType.ble,
            success: false, rttMs: 0,);

      // Allow microtask queue to flush
      await Future<void>.delayed(Duration.zero);

      expect(summaries.length, 2);
      expect(summaries[0].health.totalSends, 1);
      expect(summaries[1].health.totalSends, 2);

      await sub.cancel();
    });

    test('tracks different peers independently', () {
      tracker
        ..recordSendResult('peer-1', TransportType.ble,
            success: true, rttMs: 50,)
        ..recordSendResult('peer-2', TransportType.ble,
            success: false, rttMs: 0,);

      expect(tracker.healthFor('peer-1', TransportType.ble)!.successRate, 1.0);
      expect(tracker.healthFor('peer-2', TransportType.ble)!.successRate, 0.0);
    });

    test('tracks different transports for same peer independently', () {
      tracker
        ..recordSendResult('peer-1', TransportType.ble,
            success: true, rttMs: 100,)
        ..recordSendResult('peer-1', TransportType.lan,
            success: false, rttMs: 0,);

      expect(tracker.healthFor('peer-1', TransportType.ble)!.successRate, 1.0);
      expect(tracker.healthFor('peer-1', TransportType.lan)!.successRate, 0.0);
    });
  });
}
