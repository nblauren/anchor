import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../bloc/discovery_state.dart';

/// Bottom sheet listing discovered peers within a specific radar ring zone.
/// Shown when the user taps a ring or dot cluster on the [RadarView].
class RadarPeerSheet extends StatelessWidget {
  const RadarPeerSheet({
    super.key,
    required this.ringLabel,
    required this.ringColor,
    required this.peers,
    required this.onPeerTap,
  });

  final String ringLabel;
  final Color ringColor;
  final List<DiscoveredPeer> peers;
  final ValueChanged<DiscoveredPeer> onPeerTap;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      builder: (_, controller) {
        return Column(
          children: [
            // Handle + header
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Column(
                children: [
                  // Drag handle
                  Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  // Zone label
                  Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: ringColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        ringLabel,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: ringColor.withAlpha(38),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${peers.length} ${peers.length == 1 ? 'person' : 'people'}',
                          style: TextStyle(
                            color: ringColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: Colors.white12),
                ],
              ),
            ),

            // Peer list
            Expanded(
              child: ListView.builder(
                controller: controller,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                itemCount: peers.length,
                itemBuilder: (context, index) {
                  final peer = peers[index];
                  return _PeerListTile(
                    peer: peer,
                    ringColor: ringColor,
                    onTap: () => onPeerTap(peer),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PeerListTile extends StatelessWidget {
  const _PeerListTile({
    required this.peer,
    required this.ringColor,
    required this.onTap,
  });

  final DiscoveredPeer peer;
  final Color ringColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.darkCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            // Avatar / initial
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: ringColor.withAlpha(40),
                shape: BoxShape.circle,
                border: Border.all(color: ringColor.withAlpha(100), width: 1.5),
              ),
              child: peer.thumbnailData != null
                  ? ClipOval(
                      child: Image.memory(
                        peer.thumbnailData!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            _initial(peer.name, ringColor),
                      ),
                    )
                  : _initial(peer.name, ringColor),
            ),
            const SizedBox(width: 12),

            // Name + info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    peer.age != null
                        ? '${peer.name}, ${peer.age}'
                        : peer.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (peer.isRelayed) ...[
                        Icon(Icons.hub_outlined,
                            size: 11, color: ringColor.withAlpha(180)),
                        const SizedBox(width: 3),
                        Text(
                          '${peer.hopCount} hop${peer.hopCount == 1 ? '' : 's'}',
                          style: TextStyle(
                              fontSize: 11,
                              color: AppTheme.textHint),
                        ),
                      ] else if (peer.rssi != null) ...[
                        Icon(Icons.signal_cellular_alt,
                            size: 11, color: ringColor.withAlpha(180)),
                        const SizedBox(width: 3),
                        Text(
                          '${peer.rssi} dBm · ${peer.signalStrengthText ?? ''}',
                          style: const TextStyle(
                              fontSize: 11, color: AppTheme.textHint),
                        ),
                      ],
                      const Spacer(),
                      Text(
                        peer.lastSeenText,
                        style: const TextStyle(
                            fontSize: 11, color: AppTheme.textHint),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(width: 8),
            const Icon(Icons.chevron_right,
                size: 18, color: AppTheme.textHint),
          ],
        ),
      ),
    );
  }

  Widget _initial(String name, Color color) {
    return Center(
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : '?',
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 18,
        ),
      ),
    );
  }
}
