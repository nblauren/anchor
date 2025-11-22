import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_theme.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Messages'),
      ),
      body: BlocBuilder<ChatBloc, ChatState>(
        builder: (context, state) {
          if (state.status == ChatStatus.loading &&
              state.conversations.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }

          if (state.conversations.isEmpty) {
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

          return ListView.builder(
            itemCount: state.conversations.length,
            itemBuilder: (context, index) {
              final conversation = state.conversations[index];
              final hasUnread = conversation.unreadCount > 0;

              return Dismissible(
                key: Key(conversation.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: AppTheme.error,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 16),
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                onDismissed: (_) {
                  context
                      .read<ChatBloc>()
                      .add(DeleteConversation(conversation.id));
                },
                child: ListTile(
                  leading: CircleAvatar(
                    radius: 28,
                    backgroundColor: AppTheme.darkCard,
                    backgroundImage: conversation.participantPhotoUrl != null
                        ? FileImage(File(conversation.participantPhotoUrl!))
                        : null,
                    child: conversation.participantPhotoUrl == null
                        ? const Icon(Icons.person, color: AppTheme.textSecondary)
                        : null,
                  ),
                  title: Text(
                    conversation.participantName,
                    style: TextStyle(
                      fontWeight: hasUnread ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  subtitle: conversation.lastMessage != null
                      ? Text(
                          conversation.lastMessage!.content,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: hasUnread
                                ? AppTheme.textPrimary
                                : AppTheme.textSecondary,
                          ),
                        )
                      : null,
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _formatTime(conversation.updatedAt),
                        style: TextStyle(
                          fontSize: 12,
                          color: hasUnread
                              ? AppTheme.primaryColor
                              : AppTheme.textHint,
                        ),
                      ),
                      if (hasUnread) ...[
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryColor,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${conversation.unreadCount}',
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
                  onTap: () {
                    context.read<ChatBloc>().add(OpenConversation(
                          participantId: conversation.participantId,
                          participantName: conversation.participantName,
                          participantPhotoUrl: conversation.participantPhotoUrl,
                        ));
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const ChatScreen(),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
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
}
