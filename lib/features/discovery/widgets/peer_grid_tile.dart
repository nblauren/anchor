import 'package:anchor/core/theme/app_theme.dart';
import 'package:anchor/features/discovery/bloc/discovery_state.dart';
import 'package:flutter/material.dart';

/// Grid tile displaying a discovered peer's thumbnail and basic info
class PeerGridTile extends StatelessWidget {
  const PeerGridTile({
    required this.peer, required this.onTap, super.key,
    this.unreadCount = 0,
    this.anchorDropped = false,
  });

  final DiscoveredPeer peer;
  final VoidCallback onTap;
  final int unreadCount;
  /// Whether anchor has been dropped on this peer — shows a ⚓ badge
  final bool anchorDropped;

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
            // Thumbnail or placeholder (greyed out when not recently seen)
            if (!peer.isNearby)
              ColorFiltered(
                colorFilter: const ColorFilter.mode(
                  Colors.grey,
                  BlendMode.saturation,
                ),
                child: _buildThumbnail(),
              )
            else
              _buildThumbnail(),

            // Dark overlay for peers not seen recently
            if (!peer.isNearby)
              Positioned.fill(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.4),
                ),
              ),

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
                  // Distance / relay badge
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: _badgeColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _distanceBadge,
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

            // Signal strength indicator (top right) — direct peers recently seen
            if (peer.rssi != null && peer.isRecent)
              Positioned(
                top: 8,
                right: 8,
                child: _buildSignalIndicator(),
              ),

            // Mesh relay indicator (top right) — relayed peers only
            if (peer.isRelayed)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.hub_outlined, size: 11, color: Colors.white70),
                      SizedBox(width: 3),
                      Text(
                        'Relay',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Unread message badge (top left)
            if (unreadCount > 0)
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.chat_bubble,
                        size: 10,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '$unreadCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Anchor dropped badge (bottom-right, above name area)
            if (anchorDropped)
              Positioned(
                bottom: 52,
                right: 6,
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEC4899).withValues(alpha: 0.9),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.anchor,
                    size: 14,
                    color: Colors.white,
                  ),
                ),
              ),

            // Multi-photo badge (bottom-right of thumbnail area) — shown for
            // direct peers with extra photos not yet fetched.
            if (!peer.isRelayed &&
                peer.fullPhotoCount > 1 &&
                (peer.photoThumbnails == null || peer.photoThumbnails!.length < 2))
              Positioned(
                bottom: 48, // above the name row
                right: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.photo_library_outlined,
                          size: 10, color: Colors.white70,),
                      const SizedBox(width: 3),
                      Text(
                        '+${peer.fullPhotoCount - 1}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
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
        gaplessPlayback: true,
        // Decode to grid tile resolution instead of full image size.
        // Grid tiles are ~180x220 logical pixels; 2x for retina = 360x440.
        // This cuts decode time significantly for large thumbnails.
        cacheWidth: 360,
        cacheHeight: 440,
        errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
      );
    }
    if (peer.isRelayed) {
      return _buildRelayedPlaceholder();
    }
    return _buildPlaceholder();
  }

  Widget _buildRelayedPlaceholder() {
    final colorIndex = peer.name.hashCode.abs() % _placeholderColors.length;
    final color = _placeholderColors[colorIndex];

    return ColoredBox(
      color: color.withValues(alpha: 0.15),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Text(
              peer.name.isNotEmpty ? peer.name[0].toUpperCase() : '?',
              style: TextStyle(
                color: color.withValues(alpha: 0.4),
                fontSize: 48,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 44),
              child: Text(
                'Get closer\nto see photo',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 9,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder() {
    // Generate a consistent color based on peer name
    final colorIndex = peer.name.hashCode.abs() % _placeholderColors.length;
    final color = _placeholderColors[colorIndex];

    return ColoredBox(
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

  /// Human-readable status label using time-based proximity, matching
  /// PeerDetailScreen's status display for consistency.
  String get _distanceBadge {
    if (peer.isRelayed) return 'Via mesh';
    if (peer.isRecent) {
      // Seen within 60s — show signal-based distance if available
      final rssi = peer.rssi;
      if (rssi == null) return 'Just now';
      if (rssi >= -55) return 'Close';
      if (rssi >= -70) return 'Nearby';
      return 'In range';
    }
    // Not seen recently — show last-seen timestamp
    return peer.lastSeenText;
  }

  Color get _badgeColor {
    if (peer.isRelayed) return const Color(0xFF818CF8); // indigo for relay
    if (peer.isRecent) return Colors.greenAccent;
    if (peer.isNearby) return Colors.yellowAccent;
    return Colors.grey;
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
