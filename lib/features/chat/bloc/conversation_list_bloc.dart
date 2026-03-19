import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/utils/logger.dart';
import '../../../data/repositories/chat_repository.dart';
import '../../../services/chat_event_bus.dart';
import '../../../services/message_send_service.dart';
import '../../../services/notification_service.dart';
import '../../../services/store_and_forward_service.dart';
import '../../../services/transport/transport.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class ConversationListEvent extends Equatable {
  const ConversationListEvent();

  @override
  List<Object?> get props => [];
}

/// Load all conversations from the database.
class LoadConversations extends ConversationListEvent {
  const LoadConversations();
}

/// Delete a conversation by ID.
class DeleteConversation extends ConversationListEvent {
  const DeleteConversation(this.conversationId);
  final String conversationId;

  @override
  List<Object?> get props => [conversationId];
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class ConversationListState extends Equatable {
  const ConversationListState({
    this.status = ConversationListStatus.initial,
    this.conversations = const [],
    this.errorMessage,
  });

  final ConversationListStatus status;
  final List<ConversationWithPeer> conversations;
  final String? errorMessage;

  /// Total unread count across all conversations.
  int get totalUnreadCount =>
      conversations.fold(0, (sum, conv) => sum + conv.unreadCount);

  ConversationListState copyWith({
    ConversationListStatus? status,
    List<ConversationWithPeer>? conversations,
    String? errorMessage,
  }) {
    return ConversationListState(
      status: status ?? this.status,
      conversations: conversations ?? this.conversations,
      errorMessage: errorMessage,
    );
  }

  @override
  List<Object?> get props => [status, conversations, errorMessage];
}

enum ConversationListStatus {
  initial,
  loading,
  loaded,
  error,
}

// ---------------------------------------------------------------------------
// Bloc
// ---------------------------------------------------------------------------

/// Manages the conversation list — loading and deleting conversations.
///
/// Listens to [ChatEventBus.conversationsChanged] to auto-refresh when
/// messages are sent/received by the active chat or photo transfer blocs.
class ConversationListBloc
    extends Bloc<ConversationListEvent, ConversationListState> {
  ConversationListBloc({
    required ChatRepository chatRepository,
    required NotificationService notificationService,
    required ChatEventBus chatEventBus,
    required MessageSendService messageSendService,
    required String ownUserId,
    StoreAndForwardService? storeAndForwardService,
    TransportRetryQueue? retryQueue,
  })  : _chatRepository = chatRepository,
        _notificationService = notificationService,
        super(const ConversationListState()) {
    on<LoadConversations>(_onLoadConversations);
    on<DeleteConversation>(_onDeleteConversation);

    // Auto-refresh when other blocs signal conversation changes.
    _busSub = chatEventBus.conversationsChanged.listen((_) {
      if (!isClosed) add(const LoadConversations());
    });

    _sendConvSub = messageSendService.conversationsChangedStream.listen((_) {
      if (!isClosed) add(const LoadConversations());
    });

    // Store-and-forward deliveries may update conversation last-message.
    final sf = storeAndForwardService;
    if (sf != null) {
      _storeForwardSub = sf.messageStatusStream.listen((_) {
        if (!isClosed) add(const LoadConversations());
      });
    }

    // Retry queue deliveries.
    final rq = retryQueue;
    if (rq != null) {
      _retryQueueSub = rq.deliveryStream.listen((update) {
        if (update.delivered && !isClosed) add(const LoadConversations());
      });
    }
  }

  final ChatRepository _chatRepository;
  final NotificationService _notificationService;

  StreamSubscription<void>? _busSub;
  StreamSubscription? _sendConvSub;
  StreamSubscription? _storeForwardSub;
  StreamSubscription? _retryQueueSub;

  Future<void> _onLoadConversations(
    LoadConversations event,
    Emitter<ConversationListState> emit,
  ) async {
    emit(state.copyWith(status: ConversationListStatus.loading));

    try {
      final conversations = await _chatRepository.getAllConversations();
      emit(state.copyWith(
        status: ConversationListStatus.loaded,
        conversations: conversations,
      ));
      final totalUnread =
          conversations.fold(0, (sum, c) => sum + c.unreadCount);
      await _notificationService.setBadgeCount(totalUnread);
    } catch (e) {
      Logger.error('Failed to load conversations', e, null, 'ConversationListBloc');
      emit(state.copyWith(
        status: ConversationListStatus.error,
        errorMessage: 'Failed to load conversations',
      ));
    }
  }

  Future<void> _onDeleteConversation(
    DeleteConversation event,
    Emitter<ConversationListState> emit,
  ) async {
    try {
      await _chatRepository.deleteConversation(event.conversationId);

      final updatedConversations = state.conversations
          .where((c) => c.conversation.id != event.conversationId)
          .toList();

      emit(state.copyWith(conversations: updatedConversations));
    } catch (e) {
      Logger.error('Failed to delete conversation', e, null, 'ConversationListBloc');
      emit(state.copyWith(
        status: ConversationListStatus.error,
        errorMessage: 'Failed to delete conversation',
      ));
    }
  }

  @override
  Future<void> close() {
    _busSub?.cancel();
    _sendConvSub?.cancel();
    _storeForwardSub?.cancel();
    _retryQueueSub?.cancel();
    return super.close();
  }
}
