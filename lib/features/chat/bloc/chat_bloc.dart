import 'dart:async';
import 'package:anchor/services/chat_event_bus.dart';
import 'package:anchor/services/message_send_service.dart';
import 'package:anchor/services/notification_service.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/logger.dart';
import '../../../data/local_database/database.dart';
import '../../../data/repositories/chat_repository.dart';
import '../../../data/repositories/peer_repository.dart';
import '../../../services/ble/ble.dart' as ble;
import '../../../services/encryption/encryption.dart';
import '../../../services/store_and_forward_service.dart';
import '../../../services/transport/transport.dart';
import 'chat_event.dart';
import 'chat_state.dart';

class ChatBloc extends Bloc<ChatEvent, ChatState> {
  ChatBloc({
    required ChatRepository chatRepository,
    required PeerRepository peerRepository,
    required TransportManager transportManager,
    required NotificationService notificationService,
    required String ownUserId,
    required MessageSendService messageSendService,
    required ChatEventBus chatEventBus,
    StoreAndForwardService? storeAndForwardService,
    EncryptionService? encryptionService,
    TransportRetryQueue? retryQueue,
  })  : _chatRepository = chatRepository,
        _peerRepository = peerRepository,
        _transportManager = transportManager,
        _notificationService = notificationService,
        _ownUserId = ownUserId,
        _messageSendService = messageSendService,
        _chatEventBus = chatEventBus,
        _storeAndForwardService = storeAndForwardService,
        _encryptionService = encryptionService,
        _retryQueue = retryQueue,
        super(const ChatState()) {
    on<OpenConversation>(_onOpenConversation);
    on<LoadMessages>(_onLoadMessages);
    on<SendTextMessage>(_onSendTextMessage);
    on<SendPhotoMessage>(_onSendPhotoMessage);
    on<MessageReceived>(_onMessageReceived);
    on<BleMessageReceived>(_onBleMessageReceived);
    on<MessageStatusUpdated>(_onMessageStatusUpdated);
    on<RetryFailedMessage>(_onRetryFailedMessage);
    on<MarkMessagesRead>(_onMarkMessagesRead);
    on<CloseConversation>(_onCloseConversation);
    on<ClearChatError>(_onClearError);
    on<BlockChatPeer>(_onBlockChatPeer);
    on<UnblockChatPeer>(_onUnblockChatPeer);
    // Peer loss + MAC rotation
    on<ChatPeerLost>(_onChatPeerLost);
    on<ChatPeerIdMigrated>(_onChatPeerIdMigrated);
    // Reply
    on<SetReplyingTo>(_onSetReplyingTo);
    // Message update from PhotoTransferBloc (preview → full photo swap)
    on<PhotoPreviewUpgraded>(_onPhotoPreviewUpgraded);
    // Note: Reactions are now managed by ReactionBloc.
    // Note: Photo transfers are now managed by PhotoTransferBloc.
    // Note: E2EE handshake is now managed by ChatE2eeBloc.

    // Subscribe to transport manager streams (messages only — photo streams
    // are now handled by PhotoTransferBloc).
    _messageSubscription = _transportManager.messageReceivedStream.listen(
      (msg) => add(BleMessageReceived(msg)),
    );

    _peerIdChangedSubscription =
        _transportManager.peerIdChangedStream.listen(
      (change) => add(ChatPeerIdMigrated(
        oldPeerId: change.oldPeerId,
        newPeerId: change.newPeerId,
      )),
    );

    _peerLostSubscription = _transportManager.peerLostStream.listen(
      (peerId) => add(ChatPeerLost(peerId)),
    );

    // Listen to ChatEventBus for cross-bloc updates from PhotoTransferBloc.
    _busMessageAddedSub = _chatEventBus.messageAdded.listen((msg) {
      if (!isClosed) add(MessageReceived(msg));
    });
    _busStatusUpdatedSub = _chatEventBus.statusUpdated.listen((update) {
      if (!isClosed) {
        add(MessageStatusUpdated(
          messageId: update.messageId,
          status: update.status,
        ));
      }
    });
    _busMessageUpdatedSub = _chatEventBus.messageUpdated.listen((msg) {
      if (!isClosed) add(PhotoPreviewUpgraded(previewMessageId: msg.id, updatedMessage: msg));
    });

    // Subscribe to background delivery updates from StoreAndForwardService
    // so the open conversation UI refreshes without requiring a reload.
    final storeForward = _storeAndForwardService;
    if (storeForward != null) {
      // Re-initialize in case the service deferred init (profile was created
      // after the first app startup call).
      storeForward.initialize();

      _storeForwardSubscription = storeForward.messageStatusStream.listen(
        (update) {
          if (!isClosed) {
            add(MessageStatusUpdated(
              messageId: update.messageId,
              status: update.status,
            ));
          }
        },
      );
    }

    // Subscribe to in-session retry queue delivery updates.
    final rq = _retryQueue;
    if (rq != null) {
      _retryQueueSubscription = rq.deliveryStream.listen((update) {
        if (!isClosed) {
          add(MessageStatusUpdated(
            messageId: update.messageId,
            status: update.delivered ? MessageStatus.sent : MessageStatus.failed,
          ));
        }
      });
    }

    // Subscribe to MessageSendService delivery updates.
    _sendDeliverySubscription = _messageSendService.deliveryStream.listen(
      (update) {
        if (!isClosed) {
          add(MessageStatusUpdated(
            messageId: update.messageId,
            status: update.status,
          ));
        }
      },
    );
    // Note: pendingPhotoStream is now consumed by PhotoTransferBloc.
  }

