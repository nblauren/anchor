/// Transport layer type used for peer communication.
enum TransportType {
  /// Wi-Fi Aware (NAN) — high bandwidth, lower latency, Android only.
  wifiAware,

  /// Wi-Fi Direct (Nearby Connections / Multipeer Connectivity) — high-speed
  /// photo transfer, works on both iOS and Android without pairing.
  wifiDirect,

  /// Bluetooth Low Energy — universal fallback, lower bandwidth.
  ble,
}
