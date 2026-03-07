import 'package:equatable/equatable.dart';

import '../../../data/local_database/database.dart';
import '../../../data/repositories/chat_repository.dart';

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
  });

  final String messageId;
  final double progress; // 0.0 to 1.0
  final bool isSending; // true = sending, false = receiving

  int get progressPercent => (progress * 100).round();

  @override
  List<Object?> get props => [messageId, progress, isSending];
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
  });

  final ChatStatus status;
  final List<ConversationWithPeer> conversations;
  final CurrentConversation? currentConversation;
  final List<MessageEntry> messages;
  final String? errorMessage;
  final bool hasMoreMessages;
  final Map<String, PhotoTransferInfo> photoTransfers; // messageId -> progress
  final bool isBlocked;

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
    bool clearCurrentConversation = false,
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
      ];
}