  final ChatRepository _chatRepository;
  final PeerRepository _peerRepository;
  final TransportManager _transportManager;
  final NotificationService _notificationService;
  final String _ownUserId;
  final MessageSendService _messageSendService;
  final ChatEventBus _chatEventBus;
  final StoreAndForwardService? _storeAndForwardService;
  final EncryptionService? _encryptionService;
  final TransportRetryQueue? _retryQueue;
  StreamSubscription? _retryQueueSubscription;
  StreamSubscription? _sendDeliverySubscription;

  // Transport manager subscriptions
  StreamSubscription<ble.ReceivedMessage>? _messageSubscription;
  StreamSubscription<ble.PeerIdChanged>? _peerIdChangedSubscription;
  StreamSubscription<String>? _peerLostSubscription;

  // Store-and-forward delivery update subscription
  StreamSubscription<MessageDeliveryUpdate>? _storeForwardSubscription;

  // ChatEventBus subscriptions (cross-bloc from PhotoTransferBloc)
  StreamSubscription<MessageEntry>? _busMessageAddedSub;
  StreamSubscription<({String messageId, MessageStatus status})>? _busStatusUpdatedSub;
  StreamSubscription<MessageEntry>? _busMessageUpdatedSub;

  // Mock echo timer (for testing when using MockBleService)
  Timer? _echoTimer;

  String get ownUserId => _ownUserId;

  Future<void> _onOpenConversation(
    OpenConversation event,
    Emitter<ChatState> emit,
  ) async {
    emit(state.copyWith(status: ChatStatus.loading));

    try {
      // Get or create conversation
      final conversationEntry =
          await _chatRepository.getOrCreateConversation(event.peerId);

      // Mark any unread messages as read immediately on open
      await _chatRepository.markConversationRead(conversationEntry.id);
      _sendReadReceipt(event.peerId);

      final isBlocked = await _peerRepository.isPeerBlocked(event.peerId);

      emit(state.copyWith(
        status: ChatStatus.loaded,
        currentConversation: CurrentConversation(
          id: conversationEntry.id,
          peerId: event.peerId,
          peerName: event.peerName,
        ),
        messages: [],
        hasMoreMessages: true,
        isBlocked: isBlocked,
      ));

      // Load messages
      add(const LoadMessages());

      // Note: E2EE handshake is now initiated by ChatE2eeBloc via
      // InitiateE2eeHandshake event dispatched from the UI layer.
    } catch (e) {
      Logger.error('Failed to open conversation', e, null, 'ChatBloc');
      emit(state.copyWith(
        status: ChatStatus.error,
        errorMessage: 'Failed to open conversation',
      ));
    }
  }

