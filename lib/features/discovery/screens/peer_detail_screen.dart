import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_theme.dart';
import '../../chat/bloc/chat_bloc.dart';
import '../../chat/bloc/chat_e2ee_bloc.dart';
import '../../chat/bloc/conversation_list_bloc.dart';
import '../../chat/bloc/photo_transfer_bloc.dart';
import '../../chat/bloc/reaction_bloc.dart';
import '../../chat/screens/chat_screen.dart';
import '../bloc/anchor_drop_bloc.dart';
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
  bool _isFetchingPhotos = false;
  bool _anchorDropped = false;

  @override
  void initState() {
    super.initState();
    _peer = widget.peer;

    // Sync anchor drop state from bloc
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final dropped = context
            .read<AnchorDropBloc>()
            .state
            .droppedAnchorPeerIds
            .contains(_peer.peerId);
        if (dropped) setState(() => _anchorDropped = true);
      }
    });

    // Trigger full-photo fetch when the detail screen opens for a direct peer
    // that has extra photos not yet loaded.
    if (!widget.peer.isRelayed && widget.peer.fullPhotoCount > 1) {
      _isFetchingPhotos = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          context
              .read<DiscoveryBloc>()
              .add(FetchPeerFullPhotos(widget.peer.peerId));
        }
      });
    }
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
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
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

  void _dropAnchor() {
    context.read<AnchorDropBloc>().add(
          DropAnchor(peerId: _peer.peerId, peerName: _peer.name),
        );
    setState(() => _anchorDropped = true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Anchor dropped on ${_peer.name}! \u2693'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _openChat() async {
    final chatBloc = context.read<ChatBloc>();
    final e2eeBloc = context.read<ChatE2eeBloc>();
    final photoTransferBloc = context.read<PhotoTransferBloc>();
    final reactionBloc = context.read<ReactionBloc>();

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MultiBlocProvider(
          providers: [
            BlocProvider.value(value: chatBloc),
            BlocProvider.value(value: e2eeBloc),
            BlocProvider.value(value: photoTransferBloc),
            BlocProvider.value(value: reactionBloc),
          ],
          child: ChatScreen(
            peerId: _peer.peerId,
            peerName: _peer.name,
            peerThumbnail: _peer.thumbnailData,
            isRelayedPeer: _peer.isRelayed,
            hopCount: _peer.hopCount,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<DiscoveryBloc, DiscoveryState>(
      // Keep _peer in sync as BLE delivers bio, thumbnail, full photos, etc.
      listenWhen: (_, state) =>
          state.peers.any((p) => p.peerId == _peer.peerId),
      listener: (context, state) {
        final updated = state.peers.firstWhere((p) => p.peerId == _peer.peerId);
        if (updated != _peer) {
          setState(() {
            _peer = updated;
            // Stop the loading indicator once full photos have arrived.
            if (_isFetchingPhotos &&
                updated.photoThumbnails != null &&
                updated.photoThumbnails!.length > 1) {
              _isFetchingPhotos = false;
            }
          });
        }
      },
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            // Fullscreen photo carousel with app bar
            SliverAppBar(
              expandedHeight: MediaQuery.of(context).size.height,
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
                          Icon(Icons.block, color: AppTheme.error),
                          SizedBox(width: 12),
                          Text('Block user'),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),

            // Scrollable content below the fold
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Signal strength
                    if (_peer.signalStrengthText != null) ...[
                      Row(
                        children: [
                          const Icon(
                            Icons.signal_cellular_alt,
                            size: 16,
                            color: AppTheme.textSecondary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${_peer.signalStrengthText} signal',
                            style: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                    ],

                    // About section
                    Text(
                      'About',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _peer.bio?.isNotEmpty == true ? _peer.bio! : 'No bio yet',
                      style: TextStyle(
                        color: _peer.bio?.isNotEmpty == true
                            ? AppTheme.textPrimary
                            : AppTheme.textHint,
                        fontSize: 16,
                        height: 1.5,
                      ),
                    ),

                    // ── Position & Interests ────
                    if (_peer.positionLabel != null ||
                        _peer.interestLabels.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      const Divider(),
                      const SizedBox(height: 16),
                    ],

                    // Position
                    if (_peer.positionLabel != null) ...[
                      Row(
                        children: [
                          const Icon(Icons.swap_vert_rounded,
                              size: 18, color: AppTheme.textSecondary),
                          const SizedBox(width: 8),
                          Text(
                            'Position',
                            style: Theme.of(context)
                                .textTheme
                                .labelMedium
                                ?.copyWith(color: AppTheme.textSecondary),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryLight.withAlpha(26),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color: AppTheme.primaryLight.withAlpha(77)),
                        ),
                        child: Text(
                          _peer.positionLabel!,
                          style: const TextStyle(
                            color: AppTheme.primaryLight,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // Interests
                    if (_peer.interestLabels.isNotEmpty) ...[
                      Row(
                        children: [
                          const Icon(Icons.interests_outlined,
                              size: 18, color: AppTheme.textSecondary),
                          const SizedBox(width: 8),
                          Text(
                            'Interests',
                            style: Theme.of(context)
                                .textTheme
                                .labelMedium
                                ?.copyWith(color: AppTheme.textSecondary),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: _peer.interestLabels.map((label) {
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: AppTheme.darkCard,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: Text(
                              label,
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 16),
                    ],

                    SizedBox(
                        height: MediaQuery.of(context).padding.bottom + 32),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Returns all available photo thumbnails for this peer in display order.
  List<Uint8List> get _photos {
    if (_peer.photoThumbnails != null && _peer.photoThumbnails!.isNotEmpty) {
      return _peer.photoThumbnails!;
    }
    if (_peer.thumbnailData != null && _peer.thumbnailData!.isNotEmpty) {
      return [_peer.thumbnailData!];
    }
    return [];
  }

  Widget _buildBottomOverlay() {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(20, 40, 72, 24 + bottomPadding),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              Colors.black.withValues(alpha: 0.8),
              Colors.black.withValues(alpha: 0.4),
              Colors.transparent,
            ],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Name and age
            Text(
              _peer.age != null ? '${_peer.name}, ${_peer.age}' : _peer.name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            // Online status badge
            Row(
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
                    fontSize: 13,
                    color: _peer.isRecent
                        ? Colors.greenAccent
                        : _peer.isNearby
                            ? Colors.yellowAccent
                            : Colors.white70,
                  ),
                ),
              ],
            ),
            // Bio preview
            if (_peer.bio?.isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Text(
                _peer.bio!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons() {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    return Positioned(
      right: 12,
      bottom: 100 + bottomPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          BlocBuilder<ConversationListBloc, ConversationListState>(
            builder: (context, convState) {
              final unread = convState.conversations
                  .where((c) => c.conversation.peerId == _peer.peerId)
                  .fold(0, (sum, c) => sum + c.unreadCount);
              return _ActionIconButton(
                icon: Icons.chat_bubble_outline,
                label: 'Message',
                onPressed: _openChat,
                badgeCount: unread,
              );
            },
          ),
          const SizedBox(height: 16),
          _ActionIconButton(
            icon: Icons.anchor,
            label: _anchorDropped ? 'Anchored!' : 'Anchor',
            onPressed: _anchorDropped ? null : _dropAnchor,
            color: _anchorDropped ? const Color(0xFFEC4899) : null,
          ),
          const SizedBox(height: 16),
          _ActionIconButton(
            icon: Icons.block,
            label: 'Block',
            onPressed: _showBlockConfirmation,
            color: AppTheme.error,
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoCarousel() {
    // Relayed peers: only show photos if we received a small thumbnail (≤20 KB).
    // Full photo data is gated to direct range.
    if (_peer.isRelayed) {
      final thumb = _peer.thumbnailData;
      if (thumb != null &&
          thumb.isNotEmpty &&
          thumb.lengthInBytes <= 20 * 1024) {
        return Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(thumb,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildRelayedPhotoPlaceholder()),
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
            _buildBottomOverlay(),
            _buildActionButtons(),
          ],
        );
      }
      return Stack(
        fit: StackFit.expand,
        children: [
          _buildRelayedPhotoPlaceholder(),
          _buildBottomOverlay(),
          _buildActionButtons(),
        ],
      );
    }

    final photos = _photos;

    if (photos.isEmpty) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _buildPlaceholder(),
          _buildBottomOverlay(),
          _buildActionButtons(),
        ],
      );
    }

    // Determine how many slots to show: loaded + pending fetches
    final totalSlots =
        (_isFetchingPhotos && _peer.fullPhotoCount > photos.length)
            ? _peer.fullPhotoCount
            : photos.length;

    return Stack(
      fit: StackFit.expand,
      children: [
        PageView.builder(
          controller: _pageController,
          onPageChanged: (index) => setState(() => _currentPhotoIndex = index),
          itemCount: totalSlots,
          itemBuilder: (context, index) {
            if (index < photos.length) {
              return Image.memory(
                photos[index],
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    _buildPlaceholder(),
              );
            }
            // Placeholder for photos still loading from fff4
            return _buildPhotoLoadingPlaceholder();
          },
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

        // Bottom overlay with name, status, bio
        _buildBottomOverlay(),

        // Page indicator (above the overlay)
        if (totalSlots > 1)
          Positioned(
            bottom: 160,
            left: 0,
            right: 0,
            child: _buildPageIndicator(totalSlots),
          ),

        // Vertical action buttons on right
        _buildActionButtons(),
      ],
    );
  }

  Widget _buildRelayedPhotoPlaceholder() {
    final colorIndex = _peer.name.hashCode.abs() % _placeholderColors.length;
    final color = _placeholderColors[colorIndex];

    return Container(
      color: color.withValues(alpha: 0.15),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _peer.name.isNotEmpty ? _peer.name[0].toUpperCase() : '?',
                  style: TextStyle(
                    color: color.withValues(alpha: 0.5),
                    fontSize: 80,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.hub_outlined, size: 14, color: Colors.white70),
                      SizedBox(width: 6),
                      Text(
                        'Get closer to see photos',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
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

  Widget _buildPhotoLoadingPlaceholder() {
    final colorIndex = _peer.name.hashCode.abs() % _placeholderColors.length;
    final color = _placeholderColors[colorIndex];
    return Container(
      color: color.withValues(alpha: 0.12),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white54),
            ),
            SizedBox(height: 12),
            Text(
              'Loading photo…',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ],
        ),
      ),
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

  Widget _buildPageIndicator(int count) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (index) {
        final isActive = index == _currentPhotoIndex;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: isActive ? 20 : 8,
          height: 8,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            color:
                isActive ? Colors.white : Colors.white.withValues(alpha: 0.4),
          ),
        );
      }),
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

/// A circular icon button with a label beneath it, used in the profile action row.
class _ActionIconButton extends StatelessWidget {
  const _ActionIconButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
    this.badgeCount = 0,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color? color;
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = onPressed == null
        ? color ?? AppTheme.primaryLight
        : color ?? AppTheme.primaryLight;
    final dimmed = onPressed == null;

    return GestureDetector(
      onTap: onPressed,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Badge(
            isLabelVisible: badgeCount > 0,
            backgroundColor: AppTheme.primaryColor,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            label: Text(
              '$badgeCount',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: dimmed ? 0.3 : 0.5),
                shape: BoxShape.circle,
                border: Border.all(
                  color: effectiveColor.withValues(alpha: dimmed ? 0.2 : 0.6),
                  width: 1.5,
                ),
              ),
              child: Icon(
                icon,
                color: effectiveColor.withValues(alpha: dimmed ? 0.4 : 1.0),
                size: 24,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withValues(alpha: dimmed ? 0.4 : 0.9),
              fontWeight: FontWeight.w600,
              shadows: const [
                Shadow(
                  blurRadius: 4,
                  color: Colors.black,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
