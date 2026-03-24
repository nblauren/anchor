import 'package:anchor/services/transport/transport_enums.dart';
import 'package:anchor/services/transport/transport_health_tracker.dart';
import 'package:equatable/equatable.dart';

class TransportState extends Equatable {
  const TransportState({
    this.activeTransport = TransportType.ble,
    this.peerTransports = const {},
    this.peerHealth = const {},
  });

  /// The global best transport (highest-priority currently available).
  final TransportType activeTransport;

  /// Best transport per peer.
  final Map<String, TransportType> peerTransports;

  /// Latest health snapshot per peer + transport.
  final Map<String, Map<TransportType, TransportHealth>> peerHealth;

  /// Get the transport for a specific peer, falling back to BLE (the baseline
  /// transport that all peers share). We intentionally do NOT fall back to
  /// [activeTransport] because that reflects what the *local* device supports,
  /// not what the *peer* supports (e.g. local device has Wi-Fi Aware but peer
  /// may only be reachable via BLE).
  TransportType transportForPeer(String peerId) =>
      peerTransports[peerId] ?? TransportType.ble;

  TransportState copyWith({
    TransportType? activeTransport,
    Map<String, TransportType>? peerTransports,
    Map<String, Map<TransportType, TransportHealth>>? peerHealth,
  }) {
    return TransportState(
      activeTransport: activeTransport ?? this.activeTransport,
      peerTransports: peerTransports ?? this.peerTransports,
      peerHealth: peerHealth ?? this.peerHealth,
    );
  }

  @override
  List<Object?> get props => [activeTransport, peerTransports, peerHealth];
}
