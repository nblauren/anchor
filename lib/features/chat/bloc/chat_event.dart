import 'package:equatable/equatable.dart';

import '../../../data/local_database/database.dart';
import '../../../services/ble/ble.dart' as ble;

abstract class ChatEvent extends Equatable {
  const ChatEvent();

  @override
  List<Object?> get props => [];
}

/// Internal event: a downloaded full photo should replace a preview bubble.
class PhotoPreviewUpgraded extends ChatEvent {
  const PhotoPreviewUpgraded({
    required this.previewMessageId,
    required this.updatedMessage,
  });

  final String previewMessageId;
  final MessageEntry updatedMessage;

  @override
  List<Object?> get props => [previewMessageId, updatedMessage];
}

// Note: LoadConversations and DeleteConversation are now in conversation_list_bloc.dart

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
  const SendTextMessage(this.text, {this.replyToMessageId});
  final String text;

  /// The ID of the message being replied to, if any.
  final String? replyToMessageId;

  @override
  List<Object?> get props => [text, replyToMessageId];
}

/// Set the message currently being replied to (shown in reply bar above input).
/// Pass null to clear the reply.
class SetReplyingTo extends ChatEvent {
  const SetReplyingTo(this.message);
  final MessageEntry? message;

  @override
  List<Object?> get props => [message];
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

/// Clear error state
class ClearChatError extends ChatEvent {
  const ClearChatError();
}

/// Block the current conversation peer
class BlockChatPeer extends ChatEvent {
  const BlockChatPeer();
}

/// Unblock the current conversation peer
class UnblockChatPeer extends ChatEvent {
  const UnblockChatPeer();
}

/// BLE message received from peer
class BleMessageReceived extends ChatEvent {
  const BleMessageReceived(this.message);
  final ble.ReceivedMessage message;

  @override
  List<Object?> get props => [message];
}

// Note: Photo transfer events are now in photo_transfer_bloc.dart
// Note: Reaction events are now in reaction_bloc.dart

/// A peer has gone out of range — cancel any active photo transfers with them.
class ChatPeerLost extends ChatEvent {
  const ChatPeerLost(this.peerId);
  final String peerId;

  @override
  List<Object?> get props => [peerId];
}

// Note: E2EE events are now in chat_e2ee_bloc.dart
// Note: Reaction events are now in reaction_bloc.dart

