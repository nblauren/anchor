import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../bloc/discovery_state.dart';

/// Grid tile displaying a discovered peer's thumbnail and basic info
class PeerGridTile extends StatelessWidget {
  const PeerGridTile({
    super.key,
    required this.peer,
    required this.onTap,
  });

  final DiscoveredPeer peer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: AppTheme.darkCard,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Thumbnail or placeholder
            _buildThumbnail(),

            // Gradient overlay for text readability
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                height: 80,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.8),
                    ],
                  ),
                ),
              ),
            ),

            // Name and age
            Positioned(
              bottom: 12,
              left: 12,
              right: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          peer.age != null
                              ? '${peer.name}, ${peer.age}'
                              : peer.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // Last seen indicator
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: peer.isRecent
                              ? Colors.greenAccent
                              : peer.isNearby
                                  ? Colors.yellowAccent
                                  : AppTheme.textHint,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        peer.lastSeenText,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Signal strength indicator (top right)
            if (peer.rssi != null)
              Positioned(
                top: 8,
                right: 8,
                child: _buildSignalIndicator(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail() {
    if (peer.thumbnailData != null && peer.thumbnailData!.isNotEmpty) {
      return Image.memory(
        peer.thumbnailData!,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
      );
    }
    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    // Generate a consistent color based on peer name
    final colorIndex = peer.name.hashCode.abs() % _placeholderColors.length;
    final color = _placeholderColors[colorIndex];

    return Container(
      color: color.withValues(alpha: 0.3),
      child: Center(
        child: Text(
          peer.name.isNotEmpty ? peer.name[0].toUpperCase() : '?',
          style: TextStyle(
            color: color,
            fontSize: 48,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildSignalIndicator() {
    final strength = peer.rssi ?? -100;
    final bars = strength >= -50
        ? 4
        : strength >= -60
            ? 3
            : strength >= -70
                ? 2
                : 1;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(4, (index) {
          final isActive = index < bars;
          final height = 4.0 + (index * 3);
          return Container(
            width: 3,
            height: height,
            margin: EdgeInsets.only(left: index > 0 ? 2 : 0),
            decoration: BoxDecoration(
              color: isActive
                  ? (bars >= 3 ? Colors.greenAccent : Colors.yellowAccent)
                  : Colors.white.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(1),
            ),
          );
        }),
      ),
    );
  }

  static const _placeholderColors = [
    Color(0xFF6366F1), // Indigo
    Color(0xFFEC4899), // Pink
    Color(0xFF10B981), // Emerald
    Color(0xFFF59E0B), // Amber
    Color(0xFF3B82F6), // Blue
    Color(0xFF8B5CF6), // Violet
    Color(0xFFEF4444), // Red
    Color(0xFF14B8A6), // Teal
  ];
}
