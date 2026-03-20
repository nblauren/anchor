import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/transport_badge.dart';
import '../../../data/local_database/database.dart';
import '../../discovery/bloc/anchor_drop_bloc.dart';
import '../../transport/bloc/transport_bloc.dart';
import '../../transport/bloc/transport_state.dart';
import '../bloc/chat_bloc.dart';
import '../bloc/chat_e2ee_bloc.dart';
import '../bloc/chat_event.dart';
import '../bloc/chat_state.dart';
import '../bloc/photo_transfer_bloc.dart';
import '../bloc/reaction_bloc.dart';
import '../widgets/floating_emoji_picker.dart';
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
  late final ChatE2eeBloc _e2eeBloc;
  late final ReactionBloc _reactionBloc;
  bool _anchorDropped = false;
  final _messageKeys = <String, GlobalKey>{};
  OverlayEntry? _overlayEntry;

  @override
  void initState() {
    super.initState();
    _chatBloc = context.read<ChatBloc>();
    _e2eeBloc = context.read<ChatE2eeBloc>();
    _reactionBloc = context.read<ReactionBloc>();
    // Open conversation for this peer (marks messages as read automatically)
    _chatBloc.add(OpenConversation(
      peerId: widget.peerId,
      peerName: widget.peerName,
    ));

    // Initiate E2EE handshake via dedicated bloc
    context.read<ChatE2eeBloc>().add(InitiateE2eeHandshake(widget.peerId));

    // Reflect any anchor already dropped on this peer from the discovery screen.
    try {
      final dropped = context
          .read<AnchorDropBloc>()
          .state
          .droppedAnchorPeerIds
          .contains(widget.peerId);
      if (dropped) _anchorDropped = true;
    } catch (_) {
      // AnchorDropBloc may not be in the tree from all entry points.
    }

    _scrollController.addListener(() {
      // Dismiss emoji picker overlay on scroll
      _removeOverlay();
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
    _removeOverlay();
    _chatBloc.add(const CloseConversation());
    _e2eeBloc.add(const ResetE2ee());
    _reactionBloc.add(const ClearReactions());
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
      context.read<AnchorDropBloc>().add(
            DropAnchor(peerId: widget.peerId, peerName: widget.peerName),
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

  void _scrollToMessage(String messageId) {
    final key = _messageKeys[messageId];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
        alignment: 0.5,
      );
    }
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

  void _dismissSelection() {
    _removeOverlay();
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _showFloatingEmojiPicker(
    BuildContext context,
    MessageEntry message,
    String peerId,
    GlobalKey messageKey,
  ) {
    _removeOverlay();

    final renderBox =
        messageKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final overlay = Overlay.of(context);
    final position = renderBox.localToGlobal(Offset.zero);

    _overlayEntry = OverlayEntry(
      builder: (ctx) {
        final ownUserId = _chatBloc.ownUserId;
        final currentReactions =
            _reactionBloc.state.reactions[message.id] ?? [];

        return Stack(
          children: [
            // Dismiss on tap outside
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _dismissSelection,
                child: const SizedBox.expand(),
              ),
            ),
            // Floating emoji picker positioned above the message
            Positioned(
              left: position.dx,
              top: position.dy - 52,
              child: FloatingEmojiPicker(
                emojis: _kReactionEmojis,
                ownUserId: ownUserId,
                currentReactions: currentReactions,
                onEmojiTap: (emoji) {
                  _dismissSelection();
                  final ownReacted = currentReactions
                      .any((r) => r.senderId == ownUserId && r.emoji == emoji);
                  if (ownReacted) {
                    _reactionBloc.add(RemoveReaction(
                      messageId: message.id,
                      peerId: peerId,
                      emoji: emoji,
                    ));
                  } else {
                    _reactionBloc.add(SendReaction(
                      messageId: message.id,
                      peerId: peerId,
                      emoji: emoji,
                    ));
                  }
                },
              ),
            ),
          ],
        );
      },
    );

    overlay.insert(_overlayEntry!);
  }

  void _requestFullPhoto(String messageId, String photoId, String peerId) {
    context.read<PhotoTransferBloc>().add(RequestFullPhoto(
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
        // Load reactions when conversation opens
        if (state.currentConversation != null &&
            state.status == ChatStatus.loaded) {
          final reactionBloc = context.read<ReactionBloc>();
          reactionBloc.activePeerName = state.currentConversation!.peerName;
          reactionBloc.activeMessages = state.messages;
          reactionBloc.add(LoadReactions(state.currentConversation!.id));
        }
        // Keep activeMessages in sync
        if (state.currentConversation != null) {
          context.read<ReactionBloc>().activeMessages = state.messages;
        }
      },
      builder: (context, state) {
        return BlocBuilder<ChatE2eeBloc, ChatE2eeState>(
          builder: (context, e2eeState) {
            return _buildChatBody(context, state, e2eeState);
          },
        );
      },
    );
  }

  Widget _buildChatBody(
    BuildContext context,
    ChatState state,
    ChatE2eeState e2eeState,
  ) {
    final conversation = state.currentConversation;
    final ownUserId = context.read<ChatBloc>().ownUserId;
    final reactionState = context.watch<ReactionBloc>().state;
    final transferState = context.watch<PhotoTransferBloc>().state;
    // Bridge E2EE state from dedicated bloc
    final isE2eeActive = e2eeState.isActive;
    final isE2eeHandshaking = e2eeState.isHandshaking;

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
                    else if (isE2eeActive)
                      // E2EE lock indicator + transport badge — visible when
                      // Noise_XK session is established.
                      GestureDetector(
                        onTap: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Row(
                                children: [
                                  Icon(Icons.lock,
                                      color: Colors.white, size: 16),
                                  SizedBox(width: 8),
                                  Text('End-to-end encrypted'),
                                ],
                              ),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                        child: BlocBuilder<TransportBloc, TransportState>(
                          builder: (context, transportState) {
                            final peerTransport =
                                transportState.transportForPeer(widget.peerId);
                            return TransportBadge(transport: peerTransport);
                          },
                        ),
                      )
                    else if (isE2eeHandshaking)
                      const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(strokeWidth: 1.5),
                          ),
                          SizedBox(width: 3),
                          Text(
                            'Securing…',
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
                      Text('Block', style: TextStyle(color: AppTheme.error)),
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
              onTap: () {
                _dismissSelection();
                _focusNode.unfocus();
              },
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
                        final itemKey = _messageKeys.putIfAbsent(
                            message.id, () => GlobalKey());

                        return Column(
                          key: itemKey,
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
                              ownUserId: ownUserId,
                              onRetry: () => _retryMessage(message.id),
                              isRelayedPeer: widget.isRelayedPeer,
                              transferInfo:
                                  transferState.getTransferProgress(message.id),
                              onRequestFullPhoto: isSentByMe
                                  ? null
                                  : (photoId) => _requestFullPhoto(
                                        message.id,
                                        photoId,
                                        state.currentConversation!.peerId,
                                      ),
                              onCancelTransfer: transferState
                                          .getTransferProgress(message.id) !=
                                      null
                                  ? () => context.read<PhotoTransferBloc>().add(
                                        CancelPhotoTransfer(message.id),
                                      )
                                  : null,
                              reactions:
                                  reactionState.reactions[message.id] ?? [],
                              onReact: state.isBlocked
                                  ? null
                                  : (emoji) {
                                      final peerId =
                                          state.currentConversation!.peerId;
                                      final ownReacted = (reactionState
                                                  .reactions[message.id] ??
                                              [])
                                          .any((r) =>
                                              r.senderId == ownUserId &&
                                              r.emoji == emoji);
                                      if (ownReacted) {
                                        context.read<ReactionBloc>().add(
                                              RemoveReaction(
                                                messageId: message.id,
                                                peerId: peerId,
                                                emoji: emoji,
                                              ),
                                            );
                                      } else {
                                        context.read<ReactionBloc>().add(
                                              SendReaction(
                                                messageId: message.id,
                                                peerId: peerId,
                                                emoji: emoji,
                                              ),
                                            );
                                      }
                                    },
                              isSelected: false,
                              onReactTap: (!isSentByMe && !state.isBlocked)
                                  ? () => _showFloatingEmojiPicker(
                                        context,
                                        message,
                                        state.currentConversation!.peerId,
                                        itemKey,
                                      )
                                  : null,
                              onReplyTap: (!isSentByMe && !state.isBlocked)
                                  ? () => _startReply(message)
                                  : null,
                              quotedMessage: message.replyToMessageId != null
                                  ? state
                                      .quotedMessages[message.replyToMessageId]
                                  : null,
                              onQuotedTap: message.replyToMessageId != null
                                  ? () => _scrollToMessage(
                                      message.replyToMessageId!)
                                  : null,
                            ),
                          ],
                        );
                      },
                    ),
            ),
          ),

          // Message input — only shown once E2EE session is established.
          if (state.isBlocked)
            _buildBlockedBanner()
          else if (!isE2eeActive)
            _buildSecureConnectionBanner(isE2eeHandshaking)
          else
            _buildMessageInput(state),
        ],
      ),
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

  Widget _buildSecureConnectionBanner(bool isHandshaking) {
    final message = isHandshaking
        ? 'Initiating secure connection\u2026'
        : 'Waiting for secure connection\u2026';
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
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
          const SizedBox(width: 10),
          Text(
            message,
            style: const TextStyle(color: AppTheme.textHint, fontSize: 13),
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
    final ownUserId = context.read<ChatBloc>().ownUserId;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (replyingTo != null)
          _buildReplyBar(replyingTo, ownUserId, widget.peerName),
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

  Widget _buildReplyBar(
      MessageEntry replyingTo, String ownUserId, String peerName) {
    final isOwnMessage = replyingTo.senderId == ownUserId;
    final senderLabel = isOwnMessage ? 'Yourself' : peerName;
    final isPhoto = replyingTo.contentType == MessageContentType.photo ||
        replyingTo.contentType == MessageContentType.photoPreview;

    return Container(
      padding: const EdgeInsets.fromLTRB(0, 8, 12, 8),
      decoration: const BoxDecoration(
        color: AppTheme.darkSurface,
        border: Border(top: BorderSide(color: AppTheme.darkCard)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Colored left accent bar
          Container(
            width: 3,
            height: 36,
            margin: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Text content
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Replying to $senderLabel',
                  style: const TextStyle(
                    color: AppTheme.primaryLight,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isPhoto) ...[
                      const Icon(Icons.image_outlined,
                          size: 12, color: AppTheme.textHint),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        isPhoto ? 'Photo' : (replyingTo.textContent ?? ''),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textHint,
                          fontSize: 12,
                          height: 1.2,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Close button
          GestureDetector(
            onTap: _cancelReply,
            child: Container(
              padding: const EdgeInsets.all(4),
              child: const Icon(Icons.close,
                  size: 16, color: AppTheme.textSecondary),
            ),
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
