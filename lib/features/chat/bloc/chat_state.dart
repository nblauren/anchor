import 'package:equatable/equatable.dart';

import '../../../data/models/chat_message.dart';
import '../../../data/models/conversation.dart';

enum ChatStatus {
  initial,
  loading,
  loaded,
  sending,
  error,
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
  final List<Conversation> conversations;
  final Conversation? currentConversation;
  final List<ChatMessage> messages;
  final String? errorMessage;
  final bool hasMoreMessages;

  /// Total unread count across all conversations
  int get totalUnreadCount =>
      conversations.fold(0, (sum, conv) => sum + conv.unreadCount);

  ChatState copyWith({
    ChatStatus? status,
    List<Conversation>? conversations,
    Conversation? currentConversation,
    List<ChatMessage>? messages,
    String? errorMessage,
    bool? hasMoreMessages,
  }) {
    return ChatState(
      status: status ?? this.status,
      conversations: conversations ?? this.conversations,
      currentConversation: currentConversation,
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
