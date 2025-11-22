import 'package:drift/drift.dart';

import '../local_database/database.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';

/// Repository for managing chat messages and conversations
class ChatRepository {
  ChatRepository(this._database);

  final AppDatabase _database;

  // ==================== Messages ====================

  /// Save a new message
  Future<void> saveMessage(ChatMessage message) async {
    final companion = ChatMessagesCompanion(
      id: Value(message.id),
      conversationId: Value(message.conversationId),
      senderId: Value(message.senderId),
      receiverId: Value(message.receiverId),
      content: Value(message.content),
      timestamp: Value(message.timestamp),
      isDelivered: Value(message.isDelivered),
      isRead: Value(message.isRead),
      isSentByMe: Value(message.isSentByMe),
    );

    await _database.into(_database.chatMessages).insertOnConflictUpdate(companion);
  }

  /// Get messages for a conversation
  Future<List<ChatMessage>> getMessagesForConversation(
    String conversationId, {
    int limit = 20,
    int offset = 0,
  }) async {
    final results = await (_database.select(_database.chatMessages)
          ..where((tbl) => tbl.conversationId.equals(conversationId))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)])
          ..limit(limit, offset: offset))
        .get();

    return results.map(_mapToMessage).toList();
  }

  /// Mark messages as read
  Future<void> markMessagesAsRead(String conversationId) async {
    await (_database.update(_database.chatMessages)
          ..where((tbl) => tbl.conversationId.equals(conversationId))
          ..where((tbl) => tbl.isRead.equals(false))
          ..where((tbl) => tbl.isSentByMe.equals(false)))
        .write(const ChatMessagesCompanion(isRead: Value(true)));
  }

  /// Mark message as delivered
  Future<void> markMessageAsDelivered(String messageId) async {
    await (_database.update(_database.chatMessages)
          ..where((tbl) => tbl.id.equals(messageId)))
        .write(const ChatMessagesCompanion(isDelivered: Value(true)));
  }

  /// Delete a message
  Future<void> deleteMessage(String messageId) async {
    await (_database.delete(_database.chatMessages)
          ..where((tbl) => tbl.id.equals(messageId)))
        .go();
  }

  // ==================== Conversations ====================

  /// Get or create a conversation with a user
  Future<Conversation> getOrCreateConversation({
    required String participantId,
    required String participantName,
    String? participantPhotoUrl,
  }) async {
    // Try to find existing conversation
    final existing = await (_database.select(_database.conversations)
          ..where((tbl) => tbl.participantId.equals(participantId)))
        .getSingleOrNull();

    if (existing != null) {
      return _mapToConversation(existing);
    }

    // Create new conversation
    final now = DateTime.now();
    final conversationId = '${participantId}_${now.millisecondsSinceEpoch}';

    final companion = ConversationsCompanion(
      id: Value(conversationId),
      participantId: Value(participantId),
      participantName: Value(participantName),
      participantPhotoUrl: Value(participantPhotoUrl),
      unreadCount: const Value(0),
      createdAt: Value(now),
      updatedAt: Value(now),
    );

    await _database.into(_database.conversations).insert(companion);

    return Conversation(
      id: conversationId,
      participantId: participantId,
      participantName: participantName,
      participantPhotoUrl: participantPhotoUrl,
      unreadCount: 0,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Get all conversations
  Future<List<Conversation>> getAllConversations() async {
    final results = await (_database.select(_database.conversations)
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.updatedAt)]))
        .get();

    final conversations = <Conversation>[];
    for (final row in results) {
      final conversation = _mapToConversation(row);

      // Get last message
      final lastMessage = await (_database.select(_database.chatMessages)
            ..where((tbl) => tbl.conversationId.equals(row.id))
            ..orderBy([(tbl) => OrderingTerm.desc(tbl.timestamp)])
            ..limit(1))
          .getSingleOrNull();

      conversations.add(conversation.copyWith(
        lastMessage: lastMessage != null ? _mapToMessage(lastMessage) : null,
      ));
    }

    return conversations;
  }

  /// Update conversation's unread count
  Future<void> updateUnreadCount(String conversationId, int count) async {
    await (_database.update(_database.conversations)
          ..where((tbl) => tbl.id.equals(conversationId)))
        .write(ConversationsCompanion(
      unreadCount: Value(count),
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// Delete a conversation and all its messages
  Future<void> deleteConversation(String conversationId) async {
    await (_database.delete(_database.chatMessages)
          ..where((tbl) => tbl.conversationId.equals(conversationId)))
        .go();
    await (_database.delete(_database.conversations)
          ..where((tbl) => tbl.id.equals(conversationId)))
        .go();
  }

  ChatMessage _mapToMessage(dynamic row) {
    return ChatMessage(
      id: row.id,
      conversationId: row.conversationId,
      senderId: row.senderId,
      receiverId: row.receiverId,
      content: row.content,
      timestamp: row.timestamp,
      isDelivered: row.isDelivered,
      isRead: row.isRead,
      isSentByMe: row.isSentByMe,
    );
  }

  Conversation _mapToConversation(dynamic row) {
    return Conversation(
      id: row.id,
      participantId: row.participantId,
      participantName: row.participantName,
      participantPhotoUrl: row.participantPhotoUrl,
      unreadCount: row.unreadCount,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }
}
