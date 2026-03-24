import 'package:anchor/services/transport/transport_enums.dart';
import 'package:flutter/material.dart';

/// Small badge showing the active transport type for a peer.
///
/// LAN = green Wi-Fi icon, Wi-Fi Aware = blue Wi-Fi icon,
/// Wi-Fi Direct = purple Wi-Fi icon, BLE = orange Bluetooth icon.
class TransportBadge extends StatelessWidget {
  const TransportBadge({
    required this.transport, super.key,
    this.showLabel = true,
    this.iconSize = 11,
    this.fontSize = 12,
  });

  final TransportType transport;
  final bool showLabel;
  final double iconSize;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = _transportInfo(transport);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: iconSize, color: color),
        if (showLabel) ...[
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(fontSize: fontSize, color: color),
          ),
        ],
      ],
    );
  }

  static (IconData, Color, String) _transportInfo(TransportType transport) {
    switch (transport) {
      case TransportType.lan:
        return (Icons.wifi, Colors.greenAccent, 'LAN');
      case TransportType.wifiAware:
        return (Icons.wifi, Colors.lightBlueAccent, 'Wi-Fi Aware');
      case TransportType.wifiDirect:
        return (Icons.wifi, Colors.purpleAccent, 'Wi-Fi Direct');
      case TransportType.ble:
        return (Icons.bluetooth, Colors.orangeAccent, 'Bluetooth');
    }
  }
}
