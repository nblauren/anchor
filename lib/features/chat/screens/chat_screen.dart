import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/local_database/database.dart';
import '../../discovery/bloc/discovery_bloc.dart';
import '../../discovery/bloc/discovery_event.dart';
import '../bloc/chat_bloc.dart';
import '../bloc/chat_event.dart';
import '../bloc/chat_state.dart';
import '../widgets/message_bubble_widget.dart';

const _kReactionEmojis = ['❤️', '👍', '😂', '😮', '😢', '🔥'];

/// Screen for individual chat conversation
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.peerId,
    required this.peerName,
    this.peerThumbnail,
    this.onViewProfile,
    this.isRelayedPeer = false,
    this.hopCount = 0,
  });

  final String peerId;
  final String peerName;
  final Uint8List? peerThumbnail;
  final VoidCallback? onViewProfile;

  /// Whether this peer is only reachable via mesh relay (not direct BLE).
  final bool isRelayedPeer;

  /// Number of relay hops to reach this peer (0 = direct).
  final int hopCount;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final _imagePicker = ImagePicker();
  late final ChatBloc _chatBloc;
  bool _anchorDropped = false;

  @override
  void initState() {
    super.initState();
    _chatBloc = context.read<ChatBloc>();
    // Open conversation for this peer (marks messages as read automatically)
    _chatBloc.add(OpenConversation(
      peerId: widget.peerId,
      peerName: widget.peerName,
    ));

    // Reflect any anchor already dropped on this peer from the discovery screen.
    try {
      final dropped = context
          .read<DiscoveryBloc>()
          .state
          .droppedAnchorPeerIds
          .contains(widget.peerId);
      if (dropped) _anchorDropped = true;
    } catch (_) {
      // DiscoveryBloc may not be in the tree from all entry points.
    }

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
    _focusNode.dispose();
    super.dispose();
  }

  void _confirmBlock(BuildContext context, ChatState state) {
    final peerName = state.currentConversation?.peerName ?? 'this user';
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Block User'),
        content:
            Text('Block $peerName? They won\'t be able to send you messages.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Block', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed == true && context.mounted) {
        context.read<ChatBloc>().add(const BlockChatPeer());
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$peerName blocked')),
        );
      }
    });
  }

  void _dropAnchor() {
    try {
      context.read<DiscoveryBloc>().add(
            DropAnchorOnPeer(peerId: widget.peerId, peerName: widget.peerName),
          );
    } catch (_) {
      // DiscoveryBloc may not be in the widget tree from all entry points
    }
    setState(() => _anchorDropped = true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Anchor dropped on ${widget.peerName}! \u2693'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _sendMessage() {
    final content = _messageController.text.trim();
    if (content.isNotEmpty) {
      final replyingTo = context.read<ChatBloc>().state.replyingToMessage;
      context.read<ChatBloc>().add(
            SendTextMessage(content, replyToMessageId: replyingTo?.id),
          );
      _messageController.clear();
      _focusNode.requestFocus();
    }
  }

  void _startReply(MessageEntry message) {
    context.read<ChatBloc>().add(SetReplyingTo(message));
    _focusNode.requestFocus();
  }

  void _cancelReply() {
    context.read<ChatBloc>().add(const SetReplyingTo(null));
  }

  void _showPhotoOptions() {
    if (widget.isRelayedPeer) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Move closer to send photos'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
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

      if (image == null || !mounted) return;

      // Warn if peer is far away — full photo download may be slow.
      if (widget.isRelayedPeer) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Move closer for best results'),
            content: const Text(
              'This person is reached via a relay hop. '
              'A preview thumbnail will be sent now — '
              'they can tap it to download the full photo once you\'re closer.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Send preview anyway'),
              ),
            ],
          ),
        );
        if (proceed != true || !mounted) return;
      }

      context.read<ChatBloc>().add(SendPhotoMessage(image.path));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to pick photo')),
      );
    }
  }

  void _showEmojiPicker(BuildContext context, String messageId, String peerId) {
    final ownUserId = context.read<ChatBloc>().ownUserId;
    final currentReactions =
        context.read<ChatBloc>().state.reactions[messageId] ?? [];

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.darkCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: _kReactionEmojis.map((emoji) {
              final alreadyReacted = currentReactions
                  .any((r) => r.senderId == ownUserId && r.emoji == emoji);
              return GestureDetector(
                onTap: () {
                  Navigator.pop(ctx);
                  if (alreadyReacted) {
                    context.read<ChatBloc>().add(RemoveReaction(
                          messageId: messageId,
                          peerId: peerId,
                          emoji: emoji,
                        ));
                  } else {
                    context.read<ChatBloc>().add(SendReaction(
                          messageId: messageId,
                          peerId: peerId,
                          emoji: emoji,
                        ));
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: alreadyReacted
                      ? BoxDecoration(
                          color: AppTheme.primaryColor.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppTheme.primaryColor.withValues(alpha: 0.5),
                          ),
                        )
                      : null,
                  child: Text(emoji, style: const TextStyle(fontSize: 28)),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  void _requestFullPhoto(String messageId, String photoId, String peerId) {
    context.read<ChatBloc>().add(RequestFullPhoto(
          messageId: messageId,
          photoId: photoId,
          peerId: peerId,
        ));
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
                  _buildAvatar(
                      conversation?.peerName ?? '?', widget.peerThumbnail),
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
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.hub_outlined,
                                  size: 11, color: AppTheme.textSecondary),
                              const SizedBox(width: 3),
                              Text(
                                widget.hopCount > 0
                                    ? 'Via relay · ${widget.hopCount} ${widget.hopCount == 1 ? 'hop' : 'hops'}'
                                    : 'Via relay',
                                style: const TextStyle(
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
              // Drop Anchor button
              if (!state.isBlocked)
                IconButton(
                  key: const Key('chat_anchor_btn'),
                  onPressed: _anchorDropped ? null : _dropAnchor,
                  icon: Icon(
                    Icons.anchor,
                    color: _anchorDropped
                        ? const Color(0xFFEC4899)
                        : AppTheme.textSecondary,
                  ),
                  tooltip: _anchorDropped ? 'Anchor dropped!' : 'Drop anchor',
                ),
              PopupMenuButton<String>(
                key: const Key('chat_more_menu_btn'),
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  if (value == 'block') {
                    _confirmBlock(context, state);
                  } else if (value == 'unblock') {
                    context.read<ChatBloc>().add(const UnblockChatPeer());
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '${state.currentConversation?.peerName ?? 'User'} unblocked',
                        ),
                      ),
                    );
                  }
                },
                itemBuilder: (_) => [
                  if (state.isBlocked)
                    const PopupMenuItem(
                      value: 'unblock',
                      child: Row(
                        children: [
                          Icon(Icons.lock_open, size: 20),
                          SizedBox(width: 12),
                          Text('Unblock'),
                        ],
                      ),
                    )
                  else
                    const PopupMenuItem(
                      value: 'block',
                      child: Row(
                        children: [
                          Icon(Icons.block, size: 20, color: AppTheme.error),
                          SizedBox(width: 12),
                          Text('Block',
                              style: TextStyle(color: AppTheme.error)),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              // Messages list — tap to dismiss keyboard
              Expanded(
                child: GestureDetector(
                  onTap: () => _focusNode.unfocus(),
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
                            final showDate =
                                index == state.messages.length - 1 ||
                                    !_isSameDay(
                                      message.createdAt,
                                      state.messages[index + 1].createdAt,
                                    );

                            return Column(
                              children: [
                                if (showDate)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 16),
                                    child: Text(
                                      _formatDate(message.createdAt),
                                      style: const TextStyle(
                                        color: AppTheme.textSecondary,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                Dismissible(
                                  key: Key('reply_${message.id}'),
                                  direction: DismissDirection.startToEnd,
                                  confirmDismiss: (_) async {
                                    if (!state.isBlocked) _startReply(message);
                                    return false;
                                  },
                                  background: const Align(
                                    alignment: Alignment.centerLeft,
                                    child: Padding(
                                      padding: EdgeInsets.only(left: 16),
                                      child: Icon(
                                        Icons.reply,
                                        color: AppTheme.primaryLight,
                                      ),
                                    ),
                                  ),
                                  child: MessageBubbleWidget(
                                    message: message,
                                    isSentByMe: isSentByMe,
                                    ownUserId: ownUserId,
                                    onRetry: () => _retryMessage(message.id),
                                    isRelayedPeer: widget.isRelayedPeer,
                                    transferInfo:
                                        state.getTransferProgress(message.id),
                                    onRequestFullPhoto: isSentByMe
                                        ? null
                                        : (photoId) => _requestFullPhoto(
                                              message.id,
                                              photoId,
                                              state.currentConversation!.peerId,
                                            ),
                                    onCancelTransfer:
                                        state.getTransferProgress(message.id) !=
                                                null
                                            ? () => context.read<ChatBloc>().add(
                                                  CancelPhotoTransfer(message.id),
                                                )
                                            : null,
                                    reactions: state.reactions[message.id] ?? [],
                                    onReact: state.isBlocked
                                        ? null
                                        : (emoji) {
                                            final peerId = state
                                                .currentConversation!.peerId;
                                            final ownReacted =
                                                (state.reactions[message.id] ??
                                                        [])
                                                    .any((r) =>
                                                        r.senderId == ownUserId &&
                                                        r.emoji == emoji);
                                            if (ownReacted) {
                                              context.read<ChatBloc>().add(
                                                    RemoveReaction(
                                                      messageId: message.id,
                                                      peerId: peerId,
                                                      emoji: emoji,
                                                    ),
                                                  );
                                            } else {
                                              context.read<ChatBloc>().add(
                                                    SendReaction(
                                                      messageId: message.id,
                                                      peerId: peerId,
                                                      emoji: emoji,
                                                    ),
                                                  );
                                            }
                                          },
                                    onLongPress: state.isBlocked ||
                                            message.senderId == ownUserId
                                        ? null
                                        : () => _showEmojiPicker(
                                              context,
                                              message.id,
                                              state.currentConversation!.peerId,
                                            ),
                                    quotedMessage: message.replyToMessageId != null
                                        ? state.quotedMessages[message.replyToMessageId]
                                        : null,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                ),
              ),

              // Message input
              state.isBlocked
                  ? _buildBlockedBanner()
                  : _buildMessageInput(state),
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

  Widget _buildBlockedBanner() {
    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: MediaQuery.of(context).padding.bottom + 12,
      ),
      decoration: const BoxDecoration(
        color: AppTheme.darkSurface,
        border: Border(top: BorderSide(color: AppTheme.darkCard)),
      ),
      child: const Text(
        'You have blocked this person. Unblock them to send messages.',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppTheme.textHint, fontSize: 13),
      ),
    );
  }

  Widget _buildMessageInput(ChatState state) {
    final replyingTo = state.replyingToMessage;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (replyingTo != null) _buildReplyBar(replyingTo),
        Container(
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
                key: const Key('chat_photo_btn'),
                onPressed: _showPhotoOptions,
                icon: const Icon(Icons.photo),
                color: AppTheme.textSecondary,
              ),

              // Text input
              Expanded(
                child: TextField(
                  key: const Key('chat_message_input'),
                  controller: _messageController,
                  focusNode: _focusNode,
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
                  textInputAction: TextInputAction.send,
                  maxLines: 4,
                  minLines: 1,
                  // Use onEditingComplete instead of onSubmitted to prevent
                  // the default unfocus behavior that closes the keyboard.
                  onEditingComplete: _sendMessage,
                ),
              ),
              const SizedBox(width: 4),

              // Send button
              IconButton(
                key: const Key('chat_send_btn'),
                onPressed: _sendMessage,
                icon: const Icon(Icons.send),
                color: AppTheme.primaryLight,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildReplyBar(MessageEntry replyingTo) {
    final isPhoto = replyingTo.contentType == MessageContentType.photo ||
        replyingTo.contentType == MessageContentType.photoPreview;
    final preview = isPhoto ? '📷 Photo' : (replyingTo.textContent ?? '');
    final truncated = preview.length > 60 ? '${preview.substring(0, 60)}…' : preview;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: AppTheme.darkCard,
        border: Border(
          top: BorderSide(color: AppTheme.darkSurface),
          left: BorderSide(color: AppTheme.primaryColor, width: 3),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.reply, size: 16, color: AppTheme.primaryLight),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              truncated,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
              ),
            ),
          ),
          GestureDetector(
            onTap: _cancelReply,
            child: const Icon(Icons.close, size: 18, color: AppTheme.textHint),
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
