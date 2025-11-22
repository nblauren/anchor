import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/logger.dart';
import '../../../data/models/chat_message.dart';
import '../../../services/ble_service.dart';
import '../../../services/database_service.dart';
import 'chat_event.dart';
import 'chat_state.dart';

class ChatBloc extends Bloc<ChatEvent, ChatState> {
  ChatBloc({
    required DatabaseService databaseService,
    required BleService bleService,
    required String ownUserId,
  })  : _databaseService = databaseService,
        _bleService = bleService,
        _ownUserId = ownUserId,
        super(const ChatState()) {
    on<LoadConversations>(_onLoadConversations);
    on<OpenConversation>(_onOpenConversation);
    on<LoadMessages>(_onLoadMessages);
    on<SendMessage>(_onSendMessage);
    on<MessageReceived>(_onMessageReceived);
    on<MarkMessagesRead>(_onMarkMessagesRead);
    on<CloseConversation>(_onCloseConversation);
    on<DeleteConversation>(_onDeleteConversation);
  }

  final DatabaseService _databaseService;
  final BleService _bleService;
  final String _ownUserId;
  final _uuid = const Uuid();

  Future<void> _onLoadConversations(
    LoadConversations event,
    Emitter<ChatState> emit,
  ) async {
    emit(state.copyWith(status: ChatStatus.loading));

    try {
      final conversations =
          await _databaseService.chatRepository.getAllConversations();
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
      final conversation =
          await _databaseService.chatRepository.getOrCreateConversation(
        participantId: event.participantId,
        participantName: event.participantName,
        participantPhotoUrl: event.participantPhotoUrl,
      );

      emit(state.copyWith(
        status: ChatStatus.loaded,
        currentConversation: conversation,
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
      final messages = await _databaseService.chatRepository
          .getMessagesForConversation(
        state.currentConversation!.id,
        limit: AppConstants.messagePageSize,
        offset: offset,
      );

      final allMessages = event.loadMore
          ? [...state.messages, ...messages]
          : messages;

      emit(state.copyWith(
        status: ChatStatus.loaded,
        messages: allMessages,
        hasMoreMessages: messages.length >= AppConstants.messagePageSize,
      ));
    } catch (e) {
      Logger.error('Failed to load messages', e, null, 'ChatBloc');
    }
  }

  Future<void> _onSendMessage(
    SendMessage event,
    Emitter<ChatState> emit,
  ) async {
    if (state.currentConversation == null) return;
    if (event.content.trim().isEmpty) return;

    emit(state.copyWith(status: ChatStatus.sending));

    try {
      final message = ChatMessage(
        id: _uuid.v4(),
        conversationId: state.currentConversation!.id,
        senderId: _ownUserId,
        receiverId: state.currentConversation!.participantId,
        content: event.content.trim(),
        timestamp: DateTime.now(),
        isSentByMe: true,
      );

      // Save locally
      await _databaseService.chatRepository.saveMessage(message);

      // Try to send via BLE
      final sent = await _bleService.sendMessage(
        recipientId: state.currentConversation!.participantId,
        message: event.content.trim(),
      );

      final updatedMessage = message.copyWith(isDelivered: sent);
      if (sent) {
        await _databaseService.chatRepository
            .markMessageAsDelivered(message.id);
      }

      // Update state
      emit(state.copyWith(
        status: ChatStatus.loaded,
        messages: [updatedMessage, ...state.messages],
      ));

      // Refresh conversations to update last message
      add(const LoadConversations());
    } catch (e) {
      Logger.error('Failed to send message', e, null, 'ChatBloc');
      emit(state.copyWith(
        status: ChatStatus.error,
        errorMessage: 'Failed to send message',
      ));
    }
  }

  Future<void> _onMessageReceived(
    MessageReceived event,
    Emitter<ChatState> emit,
  ) async {
    try {
      // Save to database
      await _databaseService.chatRepository.saveMessage(event.message);

      // If this is for the current conversation, add to messages
      if (state.currentConversation?.participantId == event.message.senderId) {
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

  Future<void> _onMarkMessagesRead(
    MarkMessagesRead event,
    Emitter<ChatState> emit,
  ) async {
    if (state.currentConversation == null) return;

    try {
      await _databaseService.chatRepository.markMessagesAsRead(
        state.currentConversation!.id,
      );
      await _databaseService.chatRepository.updateUnreadCount(
        state.currentConversation!.id,
        0,
      );

      // Refresh conversations
      add(const LoadConversations());
    } catch (e) {
      Logger.error('Failed to mark messages as read', e, null, 'ChatBloc');
    }
  }

  Future<void> _onCloseConversation(
    CloseConversation event,
    Emitter<ChatState> emit,
  ) async {
    emit(state.copyWith(
      currentConversation: null,
      messages: [],
    ));
  }

  Future<void> _onDeleteConversation(
    DeleteConversation event,
    Emitter<ChatState> emit,
  ) async {
    try {
      await _databaseService.chatRepository.deleteConversation(
        event.conversationId,
      );

      final updatedConversations = state.conversations
          .where((c) => c.id != event.conversationId)
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
}
