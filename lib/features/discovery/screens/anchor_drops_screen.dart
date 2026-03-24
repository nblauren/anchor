import 'package:anchor/core/theme/app_theme.dart';
import 'package:anchor/data/local_database/database.dart';
import 'package:anchor/data/repositories/anchor_drop_repository.dart';
import 'package:anchor/features/chat/bloc/chat_bloc.dart';
import 'package:anchor/features/chat/bloc/chat_e2ee_bloc.dart';
import 'package:anchor/features/chat/bloc/photo_transfer_bloc.dart';
import 'package:anchor/features/chat/bloc/reaction_bloc.dart';
import 'package:anchor/features/discovery/bloc/discovery_bloc.dart';
import 'package:anchor/features/discovery/bloc/discovery_state.dart';
import 'package:anchor/features/discovery/screens/peer_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Screen showing peers who have dropped anchor on the current user.
class AnchorDropsScreen extends StatefulWidget {
  const AnchorDropsScreen({required this.anchorDropRepository, super.key});

  final AnchorDropRepository anchorDropRepository;

  @override
  State<AnchorDropsScreen> createState() => _AnchorDropsScreenState();
}

class _AnchorDropsScreenState extends State<AnchorDropsScreen> {
  List<AnchorDropEntry>? _drops;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadDrops();
  }

  Future<void> _loadDrops() async {
    final drops = await widget.anchorDropRepository.getReceivedDrops();
    // Deduplicate by peerId, keeping most recent per peer
    final seen = <String>{};
    final unique = <AnchorDropEntry>[];
    for (final drop in drops) {
      if (seen.add(drop.peerId)) {
        unique.add(drop);
      }
    }
    if (mounted) {
      setState(() {
        _drops = unique;
        _loading = false;
      });
    }
  }

  void _openPeerDetail(String peerId, String peerName) {
    final discoveryState = context.read<DiscoveryBloc>().state;
    final peer = discoveryState.peers
        .where((p) => p.peerId == peerId)
        .firstOrNull;

    if (peer != null) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MultiBlocProvider(
            providers: [
              BlocProvider.value(value: context.read<DiscoveryBloc>()),
              BlocProvider.value(value: context.read<ChatBloc>()),
              BlocProvider.value(value: context.read<PhotoTransferBloc>()),
              BlocProvider.value(value: context.read<ChatE2eeBloc>()),
              BlocProvider.value(value: context.read<ReactionBloc>()),
            ],
            child: PeerDetailScreen(peer: peer),
          ),
        ),
      );
    }
  }

  String _timeAgo(DateTime droppedAt) {
    final diff = DateTime.now().difference(droppedAt);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) {
      final m = diff.inMinutes;
      return '$m ${m == 1 ? 'min' : 'mins'} ago';
    }
    if (diff.inHours < 24) {
      final h = diff.inHours;
      return '$h ${h == 1 ? 'hour' : 'hours'} ago';
    }
    final d = diff.inDays;
    return '$d ${d == 1 ? 'day' : 'days'} ago';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Anchor Drops')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _drops == null || _drops!.isEmpty
              ? _buildEmpty()
              : _buildList(),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.anchor_rounded,
            size: 64,
            color: AppTheme.textHint.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          const Text(
            'No anchor drops yet',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            "When someone drops anchor on you,\nthey'll appear here.",
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppTheme.textHint,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    return BlocBuilder<DiscoveryBloc, DiscoveryState>(
      builder: (context, discoveryState) {
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: _drops!.length,
          itemBuilder: (context, index) {
            final drop = _drops![index];
            final peer = discoveryState.peers
                .where((p) => p.peerId == drop.peerId)
                .firstOrNull;
            final isOnline = peer != null && peer.isNearby;

            return ListTile(
              leading: _buildAvatar(peer, isOnline),
              title: Text(
                drop.peerName,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                _timeAgo(drop.droppedAt),
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 13,
                ),
              ),
              trailing: isOnline
                  ? Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4,),
                      decoration: BoxDecoration(
                        color: AppTheme.online.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'Nearby',
                        style: TextStyle(
                          color: AppTheme.online,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  : null,
              onTap: peer != null
                  ? () => _openPeerDetail(drop.peerId, drop.peerName)
                  : null,
            );
          },
        );
      },
    );
  }

  Widget _buildAvatar(DiscoveredPeer? peer, bool isOnline) {
    return Stack(
      children: [
        CircleAvatar(
          radius: 24,
          backgroundColor: AppTheme.darkCard,
          backgroundImage: peer?.thumbnailData != null
              ? MemoryImage(peer!.thumbnailData!)
              : null,
          child: peer?.thumbnailData == null
              ? const Icon(Icons.person, color: AppTheme.textHint)
              : null,
        ),
        Positioned(
          bottom: 0,
          right: 0,
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: AppTheme.primaryColor,
              shape: BoxShape.circle,
              border: Border.all(
                color: AppTheme.darkBackground,
                width: 2,
              ),
            ),
            child: const Center(
              child: Text(
                '\u2693',
                style: TextStyle(fontSize: 10),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