  Future<void> _onLoadMessages(
    LoadMessages event,
    Emitter<ChatState> emit,
  ) async {
    if (state.currentConversation == null) return;

    try {
      final offset = event.loadMore ? state.messages.length : 0;
      final messages = await _chatRepository.getMessages(
        state.currentConversation!.id,
        limit: AppConstants.messagePageSize,
        offset: offset,
      );

      final allMessages =
          event.loadMore ? [...state.messages, ...messages] : messages;

      // Build quoted messages map: fetch each unique replyToMessageId once.
      final newQuotedIds = allMessages
          .where((m) => m.replyToMessageId != null)
          .map((m) => m.replyToMessageId!)
          .toSet()
          .difference(state.quotedMessages.keys.toSet());

      final newQuoted = Map<String, MessageEntry>.from(state.quotedMessages);
      await Future.wait(newQuotedIds.map((id) async {
        final quoted = await _chatRepository.getMessageById(id);
        if (quoted != null) newQuoted[id] = quoted;
      }));

      emit(state.copyWith(
        status: ChatStatus.loaded,
        messages: allMessages,
        hasMoreMessages: messages.length >= AppConstants.messagePageSize,
        quotedMessages: newQuoted,
      ));
    } catch (e) {
      Logger.error('Failed to load messages', e, null, 'ChatBloc');
    }
  }

  Future<void> _onSendTextMessage(
    SendTextMessage event,
    Emitter<ChatState> emit,
  ) async {
    if (state.currentConversation == null) return;
    if (event.text.trim().isEmpty) return;
    if (state.isBlocked) return;
    // Never send without an established E2EE session.
    final enc = _encryptionService;
    if (enc != null && !enc.hasSession(state.currentConversation!.peerId)) {
      return;
    }

    try {
      final peerId = state.currentConversation!.peerId;
      final replyToId = event.replyToMessageId;

      // Save message to database as pending
      final message = await _chatRepository.sendTextMessage(
        conversationId: state.currentConversation!.id,
        senderId: _ownUserId,
        text: event.text.trim(),
        replyToMessageId: replyToId,
      );

      // Build updated quoted messages map if this is a reply.
      // Prefer the in-state message (already in memory); fall back to a DB
      // lookup so the sender's bubble always shows the quote.
      final updatedQuoted = Map<String, MessageEntry>.from(state.quotedMessages);
      if (replyToId != null && !updatedQuoted.containsKey(replyToId)) {
        final quoted = state.replyingToMessage ??
            await _chatRepository.getMessageById(replyToId);
        if (quoted != null) updatedQuoted[replyToId] = quoted;
      }

      // Add to messages list immediately — clear reply bar
      emit(state.copyWith(
        status: ChatStatus.loaded,
        messages: [message, ...state.messages],
        quotedMessages: updatedQuoted,
        clearReplyingToMessage: true,
      ));

      // Fire-and-forget: BLE send runs in background via MessageSendService
      _messageSendService.sendText(message, peerId, replyToId: replyToId);
    } catch (e) {
      Logger.error('Failed to send message', e, null, 'ChatBloc');
      emit(state.copyWith(
        status: ChatStatus.error,
        errorMessage: 'Failed to send message',
      ));
    }
  }

  /// Fire-and-forget: notifies [peerId] that we've read their messages.
  /// Runs outside the send queue so it never delays outgoing text messages.
  void _sendReadReceipt(String peerId) {
    _transportManager.sendMessage(
      peerId,
      ble.MessagePayload(
        messageId: const Uuid().v4(),
        type: ble.MessageType.read,
        content: '',
      ),
    ).ignore();
  }

