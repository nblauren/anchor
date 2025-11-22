import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/logger.dart';
import '../../../data/local_database/database.dart';
import '../../../data/repositories/chat_repository.dart';
import '../../../services/image_service.dart';
import 'chat_event.dart';
import 'chat_state.dart';

class ChatBloc extends Bloc<ChatEvent, ChatState> {
  ChatBloc({
    required ChatRepository chatRepository,
    required ImageService imageService,
    required String ownUserId,
  })  : _chatRepository = chatRepository,
        _imageService = imageService,
        _ownUserId = ownUserId,
        super(const ChatState()) {
    on<LoadConversations>(_onLoadConversations);
    on<OpenConversation>(_onOpenConversation);
    on<LoadMessages>(_onLoadMessages);
    on<SendTextMessage>(_onSendTextMessage);
    on<SendPhotoMessage>(_onSendPhotoMessage);
    on<MessageReceived>(_onMessageReceived);
    on<MessageStatusUpdated>(_onMessageStatusUpdated);
    on<RetryFailedMessage>(_onRetryFailedMessage);
    on<MarkMessagesRead>(_onMarkMessagesRead);
    on<CloseConversation>(_onCloseConversation);
    on<DeleteConversation>(_onDeleteConversation);
    on<ClearChatError>(_onClearError);
  }

  final ChatRepository _chatRepository;
  final ImageService _imageService;
  final String _ownUserId;

  // Mock echo timer
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
      final conversationEntry = await _chatRepository.getOrCreateConversation(event.peerId);

      emit(state.copyWith(
        status: ChatStatus.loaded,
        currentConversation: CurrentConversation(
          id: conversationEntry.id,
          peerId: event.peerId,
          peerName: event.peerName,
        ),
        messages: [],
        hasMoreMessages: true,
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

      final allMessages = event.loadMore ? [...state.messages, ...messages] : messages;

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

    emit(state.copyWith(status: ChatStatus.sending));

    try {
      // Send message
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

      // Simulate sending (update to sent status after delay)
      _simulateSend(message.id);

      // Schedule mock echo response
      _scheduleMockEcho(event.text.trim());

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

    emit(state.copyWith(status: ChatStatus.sending));

    try {
      // Compress the photo for chat (target ~100-200KB)
      final compressedPath = await _imageService.compressForChat(event.photoPath);

      // Send photo message
      final message = await _chatRepository.sendPhotoMessage(
        conversationId: state.currentConversation!.id,
        senderId: _ownUserId,
        photoPath: compressedPath,
      );

      // Add to messages list
      emit(state.copyWith(
        status: ChatStatus.loaded,
        messages: [message, ...state.messages],
      ));

      // Simulate sending
      _simulateSend(message.id);

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
    try {
      // Mark as pending again
      await _chatRepository.updateMessageStatus(event.messageId, MessageStatus.pending);

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
            status: MessageStatus.pending,
            createdAt: msg.createdAt,
          );
        }
        return msg;
      }).toList();

      emit(state.copyWith(messages: updatedMessages));

      // Simulate retry
      _simulateSend(event.messageId);
    } catch (e) {
      Logger.error('Failed to retry message', e, null, 'ChatBloc');
    }
  }

  Future<void> _onMarkMessagesRead(
    MarkMessagesRead event,
    Emitter<ChatState> emit,
  ) async {
    if (state.currentConversation == null) return;

    try {
      // In a real app, you'd mark specific messages as read
      // For now, just refresh conversations to update unread count
      add(const LoadConversations());
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

  /// Simulate message sending (update status after delay)
  void _simulateSend(String messageId) {
    Future.delayed(const Duration(milliseconds: 500), () {
      add(MessageStatusUpdated(
        messageId: messageId,
        status: MessageStatus.sent,
      ));
    });
  }

  /// Schedule a mock echo response for testing
  void _scheduleMockEcho(String originalText) {
    _echoTimer?.cancel();
    _echoTimer = Timer(const Duration(seconds: 1), () async {
      if (state.currentConversation == null) return;

      try {
        // Create echo response
        final echoText = _generateEchoResponse(originalText);

        final echoMessage = await _chatRepository.receiveMessage(
          conversationId: state.currentConversation!.id,
          senderId: state.currentConversation!.peerId,
          contentType: MessageContentType.text,
          textContent: echoText,
        );

        add(MessageReceived(echoMessage));
      } catch (e) {
        Logger.error('Failed to generate echo', e, null, 'ChatBloc');
      }
    });
  }

  /// Generate a mock echo response
  String _generateEchoResponse(String originalText) {
    final responses = [
      "Hey! Got your message: \"$originalText\"",
      "Thanks for saying: $originalText",
      "Interesting! You said: $originalText",
      "Cool message! \"$originalText\"",
      "I hear you: $originalText",
    ];

    // Pick a response based on message length (deterministic for same input)
    final index = originalText.length % responses.length;
    return responses[index];
  }

  @override
  Future<void> close() {
    _echoTimer?.cancel();
    return super.close();
  }
}
