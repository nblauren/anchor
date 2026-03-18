import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/utils/logger.dart';
import '../../../data/local_database/database.dart';
import '../../../data/repositories/anchor_drop_repository.dart';
import '../../../data/repositories/peer_repository.dart';
import '../../../services/notification_service.dart';
import '../../../services/transport/transport.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class AnchorDropEvent extends Equatable {
  const AnchorDropEvent();

  @override
  List<Object?> get props => [];
}

/// Load anchor drop history (sent peer IDs from last 24h) for badge state.
class LoadAnchorDropHistory extends AnchorDropEvent {
  const LoadAnchorDropHistory();
}

/// User tapped the ⚓ button to drop anchor on a peer.
class DropAnchor extends AnchorDropEvent {
  const DropAnchor({required this.peerId, required this.peerName});
  final String peerId;
  final String peerName;

  @override
  List<Object?> get props => [peerId, peerName];
}

/// A peer dropped anchor on us (received via transport layer).
class AnchorDropReceived extends AnchorDropEvent {
  const AnchorDropReceived({required this.fromPeerId});
  final String fromPeerId;

  @override
  List<Object?> get props => [fromPeerId];
}

/// Internal: clear the in-app anchor drop notification.
class _ClearNotification extends AnchorDropEvent {
  const _ClearNotification();
}

/// Peer ID changed (MAC rotation) — migrate dropped anchor badges.
class AnchorDropPeerIdMigrated extends AnchorDropEvent {
  const AnchorDropPeerIdMigrated({
    required this.oldPeerId,
    required this.newPeerId,
  });

  final String oldPeerId;
  final String newPeerId;

  @override
  List<Object?> get props => [oldPeerId, newPeerId];
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class AnchorDropState extends Equatable {
  const AnchorDropState({
    this.droppedAnchorPeerIds = const {},
    this.incomingAnchorDropName,
  });

  /// Peer IDs we have dropped anchor on (for ⚓ button highlight).
  final Set<String> droppedAnchorPeerIds;

  /// Set briefly when a peer drops anchor on us — used to show a SnackBar.
  final String? incomingAnchorDropName;

  AnchorDropState copyWith({
    Set<String>? droppedAnchorPeerIds,
    Object? incomingAnchorDropName = _sentinel,
  }) {
    return AnchorDropState(
      droppedAnchorPeerIds: droppedAnchorPeerIds ?? this.droppedAnchorPeerIds,
      incomingAnchorDropName: incomingAnchorDropName == _sentinel
          ? this.incomingAnchorDropName
          : incomingAnchorDropName as String?,
    );
  }

  @override
  List<Object?> get props => [droppedAnchorPeerIds, incomingAnchorDropName];
}

const _sentinel = Object();

// ---------------------------------------------------------------------------
// Bloc
// ---------------------------------------------------------------------------

/// Manages the Drop Anchor ⚓ feature — sending/receiving anchor drops
/// and maintaining badge state.
class AnchorDropBloc extends Bloc<AnchorDropEvent, AnchorDropState> {
  AnchorDropBloc({
    required AnchorDropRepository anchorDropRepository,
    required PeerRepository peerRepository,
    required TransportManager transportManager,
    NotificationService? notificationService,
  })  : _anchorDropRepository = anchorDropRepository,
        _peerRepository = peerRepository,
        _transportManager = transportManager,
        _notificationService = notificationService,
        super(const AnchorDropState()) {
    on<LoadAnchorDropHistory>(_onLoadHistory);
    on<DropAnchor>(_onDropAnchor);
    on<AnchorDropReceived>(_onAnchorDropReceived);
    on<_ClearNotification>(
      (event, emit) => emit(state.copyWith(incomingAnchorDropName: null)),
    );
    on<AnchorDropPeerIdMigrated>(_onPeerIdMigrated);

    // Subscribe to incoming anchor drop signals from transport layer.
    _anchorDropSub = _transportManager.anchorDropReceivedStream.listen(
      (drop) => add(AnchorDropReceived(fromPeerId: drop.fromPeerId)),
    );

    _peerIdChangedSub = _transportManager.peerIdChangedStream.listen(
      (change) => add(AnchorDropPeerIdMigrated(
        oldPeerId: change.oldPeerId,
        newPeerId: change.newPeerId,
      )),
    );
  }

  final AnchorDropRepository _anchorDropRepository;
  final PeerRepository _peerRepository;
  final TransportManager _transportManager;
  final NotificationService? _notificationService;

  StreamSubscription? _anchorDropSub;
  StreamSubscription? _peerIdChangedSub;

  Future<void> _onLoadHistory(
    LoadAnchorDropHistory event,
    Emitter<AnchorDropState> emit,
  ) async {
    final sentDropPeerIds =
        await _anchorDropRepository.getSentPeerIdsSince(hours: 24);
    emit(state.copyWith(droppedAnchorPeerIds: sentDropPeerIds));
  }

  Future<void> _onDropAnchor(
    DropAnchor event,
    Emitter<AnchorDropState> emit,
  ) async {
    try {
      await _anchorDropRepository.recordDrop(
        peerId: event.peerId,
        peerName: event.peerName,
        direction: AnchorDropDirection.sent,
      );

      final updated = Set<String>.from(state.droppedAnchorPeerIds)
        ..add(event.peerId);
      emit(state.copyWith(droppedAnchorPeerIds: updated));

      // Best-effort send — peer may not be reachable right now.
      _transportManager.sendDropAnchor(event.peerId);

      Logger.info('AnchorDropBloc: Anchor dropped on ${event.peerName}', 'AnchorDrop');
    } catch (e) {
      Logger.error('AnchorDropBloc: Failed to drop anchor', e, null, 'AnchorDrop');
    }
  }

  Future<void> _onAnchorDropReceived(
    AnchorDropReceived event,
    Emitter<AnchorDropState> emit,
  ) async {
    try {
      // Resolve peer name from DB.
      final peer = await _peerRepository.getPeerById(event.fromPeerId);
      final peerName = peer?.name ?? 'Someone';

      // Discard if blocked.
      if (peer?.isBlocked == true) return;

      await _anchorDropRepository.recordDrop(
        peerId: event.fromPeerId,
        peerName: peerName,
        direction: AnchorDropDirection.received,
      );

      await _notificationService?.showAnchorDropNotification(
        fromPeerId: event.fromPeerId,
        fromName: peerName,
      );

      emit(state.copyWith(incomingAnchorDropName: '$peerName \u2693'));

      // Clear after a moment so the same name can re-trigger.
      Future.delayed(const Duration(seconds: 2), () {
        if (!isClosed) add(const _ClearNotification());
      });

      Logger.info('AnchorDropBloc: Received anchor drop from $peerName', 'AnchorDrop');
    } catch (e) {
      Logger.error('AnchorDropBloc: Failed to handle anchor drop', e, null, 'AnchorDrop');
    }
  }

  void _onPeerIdMigrated(
    AnchorDropPeerIdMigrated event,
    Emitter<AnchorDropState> emit,
  ) {
    final updated = Set<String>.from(state.droppedAnchorPeerIds);
    if (updated.remove(event.oldPeerId)) {
      updated.add(event.newPeerId);
    }
    emit(state.copyWith(droppedAnchorPeerIds: updated));
  }

  @override
  Future<void> close() {
    _anchorDropSub?.cancel();
    _peerIdChangedSub?.cancel();
    return super.close();
  }
}