  /// Consent-first photo send:
  ///   1. Compress photo for local display.
  ///   2. Store local message as [photo] type (sender sees their own image).
  ///   3. Send a lightweight [photo_preview] notification via BLE (no thumbnail).
  ///   4. Wait for receiver's [photo_request] — handled by [_onPhotoRequestReceived].
  Future<void> _onSendPhotoMessage(
    SendPhotoMessage event,
    Emitter<ChatState> emit,
  ) async {
    if (state.currentConversation == null) return;
    if (state.isBlocked) return;
    // Never send without an established E2EE session.
    final enc2 = _encryptionService;
    if (enc2 != null && !enc2.hasSession(state.currentConversation!.peerId)) {
      return;
    }

    try {
      final peerId = state.currentConversation!.peerId;
      final conversationId = state.currentConversation!.id;

      // 1. Save local message immediately so the sender sees it in the chat.
      final message = await _chatRepository.sendPhotoMessage(
        conversationId: conversationId,
        senderId: _ownUserId,
        photoPath: event.photoPath,
      );

      // Add to messages list immediately — don't block input
      emit(state.copyWith(
        status: ChatStatus.loaded,
        messages: [message, ...state.messages],
      ));

      // 2. Fire-and-forget: compress + BLE preview send in background via MessageSendService
      _messageSendService.sendPhoto(
        photoPath: event.photoPath,
        message: message,
        peerId: peerId,
      );
    } catch (e) {
      Logger.error('Failed to send photo', e, null, 'ChatBloc');
      emit(state.copyWith(
        status: ChatStatus.error,
        errorMessage: 'Failed to send photo',
      ));
    }
  }

  // Note: Photo preview/consent/transfer handlers are now in PhotoTransferBloc.

  Future<void> _onMessageReceived(
    MessageReceived event,
    Emitter<ChatState> emit,
  ) async {
    try {
      // If this is for the current conversation, add to messages
      if (state.currentConversation?.id == event.message.conversationId) {
        emit(state.copyWith(
          messages: [event.message, ...state.messages],
        ));
      }
    } catch (e) {
      Logger.error('Failed to handle received message', e, null, 'ChatBloc');
    }
  }

  /// Handle BLE message received from peer
  Future<void> _onBleMessageReceived(
    BleMessageReceived event,
    Emitter<ChatState> emit,
  ) async {
    try {
      final bleMsg = event.message;

      // Discard messages from blocked peers
      if (await _peerRepository.isPeerBlocked(bleMsg.fromPeerId)) return;

      // wifiTransferReady signals are handled by PhotoTransferBloc.
      if (bleMsg.type == ble.MessageType.wifiTransferReady) return;

      // Handle read receipt — peer opened our conversation and read our messages.
      if (bleMsg.type == ble.MessageType.read) {
        final conversation =
            await _chatRepository.getConversationByPeerId(bleMsg.fromPeerId);
        if (conversation != null) {
          await _chatRepository.markSentMessagesRead(
              conversation.id, _ownUserId);
          if (state.currentConversation?.peerId == bleMsg.fromPeerId) {
            final updatedMessages = state.messages.map((msg) {
              if (msg.senderId == _ownUserId &&
                  msg.status == MessageStatus.sent &&
                  msg.contentType == MessageContentType.text) {
                return MessageEntry(
                  id: msg.id,
                  conversationId: msg.conversationId,
                  senderId: msg.senderId,
                  contentType: msg.contentType,
                  textContent: msg.textContent,
                  photoPath: msg.photoPath,
                  status: MessageStatus.read,
                  createdAt: msg.createdAt,
                  retryCount: msg.retryCount,
                  lastAttemptAt: msg.lastAttemptAt,
                  replyToMessageId: msg.replyToMessageId,
                );
              }
              return msg;
            }).toList();
            emit(state.copyWith(messages: updatedMessages));
          }
        }
        return;
      }

      // Get or create conversation with this peer
      final conversation =
          await _chatRepository.getOrCreateConversation(bleMsg.fromPeerId);

      final senderPeer =
          await _peerRepository.getPeerById(bleMsg.fromPeerId);
      await _notificationService.showMessageNotification(
        fromPeerId: bleMsg.fromPeerId,
        fromName: senderPeer?.name ?? state.currentConversation?.peerName ?? 'Someone nearby',
        messagePreview: bleMsg.type == ble.MessageType.text
            ? bleMsg.content
            : 'Photo received',
      );

      // Save received message to database, preserving the sender's messageId
      // so both sides share the same stable ID for reaction targeting.
      final message = await _chatRepository.receiveMessage(
        id: bleMsg.messageId,
        conversationId: conversation.id,
        senderId: bleMsg.fromPeerId,
        contentType: bleMsg.type == ble.MessageType.text
            ? MessageContentType.text
            : MessageContentType.photo,
        textContent:
            bleMsg.type == ble.MessageType.text ? bleMsg.content : null,
        replyToMessageId: bleMsg.replyToId,
      );

      // If viewing this conversation, add to UI and immediately mark as read
      if (state.currentConversation?.peerId == bleMsg.fromPeerId) {
        // Fetch quoted message if needed
        final updatedQuoted = Map<String, MessageEntry>.from(state.quotedMessages);
        final replyId = bleMsg.replyToId;
        if (replyId != null && !updatedQuoted.containsKey(replyId)) {
          final quoted = await _chatRepository.getMessageById(replyId);
          if (quoted != null) updatedQuoted[replyId] = quoted;
        }
        emit(state.copyWith(
          messages: [message, ...state.messages],
          quotedMessages: updatedQuoted,
        ));
        add(const MarkMessagesRead());
      }

      // Notify ConversationListBloc to refresh unread badges.
      _chatEventBus.notifyConversationsChanged();

      Logger.info(
        'ChatBloc: Received BLE message from ${bleMsg.fromPeerId.substring(0, 8)}',
        'Chat',
      );
    } catch (e) {
      Logger.error('Failed to handle BLE message', e, null, 'ChatBloc');
    }
  }

