import 'package:equatable/equatable.dart';

import '../../../data/models/chat_message.dart';

abstract class ChatEvent extends Equatable {
  const ChatEvent();

  @override
  List<Object?> get props => [];
}

/// Load all conversations
class LoadConversations extends ChatEvent {
  const LoadConversations();
}

/// Open a specific conversation
class OpenConversation extends ChatEvent {
  const OpenConversation({
    required this.participantId,
    required this.participantName,
    this.participantPhotoUrl,
  });

  final String participantId;
  final String participantName;
  final String? participantPhotoUrl;

  @override
  List<Object?> get props => [participantId, participantName, participantPhotoUrl];
}

/// Load messages for current conversation
class LoadMessages extends ChatEvent {
  const LoadMessages({this.loadMore = false});
  final bool loadMore;

  @override
  List<Object?> get props => [loadMore];
}

/// Send a message
class SendMessage extends ChatEvent {
  const SendMessage(this.content);
  final String content;

  @override
  List<Object?> get props => [content];
}

/// Message received from BLE
class MessageReceived extends ChatEvent {
  const MessageReceived(this.message);
  final ChatMessage message;

  @override
  List<Object?> get props => [message];
}

/// Mark messages as read
class MarkMessagesRead extends ChatEvent {
  const MarkMessagesRead();
}

/// Close current conversation
class CloseConversation extends ChatEvent {
  const CloseConversation();
}

/// Delete a conversation
class DeleteConversation extends ChatEvent {
  const DeleteConversation(this.conversationId);
  final String conversationId;

  @override
  List<Object?> get props => [conversationId];
}
