import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../local_database/database.dart';

/// Repository for managing conversations and messages
class ChatRepository {
  ChatRepository(this._db);

  final AppDatabase _db;
  static const _uuid = Uuid();

  // ==================== Conversations ====================

  /// Get all conversations with peer details
  Future<List<ConversationWithPeer>> getAllConversations() async {
    final query = _db.select(_db.conversations).join([
      leftOuterJoin(
        _db.discoveredPeers,
        _db.discoveredPeers.peerId.equalsExp(_db.conversations.peerId),
      ),
    ]);
    query.orderBy([OrderingTerm.desc(_db.conversations.updatedAt)]);

    final results = await query.get();
    final conversations = <ConversationWithPeer>[];

    for (final row in results) {
      final conversation = row.readTable(_db.conversations);
      final peer = row.readTableOrNull(_db.discoveredPeers);

      // Get last message
      final lastMessage = await getLastMessage(conversation.id);

      // Get unread count
      final unreadCount = await getUnreadCount(conversation.id);

      conversations.add(ConversationWithPeer(
        conversation: conversation,
        peer: peer,
        lastMessage: lastMessage,
        unreadCount: unreadCount,
      ));
    }

    return conversations;
  }

  /// Get a conversation by ID
  Future<ConversationEntry?> getConversationById(String id) async {
    return await (_db.select(_db.conversations)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// Get or create a conversation with a peer
  Future<ConversationEntry> getOrCreateConversation(String peerId) async {
    // Try to find existing
    final existing = await (_db.select(_db.conversations)
          ..where((t) => t.peerId.equals(peerId)))
        .getSingleOrNull();

    if (existing != null) {
      return existing;
    }

    // Create new
    final now = DateTime.now();
    final id = _uuid.v4();

    final entry = ConversationsCompanion.insert(
      id: id,
      peerId: peerId,
      createdAt: now,
      updatedAt: now,
    );

    await _db.into(_db.conversations).insert(entry);

    return ConversationEntry(
      id: id,
      peerId: peerId,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Update conversation's updated_at timestamp
  Future<void> touchConversation(String id) async {
    await (_db.update(_db.conversations)..where((t) => t.id.equals(id)))
        .write(ConversationsCompanion(updatedAt: Value(DateTime.now())));
  }

  /// Delete a conversation and all its messages
  Future<void> deleteConversation(String id) async {
    await _db.transaction(() async {
      // Delete messages first
      await (_db.delete(_db.messages)..where((t) => t.conversationId.equals(id)))
          .go();
      // Delete conversation
      await (_db.delete(_db.conversations)..where((t) => t.id.equals(id))).go();
    });
  }

  /// Watch all conversations
  Stream<List<ConversationEntry>> watchConversations() {
    return (_db.select(_db.conversations)
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .watch();
  }

  // ==================== Messages ====================

  /// Get messages for a conversation
  Future<List<MessageEntry>> getMessages(
    String conversationId, {
    int limit = 50,
    int offset = 0,
  }) async {
    return await (_db.select(_db.messages)
          ..where((t) => t.conversationId.equals(conversationId))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit, offset: offset))
        .get();
  }

  /// Get the last message in a conversation
  Future<MessageEntry?> getLastMessage(String conversationId) async {
    return await (_db.select(_db.messages)
          ..where((t) => t.conversationId.equals(conversationId))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(1))
        .getSingleOrNull();
  }

  /// Send a text message
  Future<MessageEntry> sendTextMessage({
    required String conversationId,
    required String senderId,
    required String text,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now();

    final entry = MessagesCompanion.insert(
      id: id,
      conversationId: conversationId,
      senderId: senderId,
      contentType: MessageContentType.text,
      textContent: Value(text),
      status: MessageStatus.pending,
      createdAt: now,
    );

    await _db.into(_db.messages).insert(entry);

    // Update conversation timestamp
    await touchConversation(conversationId);

    return MessageEntry(
      id: id,
      conversationId: conversationId,
      senderId: senderId,
      contentType: MessageContentType.text,
      textContent: text,
      photoPath: null,
      status: MessageStatus.pending,
      createdAt: now,
    );
  }

  /// Send a photo message
  Future<MessageEntry> sendPhotoMessage({
    required String conversationId,
    required String senderId,
    required String photoPath,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now();

    final entry = MessagesCompanion.insert(
      id: id,
      conversationId: conversationId,
      senderId: senderId,
      contentType: MessageContentType.photo,
      photoPath: Value(photoPath),
      status: MessageStatus.pending,
      createdAt: now,
    );

    await _db.into(_db.messages).insert(entry);

    // Update conversation timestamp
    await touchConversation(conversationId);

    return MessageEntry(
      id: id,
      conversationId: conversationId,
      senderId: senderId,
      contentType: MessageContentType.photo,
      textContent: null,
      photoPath: photoPath,
      status: MessageStatus.pending,
      createdAt: now,
    );
  }

  /// Receive a message (from BLE)
  Future<MessageEntry> receiveMessage({
    required String conversationId,
    required String senderId,
    required MessageContentType contentType,
    String? textContent,
    String? photoPath,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now();

    final entry = MessagesCompanion.insert(
      id: id,
      conversationId: conversationId,
      senderId: senderId,
      contentType: contentType,
      textContent: Value(textContent),
      photoPath: Value(photoPath),
      status: MessageStatus.delivered,
      createdAt: now,
    );

    await _db.into(_db.messages).insert(entry);

    // Update conversation timestamp
    await touchConversation(conversationId);

    return MessageEntry(
      id: id,
      conversationId: conversationId,
      senderId: senderId,
      contentType: contentType,
      textContent: textContent,
      photoPath: photoPath,
      status: MessageStatus.delivered,
      createdAt: now,
    );
  }

  /// Update message status
  Future<void> updateMessageStatus(String id, MessageStatus status) async {
    await (_db.update(_db.messages)..where((t) => t.id.equals(id)))
        .write(MessagesCompanion(status: Value(status)));
  }

  /// Mark all pending messages as failed
  Future<void> markPendingAsFailed(String conversationId) async {
    await (_db.update(_db.messages)
          ..where((t) =>
              t.conversationId.equals(conversationId) &
              t.status.equalsValue(MessageStatus.pending)))
        .write(const MessagesCompanion(status: Value(MessageStatus.failed)));
  }

  /// Delete a message
  Future<void> deleteMessage(String id) async {
    await (_db.delete(_db.messages)..where((t) => t.id.equals(id))).go();
  }

  /// Get unread count for a conversation (messages from peer)
  Future<int> getUnreadCount(String conversationId, {String? localUserId}) async {
    // For simplicity, count messages with status 'delivered' that aren't from local user
    // In a real app, you'd track read status separately
    final count = _db.messages.id.count();
    final query = _db.selectOnly(_db.messages)
      ..where(_db.messages.conversationId.equals(conversationId))
      ..where(_db.messages.status.equalsValue(MessageStatus.delivered));
    if (localUserId != null) {
      query.where(_db.messages.senderId.equals(localUserId).not());
    }
    query.addColumns([count]);
    final result = await query.getSingle();
    return result.read(count) ?? 0;
  }

  /// Watch messages for a conversation
  Stream<List<MessageEntry>> watchMessages(String conversationId) {
    return (_db.select(_db.messages)
          ..where((t) => t.conversationId.equals(conversationId))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch();
  }

  /// Get message count for a conversation
  Future<int> getMessageCount(String conversationId) async {
    final count = _db.messages.id.count();
    final query = _db.selectOnly(_db.messages)
      ..where(_db.messages.conversationId.equals(conversationId))
      ..addColumns([count]);
    final result = await query.getSingle();
    return result.read(count) ?? 0;
  }

  /// Retry sending a failed message
  Future<void> retryMessage(String id) async {
    await updateMessageStatus(id, MessageStatus.pending);
  }
}

/// Helper class for conversation with peer details
class ConversationWithPeer {
  const ConversationWithPeer({
    required this.conversation,
    this.peer,
    this.lastMessage,
    this.unreadCount = 0,
  });

  final ConversationEntry conversation;
  final DiscoveredPeerEntry? peer;
  final MessageEntry? lastMessage;
  final int unreadCount;
}
