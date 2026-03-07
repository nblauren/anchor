import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/theme/app_theme.dart';
import '../bloc/chat_bloc.dart';
import '../bloc/chat_event.dart';
import '../bloc/chat_state.dart';
import '../widgets/message_bubble_widget.dart';

/// Screen for individual chat conversation
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.peerId,
    required this.peerName,
    this.peerThumbnail,
    this.onViewProfile,
    this.isRelayedPeer = false,
  });

  final String peerId;
  final String peerName;
  final Uint8List? peerThumbnail;
  final VoidCallback? onViewProfile;
  /// Whether this peer is only reachable via mesh relay (not direct BLE).
  final bool isRelayedPeer;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _imagePicker = ImagePicker();
  late final ChatBloc _chatBloc;

  @override
  void initState() {
    super.initState();
    _chatBloc = context.read<ChatBloc>();
    // Open conversation for this peer (marks messages as read automatically)
    _chatBloc.add(OpenConversation(
          peerId: widget.peerId,
          peerName: widget.peerName,
        ));

    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 200) {
        final state = context.read<ChatBloc>().state;
        if (state.hasMoreMessages && state.status != ChatStatus.loading) {
          context.read<ChatBloc>().add(const LoadMessages(loadMore: true));
        }
      }
    });
  }

  @override
  void dispose() {
    _chatBloc.add(const CloseConversation());
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _sendMessage() {
    final content = _messageController.text.trim();
    if (content.isNotEmpty) {
      context.read<ChatBloc>().add(SendTextMessage(content));
      _messageController.clear();
    }
  }

  void _showPhotoOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.darkCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.textHint,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Take Photo'),
              onTap: () {
                Navigator.pop(context);
                _pickPhoto(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose from Gallery'),
              onTap: () {
                Navigator.pop(context);
                _pickPhoto(ImageSource.gallery);
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Future<void> _pickPhoto(ImageSource source) async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 80,
      );

      if (image != null && mounted) {
        context.read<ChatBloc>().add(SendPhotoMessage(image.path));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to pick photo')),
      );
    }
  }

  void _retryMessage(String messageId) {
    context.read<ChatBloc>().add(RetryFailedMessage(messageId));
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ChatBloc, ChatState>(
      listener: (context, state) {
        if (state.errorMessage != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(state.errorMessage!)),
          );
          context.read<ChatBloc>().add(const ClearChatError());
        }
      },
      builder: (context, state) {
        final conversation = state.currentConversation;
        final ownUserId = context.read<ChatBloc>().ownUserId;

        return Scaffold(
          appBar: AppBar(
            title: GestureDetector(
              onTap: widget.onViewProfile,
              child: Row(
                children: [
                  _buildAvatar(conversation?.peerName ?? '?', widget.peerThumbnail),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          conversation?.peerName ?? widget.peerName,
                          style: const TextStyle(fontSize: 16),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (widget.isRelayedPeer)
                          const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.hub_outlined,
                                  size: 11, color: AppTheme.textSecondary),
                              SizedBox(width: 3),
                              Text(
                                'Via relay',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                            ],
                          )
                        else if (widget.onViewProfile != null)
                          const Text(
                            'Tap for info',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.more_vert),
                onPressed: () {
                  // Show chat options
                },
              ),
            ],
          ),
          body: Column(
            children: [
              // Messages list
              Expanded(
                child: state.messages.isEmpty
                    ? _buildEmptyState()
                    : ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        itemCount: state.messages.length,
                        itemBuilder: (context, index) {
                          final message = state.messages[index];
                          final isSentByMe = message.senderId == ownUserId;
                          final showDate = index == state.messages.length - 1 ||
                              !_isSameDay(
                                message.createdAt,
                                state.messages[index + 1].createdAt,
                              );

                          return Column(
                            children: [
                              if (showDate)
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 16),
                                  child: Text(
                                    _formatDate(message.createdAt),
                                    style: const TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              MessageBubbleWidget(
                                message: message,
                                isSentByMe: isSentByMe,
                                onRetry: () => _retryMessage(message.id),
                                isRelayedPeer: widget.isRelayedPeer,
                              ),
                            ],
                          );
                        },
                      ),
              ),

              // Message input
              _buildMessageInput(state),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAvatar(String name, Uint8List? thumbnail) {
    if (thumbnail != null && thumbnail.isNotEmpty) {
      return CircleAvatar(
        radius: 18,
        backgroundImage: MemoryImage(thumbnail),
      );
    }

    final colorIndex = name.hashCode.abs() % _avatarColors.length;
    final color = _avatarColors[colorIndex];

    return CircleAvatar(
      radius: 18,
      backgroundColor: color.withValues(alpha: 0.3),
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : '?',
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 16,
        ),
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
            size: 64,
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
            'Say hello to ${widget.peerName}!',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textHint,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageInput(ChatState state) {
    final isSending = state.status == ChatStatus.sending;

    return Container(
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      decoration: const BoxDecoration(
        color: AppTheme.darkSurface,
        border: Border(
          top: BorderSide(color: AppTheme.darkCard),
        ),
      ),
      child: Row(
        children: [
          // Photo button
          IconButton(
            onPressed: isSending ? null : _showPhotoOptions,
            icon: const Icon(Icons.photo),
            color: AppTheme.textSecondary,
          ),

          // Text input
          Expanded(
            child: TextField(
              controller: _messageController,
              decoration: InputDecoration(
                hintText: 'Type a message...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: AppTheme.darkCard,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
              textCapitalization: TextCapitalization.sentences,
              maxLines: 4,
              minLines: 1,
              onTapOutside: (PointerDownEvent event) {
                FocusManager.instance.primaryFocus?.unfocus();
              },
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          const SizedBox(width: 4),

          // Send button
          IconButton(
            onPressed: isSending ? null : _sendMessage,
            icon: isSending
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
            color: AppTheme.primaryColor,
          ),
        ],
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  String _formatDate(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays == 0) {
      return 'Today';
    } else if (difference.inDays == 1) {
      return 'Yesterday';
    } else {
      return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
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