  /// Swap a photoPreview bubble with the fully-downloaded photo.
  /// Triggered via ChatEventBus.messageUpdated from PhotoTransferBloc.
  void _onPhotoPreviewUpgraded(
    PhotoPreviewUpgraded event,
    Emitter<ChatState> emit,
  ) {
    final updatedMessages = state.messages.map((m) {
      if (m.id == event.previewMessageId) return event.updatedMessage;
      return m;
    }).toList();

    emit(state.copyWith(messages: updatedMessages));
  }

  Future<void> _onMessageStatusUpdated(
    MessageStatusUpdated event,
    Emitter<ChatState> emit,
  ) async {
    try {
      // Update in database
      await _chatRepository.updateMessageStatus(event.messageId, event.status);

      // Update in state
      final updatedMessages = state.messages.map((msg) {
        if (msg.id == event.messageId) {
          return MessageEntry(
            id: msg.id,
            conversationId: msg.conversationId,
            senderId: msg.senderId,
            contentType: msg.contentType,
            textContent: msg.textContent,
            photoPath: msg.photoPath,
            status: event.status,
            createdAt: msg.createdAt,
            retryCount: msg.retryCount,
            lastAttemptAt: msg.lastAttemptAt,
            replyToMessageId: msg.replyToMessageId,
          );
        }
        return msg;
      }).toList();

      emit(state.copyWith(messages: updatedMessages));
    } catch (e) {
      Logger.error('Failed to update message status', e, null, 'ChatBloc');
    }
  }

  Future<void> _onRetryFailedMessage(
    RetryFailedMessage event,
    Emitter<ChatState> emit,
  ) async {
    if (state.currentConversation == null) return;

    final message = state.messages.firstWhere(
      (m) => m.id == event.messageId,
      orElse: () => throw StateError('Message not found'),
    );

    final peerId = state.currentConversation!.peerId;

    try {
      // Mark as pending in DB and state — don't block input
      await _chatRepository.updateMessageStatus(
          event.messageId, MessageStatus.pending);

      final updatedMessages = state.messages.map((msg) {
        if (msg.id == event.messageId) {
          return MessageEntry(
            id: msg.id,
            conversationId: msg.conversationId,
            senderId: msg.senderId,
            contentType: msg.contentType,
            textContent: msg.textContent,
            photoPath: msg.photoPath,
            status: MessageStatus.pending,
            createdAt: msg.createdAt,
            retryCount: msg.retryCount,
            lastAttemptAt: msg.lastAttemptAt,
            replyToMessageId: msg.replyToMessageId,
          );
        }
        return msg;
      }).toList();

      emit(state.copyWith(status: ChatStatus.loaded, messages: updatedMessages));

      // Fire-and-forget: retry in background via MessageSendService
      if (message.contentType == MessageContentType.text) {
        _messageSendService.sendText(message, peerId, replyToId: message.replyToMessageId);
      } else if (message.contentType == MessageContentType.photo) {
        _messageSendService.retryPhoto(message, peerId);
      }
    } catch (e) {
      Logger.error('Failed to retry message', e, null, 'ChatBloc');
      add(MessageStatusUpdated(
        messageId: event.messageId,
        status: MessageStatus.failed,
      ));
    }
  }

