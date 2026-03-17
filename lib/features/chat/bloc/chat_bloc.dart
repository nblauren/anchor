import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
import '../../../services/image_service.dart';
import '../../../services/nearby/nearby.dart';
import '../../../services/store_and_forward_service.dart';
import '../../../services/transport/transport.dart';
import 'chat_event.dart';
import 'chat_state.dart';

class ChatBloc extends Bloc<ChatEvent, ChatState> {
  ChatBloc({
    required ChatRepository chatRepository,
    required PeerRepository peerRepository,
    required ImageService imageService,
    required TransportManager transportManager,
    required NotificationService notificationService,
    required String ownUserId,
    HighSpeedTransferService? highSpeedTransferService,
    StoreAndForwardService? storeAndForwardService,
    EncryptionService? encryptionService,
    TransportRetryQueue? retryQueue,
  })  : _chatRepository = chatRepository,
        _peerRepository = peerRepository,
        _imageService = imageService,
        _transportManager = transportManager,
        _notificationService = notificationService,
        _ownUserId = ownUserId,
        _highSpeedService = highSpeedTransferService,
        _storeAndForwardService = storeAndForwardService,
        _encryptionService = encryptionService,
        _retryQueue = retryQueue,
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
    // Background send queue
    on<RegisterPendingOutgoingPhoto>(_onRegisterPendingOutgoingPhoto);
    // Wi-Fi Direct / Nearby events
    on<NearbyTransferProgressUpdated>(_onNearbyTransferProgress);
    on<NearbyPayloadCompleted>(_onNearbyPayloadCompleted);
    on<WifiTransferReadyReceived>(_onWifiTransferReady);
    // Peer loss + MAC rotation
    on<ChatPeerLost>(_onChatPeerLost);
    on<ChatPeerIdMigrated>(_onChatPeerIdMigrated);
    // Reactions
    on<SendReaction>(_onSendReaction);
    on<RemoveReaction>(_onRemoveReaction);
    on<BleReactionReceived>(_onBleReactionReceived);
    // Reply
    on<SetReplyingTo>(_onSetReplyingTo);
    // E2EE
    on<E2eeSessionEstablished>(_onE2eeSessionEstablished);
    on<_E2eePeerKeyArrived>(_onE2eePeerKeyArrived);
    on<_E2eeHandshakeTimeout>(_onE2eeHandshakeTimeout);

    // Subscribe to transport manager streams (Wi-Fi Aware or BLE — unified)
    _messageSubscription = _transportManager.messageReceivedStream.listen(
      (msg) => add(BleMessageReceived(msg)),
    );

    _photoProgressSubscription = _transportManager.photoProgressStream.listen(
      (progress) => add(PhotoTransferProgressUpdated(progress)),
    );

    _photoReceivedSubscription = _transportManager.photoReceivedStream.listen(
      _onBlePhotoReceived,
    );

