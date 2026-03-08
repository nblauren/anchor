import 'dart:async';
import 'dart:convert';

import 'package:anchor/services/notification_service.dart';
import 'package:uuid/uuid.dart';
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
    // Photo preview / consent flow
    on<PhotoPreviewReceived>(_onPhotoPreviewReceived);
    on<RequestFullPhoto>(_onRequestFullPhoto);
    on<PhotoRequestReceived>(_onPhotoRequestReceived);
    on<CancelPhotoTransfer>(_onCancelPhotoTransfer);
    on<PhotoPreviewUpgraded>(_onPhotoPreviewUpgraded);

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

    // Subscribe to photo-preview and photo-request streams
    _photoPreviewSubscription = _bleService.photoPreviewReceivedStream.listen(
      (preview) => add(PhotoPreviewReceived(preview)),
    );
    _photoRequestSubscription = _bleService.photoRequestReceivedStream.listen(
      (request) => add(PhotoRequestReceived(request)),
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
  StreamSubscription<ble.ReceivedPhotoPreview>? _photoPreviewSubscription;
  StreamSubscription<ble.ReceivedPhotoRequest>? _photoRequestSubscription;

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

  /// Consent-first photo send:
  ///   1. Compress photo and generate preview thumbnail.
  ///   2. Store local message as [photo] type (sender sees their own image).
  ///   3. Send a [photo_preview] BLE message (thumbnail + metadata).
  ///   4. Wait for receiver's [photo_request] — handled by [_onPhotoRequestReceived].
  Future<void> _onSendPhotoMessage(
    SendPhotoMessage event,
    Emitter<ChatState> emit,
  ) async {
    if (state.currentConversation == null) return;
    if (state.isBlocked) return;

    emit(state.copyWith(status: ChatStatus.sending));

    try {
      // 1. Compress photo for local display and BLE transfer.
      final compressedPath =
          await _imageService.compressForChat(event.photoPath);
      final absolutePath =
          await resolvePhotoPath(compressedPath) ?? compressedPath;
      final blePhotoBytes =
          await _imageService.compressForBleTransfer(absolutePath);

      // 2. Generate thumbnail (≤15 KB) for the preview bubble.
      final thumbnailBytes =
          await _imageService.generatePreviewThumbnail(absolutePath);

      // 3. Generate a stable UUID that links preview ↔ full-transfer.
      const uuidGen = Uuid();
      final photoId = uuidGen.v4();

      // 4. Save local message as 'photo' type so the sender sees their image.
      final message = await _chatRepository.sendPhotoMessage(
        conversationId: state.currentConversation!.id,
        senderId: _ownUserId,
        photoPath: compressedPath,
      );

      // Register pending outgoing photo so we can respond to a photo_request.
      final updatedPending =
          Map<String, PendingOutgoingPhoto>.from(state.pendingOutgoingPhotos);
      updatedPending[photoId] = PendingOutgoingPhoto(
        photoId: photoId,
        localPhotoPath: absolutePath,
        messageId: message.id,
        peerId: state.currentConversation!.peerId,
      );

      emit(state.copyWith(
        status: ChatStatus.loaded,
        messages: [message, ...state.messages],
        pendingOutgoingPhotos: updatedPending,
      ));

      // 5. Send photo_preview (thumbnail + metadata) over BLE.
      final success = await _bleService.sendPhotoPreview(
        peerId: state.currentConversation!.peerId,
        messageId: message.id,
        photoId: photoId,
        thumbnailBytes: thumbnailBytes,
        originalSize: blePhotoBytes.length,
      );

      add(MessageStatusUpdated(
        messageId: message.id,
        status: success ? MessageStatus.sent : MessageStatus.failed,
      ));

      add(const LoadConversations());
    } catch (e) {
      Logger.error('Failed to send photo preview', e, null, 'ChatBloc');
      emit(state.copyWith(
        status: ChatStatus.error,
        errorMessage: 'Failed to send photo',
      ));
    }
  }

  // ---------------------------------------------------------------------------
  // Photo preview / consent flow handlers
  // ---------------------------------------------------------------------------

  /// Receiver: store incoming preview and show thumbnail bubble.
  Future<void> _onPhotoPreviewReceived(
    PhotoPreviewReceived event,
    Emitter<ChatState> emit,
  ) async {
    try {
      final preview = event.preview;

      if (await _peerRepository.isPeerBlocked(preview.fromPeerId)) return;

      final conversation =
          await _chatRepository.getOrCreateConversation(preview.fromPeerId);

      // Save thumbnail bytes to a file so the path is storable in the DB.
      final thumbnailPath =
          await _imageService.saveChatThumbnail(preview.thumbnailBytes);

      // Store JSON metadata in textContent.
      final metadata = jsonEncode({
        'photo_id': preview.photoId,
        'original_size': preview.originalSize,
      });

      final message = await _chatRepository.receivePhotoPreview(
        conversationId: conversation.id,
        senderId: preview.fromPeerId,
        textContent: metadata,
        thumbnailPath: thumbnailPath,
      );

      await _notificationService.showMessageNotification(
        fromPeerId: preview.fromPeerId,
        fromName: state.currentConversation?.peerName ?? 'Someone',
        messagePreview:
            'Photo (${preview.formattedOriginalSize}) – Tap to download',
      );

      if (state.currentConversation?.peerId == preview.fromPeerId) {
        emit(state.copyWith(messages: [message, ...state.messages]));
        add(const MarkMessagesRead());
      }

      add(const LoadConversations());
    } catch (e) {
      Logger.error('Failed to handle photo preview', e, null, 'ChatBloc');
    }
  }

  /// Receiver: user taps the thumbnail → send photo_request to sender.
  Future<void> _onRequestFullPhoto(
    RequestFullPhoto event,
    Emitter<ChatState> emit,
  ) async {
    try {
      // Mark the preview bubble as 'pending' (download in progress).
      add(MessageStatusUpdated(
        messageId: event.messageId,
        status: MessageStatus.pending,
      ));

      // Add to photo transfers map so the UI can show a progress indicator.
      final updatedTransfers =
          Map<String, PhotoTransferInfo>.from(state.photoTransfers);
      updatedTransfers[event.messageId] = PhotoTransferInfo(
        messageId: event.messageId,
        progress: 0,
        isSending: false,
      );
      emit(state.copyWith(photoTransfers: updatedTransfers));

      final requestMsgId = const Uuid().v4();
      final success = await _bleService.sendPhotoRequest(
        peerId: event.peerId,
        messageId: requestMsgId,
        photoId: event.photoId,
      );

      if (!success) {
        // Revert to delivered so user can retry.
        add(MessageStatusUpdated(
          messageId: event.messageId,
          status: MessageStatus.delivered,
        ));
        final revertedTransfers =
            Map<String, PhotoTransferInfo>.from(state.photoTransfers)
              ..remove(event.messageId);
        emit(state.copyWith(photoTransfers: revertedTransfers));
      }
    } catch (e) {
      Logger.error('Failed to send photo request', e, null, 'ChatBloc');
    }
  }

  /// Sender: receiver consented → transmit the full photo.
  Future<void> _onPhotoRequestReceived(
    PhotoRequestReceived event,
    Emitter<ChatState> emit,
  ) async {
    try {
      final request = event.request;
      final pending = state.pendingOutgoingPhotos[request.photoId];

      if (pending == null) {
        Logger.warning(
          'ChatBloc: photo_request for unknown photoId ${request.photoId}',
          'Chat',
        );
        return;
      }

      Logger.info(
        'ChatBloc: Sending full photo for ${request.photoId}',
        'Chat',
      );

      final photoBytes =
          await _imageService.compressForBleTransfer(pending.localPhotoPath);

      final success = await _bleService.sendPhoto(
        request.fromPeerId,
        photoBytes,
        pending.messageId,
      );

      if (!success) {
        Logger.warning(
          'ChatBloc: Full photo send failed for ${request.photoId}',
          'Chat',
        );
      }

      // Remove from pending map — transfer is underway (progress via stream).
      final updatedPending =
          Map<String, PendingOutgoingPhoto>.from(state.pendingOutgoingPhotos)
            ..remove(request.photoId);
      emit(state.copyWith(pendingOutgoingPhotos: updatedPending));
    } catch (e) {
      Logger.error('Failed to handle photo request', e, null, 'ChatBloc');
    }
  }

  /// Cancel an in-progress photo transfer.
  Future<void> _onCancelPhotoTransfer(
    CancelPhotoTransfer event,
    Emitter<ChatState> emit,
  ) async {
    await _bleService.cancelPhotoTransfer(event.messageId);
    final updatedTransfers =
        Map<String, PhotoTransferInfo>.from(state.photoTransfers)
          ..remove(event.messageId);
    emit(state.copyWith(photoTransfers: updatedTransfers));
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

  /// Handle BLE photo received from peer.
  ///
  /// This is a stream listener (no Emitter access) — all state changes go
  /// through [add()].  In the consent-first flow, [photo.messageId] equals
  /// the [photoId] from the original preview.  We look up the matching
  /// [photoPreview] bubble and dispatch [PhotoPreviewUpgraded] to swap it
  /// in-place; otherwise we fall back to creating a new photo message.
  Future<void> _onBlePhotoReceived(ble.ReceivedPhoto photo) async {
    try {
      if (await _peerRepository.isPeerBlocked(photo.fromPeerId)) return;

      final conversation =
          await _chatRepository.getOrCreateConversation(photo.fromPeerId);

      // Save full photo to disk.
      final photoPath = await _imageService.saveReceivedPhoto(photo.photoBytes);

      // Look for a photoPreview message whose metadata contains this photoId.
      final previewMsg = state.messages.where((m) {
        if (m.contentType != MessageContentType.photoPreview) return false;
        try {
          final meta =
              jsonDecode(m.textContent ?? '{}') as Map<String, dynamic>;
          return meta['photo_id'] == photo.messageId;
        } catch (_) {
          return false;
        }
      }).firstOrNull;

      if (previewMsg != null) {
        final upgraded = await _chatRepository.upgradePreviewToPhoto(
          messageId: previewMsg.id,
          fullPhotoPath: photoPath,
        );
        add(PhotoPreviewUpgraded(
          previewMessageId: previewMsg.id,
          updatedMessage: upgraded ?? previewMsg,
        ));
      } else {
        // Legacy / direct send — create a new photo message.
        final message = await _chatRepository.receiveMessage(
          conversationId: conversation.id,
          senderId: photo.fromPeerId,
          contentType: MessageContentType.photo,
          photoPath: photoPath,
        );
        add(MessageReceived(message));
      }

      Logger.info(
        'ChatBloc: Received full photo from ${photo.fromPeerId.substring(0, 8)}',
        'Chat',
      );
    } catch (e) {
      Logger.error('Failed to handle BLE photo', e, null, 'ChatBloc');
    }
  }

  /// Swap a photoPreview bubble with the fully-downloaded photo.
  void _onPhotoPreviewUpgraded(
    PhotoPreviewUpgraded event,
    Emitter<ChatState> emit,
  ) {
    final updatedTransfers =
        Map<String, PhotoTransferInfo>.from(state.photoTransfers)
          ..remove(event.previewMessageId);

    final updatedMessages = state.messages.map((m) {
      if (m.id == event.previewMessageId) return event.updatedMessage;
      return m;
    }).toList();

    emit(state.copyWith(
      photoTransfers: updatedTransfers,
      messages: updatedMessages,
    ));
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
      } else if (message.contentType == MessageContentType.photo) {
        // Photo retry via consent flow — re-generate thumbnail and re-send preview.
        final absolutePath =
            await resolvePhotoPath(message.photoPath) ?? message.photoPath!;
        final thumbnailBytes =
            await _imageService.generatePreviewThumbnail(absolutePath);
        final bleBytes = await _imageService.compressForBleTransfer(absolutePath);
        const uuidGen = Uuid();
        final photoId = uuidGen.v4();
        final updatedPending =
            Map<String, PendingOutgoingPhoto>.from(state.pendingOutgoingPhotos);
        updatedPending[photoId] = PendingOutgoingPhoto(
          photoId: photoId,
          localPhotoPath: absolutePath,
          messageId: message.id,
          peerId: state.currentConversation!.peerId,
        );
        emit(state.copyWith(pendingOutgoingPhotos: updatedPending));
        success = await _bleService.sendPhotoPreview(
          peerId: state.currentConversation!.peerId,
          messageId: message.id,
          photoId: photoId,
          thumbnailBytes: thumbnailBytes,
          originalSize: bleBytes.length,
        );
      } else {
        // photoPreview retry — nothing to re-send (receiver must tap again).
        success = false;
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
    _photoPreviewSubscription?.cancel();
    _photoRequestSubscription?.cancel();
    return super.close();
  }
}
