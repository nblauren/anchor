import 'package:equatable/equatable.dart';

import '../../../data/local_database/database.dart';
import '../../../services/ble/ble.dart' as ble;
import '../../../services/nearby/nearby.dart';
import 'chat_state.dart';

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

/// Photo transfer progress updated
class PhotoTransferProgressUpdated extends ChatEvent {
  const PhotoTransferProgressUpdated(this.progress);
  final ble.PhotoTransferProgress progress;

  @override
  List<Object?> get props => [progress];
}

// ── Photo preview / consent flow ────────────────────────────────────────────

/// BLE photo preview received from a peer (thumbnail + metadata).
class PhotoPreviewReceived extends ChatEvent {
  const PhotoPreviewReceived(this.preview);
  final ble.ReceivedPhotoPreview preview;

  @override
  List<Object?> get props => [preview];
}

/// Receiver taps the thumbnail → sends a [photo_request] to the sender.
///
/// [messageId] is the DB ID of the [photoPreview] message bubble.
/// [photoId]   is the UUID in the preview metadata.
/// [peerId]    is the sender's peerId so we know where to send the request.
class RequestFullPhoto extends ChatEvent {
  const RequestFullPhoto({
    required this.messageId,
    required this.photoId,
    required this.peerId,
  });

  final String messageId;
  final String photoId;
  final String peerId;

  @override
  List<Object?> get props => [messageId, photoId, peerId];
}

/// Sender received a consent [photo_request] from the receiver.
class PhotoRequestReceived extends ChatEvent {
  const PhotoRequestReceived(this.request);
  final ble.ReceivedPhotoRequest request;

  @override
  List<Object?> get props => [request];
}

/// Cancel an in-progress incoming or outgoing photo transfer.
class CancelPhotoTransfer extends ChatEvent {
  const CancelPhotoTransfer(this.messageId);
  final String messageId;

  @override
  List<Object?> get props => [messageId];
}

/// Nearby Connections transfer progress updated.
class NearbyTransferProgressUpdated extends ChatEvent {
  const NearbyTransferProgressUpdated(this.progress);
  final NearbyTransferProgress progress;

  @override
  List<Object?> get props => [progress];
}

/// A complete payload was received via Nearby Connections.
class NearbyPayloadCompleted extends ChatEvent {
  const NearbyPayloadCompleted(this.payload);
  final NearbyPayloadReceived payload;

  @override
  List<Object?> get props => [payload];
}

/// BLE signal: sender says Wi-Fi transfer is ready for [transferId].
///
/// For full-photo transfers, [transferId] is the photoId and [isPreview] is
/// false.  For thumbnail/preview transfers, [transferId] is `preview-$photoId`
/// and the additional preview metadata fields are populated.
class WifiTransferReadyReceived extends ChatEvent {
  const WifiTransferReadyReceived({
    required this.fromPeerId,
    required this.transferId,
    this.senderNearbyId,
    this.isPreview = false,
    this.photoId,
    this.originalSize,
    this.messageId,
  });

  final String fromPeerId;
  final String transferId;

  /// The sender's userId used as the Nearby Connections device name.
  /// This is different from [fromPeerId] which is the BLE device ID.
  final String? senderNearbyId;
  final bool isPreview;
  final String? photoId;
  final int? originalSize;
  final String? messageId;

  @override
  List<Object?> get props => [
        fromPeerId,
        transferId,
        senderNearbyId,
        isPreview,
        photoId,
        originalSize,
        messageId,
      ];
}

/// Internal event: register a pending outgoing photo from a background send.
class RegisterPendingOutgoingPhoto extends ChatEvent {
  const RegisterPendingOutgoingPhoto({required this.photo});
  final PendingOutgoingPhoto photo;

  @override
  List<Object?> get props => [photo];
}
