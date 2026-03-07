import 'dart:async';

import 'package:anchor/services/notification_service.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/logger.dart';
import '../../../data/local_database/database.dart';
import '../../../data/repositories/chat_repository.dart';
import '../../../data/repositories/peer_repository.dart';
import '../../../services/ble/ble.dart' as ble;
import '../../../services/image_service.dart';
import 'chat_event.dart';
import 'chat_state.dart';

class ChatBloc extends Bloc<ChatEvent, ChatState> {
  ChatBloc({
    required ChatRepository chatRepository,
    required PeerRepository peerRepository,
    required ImageService imageService,
    required ble.BleServiceInterface bleService,
    required NotificationService notificationService,
    required String ownUserId,
  })  : _chatRepository = chatRepository,
        _peerRepository = peerRepository,
        _imageService = imageService,
        _bleService = bleService,
        _notificationService = notificationService,
        _ownUserId = ownUserId,
        super(const ChatState()) {
    on<LoadConversations>(_onLoadConversations);
    on<OpenConversation>(_onOpenConversation);
    on<LoadMessages>(_onLoadMessages);
    on<SendTextMessage>(_onSendTextMessage);
    on<SendPhotoMessage>(_onSendPhotoMessage);
    on<MessageReceived>(_onMessageReceived);
    on<BleMessageReceived>(_onBleMessageReceived);
    on<MessageStatusUpdated>(_onMessageStatusUpdated);
    on<PhotoTransferProgressUpdated>(_onPhotoTransferProgress);
    on<RetryFailedMessage>(_onRetryFailedMessage);
    on<MarkMessagesRead>(_onMarkMessagesRead);
    on<CloseConversation>(_onCloseConversation);
    on<DeleteConversation>(_onDeleteConversation);
    on<ClearChatError>(_onClearError);
    on<BlockChatPeer>(_onBlockChatPeer);
    on<UnblockChatPeer>(_onUnblockChatPeer);

    // Subscribe to BLE message stream
    _messageSubscription = _bleService.messageReceivedStream.listen(
      (msg) => add(BleMessageReceived(msg)),
    );

    // Subscribe to BLE photo progress stream
    _photoProgressSubscription = _bleService.photoProgressStream.listen(
      (progress) => add(PhotoTransferProgressUpdated(progress)),
    );

    // Subscribe to BLE photo received stream
    _photoReceivedSubscription = _bleService.photoReceivedStream.listen(
      _onBlePhotoReceived,
    );
  }

  final ChatRepository _chatRepository;
  final PeerRepository _peerRepository;
  final ImageService _imageService;
  final ble.BleServiceInterface _bleService;
  final NotificationService _notificationService;
  final String _ownUserId;

  // BLE subscriptions
  StreamSubscription<ble.ReceivedMessage>? _messageSubscription;
  StreamSubscription<ble.PhotoTransferProgress>? _photoProgressSubscription;
  StreamSubscription<ble.ReceivedPhoto>? _photoReceivedSubscription;

  // Mock echo timer (for testing when using MockBleService)
  Timer? _echoTimer;

  String get ownUserId => _ownUserId;

  Future<void> _onLoadConversations(
    LoadConversations event,
    Emitter<ChatState> emit,
  ) async {
    emit(state.copyWith(status: ChatStatus.loading));

    try {
      final conversations = await _chatRepository.getAllConversations();
      emit(state.copyWith(
        status: ChatStatus.loaded,
        conversations: conversations,
      ));
      // Keep app icon badge in sync with total unread count
      final totalUnread =
          conversations.fold(0, (sum, c) => sum + c.unreadCount);
      await _notificationService.setBadgeCount(totalUnread);
    } catch (e) {
      Logger.error('Failed to load conversations', e, null, 'ChatBloc');
      emit(state.copyWith(
        status: ChatStatus.error,
        errorMessage: 'Failed to load conversations',
      ));
    }
  }

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

