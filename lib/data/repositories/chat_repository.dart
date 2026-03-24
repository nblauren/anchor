import 'package:anchor/core/constants/app_constants.dart';
import 'package:anchor/data/local_database/database.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

/// Repository for managing conversations and messages.
///
/// All [peerId] parameters refer to the peer's stable app-level userId
/// (canonical UUID). Transport-specific IDs are resolved upstream.
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
    ])
      ..orderBy([OrderingTerm.desc(_db.conversations.updatedAt)]);

    final results = await query.get();

    // Run last-message + unread-count queries in parallel (one pair per
    // conversation) instead of sequentially to avoid O(N) blocking.
    return Future.wait(results.map((row) async {
      final conversation = row.readTable(_db.conversations);
      final peer = row.readTableOrNull(_db.discoveredPeers);

      final results = await Future.wait([
        getLastMessage(conversation.id),
        getUnreadCount(conversation.id),
      ]);

      return ConversationWithPeer(
        conversation: conversation,
        peer: peer,
        lastMessage: results[0] as MessageEntry?,
        unreadCount: results[1]! as int,
      );
    }),);
  }

  /// Get a conversation by ID
  Future<ConversationEntry?> getConversationById(String id) async {
    return (_db.select(_db.conversations)..where((t) => t.id.equals(id)))
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

    // Ensure the peer exists in discovered_peers (foreign key requirement).
    // This handles the case where a message arrives before discovery completes.
    final peerExists = await (_db.select(_db.discoveredPeers)
          ..where((t) => t.peerId.equals(peerId)))
        .getSingleOrNull();

    if (peerExists == null) {
      // Use insertOrIgnore to handle the race where BLE discovery inserts
      // the same peerId between our SELECT and this INSERT. We must NOT use
      // insertOnConflictUpdate — it would overwrite the peer's real
      // name/profile with 'Unknown'.
      await _db.into(_db.discoveredPeers).insert(
            DiscoveredPeersCompanion.insert(
              peerId: peerId,
              name: 'Unknown',
              lastSeenAt: DateTime.now(),
            ),
            mode: InsertMode.insertOrIgnore,
          );
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
      await (_db.delete(_db.messages)
            ..where((t) => t.conversationId.equals(id)))
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
    return (_db.select(_db.messages)
          ..where((t) => t.conversationId.equals(conversationId))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit, offset: offset))
        .get();
  }

  /// Get a single message by its ID (used for reply quote lookup).
  Future<MessageEntry?> getMessageById(String messageId) async {
    return (_db.select(_db.messages)
          ..where((t) => t.id.equals(messageId)))
        .getSingleOrNull();
  }

  /// Get the last message in a conversation
  Future<MessageEntry?> getLastMessage(String conversationId) async {
    return (_db.select(_db.messages)
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
    String? replyToMessageId,
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
      replyToMessageId: Value(replyToMessageId),
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
      status: MessageStatus.pending,
      createdAt: now,
      retryCount: 0,
      replyToMessageId: replyToMessageId,
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
      photoPath: photoPath,
      status: MessageStatus.pending,
      createdAt: now,
      retryCount: 0,
    );
  }

  /// Receive a message (from BLE)
  ///
  /// Pass the sender's [id] (from the BLE payload's `messageId`) so that
  /// reactions sent by either side can reference the same stable ID.
  /// Uses insert-or-ignore so duplicate deliveries are silently dropped.
  ///
  /// Returns null if the message was a duplicate (already in DB), allowing
  /// callers to skip UI updates for re-delivered messages.
  Future<MessageEntry?> receiveMessage({
    required String conversationId,
    required String senderId,
    required MessageContentType contentType,
    String? textContent,
    String? photoPath,
    String? id,
    String? replyToMessageId,
  }) async {
    final msgId = id ?? _uuid.v4();

    // Check if this message already exists (duplicate delivery).
    if (id != null) {
      final existing = await getMessageById(id);
      if (existing != null) return null;
    }

    final now = DateTime.now();

    final entry = MessagesCompanion.insert(
      id: msgId,
      conversationId: conversationId,
      senderId: senderId,
      contentType: contentType,
      textContent: Value(textContent),
      photoPath: Value(photoPath),
      status: MessageStatus.delivered,
      createdAt: now,
      replyToMessageId: Value(replyToMessageId),
    );

    await _db.into(_db.messages).insert(
          entry,
          mode: InsertMode.insertOrIgnore,
        );

    // Update conversation timestamp
    await touchConversation(conversationId);

    return MessageEntry(
      id: msgId,
      conversationId: conversationId,
      senderId: senderId,
      contentType: contentType,
      textContent: textContent,
      photoPath: photoPath,
      status: MessageStatus.delivered,
      createdAt: now,
      retryCount: 0,
      replyToMessageId: replyToMessageId,
    );
  }

  /// Persist a received photo preview message.
  ///
  /// [textContent] stores JSON-encoded metadata:
  ///   {"photo_id":"<uuid>","original_size":<bytes>}
  /// [thumbnailPath] is the relative path to the saved thumbnail file.
  ///
  /// Returns null if the message was a duplicate (already in DB).
  Future<MessageEntry?> receivePhotoPreview({
    required String conversationId,
    required String senderId,
    required String textContent,
    String? thumbnailPath,
    String? id,
  }) async {
    final msgId = id ?? _uuid.v4();

    // Check if this message already exists (duplicate delivery).
    if (id != null) {
      final existing = await getMessageById(id);
      if (existing != null) return null;
    }

    final now = DateTime.now();

    final entry = MessagesCompanion.insert(
      id: msgId,
      conversationId: conversationId,
      senderId: senderId,
      contentType: MessageContentType.photoPreview,
      textContent: Value(textContent),
      photoPath: thumbnailPath != null ? Value(thumbnailPath) : const Value.absent(),
      status: MessageStatus.delivered,
      createdAt: now,
    );

    await _db.into(_db.messages).insert(
          entry,
          mode: InsertMode.insertOrIgnore,
        );
    await touchConversation(conversationId);

    return MessageEntry(
      id: msgId,
      conversationId: conversationId,
      senderId: senderId,
      contentType: MessageContentType.photoPreview,
      textContent: textContent,
      photoPath: thumbnailPath,
      status: MessageStatus.delivered,
      createdAt: now,
      retryCount: 0,
    );
  }

  /// Upgrade a [photoPreview] message to a full [photo] message once the
  /// receiver has downloaded the full photo.
  ///
  /// Updates the content type to [photo], replaces the thumbnail path with
  /// the full-resolution photo path, and clears the metadata JSON.
  Future<MessageEntry?> upgradePreviewToPhoto({
    required String messageId,
    required String fullPhotoPath,
  }) async {
    await (_db.update(_db.messages)..where((t) => t.id.equals(messageId)))
        .write(MessagesCompanion(
      contentType: const Value(MessageContentType.photo),
      photoPath: Value(fullPhotoPath),
      textContent: const Value(null),
      status: const Value(MessageStatus.read),
    ),);

    return (_db.select(_db.messages)..where((t) => t.id.equals(messageId)))
        .getSingleOrNull();
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
              t.status.equalsValue(MessageStatus.pending),))
        .write(const MessagesCompanion(status: Value(MessageStatus.failed)));
  }

  /// Delete a message
  Future<void> deleteMessage(String id) async {
    await (_db.delete(_db.messages)..where((t) => t.id.equals(id))).go();
  }

  /// Get unread count for a conversation (messages from peer, not yet read)
  Future<int> getUnreadCount(String conversationId,
      {String? localUserId,}) async {
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

  /// Mark all delivered messages in a conversation as read
  Future<void> markConversationRead(String conversationId) async {
    await (_db.update(_db.messages)
          ..where((t) => t.conversationId.equals(conversationId))
          ..where((t) => t.status.equalsValue(MessageStatus.delivered)))
        .write(const MessagesCompanion(status: Value(MessageStatus.read)));
  }

  /// Mark all [sent] outgoing TEXT messages in a conversation as [read].
  /// Called when a read receipt arrives from the peer.
  ///
  /// Photo messages are intentionally excluded — they should only be marked
  /// [read] after the receiver has actually downloaded the full photo (handled
  /// in ChatBloc._sendFullPhoto). A read receipt fires when the receiver opens
  /// the chat, which precedes any photo download request.
  Future<void> markSentMessagesRead(
    String conversationId,
    String ownUserId,
  ) async {
    await (_db.update(_db.messages)
          ..where((t) =>
              t.conversationId.equals(conversationId) &
              t.senderId.equals(ownUserId) &
              t.status.equalsValue(MessageStatus.sent) &
              t.contentType.equalsValue(MessageContentType.text),))
        .write(const MessagesCompanion(status: Value(MessageStatus.read)));
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

  /// Get conversation by peer ID
  Future<ConversationEntry?> getConversationByPeerId(String peerId) async {
    return (_db.select(_db.conversations)
          ..where((t) => t.peerId.equals(peerId)))
        .getSingleOrNull();
  }

  /// Add a message to a conversation (for received messages)
  Future<MessageEntry?> addMessage({
    required String conversationId,
    required String senderId,
    String? textContent,
    String? photoPath,
  }) async {
    final contentType =
        photoPath != null ? MessageContentType.photo : MessageContentType.text;
    return receiveMessage(
      conversationId: conversationId,
      senderId: senderId,
      contentType: contentType,
      textContent: textContent,
      photoPath: photoPath,
    );
  }

  /// Get conversations with peer details (alias for getAllConversations)
  Future<List<ConversationWithPeer>> getConversationsWithPeers() async {
    return getAllConversations();
  }

  /// Clear all conversations and messages
  Future<void> clearAllConversations() async {
    await _db.transaction(() async {
      await _db.delete(_db.messages).go();
      await _db.delete(_db.conversations).go();
    });
  }

  Future<int> getUnreadMessageCount(String senderId) {
    final count = _db.messages.id.count();
    final query = _db.selectOnly(_db.messages)
      ..where(_db.messages.status.equalsValue(MessageStatus.delivered))
      ..where(_db.messages.senderId.equals(senderId).not())
      ..addColumns([count]);
    return query.getSingle().then((result) => result.read(count) ?? 0);
  }

  /// Persist the stable [photoId] into a sent photo message's [textContent]
  /// so it survives session restarts and can be recovered in [findMessageByPhotoId].
  Future<void> updateMessagePhotoPath(String messageId, String photoPath) async {
    await (_db.update(_db.messages)..where((t) => t.id.equals(messageId)))
        .write(MessagesCompanion(photoPath: Value(photoPath)));
  }

  Future<void> updateMessagePhotoId(String messageId, String photoId) async {
    await (_db.update(_db.messages)..where((t) => t.id.equals(messageId)))
        .write(MessagesCompanion(textContent: Value('{"photo_id":"$photoId"}')));
  }

  /// Find a [photoPreview] message whose JSON textContent contains the given
  /// [photoId]. Used by [PhotoTransferBloc] to match incoming full photos to
  /// their preview bubble.
  Future<MessageEntry?> findPreviewByPhotoId(String photoId) async {
    return (_db.select(_db.messages)
          ..where((t) =>
              t.contentType.equalsValue(MessageContentType.photoPreview) &
              t.textContent.like('%$photoId%'),)
          ..limit(1))
        .getSingleOrNull();
  }

  /// Find a sent photo message by its stored [photoId] (set via [updateMessagePhotoId]).
  /// Used to recover [PendingOutgoingPhoto] data after session restarts.
  Future<MessageEntry?> findMessageByPhotoId(String photoId) async {
    // Try exact content type first (photo messages on the sender side).
    final result = await (_db.select(_db.messages)
          ..where((t) =>
              t.contentType.equalsValue(MessageContentType.photo) &
              t.textContent.like('%$photoId%'),)
          ..limit(1))
        .getSingleOrNull();
    if (result != null) return result;

    // Fallback: search across all content types. The photoId may be stored
    // in a photoPreview message if the content type wasn't updated.
    return (_db.select(_db.messages)
          ..where((t) => t.textContent.like('%$photoId%'))
          ..limit(1))
        .getSingleOrNull();
  }

  /// Find the most recent outgoing photo message for a given peer that has a
  /// valid [photoPath]. Used as a last-resort fallback when [findMessageByPhotoId]
  /// fails (e.g. textContent doesn't contain the photoId).
  Future<MessageEntry?> findRecentOutgoingPhoto({
    required String ownUserId,
    required String peerId,
  }) async {
    // Find conversation for this peer.
    final conversation = await (_db.select(_db.conversations)
          ..where((t) => t.peerId.equals(peerId))
          ..limit(1))
        .getSingleOrNull();
    if (conversation == null) return null;

    // Most recent outgoing photo with a valid photoPath.
    return (_db.select(_db.messages)
          ..where((t) =>
              t.conversationId.equals(conversation.id) &
              t.senderId.equals(ownUserId) &
              t.contentType.equalsValue(MessageContentType.photo) &
              t.photoPath.isNotNull(),)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(1))
        .getSingleOrNull();
  }

  // ==================== Store-and-Forward ====================

  /// Returns pending or failed outgoing text messages for a conversation that
  /// are still within the retry window and haven't exceeded the retry cap.
  /// Used by [StoreAndForwardService] to retry delivery on peer rediscovery.
  Future<List<MessageEntry>> getPendingOutgoingMessages({
    required String ownUserId,
    required String conversationId,
  }) async {
    final cutoff = DateTime.now()
        .subtract(const Duration(hours: AppConstants.messageRetryWindowHours));

    return (_db.select(_db.messages)
          ..where((t) =>
              t.conversationId.equals(conversationId) &
              t.senderId.equals(ownUserId) &
              (t.status.equalsValue(MessageStatus.pending) |
                  t.status.equalsValue(MessageStatus.queued) |
                  t.status.equalsValue(MessageStatus.failed)) &
              (t.contentType.equalsValue(MessageContentType.text) |
                  t.contentType.equalsValue(MessageContentType.photo) |
                  t.contentType.equalsValue(MessageContentType.photoPreview)) &
              t.createdAt.isBiggerThanValue(cutoff) &
              t.retryCount.isSmallerThanValue(
                  AppConstants.messageMaxCrossSessionRetries,),)
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
  }

  /// Updates retry tracking columns without touching message status.
  Future<void> updateRetryMetadata(
    String messageId, {
    required int retryCount,
    required DateTime lastAttemptAt,
  }) async {
    await (_db.update(_db.messages)..where((t) => t.id.equals(messageId)))
        .write(MessagesCompanion(
      retryCount: Value(retryCount),
      lastAttemptAt: Value(lastAttemptAt),
    ),);
  }

  /// Marks all pending/failed outgoing messages older than [window] as failed.
  /// Called at startup to clear stale state from previous sessions.
  Future<void> expireStaleOutgoingMessages(
    String ownUserId,
    Duration window,
  ) async {
    final cutoff = DateTime.now().subtract(window);
    await (_db.update(_db.messages)
          ..where((t) =>
              t.senderId.equals(ownUserId) &
              (t.status.equalsValue(MessageStatus.pending) |
                  t.status.equalsValue(MessageStatus.queued) |
                  t.status.equalsValue(MessageStatus.failed)) &
              t.createdAt.isSmallerThanValue(cutoff),))
        .write(const MessagesCompanion(status: Value(MessageStatus.failed)));
  }

  // ==================== Reactions ====================

  /// Add an emoji reaction on a message, replacing any existing reaction from
  /// the same sender (only one reaction per user per message is allowed).
  Future<void> addReaction({
    required String messageId,
    required String senderId,
    required String emoji,
  }) async {
    // Check for existing same reaction (same sender + emoji + message)
    final existing = await (_db.select(_db.messageReactions)
          ..where((t) =>
              t.messageId.equals(messageId) &
              t.senderId.equals(senderId) &
              t.emoji.equals(emoji),))
        .getSingleOrNull();

    if (existing != null) return; // already reacted with same emoji — no-op

    // Remove any previous reaction from this sender on this message
    await (_db.delete(_db.messageReactions)
          ..where((t) =>
              t.messageId.equals(messageId) & t.senderId.equals(senderId),))
        .go();

    final id = _uuid.v4();
    await _db.into(_db.messageReactions).insert(
          MessageReactionsCompanion.insert(
            id: id,
            messageId: messageId,
            senderId: senderId,
            emoji: emoji,
            createdAt: DateTime.now(),
          ),
        );
  }

  /// Remove an emoji reaction from a message.
  Future<void> removeReaction({
    required String messageId,
    required String senderId,
    required String emoji,
  }) async {
    await (_db.delete(_db.messageReactions)
          ..where((t) =>
              t.messageId.equals(messageId) &
              t.senderId.equals(senderId) &
              t.emoji.equals(emoji),))
        .go();
  }

  /// Return all reactions for messages in a conversation, grouped by messageId.
  Future<Map<String, List<ReactionEntry>>> getReactionsForConversation(
    String conversationId,
  ) async {
    final query = _db.select(_db.messageReactions).join([
      innerJoin(
        _db.messages,
        _db.messages.id.equalsExp(_db.messageReactions.messageId),
      ),
    ])
      ..where(_db.messages.conversationId.equals(conversationId));

    final rows = await query.get();
    final result = <String, List<ReactionEntry>>{};
    for (final row in rows) {
      final reaction = row.readTable(_db.messageReactions);
      result.putIfAbsent(reaction.messageId, () => []).add(reaction);
    }
    return result;
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
