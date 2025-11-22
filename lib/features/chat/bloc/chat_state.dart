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

class ChatState extends Equatable {
  const ChatState({
    this.status = ChatStatus.initial,
    this.conversations = const [],
    this.currentConversation,
    this.messages = const [],
    this.errorMessage,
    this.hasMoreMessages = true,
  });

  final ChatStatus status;
  final List<ConversationWithPeer> conversations;
  final CurrentConversation? currentConversation;
  final List<MessageEntry> messages;
  final String? errorMessage;
  final bool hasMoreMessages;

  /// Total unread count across all conversations
  int get totalUnreadCount =>
      conversations.fold(0, (sum, conv) => sum + conv.unreadCount);

  /// Check if we're in a conversation
  bool get isInConversation => currentConversation != null;

  ChatState copyWith({
    ChatStatus? status,
    List<ConversationWithPeer>? conversations,
    CurrentConversation? currentConversation,
    List<MessageEntry>? messages,
    String? errorMessage,
    bool? hasMoreMessages,
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
      ];
}
