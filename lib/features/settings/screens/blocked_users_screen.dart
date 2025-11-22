import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/local_database/database.dart';
import '../../../injection.dart';
import '../../../services/database_service.dart';

/// Screen showing list of blocked users with unblock option
class BlockedUsersScreen extends StatefulWidget {
  const BlockedUsersScreen({super.key});

  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
  late final DatabaseService _db;
  List<DiscoveredPeerEntry>? _blockedPeers;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _db = getIt<DatabaseService>();
    _loadBlockedPeers();
  }

  Future<void> _loadBlockedPeers() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final peers = await _db.peerRepository.getBlockedPeerDetails();
      setState(() {
        _blockedPeers = peers;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load blocked users';
        _isLoading = false;
      });
    }
  }

  Future<void> _unblockPeer(DiscoveredPeerEntry peer) async {
    HapticFeedback.selectionClick();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.darkCard,
        title: const Text('Unblock User?'),
        content: Text(
          'Unblock ${peer.name}? They will be able to discover you and send you messages again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Unblock'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _db.peerRepository.unblockPeer(peer.peerId);
        _loadBlockedPeers();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${peer.name} unblocked')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to unblock user')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Blocked Users'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const LoadingWidget(message: 'Loading...');
    }

    if (_error != null) {
      return ErrorStateWidget(
        message: _error!,
        onRetry: _loadBlockedPeers,
      );
    }

    if (_blockedPeers == null || _blockedPeers!.isEmpty) {
      return const EmptyStateWidget(
        icon: Icons.check_circle_outline,
        title: 'No Blocked Users',
        subtitle: 'People you block will appear here.\nThey won\'t be able to discover you or message you.',
      );
    }

    return ListView.builder(
      itemCount: _blockedPeers!.length,
      itemBuilder: (context, index) {
        final peer = _blockedPeers![index];
        return _buildBlockedPeerTile(peer);
      },
    );
  }

  Widget _buildBlockedPeerTile(DiscoveredPeerEntry peer) {
    return ListTile(
      leading: _buildAvatar(peer.name, peer.thumbnailData),
      title: Text(
        peer.name,
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: peer.bio != null
          ? Text(
              peer.bio!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppTheme.textSecondary),
            )
          : null,
      trailing: TextButton(
        onPressed: () => _unblockPeer(peer),
        child: const Text('Unblock'),
      ),
    );
  }

  Widget _buildAvatar(String name, Uint8List? thumbnailData) {
    if (thumbnailData != null && thumbnailData.isNotEmpty) {
      return CircleAvatar(
        radius: 24,
        backgroundImage: MemoryImage(thumbnailData),
      );
    }

    final colorIndex = name.hashCode.abs() % _avatarColors.length;
    final color = _avatarColors[colorIndex];

    return CircleAvatar(
      radius: 24,
      backgroundColor: color.withOpacity(0.3),
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

  static const _avatarColors = [
    Color(0xFF6366F1),
    Color(0xFFEC4899),
    Color(0xFF10B981),
    Color(0xFFF59E0B),
    Color(0xFF3B82F6),
    Color(0xFF8B5CF6),
  ];
}