    _photoPreviewSubscription =
        _transportManager.photoPreviewReceivedStream.listen(
      (preview) => add(PhotoPreviewReceived(preview)),
    );
    _photoRequestSubscription =
        _transportManager.photoRequestReceivedStream.listen(
      (request) => add(PhotoRequestReceived(request)),
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

    _reactionSubscription = _transportManager.reactionReceivedStream.listen(
      (reaction) => add(BleReactionReceived(reaction)),
    );

    // Subscribe to E2EE session established events — update UI lock icon.
    final enc = _encryptionService;
    if (enc != null) {
      _e2eeSessionSubscription = enc.sessionEstablishedStream.listen((peerId) {
        if (!isClosed) add(E2eeSessionEstablished(peerId));
      });

      // Retry handshake when the peer's public key arrives after conversation
      // open (e.g. user tapped chat before the BLE profile read completed, or
      // the peer just upgraded to E2EE-capable firmware).
      _e2eeKeyStoredSubscription = enc.peerKeyStoredStream.listen((peerId) {
        if (!isClosed) add(_E2eePeerKeyArrived(peerId));
      });

      _e2eeTimeoutSubscription = enc.handshakeTimeoutStream.listen((peerId) {
        if (!isClosed) add(_E2eeHandshakeTimeout(peerId));
      });
    }

    // Initialize Nearby / Wi-Fi Direct and subscribe to streams.
    final highSpeed = _highSpeedService;
    if (highSpeed != null) {
      highSpeed.initialize(ownUserId: ownUserId).then((_) {
        Logger.info('HighSpeedTransferService initialized with userId', 'Chat');
      }).catchError((e) {
        Logger.warning('HighSpeedTransferService init deferred: $e', 'Chat');
      });

      _nearbyProgressSubscription =
          highSpeed.transferProgressStream.listen(
        (progress) => add(NearbyTransferProgressUpdated(progress)),
      );
      _nearbyPayloadSubscription =
          highSpeed.payloadReceivedStream.listen(
        (payload) => add(NearbyPayloadCompleted(payload)),
      );
    }

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
          if (update.delivered) add(const LoadConversations());
        }
      });
    }
  }

  final ChatRepository _chatRepository;
  final PeerRepository _peerRepository;
  final ImageService _imageService;
  final TransportManager _transportManager;
  final NotificationService _notificationService;
  final String _ownUserId;
  final HighSpeedTransferService? _highSpeedService;
  final StoreAndForwardService? _storeAndForwardService;
  final EncryptionService? _encryptionService;
  final TransportRetryQueue? _retryQueue;
  StreamSubscription? _e2eeSessionSubscription;
  StreamSubscription? _e2eeKeyStoredSubscription;
  StreamSubscription? _e2eeTimeoutSubscription;
  StreamSubscription? _retryQueueSubscription;
  int _handshakeRetryCount = 0;

  /// True when the transport for [peerId] has enough bandwidth to send
  /// full-quality photos without BLE compression (LAN or Wi-Fi Aware).
  bool _isHighBandwidthForPeer(String peerId) {
    final transport = _transportManager.transportForPeer(peerId) ??
        _transportManager.activeTransport;
    return transport == TransportType.lan ||
        transport == TransportType.wifiAware;
  }

  // Transport manager subscriptions
  StreamSubscription<ble.ReceivedMessage>? _messageSubscription;
  StreamSubscription<ble.PhotoTransferProgress>? _photoProgressSubscription;
  StreamSubscription<ble.ReceivedPhoto>? _photoReceivedSubscription;
  StreamSubscription<ble.ReceivedPhotoPreview>? _photoPreviewSubscription;
  StreamSubscription<ble.ReceivedPhotoRequest>? _photoRequestSubscription;
  StreamSubscription<ble.PeerIdChanged>? _peerIdChangedSubscription;
  StreamSubscription<String>? _peerLostSubscription;
  StreamSubscription<ble.ReactionReceived>? _reactionSubscription;

  // Photo download timeout timers (keyed by messageId)
  final Map<String, Timer> _photoDownloadTimers = {};

  // Nearby / Wi-Fi Direct subscriptions
  StreamSubscription<NearbyTransferProgress>? _nearbyProgressSubscription;
  StreamSubscription<NearbyPayloadReceived>? _nearbyPayloadSubscription;

  // Store-and-forward delivery update subscription
  StreamSubscription<MessageDeliveryUpdate>? _storeForwardSubscription;

  // Metadata from BLE signal for pending Wi-Fi Direct preview transfers.
  // Keyed by photoId (without 'preview-' prefix).
  final Map<String, Map<String, dynamic>> _pendingPreviewMeta = {};

  // Maps Nearby transferId → BLE device ID so _onNearbyPayloadCompleted can
  // look up the correct conversation.  Populated in _onWifiTransferReady where
  // we still have the BLE device ID (event.fromPeerId).
  final Map<String, String> _transferToBleId = {};

  // FIFO send queue — guarantees messages are sent in the order they were typed.
  final List<Future<void> Function()> _sendQueue = [];
  bool _isProcessingQueue = false;

  // Mock echo timer (for testing when using MockBleService)
  Timer? _echoTimer;

  String get ownUserId => _ownUserId;

  Future<void> _onLoadConversations(
    LoadConversations event,
    Emitter<ChatState> emit,
  ) async {
    emit(state.copyWith(status: ChatStatus.loading));

    // One-time repair: fix any messages whose senderId was saved as '' because
    // ChatBloc was constructed before the profile UUID was ready.
    if (_ownUserId.isNotEmpty) {
      await _chatRepository.fixEmptySenderIds(_ownUserId);
    }

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
      _sendReadReceipt(event.peerId);

      final isBlocked = await _peerRepository.isPeerBlocked(event.peerId);

      // Load reactions for this conversation
      Map<String, List<ReactionEntry>> loadedReactions = {};
      try {
        loadedReactions = await _chatRepository.getReactionsForConversation(
          conversationEntry.id,
        );
      } catch (e) {
        Logger.warning('ChatBloc: Failed to load reactions', 'ChatBloc');
      }

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
        reactions: loadedReactions,
      ));

      // Load messages
      add(const LoadMessages());

      // E2EE: initiate Noise_XK handshake if no session exists yet.
      // The handshake runs in the background; the lock icon appears when
      // the session is established (E2eeSessionEstablished event).
      final enc = _encryptionService;
      if (enc != null) {
        // E2EE sessions are keyed by canonical peerId (= conv.peerId).
        // TransportManager routes handshake messages to the right transport.
        final peerId = event.peerId;
        if (enc.hasSession(peerId)) {
          emit(state.copyWith(isE2eeActive: true));
        } else if (enc.hasPendingHandshake(peerId)) {
          // Handshake already in flight (e.g. user closed and reopened chat).
          // Just mark handshaking and wait for sessionEstablishedStream.
          emit(state.copyWith(isE2eeHandshaking: true));
        } else {
          emit(state.copyWith(isE2eeHandshaking: true));
          final result = await enc.initiateHandshake(peerId);
          if (result.hasError) {
            Logger.warning(
              'E2EE handshake initiation failed for $peerId: ${result.error}',
              'Chat',
            );
            // Keep isE2eeHandshaking true — peerKeyStoredStream retries when
            // the peer's public key is stored (via BLE profile or LAN beacon).
          }
        }
      }
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
    if (!state.isE2eeActive) return; // Never send without an established E2EE session.

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

      // Fire-and-forget: BLE send runs in background
      _enqueueSend(() => _sendTextInBackground(message, peerId, replyToId: replyToId));
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

  /// Background helper: sends a text message via BLE without blocking the
  /// event queue.  Status updates are dispatched as events.
  ///
  /// On failure, enqueues to [TransportRetryQueue] for automatic retry when
  /// the peer's transport becomes available (instead of inline exponential
  /// backoff).
  Future<void> _sendTextInBackground(
    MessageEntry message,
    String peerId, {
    String? replyToId,
  }) async {
    try {
      final payload = ble.MessagePayload(
        messageId: message.id,
        type: ble.MessageType.text,
        content: message.textContent ?? '',
        replyToId: replyToId,
      );

      final success = await _transportManager.sendMessage(peerId, payload);
      if (success) {
        add(MessageStatusUpdated(
          messageId: message.id,
          status: MessageStatus.sent,
        ));
        add(const LoadConversations());
        return;
      }

      // All transports failed — enqueue for retry when peer reconnects.
      final rq = _retryQueue;
      if (rq != null) {
        rq.enqueue(PendingSend(
          peerId: peerId,
          messageId: message.id,
          type: PendingSendType.text,
          payload: payload,
        ));
        // Leave status as pending — retry queue will update on success/failure.
      } else {
        add(MessageStatusUpdated(
          messageId: message.id,
          status: MessageStatus.failed,
        ));
        add(const LoadConversations());
      }
    } catch (e) {
      Logger.error('Background text send failed', e, null, 'ChatBloc');
      add(MessageStatusUpdated(
        messageId: message.id,
        status: MessageStatus.failed,
      ));
    }
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
    if (!state.isE2eeActive) return; // Never send without an established E2EE session.

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

      // 2. Fire-and-forget: compress + BLE preview send in background
      _enqueueSend(() => _sendPhotoInBackground(
            photoPath: event.photoPath,
            message: message,
            peerId: peerId,
          ));
    } catch (e) {
      Logger.error('Failed to send photo', e, null, 'ChatBloc');
      emit(state.copyWith(
        status: ChatStatus.error,
        errorMessage: 'Failed to send photo',
      ));
    }
  }

  /// Background helper: compresses the photo and sends a BLE preview
  /// notification without blocking the event queue.
  Future<void> _sendPhotoInBackground({
    required String photoPath,
    required MessageEntry message,
    required String peerId,
  }) async {
    try {
      // 1. Compress photo for storage (chat quality, ~100-200 KB).
      final compressedPath = await _imageService.compressForChat(photoPath);
      final absolutePath =
          await resolvePhotoPath(compressedPath) ?? compressedPath;
      // On high-bandwidth transports (LAN, Wi-Fi Aware) the full chat-quality
      // photo is sent — no need for aggressive BLE compression.
      final int previewOriginalSize;
      if (_isHighBandwidthForPeer(peerId)) {
        previewOriginalSize = await File(absolutePath).length();
      } else {
        previewOriginalSize =
            (await _imageService.compressForBleTransfer(absolutePath)).length;
      }

      // Persist the compressed relative path so the photo survives app restarts.
      // The original photoPath may be a picker temp file that gets deleted.
      await _chatRepository.updateMessagePhotoPath(message.id, compressedPath);

      // 2. Generate a stable UUID that links preview ↔ full-transfer.
      const uuidGen = Uuid();
      final photoId = uuidGen.v4();

      // 3. Persist photoId in the message row so it can be recovered after a
      //    session restart (pendingOutgoingPhotos is in-memory only).
      await _chatRepository.updateMessagePhotoId(message.id, photoId);

      // Register pending outgoing photo via event so the bloc can respond
      //    to a future photo_request from the receiver.
      add(RegisterPendingOutgoingPhoto(
        photo: PendingOutgoingPhoto(
          photoId: photoId,
          localPhotoPath: absolutePath,
          messageId: message.id,
          peerId: peerId,
        ),
      ));

      // 4. Send lightweight notification (no thumbnail).
      final previewSent = await _transportManager.sendPhotoPreview(
        peerId: peerId,
        messageId: message.id,
        photoId: photoId,
        thumbnailBytes: Uint8List(0),
        originalSize: previewOriginalSize,
      );

      if (!previewSent && !isClosed) {
        // Schedule retry without blocking the queue
        add(MessageStatusUpdated(
          messageId: message.id,
          status: MessageStatus.failed,
        ));
        add(const LoadConversations());
        return;
      }

      add(MessageStatusUpdated(
        messageId: message.id,
        status: previewSent ? MessageStatus.sent : MessageStatus.failed,
      ));
      add(const LoadConversations());
    } catch (e) {
      Logger.error('Background photo send failed', e, null, 'ChatBloc');
      add(MessageStatusUpdated(
        messageId: message.id,
        status: MessageStatus.failed,
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

      // Save thumbnail bytes to a file (skip if no thumbnail data).
      final String? thumbnailPath = preview.thumbnailBytes.isNotEmpty
          ? await _imageService.saveChatThumbnail(preview.thumbnailBytes)
          : null;

      // Store JSON metadata in textContent.
      final metadata = jsonEncode({
        'photo_id': preview.photoId,
        'original_size': preview.originalSize,
      });

      final message = await _chatRepository.receivePhotoPreview(
        id: preview.messageId,
        conversationId: conversation.id,
        senderId: preview.fromPeerId,
        textContent: metadata,
        thumbnailPath: thumbnailPath,
      );

      final previewSender =
          await _peerRepository.getPeerById(preview.fromPeerId);
      await _notificationService.showMessageNotification(
        fromPeerId: preview.fromPeerId,
        fromName: previewSender?.name ?? state.currentConversation?.peerName ?? 'Someone nearby',
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
      final success = await _transportManager.sendPhotoRequest(
        peerId: event.peerId,
        messageId: requestMsgId,
        photoId: event.photoId,
      );

      if (!success) {
        // Revert to delivered so user can retry.
        _photoDownloadTimers.remove(event.messageId)?.cancel();
        add(MessageStatusUpdated(
          messageId: event.messageId,
          status: MessageStatus.delivered,
        ));
        final revertedTransfers =
            Map<String, PhotoTransferInfo>.from(state.photoTransfers)
              ..remove(event.messageId);
        emit(state.copyWith(photoTransfers: revertedTransfers));
      } else {
        // Start a timeout — if no photo arrives within 45 seconds, fail.
        _photoDownloadTimers[event.messageId]?.cancel();
        _photoDownloadTimers[event.messageId] = Timer(
          const Duration(seconds: 45),
          () {
            if (!isClosed && state.photoTransfers.containsKey(event.messageId)) {
              Logger.warning(
                'ChatBloc: Photo download timed out for ${event.messageId}',
                'Chat',
              );
              _cancelPhotoDownload(event.messageId);
            }
          },
        );
      }
    } catch (e) {
      Logger.error('Failed to send photo request', e, null, 'ChatBloc');
    }
  }

  /// Sender: receiver consented → try Wi-Fi Direct first, fall back to BLE.
  ///
  /// Wi-Fi Direct protocol:
  ///   1. Sender starts ADVERTISING on Nearby (visible immediately).
  ///   2. Sender sends `wifiTransferReady` BLE signal to receiver.
  ///   3. Receiver gets signal → starts BROWSING → discovers sender → invites.
  ///   4. Connection made → sender streams data over Nearby text channel.
  ///   5. On timeout/failure → fall back to BLE chunking.
  Future<void> _onPhotoRequestReceived(
    PhotoRequestReceived event,
    Emitter<ChatState> emit,
  ) async {
    try {
      final request = event.request;
      var pending = state.pendingOutgoingPhotos[request.photoId];

      if (pending == null) {
        // pendingOutgoingPhotos is in-memory only — recover from DB after a
        // session restart or conversation close.
        final storedMessage =
            await _chatRepository.findMessageByPhotoId(request.photoId);
        if (storedMessage == null || storedMessage.photoPath == null) {
          Logger.warning(
            'ChatBloc: photo_request for unknown photoId ${request.photoId} — not found in DB',
            'Chat',
          );
          return;
        }
        pending = PendingOutgoingPhoto(
          photoId: request.photoId,
          localPhotoPath: storedMessage.photoPath!,
          messageId: storedMessage.id,
          peerId: request.fromPeerId,
        );
        Logger.info(
          'ChatBloc: Recovered photo ${request.photoId} from DB for re-send',
          'Chat',
        );
      }

      Logger.info(
        'ChatBloc: Sending full photo for ${request.photoId}',
        'Chat',
      );

      // Remove from pending map immediately — transfer is about to start.
      final updatedPending =
          Map<String, PendingOutgoingPhoto>.from(state.pendingOutgoingPhotos)
            ..remove(request.photoId);
      emit(state.copyWith(pendingOutgoingPhotos: updatedPending));

      // On high-bandwidth transports send full chat-quality photo; BLE gets
      // aggressively compressed to fit its tight bandwidth constraints.
      final Uint8List photoBytes;
      if (_isHighBandwidthForPeer(request.fromPeerId)) {
        final absolutePath = await resolvePhotoPath(pending.localPhotoPath)
            ?? pending.localPhotoPath;
        photoBytes = await File(absolutePath).readAsBytes();
      } else {
        final absolutePath = await resolvePhotoPath(pending.localPhotoPath)
            ?? pending.localPhotoPath;
        photoBytes =
            await _imageService.compressForBleTransfer(absolutePath);
      }

      // Fire-and-forget: kick off the transfer in the background so we don't
      // block the bloc event queue (Wi-Fi Direct timeout + BLE chunking can
      // take 30-45 s, during which text messages would be stuck in queue).
      _sendFullPhoto(
        request: request,
        pending: pending,
        photoBytes: photoBytes,
      );
    } catch (e) {
      Logger.error('Failed to handle photo request', e, null, 'ChatBloc');
    }
  }

  /// Background helper: sends a full-resolution photo via TransportManager.
  ///
  /// TransportManager handles the LAN → Wi-Fi Aware → Wi-Fi Direct → BLE
  /// fallback chain internally.  This method just delegates and updates status.
  ///
  /// Runs outside the bloc event handler so it doesn't block the event queue.
  /// State updates go through `add()` (events) so they're processed safely.
  Future<void> _sendFullPhoto({
    required ble.ReceivedPhotoRequest request,
    required PendingOutgoingPhoto pending,
    required Uint8List photoBytes,
  }) async {
    try {
      final success = await _transportManager.sendPhoto(
        request.fromPeerId,
        photoBytes,
        pending.messageId,
        photoId: request.photoId,
      );

      // Mark the photo message as read only after the full photo is delivered.
      // Read receipts (sent when the receiver opens the chat) intentionally
      // exclude photo messages, so this is the only place a sent photo gets
      // promoted to [read].
      if (success) {
        add(MessageStatusUpdated(
          messageId: pending.messageId,
          status: MessageStatus.read,
        ));
      } else {
        Logger.warning(
          'ChatBloc: Photo send failed for ${request.photoId}',
          'Chat',
        );
      }
    } catch (e) {
      Logger.error('_sendFullPhoto failed', e, null, 'ChatBloc');
    }
  }

  /// Cancel an in-progress photo transfer.
  Future<void> _onCancelPhotoTransfer(
    CancelPhotoTransfer event,
    Emitter<ChatState> emit,
  ) async {
    await _transportManager.cancelPhotoTransfer(event.messageId);
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

      // Handle wifiTransferReady signal — route to Nearby handler.
      // Content is always JSON with transfer_id and sender_nearby_id.
      // Preview transfers additionally have is_preview: true + metadata.
      if (bleMsg.type == ble.MessageType.wifiTransferReady) {
        try {
          final parsed =
              jsonDecode(bleMsg.content) as Map<String, dynamic>;
          final transferId = parsed['transfer_id'] as String? ?? bleMsg.content;
          final senderNearbyId = parsed['sender_nearby_id'] as String?;

          if (parsed['is_preview'] == true) {
            add(WifiTransferReadyReceived(
              fromPeerId: bleMsg.fromPeerId,
              transferId: transferId,
              senderNearbyId: senderNearbyId,
              isPreview: true,
              photoId: parsed['photo_id'] as String?,
              originalSize: parsed['original_size'] as int?,
              messageId: parsed['message_id'] as String?,
            ));
          } else {
            add(WifiTransferReadyReceived(
              fromPeerId: bleMsg.fromPeerId,
              transferId: transferId,
              senderNearbyId: senderNearbyId,
            ));
          }
        } catch (_) {
          add(WifiTransferReadyReceived(
            fromPeerId: bleMsg.fromPeerId,
            transferId: bleMsg.content,
          ));
        }
        return;
      }

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
      // Transfer done — clear timeout and tracking
      _photoDownloadTimers.remove(progress.messageId)?.cancel();
      updatedTransfers.remove(progress.messageId);
      add(MessageStatusUpdated(
        messageId: progress.messageId,
        status: MessageStatus.sent,
      ));
    } else if (progress.status == ble.PhotoTransferStatus.failed ||
        progress.status == ble.PhotoTransferStatus.cancelled) {
      // Clear timeout and remove from tracking
      _photoDownloadTimers.remove(progress.messageId)?.cancel();
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
      // photo.photoId is the consent-flow UUID that links preview → full photo.
      final matchId = photo.photoId ?? photo.messageId;
      final previewMsg = state.messages.where((m) {
        if (m.contentType != MessageContentType.photoPreview) return false;
        try {
          final meta =
              jsonDecode(m.textContent ?? '{}') as Map<String, dynamic>;
          return meta['photo_id'] == matchId;
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
    _photoDownloadTimers.remove(event.previewMessageId)?.cancel();
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

      // Fire-and-forget: retry in background
      if (message.contentType == MessageContentType.text) {
        _enqueueSend(() => _sendTextInBackground(message, peerId, replyToId: message.replyToMessageId));
      } else if (message.contentType == MessageContentType.photo) {
        _enqueueSend(() => _retryPhotoInBackground(message, peerId));
      }
    } catch (e) {
      Logger.error('Failed to retry message', e, null, 'ChatBloc');
      add(MessageStatusUpdated(
        messageId: event.messageId,
        status: MessageStatus.failed,
      ));
    }
  }

  /// Background helper for retrying a failed photo message.
  Future<void> _retryPhotoInBackground(
      MessageEntry message, String peerId) async {
    try {
      final absolutePath =
          await resolvePhotoPath(message.photoPath) ?? message.photoPath!;
      final bleBytes = _isHighBandwidthForPeer(peerId)
          ? await File(absolutePath).readAsBytes()
          : await _imageService.compressForBleTransfer(absolutePath);
      const uuidGen = Uuid();
      final photoId = uuidGen.v4();

      add(RegisterPendingOutgoingPhoto(
        photo: PendingOutgoingPhoto(
          photoId: photoId,
          localPhotoPath: absolutePath,
          messageId: message.id,
          peerId: peerId,
        ),
      ));

      final success = await _transportManager.sendPhotoPreview(
        peerId: peerId,
        messageId: message.id,
        photoId: photoId,
        thumbnailBytes: Uint8List(0),
        originalSize: bleBytes.length,
      );

      add(MessageStatusUpdated(
        messageId: message.id,
        status: success ? MessageStatus.sent : MessageStatus.failed,
      ));
      add(const LoadConversations());
    } catch (e) {
      Logger.error('Background photo retry failed', e, null, 'ChatBloc');
      add(MessageStatusUpdated(
        messageId: message.id,
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

  /// Cancel a photo download: clear timer, remove transfer tracking, revert
  /// message status to [delivered] so the user can tap to retry.
  ///
  /// Called from Timer callbacks (no Emitter access) — dispatches events
  /// through the normal Bloc pipeline.
  void _cancelPhotoDownload(String messageId) {
    _photoDownloadTimers.remove(messageId)?.cancel();
    // CancelPhotoTransfer removes from photoTransfers map (clears spinner).
    add(CancelPhotoTransfer(messageId));
    // Revert to delivered so user can tap to retry.
    add(MessageStatusUpdated(
      messageId: messageId,
      status: MessageStatus.delivered,
    ));
  }

  /// Peer went out of range — cancel any active photo downloads from them.
  Future<void> _onChatPeerLost(
    ChatPeerLost event,
    Emitter<ChatState> emit,
  ) async {
    final currentConv = state.currentConversation;
    if (currentConv == null || currentConv.peerId != event.peerId) return;

    // Find all active incoming photo transfers for this peer and cancel them.
    final transfersToCancel = <String>[];
    for (final entry in state.photoTransfers.entries) {
      if (!entry.value.isSending) {
        transfersToCancel.add(entry.key);
      }
    }

    if (transfersToCancel.isEmpty) return;

    for (final messageId in transfersToCancel) {
      _cancelPhotoDownload(messageId);
    }

    Logger.info(
      'ChatBloc: Cancelled ${transfersToCancel.length} photo download(s) — '
          'peer ${event.peerId.substring(0, 8)} lost',
      'Chat',
    );
  }

  Future<void> _onCloseConversation(
    CloseConversation event,
    Emitter<ChatState> emit,
  ) async {
    _echoTimer?.cancel();
    // Cancel all photo download timers
    for (final timer in _photoDownloadTimers.values) {
      timer.cancel();
    }
    _photoDownloadTimers.clear();
    emit(state.copyWith(
      clearCurrentConversation: true,
      messages: [],
      photoTransfers: const {},
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

  // ---------------------------------------------------------------------------
  // Wi-Fi Direct / Nearby handlers
  // ---------------------------------------------------------------------------

  /// Handle progress updates from Nearby Connections transfers.
  void _onNearbyTransferProgress(
    NearbyTransferProgressUpdated event,
    Emitter<ChatState> emit,
  ) {
    final progress = event.progress;

    // Map transferId back to messageId via pending outgoing photos.
    String? messageId;
    for (final pending in state.pendingOutgoingPhotos.values) {
      if (pending.photoId == progress.transferId) {
        messageId = pending.messageId;
        break;
      }
    }

    // Also check existing transfer map (receiver side).
    messageId ??= state.photoTransfers.keys.where((key) {
      final info = state.photoTransfers[key];
      return info != null && info.transport == TransportType.wifiDirect;
    }).firstOrNull;

    if (messageId == null) return;

    final updatedTransfers =
        Map<String, PhotoTransferInfo>.from(state.photoTransfers);

    if (progress.isComplete || progress.isFailed) {
      updatedTransfers.remove(messageId);
      if (progress.isComplete) {
        add(MessageStatusUpdated(
          messageId: messageId,
          status: MessageStatus.sent,
        ));
      }
    } else {
      updatedTransfers[messageId] = PhotoTransferInfo(
        messageId: messageId,
        progress: progress.progress,
        isSending: true,
        transport: TransportType.wifiDirect,
      );
    }

    emit(state.copyWith(photoTransfers: updatedTransfers));
  }

  /// A complete payload was received via Nearby Connections.
  ///
  /// Two cases:
  ///   - **Preview/thumbnail**: transferId starts with `preview-`.
  ///   - **Full photo**: transferId matches a photoId.
  Future<void> _onNearbyPayloadCompleted(
    NearbyPayloadCompleted event,
    Emitter<ChatState> emit,
  ) async {
    try {
      final payload = event.payload;

      // Resolve the BLE device ID from the mapping populated in
      // _onWifiTransferReady.
      final bleDeviceId =
          _transferToBleId.remove(payload.transferId) ?? payload.fromPeerId;

      if (await _peerRepository.isPeerBlocked(bleDeviceId)) return;

      // ── Preview / thumbnail transfer ──────────────────────────────────
      if (payload.transferId.startsWith('preview-')) {
        final photoId = payload.transferId.substring('preview-'.length);
        Logger.info(
          'ChatBloc: Received thumbnail via Wi-Fi Direct for $photoId',
          'Chat',
        );

        final conversation =
            await _chatRepository.getOrCreateConversation(bleDeviceId);

        final thumbnailPath =
            await _imageService.saveChatThumbnail(payload.data);

        final originalSize =
            _pendingPreviewMeta[photoId]?['original_size'] as int? ??
                payload.data.length;
        _pendingPreviewMeta.remove(photoId);

        final metadata = jsonEncode({
          'photo_id': photoId,
          'original_size': originalSize,
        });

        final message = await _chatRepository.receivePhotoPreview(
          conversationId: conversation.id,
          senderId: bleDeviceId,
          textContent: metadata,
          thumbnailPath: thumbnailPath,
        );

        final wifiSender =
            await _peerRepository.getPeerById(bleDeviceId);
        await _notificationService.showMessageNotification(
          fromPeerId: bleDeviceId,
          fromName: wifiSender?.name ?? state.currentConversation?.peerName ?? 'Someone nearby',
          messagePreview: 'Photo – Tap to download',
        );

        if (state.currentConversation?.peerId == bleDeviceId) {
          emit(state.copyWith(messages: [message, ...state.messages]));
          add(const MarkMessagesRead());
        }

        add(const LoadConversations());
        return;
      }

      // ── Full photo transfer ───────────────────────────────────────────
      final conversation =
          await _chatRepository.getOrCreateConversation(bleDeviceId);

      // Decrypt if the sender E2EE-encrypted the payload.
      // Wire format: [0x01] + 24-byte nonce + ciphertext (set by _sendFullPhoto).
      Uint8List photoBytes = payload.data;
      if (photoBytes.length > 25 && photoBytes[0] == 0x01) {
        final enc = _encryptionService;
        if (enc != null) {
          final decrypted = await enc.decryptBytes(
            bleDeviceId,
            EncryptedPayload(
              nonce: photoBytes.sublist(1, 25),
              ciphertext: photoBytes.sublist(25),
            ),
          );
          if (decrypted != null) photoBytes = decrypted;
        }
      }

      final photoPath = await _imageService.saveReceivedPhoto(photoBytes);

      final previewMsg = state.messages.where((m) {
        if (m.contentType != MessageContentType.photoPreview) return false;
        try {
          final meta =
              jsonDecode(m.textContent ?? '{}') as Map<String, dynamic>;
          return meta['photo_id'] == payload.transferId;
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
        final message = await _chatRepository.receiveMessage(
          conversationId: conversation.id,
          senderId: bleDeviceId,
          contentType: MessageContentType.photo,
          photoPath: photoPath,
        );
        add(MessageReceived(message));
      }

      Logger.info(
        'ChatBloc: Received photo via Wi-Fi Direct from ${bleDeviceId.substring(0, 8)}',
        'Chat',
      );
    } catch (e) {
      Logger.error('Failed to handle Nearby payload', e, null, 'ChatBloc');
    }
  }

  /// Receiver: BLE signal says sender is advertising on Nearby.
  /// Start BROWSING to find the sender, discover, invite, and receive data.
  Future<void> _onWifiTransferReady(
    WifiTransferReadyReceived event,
    Emitter<ChatState> emit,
  ) async {
    final hsService = _highSpeedService;
    if (hsService == null) return;

    Logger.info(
      'ChatBloc: Wi-Fi transfer ready from ${event.fromPeerId} '
      'for ${event.transferId} (preview=${event.isPreview})',
      'Chat',
    );

    // Remember the BLE device ID for this transferId so that
    // _onNearbyPayloadCompleted can resolve the correct conversation.
    _transferToBleId[event.transferId] = event.fromPeerId;

    if (event.isPreview) {
      if (event.photoId != null) {
        _pendingPreviewMeta[event.photoId!] = {
          'original_size': event.originalSize ?? 0,
          'message_id': event.messageId,
        };
      }
    } else {
      // Full-photo: find the preview bubble and show Wi-Fi progress.
      final previewMsg = state.messages.where((m) {
        if (m.contentType != MessageContentType.photoPreview) return false;
        try {
          final meta =
              jsonDecode(m.textContent ?? '{}') as Map<String, dynamic>;
          return meta['photo_id'] == event.transferId;
        } catch (_) {
          return false;
        }
      }).firstOrNull;

      if (previewMsg != null) {
        final updatedTransfers =
            Map<String, PhotoTransferInfo>.from(state.photoTransfers);
        updatedTransfers[previewMsg.id] = PhotoTransferInfo(
          messageId: previewMsg.id,
          progress: 0,
          isSending: false,
          transport: TransportType.wifiDirect,
        );
        emit(state.copyWith(photoTransfers: updatedTransfers));
      }
    }

    // Fire-and-forget: start browsing for the sender.
    hsService.receivePayload(
      transferId: event.transferId,
      peerId: event.senderNearbyId ?? event.fromPeerId,
    ).then((success) {
      if (!success) {
        Logger.warning(
          'ChatBloc: Wi-Fi receive failed for ${event.transferId}',
          'Chat',
        );
      }
    }).catchError((e) {
      Logger.error('ChatBloc: Wi-Fi receive error', e, null, 'Chat');
    });
  }

  // ---------------------------------------------------------------------------
  // FIFO send queue
  // ---------------------------------------------------------------------------

  void _enqueueSend(Future<void> Function() task) {
    _sendQueue.add(task);
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_isProcessingQueue) return;
    _isProcessingQueue = true;
    while (_sendQueue.isNotEmpty) {
      final task = _sendQueue.removeAt(0);
      try {
        await task();
      } catch (e) {
        Logger.error('Send queue task failed', e, null, 'ChatBloc');
      }
    }
    _isProcessingQueue = false;
  }

  // ---------------------------------------------------------------------------
  // Register pending outgoing photo (from background send)
  // ---------------------------------------------------------------------------

  Future<void> _onRegisterPendingOutgoingPhoto(
    RegisterPendingOutgoingPhoto event,
    Emitter<ChatState> emit,
  ) async {
    final updatedPending =
        Map<String, PendingOutgoingPhoto>.from(state.pendingOutgoingPhotos);
    updatedPending[event.photo.photoId] = event.photo;
    emit(state.copyWith(pendingOutgoingPhotos: updatedPending));
  }

  // ---------------------------------------------------------------------------
  // MAC rotation — update active conversation peerId
  // ---------------------------------------------------------------------------

  Future<void> _onChatPeerIdMigrated(
    ChatPeerIdMigrated event,
    Emitter<ChatState> emit,
  ) async {
    final current = state.currentConversation;
    if (current == null || current.peerId != event.oldPeerId) return;

    // Update the active conversation to target the new BLE address.
    // The DB migration (conversation.peerId update) is handled by
    // DiscoveryBloc._onPeerIdChanged before this event fires.
    emit(state.copyWith(
      currentConversation: CurrentConversation(
        id: current.id,
        peerId: event.newPeerId,
        peerName: current.peerName,
      ),
    ));

    // Also update any pending outgoing photos targeting the old peerId
    final updatedPending =
        Map<String, PendingOutgoingPhoto>.from(state.pendingOutgoingPhotos);
    var changed = false;
    for (final entry in updatedPending.entries.toList()) {
      if (entry.value.peerId == event.oldPeerId) {
        updatedPending[entry.key] = PendingOutgoingPhoto(
          photoId: entry.value.photoId,
          localPhotoPath: entry.value.localPhotoPath,
          messageId: entry.value.messageId,
          peerId: event.newPeerId,
        );
        changed = true;
      }
    }
    if (changed) {
      emit(state.copyWith(pendingOutgoingPhotos: updatedPending));
    }

    // Update transferToBleId mappings
    for (final entry in _transferToBleId.entries.toList()) {
      if (entry.value == event.oldPeerId) {
        _transferToBleId[entry.key] = event.newPeerId;
      }
    }

    Logger.info(
      'ChatBloc: Migrated active conversation peerId '
          '${event.oldPeerId} → ${event.newPeerId}',
      'Chat',
    );
  }

  // ==================== Reactions ====================

  Future<void> _onSendReaction(
    SendReaction event,
    Emitter<ChatState> emit,
  ) async {
    if (state.isBlocked) return;

    // Optimistically update state
    final updatedReactions = Map<String, List<ReactionEntry>>.from(
      state.reactions.map((k, v) => MapEntry(k, List<ReactionEntry>.from(v))),
    );
    final messageReactions =
        updatedReactions.putIfAbsent(event.messageId, () => []);
    final alreadyReacted = messageReactions.any(
      (r) => r.senderId == _ownUserId && r.emoji == event.emoji,
    );
    if (alreadyReacted) return; // already reacted — no-op

    final fakeEntry = ReactionEntry(
      id: 'local-${event.messageId}-${event.emoji}',
      messageId: event.messageId,
      senderId: _ownUserId,
      emoji: event.emoji,
      createdAt: DateTime.now(),
    );
    messageReactions.add(fakeEntry);
    emit(state.copyWith(reactions: updatedReactions));

    // Persist to DB
    try {
      await _chatRepository.addReaction(
        messageId: event.messageId,
        senderId: _ownUserId,
        emoji: event.emoji,
      );
    } catch (e) {
      Logger.error('ChatBloc: Failed to save reaction', e, null, 'ChatBloc');
    }

    // Send via BLE (fire-and-forget)
    _transportManager
        .sendReaction(
          peerId: event.peerId,
          messageId: event.messageId,
          emoji: event.emoji,
          action: 'add',
        )
        .catchError((Object e) {
          Logger.error('ChatBloc: BLE reaction send failed', e, null, 'ChatBloc');
          return false;
        });
  }

  Future<void> _onRemoveReaction(
    RemoveReaction event,
    Emitter<ChatState> emit,
  ) async {
    // Optimistically update state
    final updatedReactions = Map<String, List<ReactionEntry>>.from(
      state.reactions.map((k, v) => MapEntry(k, List<ReactionEntry>.from(v))),
    );
    updatedReactions[event.messageId]?.removeWhere(
      (r) => r.senderId == _ownUserId && r.emoji == event.emoji,
    );
    emit(state.copyWith(reactions: updatedReactions));

    // Persist to DB
    try {
      await _chatRepository.removeReaction(
        messageId: event.messageId,
        senderId: _ownUserId,
        emoji: event.emoji,
      );
    } catch (e) {
      Logger.error('ChatBloc: Failed to remove reaction', e, null, 'ChatBloc');
    }

    // Send via BLE (fire-and-forget)
    _transportManager
        .sendReaction(
          peerId: event.peerId,
          messageId: event.messageId,
          emoji: event.emoji,
          action: 'remove',
        )
        .catchError((Object e) {
          Logger.error('ChatBloc: BLE reaction send failed', e, null, 'ChatBloc');
          return false;
        });
  }

  Future<void> _onBleReactionReceived(
    BleReactionReceived event,
    Emitter<ChatState> emit,
  ) async {
    final reaction = event.reaction;

    // Ignore reactions from blocked peers
    try {
      final isBlocked =
          await _peerRepository.isPeerBlocked(reaction.fromPeerId);
      if (isBlocked) return;
    } catch (_) {}

    final messageId = reaction.messageId;
    final isAdd = reaction.action == 'add';

    // Update DB
    try {
      if (isAdd) {
        await _chatRepository.addReaction(
          messageId: messageId,
          senderId: reaction.fromPeerId,
          emoji: reaction.emoji,
        );
      } else {
        await _chatRepository.removeReaction(
          messageId: messageId,
          senderId: reaction.fromPeerId,
          emoji: reaction.emoji,
        );
      }
    } catch (e) {
      Logger.error('ChatBloc: Failed to persist received reaction', e, null, 'ChatBloc');
    }

    // Update state
    final updatedReactions = Map<String, List<ReactionEntry>>.from(
      state.reactions.map((k, v) => MapEntry(k, List<ReactionEntry>.from(v))),
    );

    if (isAdd) {
      final msgReactions =
          updatedReactions.putIfAbsent(messageId, () => []);
      final alreadyExists = msgReactions.any(
        (r) => r.senderId == reaction.fromPeerId && r.emoji == reaction.emoji,
      );
      if (!alreadyExists) {
        msgReactions.add(ReactionEntry(
          id: 'remote-$messageId-${reaction.fromPeerId}-${reaction.emoji}',
          messageId: messageId,
          senderId: reaction.fromPeerId,
          emoji: reaction.emoji,
          createdAt: reaction.timestamp,
        ));
      }
    } else {
      updatedReactions[messageId]?.removeWhere(
        (r) =>
            r.senderId == reaction.fromPeerId && r.emoji == reaction.emoji,
      );
    }

    emit(state.copyWith(reactions: updatedReactions));
    Logger.info(
      'ChatBloc: Reaction ${reaction.emoji} (${reaction.action}) '
          'from ${reaction.fromPeerId.substring(0, 8)}',
      'ChatBloc',
    );

    // Notify only when someone adds a reaction to one of our own messages.
    if (isAdd) {
      final targetMessage = state.messages.cast<MessageEntry?>().firstWhere(
        (m) => m?.id == messageId,
        orElse: () => null,
      );
      if (targetMessage != null && targetMessage.senderId == _ownUserId) {
        final senderName = state.currentConversation?.peerName ??
            reaction.fromPeerId.substring(0, 8);
        final preview = targetMessage.textContent?.isNotEmpty == true
            ? '"${targetMessage.textContent}"'
            : 'your message';
        await _notificationService.showReactionNotification(
          fromPeerId: reaction.fromPeerId,
          fromName: senderName,
          emoji: reaction.emoji,
          messagePreview: preview,
        );
      }
    }
  }

  void _onSetReplyingTo(SetReplyingTo event, Emitter<ChatState> emit) {
    if (event.message == null) {
      emit(state.copyWith(clearReplyingToMessage: true));
    } else {
      emit(state.copyWith(replyingToMessage: event.message));
    }
  }

  // ── E2EE ────────────────────────────────────────────────────────────────

  void _onE2eeSessionEstablished(
    E2eeSessionEstablished event,
    Emitter<ChatState> emit,
  ) {
    final conv = state.currentConversation;
    if (conv == null) return;
    // Sessions are now keyed by canonical peerId — direct comparison.
    if (conv.peerId == event.peerId) {
      emit(state.copyWith(isE2eeActive: true, isE2eeHandshaking: false));
      Logger.info('E2EE session active in chat with ${conv.peerId}', 'Chat');
    }
  }

  Future<void> _onE2eeHandshakeTimeout(
    _E2eeHandshakeTimeout event,
    Emitter<ChatState> emit,
  ) async {
    final enc = _encryptionService;
    if (enc == null) return;

    final conv = state.currentConversation;
    if (conv == null || conv.peerId != event.peerId) return;

    // Already have a session (race with late msg delivery)
    if (enc.hasSession(event.peerId)) return;

    // Auto-retry once — the peer's Peripheral is likely discovered by now.
    if (_handshakeRetryCount >= 1) {
      Logger.info(
        'E2EE handshake timed out for ${event.peerId} — max retries reached',
        'Chat',
      );
      emit(state.copyWith(isE2eeHandshaking: false));
      return;
    }

    _handshakeRetryCount++;
    Logger.info(
      'E2EE handshake timed out for ${event.peerId} — auto-retrying '
      '(attempt $_handshakeRetryCount)',
      'Chat',
    );

    // Brief delay to let pending scans complete.
    await Future.delayed(const Duration(seconds: 2));
    if (isClosed) return;
    if (enc.hasSession(event.peerId) || enc.hasPendingHandshake(event.peerId)) {
      return;
    }

    emit(state.copyWith(isE2eeHandshaking: true));
    final result = await enc.initiateHandshake(event.peerId);
    if (result.hasError) {
      Logger.warning(
        'E2EE handshake auto-retry failed for ${event.peerId}: ${result.error}',
        'Chat',
      );
    }
  }

  Future<void> _onE2eePeerKeyArrived(
    _E2eePeerKeyArrived event,
    Emitter<ChatState> emit,
  ) async {
    final enc = _encryptionService;
    if (enc == null) return;

    final conv = state.currentConversation;
    if (conv == null) return;
    // peerKeyStoredStream now emits the canonical peerId — direct comparison.
    if (conv.peerId != event.peerId) return;
    if (enc.hasSession(event.peerId) || enc.hasPendingHandshake(event.peerId)) return;

    Logger.info('Public key arrived for ${event.peerId} — retrying E2EE handshake', 'Chat');
    emit(state.copyWith(isE2eeHandshaking: true));

    final result = await enc.initiateHandshake(event.peerId);
    if (result.hasError) {
      Logger.warning('E2EE handshake retry failed for ${event.peerId}: ${result.error}', 'Chat');
    }
  }

  @override
  Future<void> close() {
    _e2eeSessionSubscription?.cancel();
    _e2eeKeyStoredSubscription?.cancel();
    _e2eeTimeoutSubscription?.cancel();
    _echoTimer?.cancel();
    _messageSubscription?.cancel();
    _photoProgressSubscription?.cancel();
    _photoReceivedSubscription?.cancel();
    _photoPreviewSubscription?.cancel();
    _photoRequestSubscription?.cancel();
    _peerIdChangedSubscription?.cancel();
    _peerLostSubscription?.cancel();
    _nearbyProgressSubscription?.cancel();
    _nearbyPayloadSubscription?.cancel();
    _reactionSubscription?.cancel();
    _storeForwardSubscription?.cancel();
    _retryQueueSubscription?.cancel();
    for (final timer in _photoDownloadTimers.values) {
      timer.cancel();
    }
    _photoDownloadTimers.clear();
    return super.close();
  }
}

// Internal event: peer's public key was stored by EncryptionService.
// Used to retry a handshake when the key arrives after conversation open.
class _E2eePeerKeyArrived extends ChatEvent {
  const _E2eePeerKeyArrived(this.peerId);
  final String peerId;

  @override
  List<Object?> get props => [peerId];
}

// Internal event: handshake timed out. Auto-retry once — the peer's
// Peripheral may have been discovered since the first attempt.
class _E2eeHandshakeTimeout extends ChatEvent {
  const _E2eeHandshakeTimeout(this.peerId);
  final String peerId;

  @override
  List<Object?> get props => [peerId];
}
