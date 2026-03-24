import 'package:anchor/data/local_database/database.dart';
import 'package:anchor/data/repositories/chat_repository.dart';

/// Abstract interface for [ChatRepository].
///
/// Consumers should depend on this interface rather than the concrete
/// implementation so that repositories can be easily swapped for testing
/// or alternative storage backends.
abstract class ChatRepositoryInterface {
  // ==================== Conversations ====================

  Future<List<ConversationWithPeer>> getAllConversations();

  Future<ConversationEntry?> getConversationById(String id);

  Future<ConversationEntry> getOrCreateConversation(String peerId);

  Future<void> touchConversation(String id);

  Future<void> deleteConversation(String id);

  Stream<List<ConversationEntry>> watchConversations();

  // ==================== Messages ====================

  Future<List<MessageEntry>> getMessages(
    String conversationId, {
    int limit = 50,
    int offset = 0,
  });

  Future<MessageEntry?> getMessageById(String messageId);

  Future<MessageEntry?> getLastMessage(String conversationId);

  Future<MessageEntry> sendTextMessage({
    required String conversationId,
    required String senderId,
    required String text,
    String? replyToMessageId,
  });

  Future<MessageEntry> sendPhotoMessage({
    required String conversationId,
    required String senderId,
    required String photoPath,
  });

  Future<MessageEntry?> receiveMessage({
    required String conversationId,
    required String senderId,
    required MessageContentType contentType,
    String? textContent,
    String? photoPath,
    String? id,
    String? replyToMessageId,
  });

  Future<MessageEntry?> receivePhotoPreview({
    required String conversationId,
    required String senderId,
    required String textContent,
    String? thumbnailPath,
    String? id,
  });

  Future<MessageEntry?> upgradePreviewToPhoto({
    required String messageId,
    required String fullPhotoPath,
  });

  Future<void> updateMessageStatus(String id, MessageStatus status);

  Future<void> markPendingAsFailed(String conversationId);

  Future<void> deleteMessage(String id);

  Future<int> getUnreadCount(String conversationId, {String? localUserId});

  Future<void> markConversationRead(String conversationId);

  Future<void> markSentMessagesRead(String conversationId, String ownUserId);

  Stream<List<MessageEntry>> watchMessages(String conversationId);

  Future<int> getMessageCount(String conversationId);

  Future<void> retryMessage(String id);

  Future<ConversationEntry?> getConversationByPeerId(String peerId);

  Future<MessageEntry?> addMessage({
    required String conversationId,
    required String senderId,
    String? textContent,
    String? photoPath,
  });

  Future<List<ConversationWithPeer>> getConversationsWithPeers();

  Future<void> clearAllConversations();

  Future<int> getUnreadMessageCount(String senderId);

  Future<void> updateMessagePhotoPath(String messageId, String photoPath);

  Future<void> updateMessagePhotoId(String messageId, String photoId);

  Future<MessageEntry?> findPreviewByPhotoId(String photoId);

  Future<MessageEntry?> findMessageByPhotoId(String photoId);

  Future<MessageEntry?> findRecentOutgoingPhoto({
    required String ownUserId,
    required String peerId,
  });

  // ==================== Store-and-Forward ====================

  Future<List<MessageEntry>> getPendingOutgoingMessages({
    required String ownUserId,
    required String conversationId,
  });

  Future<void> updateRetryMetadata(
    String messageId, {
    required int retryCount,
    required DateTime lastAttemptAt,
  });

  Future<void> expireStaleOutgoingMessages(String ownUserId, Duration window);

  // ==================== Reactions ====================

  Future<void> addReaction({
    required String messageId,
    required String senderId,
    required String emoji,
  });

  Future<void> removeReaction({
    required String messageId,
    required String senderId,
    required String emoji,
  });

  Future<Map<String, List<ReactionEntry>>> getReactionsForConversation(
    String conversationId,
  );
}
