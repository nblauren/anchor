import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/local_database/database.dart';
import '../../../data/repositories/chat_repository.dart';
import '../../../injection.dart';
import '../bloc/chat_bloc.dart';
import '../bloc/chat_event.dart';
import '../bloc/chat_state.dart';
import 'chat_screen.dart';

/// Screen showing list of all conversations
class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  @override
  void initState() {
    super.initState();
    context.read<ChatBloc>().add(const LoadConversations());
  }

  void _openConversation(ConversationWithPeer conv) {
    final peerName = conv.peer?.name ?? 'Unknown';
    final peerId = conv.conversation.peerId;
    final ownUserId = context.read<ChatBloc>().ownUserId;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BlocProvider<ChatBloc>(
          create: (_) => getIt<ChatBloc>(param1: ownUserId),
          child: ChatScreen(
            peerId: peerId,
            peerName: peerName,
          ),
        ),
      ),
    );
  }

  void _deleteConversation(String conversationId) {
    context.read<ChatBloc>().add(DeleteConversation(conversationId));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Messages'),
      ),
      body: BlocBuilder<ChatBloc, ChatState>(
        builder: (context, state) {
          if (state.status == ChatStatus.loading && state.conversations.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }

          if (state.conversations.isEmpty) {
            return _buildEmptyState();
          }

          return RefreshIndicator(
            onRefresh: () async {
              context.read<ChatBloc>().add(const LoadConversations());
            },
            child: ListView.builder(
              itemCount: state.conversations.length,
              itemBuilder: (context, index) {
                final conv = state.conversations[index];
                return _buildConversationTile(conv);
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.chat_bubble_outline,
            size: 80,
            color: AppTheme.textSecondary,
          ),
          const SizedBox(height: 16),
          Text(
            'No messages yet',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AppTheme.textSecondary,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Start a conversation with someone nearby',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textHint,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildConversationTile(ConversationWithPeer conv) {
    final peer = conv.peer;
    final lastMessage = conv.lastMessage;
    final hasUnread = conv.unreadCount > 0;
    final peerName = peer?.name ?? 'Unknown';

    return Dismissible(
      key: Key(conv.conversation.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: AppTheme.errorColor,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: AppTheme.darkCard,
            title: const Text('Delete Conversation'),
            content: Text('Delete all messages with $peerName?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                style: TextButton.styleFrom(foregroundColor: AppTheme.errorColor),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
      },
      onDismissed: (_) => _deleteConversation(conv.conversation.id),
      child: ListTile(
        leading: _buildAvatar(peerName, peer?.thumbnailData),
        title: Text(
          peerName,
          style: TextStyle(
            fontWeight: hasUnread ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        subtitle: lastMessage != null ? _buildLastMessage(lastMessage, hasUnread) : null,
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              _formatTime(conv.conversation.updatedAt),
              style: TextStyle(
                fontSize: 12,
                color: hasUnread ? AppTheme.primaryColor : AppTheme.textHint,
              ),
            ),
            if (hasUnread) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${conv.unreadCount}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        ),
        onTap: () => _openConversation(conv),
      ),
    );
  }

  Widget _buildAvatar(String name, dynamic thumbnailData) {
    final colorIndex = name.hashCode.abs() % _avatarColors.length;
    final color = _avatarColors[colorIndex];

    if (thumbnailData != null && thumbnailData is List<int> && thumbnailData.isNotEmpty) {
      return CircleAvatar(
        radius: 28,
        backgroundImage: MemoryImage(
          thumbnailData is List<int> ? List<int>.from(thumbnailData) as dynamic : thumbnailData,
        ),
      );
    }

    return CircleAvatar(
      radius: 28,
      backgroundColor: color.withValues(alpha: 0.3),
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : '?',
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 20,
        ),
      ),
    );
  }

  Widget _buildLastMessage(MessageEntry message, bool hasUnread) {
    String preview;
    if (message.contentType == MessageContentType.photo) {
      preview = '📷 Photo';
    } else {
      preview = message.textContent ?? '';
    }

    return Text(
      preview,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: hasUnread ? AppTheme.textPrimary : AppTheme.textSecondary,
      ),
    );
  }

  String _formatTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays == 0) {
      return '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
    } else if (difference.inDays == 1) {
      return 'Yesterday';
    } else if (difference.inDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[dateTime.weekday - 1];
    } else {
      return '${dateTime.day}/${dateTime.month}';
    }
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
