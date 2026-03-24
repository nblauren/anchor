import 'dart:async';

import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/data/local_database/database.dart';
import 'package:anchor/data/repositories/chat_repository_interface.dart';
import 'package:anchor/data/repositories/peer_repository_interface.dart';
import 'package:anchor/services/ble/ble.dart' as ble;
import 'package:anchor/services/notification_service.dart';
import 'package:anchor/services/transport/transport.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class ReactionEvent extends Equatable {
  const ReactionEvent();

  @override
  List<Object?> get props => [];
}

/// Load reactions for a conversation.
class LoadReactions extends ReactionEvent {
  const LoadReactions(this.conversationId);
  final String conversationId;

  @override
  List<Object?> get props => [conversationId];
}

/// Send an emoji reaction for a message.
class SendReaction extends ReactionEvent {
  const SendReaction({
    required this.messageId,
    required this.peerId,
    required this.emoji,
  });

  final String messageId;
  final String peerId;
  final String emoji;

  @override
  List<Object?> get props => [messageId, peerId, emoji];
}

/// Remove an emoji reaction from a message.
class RemoveReaction extends ReactionEvent {
  const RemoveReaction({
    required this.messageId,
    required this.peerId,
    required this.emoji,
  });

  final String messageId;
  final String peerId;
  final String emoji;

  @override
  List<Object?> get props => [messageId, peerId, emoji];
}

/// Incoming emoji reaction received from a peer via BLE.
class BleReactionReceived extends ReactionEvent {
  const BleReactionReceived(this.reaction);
  final ble.ReactionReceived reaction;

  @override
  List<Object?> get props => [reaction];
}

/// Reset reactions (e.g. when conversation is closed).
class ClearReactions extends ReactionEvent {
  const ClearReactions();
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class ReactionState extends Equatable {
  const ReactionState({
    this.reactions = const {},
  });

  /// Emoji reactions keyed by messageId.
  final Map<String, List<ReactionEntry>> reactions;

  ReactionState copyWith({
    Map<String, List<ReactionEntry>>? reactions,
  }) {
    return ReactionState(
      reactions: reactions ?? this.reactions,
    );
  }

  @override
  List<Object?> get props => [reactions];
}

// ---------------------------------------------------------------------------
// Bloc
// ---------------------------------------------------------------------------

/// Manages emoji reactions for the active chat conversation.
class ReactionBloc extends Bloc<ReactionEvent, ReactionState> {
  ReactionBloc({
    required ChatRepositoryInterface chatRepository,
    required PeerRepositoryInterface peerRepository,
    required TransportManager transportManager,
    required NotificationService notificationService,
    required String ownUserId,
  })  : _chatRepository = chatRepository,
        _peerRepository = peerRepository,
        _transportManager = transportManager,
        _notificationService = notificationService,
        _ownUserId = ownUserId,
        super(const ReactionState()) {
    on<LoadReactions>(_onLoadReactions);
    on<SendReaction>(_onSendReaction);
    on<RemoveReaction>(_onRemoveReaction);
    on<BleReactionReceived>(_onBleReactionReceived);
    on<ClearReactions>(_onClearReactions);

    _reactionSubscription = _transportManager.reactionReceivedStream.listen(
      (reaction) {
        if (!isClosed) add(BleReactionReceived(reaction));
      },
    );
  }

  final ChatRepositoryInterface _chatRepository;
  final PeerRepositoryInterface _peerRepository;
  final TransportManager _transportManager;
  final NotificationService _notificationService;
  final String _ownUserId;
  StreamSubscription<ble.ReactionReceived>? _reactionSubscription;

  /// Context set by the UI when a conversation is opened. Used for
  /// resolving peer names in notifications.
  String? activePeerName;

  /// Messages in the active conversation — set by the UI so we can
  /// look up senders for notification text.
  List<MessageEntry> activeMessages = const [];

  Future<void> _onLoadReactions(
    LoadReactions event,
    Emitter<ReactionState> emit,
  ) async {
    try {
      final loaded = await _chatRepository.getReactionsForConversation(
        event.conversationId,
      );
      emit(state.copyWith(reactions: loaded));
    } on Exception {
      Logger.warning('ReactionBloc: Failed to load reactions', 'ReactionBloc');
    }
  }

