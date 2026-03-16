/// Transport layer type used for peer communication.
enum TransportType {
  /// LAN (ship Wi-Fi local network) — highest bandwidth, ship-wide range,
  /// works on both iOS and Android. Uses pure dart:io sockets.
  lan,

  /// Wi-Fi Aware (NAN) — high bandwidth, lower latency, Android only.
  wifiAware,

  /// Wi-Fi Direct (Nearby Connections / Multipeer Connectivity) — high-speed
  /// photo transfer, works on both iOS and Android without pairing.
  wifiDirect,

  /// Bluetooth Low Energy — universal fallback, lower bandwidth.
  ble,
}

/// Emitted when a peer's best available transport changes (e.g. LAN drops,
/// falls back to BLE).
class PeerTransportChanged {
  const PeerTransportChanged({
    required this.peerId,
    required this.oldTransport,
    required this.newTransport,
  });

  final String peerId;
  final TransportType? oldTransport;
  final TransportType newTransport;
}
