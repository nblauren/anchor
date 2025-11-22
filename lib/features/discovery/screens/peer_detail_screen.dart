import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_theme.dart';
import '../../../injection.dart';
import '../../chat/bloc/chat_bloc.dart';
import '../../chat/screens/chat_screen.dart';
import '../../profile/bloc/profile_bloc.dart';
import '../../profile/bloc/profile_state.dart';
import '../bloc/discovery_bloc.dart';
import '../bloc/discovery_event.dart';
import '../bloc/discovery_state.dart';

/// Screen displaying detailed view of a discovered peer
class PeerDetailScreen extends StatefulWidget {
  const PeerDetailScreen({
    super.key,
    required this.peer,
  });

  final DiscoveredPeer peer;

  @override
  State<PeerDetailScreen> createState() => _PeerDetailScreenState();
}

class _PeerDetailScreenState extends State<PeerDetailScreen> {
  late DiscoveredPeer _peer;
  final PageController _pageController = PageController();
  int _currentPhotoIndex = 0;

  @override
  void initState() {
    super.initState();
    _peer = widget.peer;
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _showBlockConfirmation() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.darkCard,
        title: const Text('Block User'),
        content: Text(
          'Are you sure you want to block ${_peer.name}? '
          'You won\'t see them in discovery and they won\'t be able to message you.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _blockPeer();
            },
            style: TextButton.styleFrom(foregroundColor: AppTheme.errorColor),
            child: const Text('Block'),
          ),
        ],
      ),
    );
  }

  void _blockPeer() {
    context.read<DiscoveryBloc>().add(BlockPeer(_peer.peerId));
    Navigator.pop(context); // Go back to discovery
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${_peer.name} has been blocked')),
    );
  }

  void _openChat() {
    // Get the current user's profile ID for ChatBloc
    final profileState = context.read<ProfileBloc>().state;
    final ownUserId = profileState.profileId ?? '';

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BlocProvider<ChatBloc>(
          create: (_) => getIt<ChatBloc>(param1: ownUserId),
          child: ChatScreen(
            peerId: _peer.peerId,
            peerName: _peer.name,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // Photo carousel with app bar
          SliverAppBar(
            expandedHeight: MediaQuery.of(context).size.height * 0.5,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              background: _buildPhotoCarousel(),
            ),
            actions: [
              // More options menu
              PopupMenuButton<String>(
                icon: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.3),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.more_vert, color: Colors.white),
                ),
                onSelected: (value) {
                  if (value == 'block') {
                    _showBlockConfirmation();
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'block',
                    child: Row(
                      children: [
                        Icon(Icons.block, color: AppTheme.errorColor),
                        SizedBox(width: 12),
                        Text('Block user'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),

          // Profile info
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Name and age
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _peer.age != null
                              ? '${_peer.name}, ${_peer.age}'
                              : _peer.name,
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                      ),
                      // Online indicator
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: _peer.isRecent
                              ? Colors.greenAccent.withValues(alpha: 0.2)
                              : _peer.isNearby
                                  ? Colors.yellowAccent.withValues(alpha: 0.2)
                                  : AppTheme.textHint.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: _peer.isRecent
                                    ? Colors.greenAccent
                                    : _peer.isNearby
                                        ? Colors.yellowAccent
                                        : AppTheme.textHint,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _peer.lastSeenText,
                              style: TextStyle(
                                fontSize: 12,
                                color: _peer.isRecent
                                    ? Colors.greenAccent
                                    : _peer.isNearby
                                        ? Colors.yellowAccent
                                        : AppTheme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  // Signal strength
                  if (_peer.signalStrengthText != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          Icons.signal_cellular_alt,
                          size: 16,
                          color: AppTheme.textSecondary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${_peer.signalStrengthText} signal',
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ],

                  const SizedBox(height: 20),
                  const Divider(),
                  const SizedBox(height: 20),

                  // Bio section
                  Text(
                    'About',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _peer.bio?.isNotEmpty == true
                        ? _peer.bio!
                        : 'No bio yet',
                    style: TextStyle(
                      color: _peer.bio?.isNotEmpty == true
                          ? AppTheme.textPrimary
                          : AppTheme.textHint,
                      fontSize: 16,
                      height: 1.5,
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Action buttons
                  Row(
                    children: [
                      // Message button
                      Expanded(
                        flex: 2,
                        child: ElevatedButton.icon(
                          onPressed: _openChat,
                          icon: const Icon(Icons.chat_bubble_outline),
                          label: const Text('Message'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Block button
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _showBlockConfirmation,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.errorColor,
                            side: const BorderSide(color: AppTheme.errorColor),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: const Icon(Icons.block),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 100), // Bottom padding
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoCarousel() {
    // For now, we only have thumbnail data (single image)
    // In future, this would show multiple photos received via BLE
    final hasPhoto = _peer.thumbnailData != null && _peer.thumbnailData!.isNotEmpty;

    if (!hasPhoto) {
      return _buildPlaceholder();
    }

    // Single photo for now - PageView ready for multiple
    return Stack(
      fit: StackFit.expand,
      children: [
        PageView.builder(
          controller: _pageController,
          onPageChanged: (index) {
            setState(() {
              _currentPhotoIndex = index;
            });
          },
          itemCount: 1, // Would be photos.length when we have multiple
          itemBuilder: (context, index) {
            return Image.memory(
              _peer.thumbnailData!,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
            );
          },
        ),

        // Page indicator (shown when multiple photos)
        // Positioned(
        //   bottom: 20,
        //   left: 0,
        //   right: 0,
        //   child: _buildPageIndicator(photoCount),
        // ),

        // Gradient for back button visibility
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            height: 100,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.5),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPlaceholder() {
    // Generate a consistent color based on peer name
    final colorIndex = _peer.name.hashCode.abs() % _placeholderColors.length;
    final color = _placeholderColors[colorIndex];

    return Container(
      color: color.withValues(alpha: 0.3),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Text(
              _peer.name.isNotEmpty ? _peer.name[0].toUpperCase() : '?',
              style: TextStyle(
                color: color,
                fontSize: 120,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          // Gradient for back button visibility
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 100,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.5),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // For future use when we have multiple photos
  // Widget _buildPageIndicator(int count) {
  //   return Row(
  //     mainAxisAlignment: MainAxisAlignment.center,
  //     children: List.generate(count, (index) {
  //       return Container(
  //         width: 8,
  //         height: 8,
  //         margin: const EdgeInsets.symmetric(horizontal: 4),
  //         decoration: BoxDecoration(
  //           shape: BoxShape.circle,
  //           color: index == _currentPhotoIndex
  //               ? Colors.white
  //               : Colors.white.withValues(alpha: 0.4),
  //         ),
  //       );
  //     }),
  //   );
  // }

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