      emit(state.copyWith(
        status: ChatStatus.loaded,
        messages: allMessages,
        hasMoreMessages: messages.length >= AppConstants.messagePageSize,
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

    emit(state.copyWith(status: ChatStatus.sending));

    try {
      // Save message to database as pending
      final message = await _chatRepository.sendTextMessage(
        conversationId: state.currentConversation!.id,
        senderId: _ownUserId,
        text: event.text.trim(),
      );

      // Add to messages list
      emit(state.copyWith(
        status: ChatStatus.loaded,
        messages: [message, ...state.messages],
      ));

      // Send via BLE
      final payload = ble.MessagePayload(
        messageId: message.id,
        type: ble.MessageType.text,
        content: event.text.trim(),
      );

      final success = await _bleService.sendMessage(
        state.currentConversation!.peerId,
        payload,
      );

      if (success) {
        add(MessageStatusUpdated(
          messageId: message.id,
          status: MessageStatus.sent,
        ));
      } else {
        add(MessageStatusUpdated(
          messageId: message.id,
          status: MessageStatus.failed,
        ));
      }

      // Refresh conversations
      add(const LoadConversations());
    } catch (e) {
      Logger.error('Failed to send message', e, null, 'ChatBloc');
      emit(state.copyWith(
        status: ChatStatus.error,
        errorMessage: 'Failed to send message',
      ));
    }
  }

  Future<void> _onSendPhotoMessage(
    SendPhotoMessage event,
    Emitter<ChatState> emit,
  ) async {
    if (state.currentConversation == null) return;
    if (state.isBlocked) return;

    emit(state.copyWith(status: ChatStatus.sending));

    try {
      // Compress the photo for chat (target ~100-200KB)
      final compressedPath =
          await _imageService.compressForChat(event.photoPath);

      // Save photo message to database as pending
      final message = await _chatRepository.sendPhotoMessage(
        conversationId: state.currentConversation!.id,
        senderId: _ownUserId,
        photoPath: compressedPath,
      );

      // Add to messages list with transfer progress tracking
      final updatedTransfers =
          Map<String, PhotoTransferInfo>.from(state.photoTransfers);
      updatedTransfers[message.id] = PhotoTransferInfo(
        messageId: message.id,
        progress: 0,
        isSending: true,
      );

      emit(state.copyWith(
        status: ChatStatus.loaded,
        messages: [message, ...state.messages],
        photoTransfers: updatedTransfers,
      ));

      // Compress aggressively for BLE transfer (~50KB) while keeping the
      // higher-quality local copy for display.
      // compressedPath is a relative path (for DB storage); resolve to absolute.
      final absolutePath =
          await resolvePhotoPath(compressedPath) ?? compressedPath;
      final photoBytes =
          await _imageService.compressForBleTransfer(absolutePath);
      final success = await _bleService.sendPhoto(
        state.currentConversation!.peerId,
        photoBytes,
        message.id,
      );

      if (!success) {
        add(MessageStatusUpdated(
          messageId: message.id,
          status: MessageStatus.failed,
        ));
      }
      // Status will be updated via PhotoTransferProgressUpdated events

      // Refresh conversations
      add(const LoadConversations());
    } catch (e) {
      Logger.error('Failed to send photo', e, null, 'ChatBloc');
      emit(state.copyWith(
        status: ChatStatus.error,
        errorMessage: 'Failed to send photo',
      ));
    }
  }

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

      // Refresh conversations
      add(const LoadConversations());
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

      // Get or create conversation with this peer
      final conversation =
          await _chatRepository.getOrCreateConversation(bleMsg.fromPeerId);

      await _notificationService.showMessageNotification(
        fromPeerId: bleMsg.fromPeerId,
        fromName: state.currentConversation?.peerName ?? 'Unknown',
        messagePreview: bleMsg.type == ble.MessageType.text
            ? bleMsg.content
            : 'Photo received',
      );

      // Save received message to database
      final message = await _chatRepository.receiveMessage(
        conversationId: conversation.id,
        senderId: bleMsg.fromPeerId,
        contentType: bleMsg.type == ble.MessageType.text
            ? MessageContentType.text
            : MessageContentType.photo,
        textContent:
            bleMsg.type == ble.MessageType.text ? bleMsg.content : null,
      );

      // If viewing this conversation, add to UI and immediately mark as read
      if (state.currentConversation?.peerId == bleMsg.fromPeerId) {
        emit(state.copyWith(
          messages: [message, ...state.messages],
        ));
        add(const MarkMessagesRead());
      }

      // Refresh conversations list
      add(const LoadConversations());

      Logger.info(
        'ChatBloc: Received BLE message from ${bleMsg.fromPeerId.substring(0, 8)}',
        'Chat',
      );
    } catch (e) {
      Logger.error('Failed to handle BLE message', e, null, 'ChatBloc');
    }
  }

  /// Handle photo transfer progress updates
  void _onPhotoTransferProgress(
    PhotoTransferProgressUpdated event,
    Emitter<ChatState> emit,
  ) {
    final progress = event.progress;
    final updatedTransfers =
        Map<String, PhotoTransferInfo>.from(state.photoTransfers);

    if (progress.status == ble.PhotoTransferStatus.completed) {
      // Remove from tracking and update message status
      updatedTransfers.remove(progress.messageId);
      add(MessageStatusUpdated(
        messageId: progress.messageId,
        status: MessageStatus.sent,
      ));
    } else if (progress.status == ble.PhotoTransferStatus.failed ||
        progress.status == ble.PhotoTransferStatus.cancelled) {
      // Remove from tracking and mark as failed
      updatedTransfers.remove(progress.messageId);
      add(MessageStatusUpdated(
        messageId: progress.messageId,
        status: MessageStatus.failed,
      ));
    } else {
      // Update progress
      updatedTransfers[progress.messageId] = PhotoTransferInfo(
        messageId: progress.messageId,
        progress: progress.progress,
        isSending: true, // Receiving progress tracked separately
      );
    }

    emit(state.copyWith(photoTransfers: updatedTransfers));
  }

  /// Handle BLE photo received from peer
  Future<void> _onBlePhotoReceived(ble.ReceivedPhoto photo) async {
    try {
      // Discard photos from blocked peers
      if (await _peerRepository.isPeerBlocked(photo.fromPeerId)) return;

      // Get or create conversation with this peer
      final conversation =
          await _chatRepository.getOrCreateConversation(photo.fromPeerId);

      // Save photo to file
      final photoPath = await _imageService.saveReceivedPhoto(photo.photoBytes);

      // Save received photo message to database
      final message = await _chatRepository.receiveMessage(
        conversationId: conversation.id,
        senderId: photo.fromPeerId,
        contentType: MessageContentType.photo,
        photoPath: photoPath,
      );

      // Add MessageReceived event to update UI
      add(MessageReceived(message));

      Logger.info(
        'ChatBloc: Received BLE photo from ${photo.fromPeerId.substring(0, 8)}',
        'Chat',
      );
    } catch (e) {
      Logger.error('Failed to handle BLE photo', e, null, 'ChatBloc');
    }
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

    try {
      // Mark as pending in DB and state
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
          );
        }
        return msg;
      }).toList();

      emit(state.copyWith(status: ChatStatus.sending, messages: updatedMessages));

      bool success;

      if (message.contentType == MessageContentType.text) {
        final payload = ble.MessagePayload(
          messageId: message.id,
          type: ble.MessageType.text,
          content: message.textContent ?? '',
        );
        success = await _bleService.sendMessage(
          state.currentConversation!.peerId,
          payload,
        );
      } else {
        // Photo retry — re-compress from stored path and resend
        final absolutePath =
            await resolvePhotoPath(message.photoPath) ?? message.photoPath!;
        final photoBytes =
            await _imageService.compressForBleTransfer(absolutePath);
        success = await _bleService.sendPhoto(
          state.currentConversation!.peerId,
          photoBytes,
          message.id,
        );
      }

      add(MessageStatusUpdated(
        messageId: message.id,
        status: success ? MessageStatus.sent : MessageStatus.failed,
      ));
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
    } catch (e) {
      Logger.error('Failed to mark messages as read', e, null, 'ChatBloc');
    }
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

  Future<void> _onDeleteConversation(
    DeleteConversation event,
    Emitter<ChatState> emit,
  ) async {
    try {
      await _chatRepository.deleteConversation(event.conversationId);

      final updatedConversations = state.conversations
          .where((c) => c.conversation.id != event.conversationId)
          .toList();

      emit(state.copyWith(conversations: updatedConversations));
    } catch (e) {
      Logger.error('Failed to delete conversation', e, null, 'ChatBloc');
      emit(state.copyWith(
        status: ChatStatus.error,
        errorMessage: 'Failed to delete conversation',
      ));
    }
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

  @override
  Future<void> close() {
    _echoTimer?.cancel();
    _messageSubscription?.cancel();
    _photoProgressSubscription?.cancel();
    _photoReceivedSubscription?.cancel();
    return super.close();
  }
}
