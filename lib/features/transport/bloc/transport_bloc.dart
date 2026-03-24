import 'dart:async';

import 'package:anchor/features/transport/bloc/transport_event.dart';
import 'package:anchor/features/transport/bloc/transport_state.dart';
import 'package:anchor/services/transport/transport_enums.dart';
import 'package:anchor/services/transport/transport_health_tracker.dart';
import 'package:anchor/services/transport/transport_manager.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Bloc that exposes transport-layer state to the UI.
///
/// Subscribes to [TransportManager] transport change streams and
/// [TransportHealthTracker] health summaries.
class TransportBloc extends Bloc<TransportEvent, TransportState> {
  TransportBloc({
    required TransportManager transportManager,
    required TransportHealthTracker healthTracker,
  })  : _transportManager = transportManager,
        _healthTracker = healthTracker,
        super(TransportState(
          activeTransport: transportManager.activeTransport,
        ),) {
    on<ActiveTransportChanged>(_onActiveTransportChanged);
    on<PeerTransportUpdated>(_onPeerTransportUpdated);
    on<HealthUpdated>(_onHealthUpdated);

    _activeTransportSub =
        _transportManager.activeTransportStream.listen((transport) {
      add(ActiveTransportChanged(transport));
    });

    _peerTransportSub =
        _transportManager.peerTransportChangedStream.listen((event) {
      add(PeerTransportUpdated(
        peerId: event.peerId,
        oldTransport: event.oldTransport,
        newTransport: event.newTransport,
      ),);
    });

    _healthSub = _healthTracker.healthStream.listen((summary) {
      add(HealthUpdated(summary));
    });
  }

  final TransportManager _transportManager;
  final TransportHealthTracker _healthTracker;

  StreamSubscription<TransportType>? _activeTransportSub;
  StreamSubscription<PeerTransportChanged>? _peerTransportSub;
  StreamSubscription<TransportHealthSummary>? _healthSub;

  void _onActiveTransportChanged(
    ActiveTransportChanged event,
    Emitter<TransportState> emit,
  ) {
    emit(state.copyWith(activeTransport: event.transport));
  }

  void _onPeerTransportUpdated(
    PeerTransportUpdated event,
    Emitter<TransportState> emit,
  ) {
    final updated = Map<String, TransportType>.from(state.peerTransports);
    updated[event.peerId] = event.newTransport;
    emit(state.copyWith(peerTransports: updated));
  }

  void _onHealthUpdated(
    HealthUpdated event,
    Emitter<TransportState> emit,
  ) {
    final summary = event.summary;
    final updated =
        Map<String, Map<TransportType, TransportHealth>>.from(state.peerHealth);
    final peerMap = Map<TransportType, TransportHealth>.from(
        updated[summary.peerId] ?? {},);
    peerMap[summary.transport] = summary.health;
    updated[summary.peerId] = peerMap;
    emit(state.copyWith(peerHealth: updated));
  }

  @override
  Future<void> close() {
    _activeTransportSub?.cancel();
    _peerTransportSub?.cancel();
    _healthSub?.cancel();
    return super.close();
  }
}
