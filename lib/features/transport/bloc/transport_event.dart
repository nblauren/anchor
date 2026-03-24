import 'package:anchor/services/transport/transport_enums.dart';
import 'package:anchor/services/transport/transport_health_tracker.dart';
import 'package:equatable/equatable.dart';

abstract class TransportEvent extends Equatable {
  const TransportEvent();

  @override
  List<Object?> get props => [];
}

/// Global active transport changed.
class ActiveTransportChanged extends TransportEvent {
  const ActiveTransportChanged(this.transport);
  final TransportType transport;

  @override
  List<Object?> get props => [transport];
}

/// A specific peer's best transport changed.
class PeerTransportUpdated extends TransportEvent {
  const PeerTransportUpdated({
    required this.peerId,
    required this.oldTransport,
    required this.newTransport,
  });

  final String peerId;
  final TransportType? oldTransport;
  final TransportType newTransport;

  @override
  List<Object?> get props => [peerId, oldTransport, newTransport];
}

/// Health metrics updated for a peer + transport.
class HealthUpdated extends TransportEvent {
  const HealthUpdated(this.summary);
  final TransportHealthSummary summary;

  @override
  List<Object?> get props => [summary];
}
