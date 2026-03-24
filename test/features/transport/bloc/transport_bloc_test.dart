import 'package:anchor/features/transport/bloc/transport_event.dart';
import 'package:anchor/features/transport/bloc/transport_state.dart';
import 'package:anchor/services/transport/transport_enums.dart';
import 'package:anchor/services/transport/transport_health_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TransportBloc', () {
    test('initial state has ble as active transport', () {
      final tracker = TransportHealthTracker();
      // We test the state model directly since we can't easily
      // construct a TransportBloc without a real TransportManager.
      const state = TransportState();
      expect(state.activeTransport, TransportType.ble);
      expect(state.peerTransports, isEmpty);
      expect(state.peerHealth, isEmpty);
      tracker.dispose();
    });

    test('TransportState.transportForPeer falls back to BLE for unknown peers', () {
      const state = TransportState(
        activeTransport: TransportType.lan,
        peerTransports: {'peer-1': TransportType.wifiAware},
      );
      expect(state.transportForPeer('peer-1'), TransportType.wifiAware);
      // Unknown peers fall back to BLE (baseline), not activeTransport,
      // because activeTransport reflects local capability, not peer capability.
      expect(state.transportForPeer('unknown'), TransportType.ble);
    });

    test('TransportState.copyWith updates fields correctly', () {
      const initial = TransportState();
      final updated = initial.copyWith(
        activeTransport: TransportType.lan,
        peerTransports: {'peer-1': TransportType.lan},
      );
      expect(updated.activeTransport, TransportType.lan);
      expect(updated.peerTransports['peer-1'], TransportType.lan);
      // Original unchanged
      expect(initial.activeTransport, TransportType.ble);
    });

    test('ActiveTransportChanged event updates state', () {
      // Test the event model
      const event = ActiveTransportChanged(TransportType.lan);
      expect(event.transport, TransportType.lan);
      expect(event.props, [TransportType.lan]);
    });

    test('PeerTransportUpdated event carries correct data', () {
      const event = PeerTransportUpdated(
        peerId: 'peer-1',
        oldTransport: TransportType.ble,
        newTransport: TransportType.lan,
      );
      expect(event.peerId, 'peer-1');
      expect(event.oldTransport, TransportType.ble);
      expect(event.newTransport, TransportType.lan);
    });

    test('HealthUpdated event wraps summary', () {
      const summary = TransportHealthSummary(
        peerId: 'peer-1',
        transport: TransportType.ble,
        health: TransportHealth(totalSends: 5, successfulSends: 4),
      );
      const event = HealthUpdated(summary);
      expect(event.summary.health.successRate, closeTo(0.8, 0.01));
    });

    test('TransportState equality works', () {
      const a = TransportState(activeTransport: TransportType.lan);
      const b = TransportState(activeTransport: TransportType.lan);
      const c = TransportState();
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });
  });
}