  Future<void> _onSendReaction(
    SendReaction event,
    Emitter<ReactionState> emit,
  ) async {
    // Optimistically update state
    final updatedReactions = Map<String, List<ReactionEntry>>.from(
      state.reactions
          .map((k, v) => MapEntry(k, List<ReactionEntry>.from(v))),
    );
    final messageReactions =
        updatedReactions.putIfAbsent(event.messageId, () => []);

    // If the user already reacted with this exact emoji, no-op
    final alreadyReacted = messageReactions.any(
      (r) => r.senderId == _ownUserId && r.emoji == event.emoji,
    );
    if (alreadyReacted) return;

    // Remove any existing reaction from this user (only one reaction allowed)
    final previousReaction = messageReactions.cast<ReactionEntry?>().firstWhere(
      (r) => r?.senderId == _ownUserId,
      orElse: () => null,
    );
    if (previousReaction != null) {
      messageReactions.removeWhere((r) => r.senderId == _ownUserId);
      // Remove old reaction from DB and notify peer
      unawaited(_chatRepository.removeReaction(
        messageId: event.messageId,
        senderId: _ownUserId,
        emoji: previousReaction.emoji,
      ).catchError((Object e) {
        Logger.error('ReactionBloc: Failed to remove old reaction', e, null,
            'ReactionBloc',);
      }),);
      unawaited(_transportManager
          .sendReaction(
            peerId: event.peerId,
            messageId: event.messageId,
            emoji: previousReaction.emoji,
            action: 'remove',
          )
          .catchError((Object e) => false),);
    }

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
    } on Exception catch (e) {
      Logger.error(
          'ReactionBloc: Failed to save reaction', e, null, 'ReactionBloc',);
    }

    // Send via transport (fire-and-forget)
    unawaited(_transportManager
        .sendReaction(
          peerId: event.peerId,
          messageId: event.messageId,
          emoji: event.emoji,
          action: 'add',
        )
        .catchError((Object e) {
      Logger.error(
          'ReactionBloc: BLE reaction send failed', e, null, 'ReactionBloc',);
      return false;
    }),);
  }

  Future<void> _onRemoveReaction(
    RemoveReaction event,
    Emitter<ReactionState> emit,
  ) async {
    // Optimistically update state
    final updatedReactions = Map<String, List<ReactionEntry>>.from(
      state.reactions
          .map((k, v) => MapEntry(k, List<ReactionEntry>.from(v))),
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
    } on Exception catch (e) {
      Logger.error(
          'ReactionBloc: Failed to remove reaction', e, null, 'ReactionBloc',);
    }

    // Send via transport (fire-and-forget)
    unawaited(_transportManager
        .sendReaction(
          peerId: event.peerId,
          messageId: event.messageId,
          emoji: event.emoji,
          action: 'remove',
        )
        .catchError((Object e) {
      Logger.error(
          'ReactionBloc: BLE reaction send failed', e, null, 'ReactionBloc',);
      return false;
    }),);
  }

  Future<void> _onBleReactionReceived(
    BleReactionReceived event,
    Emitter<ReactionState> emit,
  ) async {
    final reaction = event.reaction;

    // Ignore reactions from blocked peers
    try {
      final isBlocked =
          await _peerRepository.isPeerBlocked(reaction.fromPeerId);
      if (isBlocked) return;
    } on Exception catch (_) {}

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
    } on Exception catch (e) {
      Logger.error('ReactionBloc: Failed to persist received reaction', e, null,
          'ReactionBloc',);
    }

    // Update state
    final updatedReactions = Map<String, List<ReactionEntry>>.from(
      state.reactions
          .map((k, v) => MapEntry(k, List<ReactionEntry>.from(v))),
    );

    if (isAdd) {
      final msgReactions =
          updatedReactions.putIfAbsent(messageId, () => []);
      final alreadyExists = msgReactions.any(
        (r) =>
            r.senderId == reaction.fromPeerId && r.emoji == reaction.emoji,
      );
      if (!alreadyExists) {
        // Remove any existing reaction from this sender (one per message)
        msgReactions
            ..removeWhere((r) => r.senderId == reaction.fromPeerId)
            ..add(ReactionEntry(
              id: 'remote-$messageId-${reaction.fromPeerId}-${reaction.emoji}',
              messageId: messageId,
              senderId: reaction.fromPeerId,
              emoji: reaction.emoji,
              createdAt: reaction.timestamp,
            ),);
      }
    } else {
      updatedReactions[messageId]?.removeWhere(
        (r) =>
            r.senderId == reaction.fromPeerId && r.emoji == reaction.emoji,
      );
    }

    emit(state.copyWith(reactions: updatedReactions));
    Logger.info(
      'ReactionBloc: Reaction ${reaction.emoji} (${reaction.action}) '
      'from ${reaction.fromPeerId.substring(0, 8)}',
      'ReactionBloc',
    );

    // Notify only when someone adds a reaction to one of our own messages.
    if (isAdd) {
      final targetMessage = activeMessages.cast<MessageEntry?>().firstWhere(
        (m) => m?.id == messageId,
        orElse: () => null,
      );
      if (targetMessage != null && targetMessage.senderId == _ownUserId) {
        final senderName =
            activePeerName ?? reaction.fromPeerId.substring(0, 8);
        final preview = targetMessage.textContent?.isNotEmpty ?? false
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

  void _onClearReactions(ClearReactions event, Emitter<ReactionState> emit) {
    emit(const ReactionState());
  }

  @override
  Future<void> close() {
    _reactionSubscription?.cancel();
    return super.close();
  }
}
