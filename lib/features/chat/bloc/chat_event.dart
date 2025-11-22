import 'package:equatable/equatable.dart';

import '../../../data/local_database/database.dart';
import '../../../services/ble/ble.dart' as ble;

abstract class ChatEvent extends Equatable {
  const ChatEvent();

  @override
  List<Object?> get props => [];
}

/// Load all conversations
class LoadConversations extends ChatEvent {
  const LoadConversations();
}

/// Open a specific conversation with a peer
class OpenConversation extends ChatEvent {
  const OpenConversation({
    required this.peerId,
    required this.peerName,
  });

  final String peerId;
  final String peerName;

  @override
  List<Object?> get props => [peerId, peerName];
}

/// Load messages for current conversation (paginated)
class LoadMessages extends ChatEvent {
  const LoadMessages({this.loadMore = false});
  final bool loadMore;

  @override
  List<Object?> get props => [loadMore];
}

/// Send a text message
class SendTextMessage extends ChatEvent {
  const SendTextMessage(this.text);
  final String text;

  @override
  List<Object?> get props => [text];
}

/// Send a photo message
class SendPhotoMessage extends ChatEvent {
  const SendPhotoMessage(this.photoPath);
  final String photoPath;

  @override
  List<Object?> get props => [photoPath];
}

/// Message received from BLE (will be called later)
class MessageReceived extends ChatEvent {
  const MessageReceived(this.message);
  final MessageEntry message;

  @override
  List<Object?> get props => [message];
}

/// Message status was updated
class MessageStatusUpdated extends ChatEvent {
  const MessageStatusUpdated({
    required this.messageId,
    required this.status,
  });

  final String messageId;
  final MessageStatus status;

  @override
  List<Object?> get props => [messageId, status];
}

/// Retry sending a failed message
class RetryFailedMessage extends ChatEvent {
  const RetryFailedMessage(this.messageId);
  final String messageId;

  @override
  List<Object?> get props => [messageId];
}

/// Mark messages as read in current conversation
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

/// Clear error state
class ClearChatError extends ChatEvent {
  const ClearChatError();
}

/// BLE message received from peer
class BleMessageReceived extends ChatEvent {
  const BleMessageReceived(this.message);
  final ble.ReceivedMessage message;

  @override
  List<Object?> get props => [message];
}

/// Photo transfer progress updated
class PhotoTransferProgressUpdated extends ChatEvent {
  const PhotoTransferProgressUpdated(this.progress);
  final ble.PhotoTransferProgress progress;

  @override
  List<Object?> get props => [progress];
}
