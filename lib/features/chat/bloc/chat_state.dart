import 'package:equatable/equatable.dart';

import '../../../data/local_database/database.dart';
import '../../../data/repositories/chat_repository.dart';
import '../../../services/transport/transport_enums.dart';

/// Preset emoji set for reactions.
const kReactionEmojis = ['❤️', '👍', '😂', '😮', '😢', '🔥'];

enum ChatStatus {
  initial,
  loading,
  loaded,
  sending,
  error,
}

/// Current conversation info
class CurrentConversation extends Equatable {
  const CurrentConversation({
    required this.id,
    required this.peerId,
    required this.peerName,
  });

  final String id;
  final String peerId;
  final String peerName;

  @override
  List<Object?> get props => [id, peerId, peerName];
}

/// Photo transfer progress info
class PhotoTransferInfo extends Equatable {
  const PhotoTransferInfo({
    required this.messageId,
    required this.progress,
    required this.isSending,
    this.transport = TransportType.ble,
  });

  final String messageId;
  final double progress; // 0.0 to 1.0
  final bool isSending; // true = sending, false = receiving
  /// Which transport is being used for this transfer.
  final TransportType transport;

  int get progressPercent => (progress * 100).round();

  /// Human-readable transport label for UI.
  String get transportLabel {
    switch (transport) {
      case TransportType.lan:
        return 'LAN';
      case TransportType.wifiAware:
        return 'Wi-Fi Aware';
      case TransportType.wifiDirect:
        return 'Wi-Fi Direct';
      case TransportType.ble:
        return 'Bluetooth';
    }
  }

  @override
  List<Object?> get props => [messageId, progress, isSending, transport];
}

/// Metadata for an outgoing photo that has been previewed but not yet
/// requested (or is mid-transfer).  Keyed by [photoId] in [ChatState].
class PendingOutgoingPhoto extends Equatable {
  const PendingOutgoingPhoto({
    required this.photoId,
    required this.localPhotoPath,
    required this.messageId,
    required this.peerId,
  });

  /// UUID shared between the preview and the full-transfer request.
  final String photoId;
  /// Absolute path to the BLE-compressed photo bytes on the sender's device.
  final String localPhotoPath;
  /// DB message ID for the sender's own chat bubble (type: photo).
  final String messageId;
  /// BLE peer ID of the recipient.
  final String peerId;

  @override
  List<Object?> get props => [photoId, localPhotoPath, messageId, peerId];
}

class ChatState extends Equatable {
  const ChatState({
    this.status = ChatStatus.initial,
    this.conversations = const [],
    this.currentConversation,
    this.messages = const [],
    this.errorMessage,
    this.hasMoreMessages = true,
    this.photoTransfers = const {},
    this.isBlocked = false,
    this.pendingOutgoingPhotos = const {},
    this.reactions = const {},
    this.replyingToMessage,
    this.quotedMessages = const {},
  });

  final ChatStatus status;
  final List<ConversationWithPeer> conversations;
  final CurrentConversation? currentConversation;
  final List<MessageEntry> messages;
  final String? errorMessage;
  final bool hasMoreMessages;
  final Map<String, PhotoTransferInfo> photoTransfers; // messageId -> progress
  final bool isBlocked;
  /// Outgoing photos awaiting a [photo_request] from the receiver.
  /// Keyed by [photoId].
  final Map<String, PendingOutgoingPhoto> pendingOutgoingPhotos;
  /// Emoji reactions keyed by messageId. Each list contains one entry per
  /// (senderId, emoji) pair that has been added.
  final Map<String, List<ReactionEntry>> reactions;
  /// The message currently being replied to, shown in the reply bar. null = not replying.
  final MessageEntry? replyingToMessage;
  /// Quoted messages keyed by message ID. Used to render reply previews inside bubbles.
  /// Populated from [Messages.replyToMessageId] when loading messages.
  final Map<String, MessageEntry> quotedMessages;

  /// Total unread count across all conversations
  int get totalUnreadCount =>
      conversations.fold(0, (sum, conv) => sum + conv.unreadCount);

  /// Check if we're in a conversation
  bool get isInConversation => currentConversation != null;

  /// Get transfer progress for a specific message
  PhotoTransferInfo? getTransferProgress(String messageId) => photoTransfers[messageId];

  ChatState copyWith({
    ChatStatus? status,
    List<ConversationWithPeer>? conversations,
    CurrentConversation? currentConversation,
    List<MessageEntry>? messages,
    String? errorMessage,
    bool? hasMoreMessages,
    Map<String, PhotoTransferInfo>? photoTransfers,
    bool? isBlocked,
    Map<String, PendingOutgoingPhoto>? pendingOutgoingPhotos,
    Map<String, List<ReactionEntry>>? reactions,
    bool clearCurrentConversation = false,
    MessageEntry? replyingToMessage,
    bool clearReplyingToMessage = false,
    Map<String, MessageEntry>? quotedMessages,
  }) {
    return ChatState(
      status: status ?? this.status,
      conversations: conversations ?? this.conversations,
      currentConversation:
          clearCurrentConversation ? null : (currentConversation ?? this.currentConversation),
      messages: messages ?? this.messages,
      errorMessage: errorMessage,
      hasMoreMessages: hasMoreMessages ?? this.hasMoreMessages,
      photoTransfers: photoTransfers ?? this.photoTransfers,
      isBlocked: isBlocked ?? this.isBlocked,
      pendingOutgoingPhotos:
          pendingOutgoingPhotos ?? this.pendingOutgoingPhotos,
      reactions: reactions ?? this.reactions,
      replyingToMessage: clearReplyingToMessage ? null : (replyingToMessage ?? this.replyingToMessage),
      quotedMessages: quotedMessages ?? this.quotedMessages,
    );
  }

  @override
  List<Object?> get props => [
        status,
        conversations,
        currentConversation,
        messages,
        errorMessage,
        hasMoreMessages,
        photoTransfers,
        isBlocked,
        pendingOutgoingPhotos,
        reactions,
        replyingToMessage,
        quotedMessages,
      ];
}