  Future<void> _onMarkMessagesRead(
    MarkMessagesRead event,
    Emitter<ChatState> emit,
  ) async {
    if (state.currentConversation == null) return;

    try {
      // Mark any newly arrived messages as read (e.g. received while chat is open)
      await _chatRepository.markConversationRead(state.currentConversation!.id);
      _sendReadReceipt(state.currentConversation!.peerId);
    } catch (e) {
      Logger.error('Failed to mark messages as read', e, null, 'ChatBloc');
    }
  }

  /// Peer went out of range — no-op for ChatBloc. PhotoTransferBloc handles
  /// cancelling active photo downloads.
  Future<void> _onChatPeerLost(
    ChatPeerLost event,
    Emitter<ChatState> emit,
  ) async {
    // PhotoTransferBloc handles transfer cancellations.
  }

  Future<void> _onCloseConversation(
    CloseConversation event,
    Emitter<ChatState> emit,
  ) async {
    _echoTimer?.cancel();
    emit(state.copyWith(
      clearCurrentConversation: true,
      messages: [],
    ));
  }

  void _onClearError(
    ClearChatError event,
    Emitter<ChatState> emit,
  ) {
    emit(state.copyWith(errorMessage: null));
  }

  Future<void> _onBlockChatPeer(
    BlockChatPeer event,
    Emitter<ChatState> emit,
  ) async {
    if (state.currentConversation == null) return;

    try {
      await _peerRepository.blockPeer(state.currentConversation!.peerId);
      emit(state.copyWith(isBlocked: true));
      Logger.info('Peer blocked from chat', 'ChatBloc');
    } catch (e) {
      Logger.error('Failed to block peer', e, null, 'ChatBloc');
      emit(state.copyWith(errorMessage: 'Failed to block user'));
    }
  }

  Future<void> _onUnblockChatPeer(
    UnblockChatPeer event,
    Emitter<ChatState> emit,
  ) async {
    if (state.currentConversation == null) return;

    try {
      await _peerRepository.unblockPeer(state.currentConversation!.peerId);
      emit(state.copyWith(isBlocked: false));
      Logger.info('Peer unblocked from chat', 'ChatBloc');
    } catch (e) {
      Logger.error('Failed to unblock peer', e, null, 'ChatBloc');
      emit(state.copyWith(errorMessage: 'Failed to unblock user'));
    }
  }

  // Note: Wi-Fi Direct, Nearby, and photo transfer handlers are now in PhotoTransferBloc.

  Future<void> _onChatPeerIdMigrated(
    ChatPeerIdMigrated event,
    Emitter<ChatState> emit,
  ) async {
    final current = state.currentConversation;
    if (current == null || current.peerId != event.oldPeerId) return;

    emit(state.copyWith(
      currentConversation: CurrentConversation(
        id: current.id,
        peerId: event.newPeerId,
        peerName: current.peerName,
      ),
    ));

    Logger.info(
      'ChatBloc: Migrated active conversation peerId '
          '${event.oldPeerId} → ${event.newPeerId}',
      'Chat',
    );
  }

  void _onSetReplyingTo(SetReplyingTo event, Emitter<ChatState> emit) {
    if (event.message == null) {
      emit(state.copyWith(clearReplyingToMessage: true));
    } else {
      emit(state.copyWith(replyingToMessage: event.message));
    }
  }

  @override
  Future<void> close() {
    _echoTimer?.cancel();
    _messageSubscription?.cancel();
    _peerIdChangedSubscription?.cancel();
    _peerLostSubscription?.cancel();
    _storeForwardSubscription?.cancel();
    _retryQueueSubscription?.cancel();
    _sendDeliverySubscription?.cancel();
    _busMessageAddedSub?.cancel();
    _busStatusUpdatedSub?.cancel();
    _busMessageUpdatedSub?.cancel();
    return super.close();
  }
}
