import 'dart:async';

import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/data/local_database/database.dart';
import 'package:anchor/data/repositories/anchor_drop_repository_interface.dart';
import 'package:anchor/data/repositories/peer_repository_interface.dart';
import 'package:anchor/services/ble/ble_models.dart' as ble;
import 'package:anchor/services/notification_service.dart';
import 'package:anchor/services/transport/transport.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

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

/// Load received anchor drops for the anchor drops screen.
class LoadReceivedDrops extends AnchorDropEvent {
  const LoadReceivedDrops();
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

/// Internal: a peer was discovered — retry any pending drops for them.
class _PeerDiscovered extends AnchorDropEvent {
  const _PeerDiscovered(this.peerId);
  final String peerId;

  @override
  List<Object?> get props => [peerId];
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
    this.receivedDrops = const [],
    this.receivedDropsLoading = false,
  });

  /// Peer IDs we have dropped anchor on (for ⚓ button highlight).
  final Set<String> droppedAnchorPeerIds;

  /// Set briefly when a peer drops anchor on us — used to show a SnackBar.
  final String? incomingAnchorDropName;

  /// Received anchor drops (deduplicated by peerId, most recent first).
  final List<AnchorDropEntry> receivedDrops;

  /// Whether received drops are currently loading.
  final bool receivedDropsLoading;

  AnchorDropState copyWith({
    Set<String>? droppedAnchorPeerIds,
    Object? incomingAnchorDropName = _sentinel,
    List<AnchorDropEntry>? receivedDrops,
    bool? receivedDropsLoading,
  }) {
    return AnchorDropState(
      droppedAnchorPeerIds: droppedAnchorPeerIds ?? this.droppedAnchorPeerIds,
      incomingAnchorDropName: incomingAnchorDropName == _sentinel
          ? this.incomingAnchorDropName
          : incomingAnchorDropName as String?,
      receivedDrops: receivedDrops ?? this.receivedDrops,
      receivedDropsLoading: receivedDropsLoading ?? this.receivedDropsLoading,
    );
  }

  @override
  List<Object?> get props => [
        droppedAnchorPeerIds,
        incomingAnchorDropName,
        receivedDrops,
        receivedDropsLoading,
      ];
}

const _sentinel = Object();

// ---------------------------------------------------------------------------
// Bloc
// ---------------------------------------------------------------------------

/// Manages the Drop Anchor ⚓ feature — sending/receiving anchor drops
/// and maintaining badge state.
///
/// When a send fails (peer unreachable), the drop is saved as [AnchorDropStatus.pending].
/// On peer rediscovery, pending drops are retried automatically.
class AnchorDropBloc extends Bloc<AnchorDropEvent, AnchorDropState> {
  AnchorDropBloc({
    required AnchorDropRepositoryInterface anchorDropRepository,
    required PeerRepositoryInterface peerRepository,
    required TransportManager transportManager,
    NotificationService? notificationService,
  })  : _anchorDropRepository = anchorDropRepository,
        _peerRepository = peerRepository,
        _transportManager = transportManager,
        _notificationService = notificationService,
        super(const AnchorDropState()) {
    on<LoadAnchorDropHistory>(_onLoadHistory);
    on<LoadReceivedDrops>(_onLoadReceivedDrops);
    on<DropAnchor>(_onDropAnchor);
    on<AnchorDropReceived>(_onAnchorDropReceived);
    on<_ClearNotification>(
      (event, emit) => emit(state.copyWith(incomingAnchorDropName: null)),
    );
    on<_PeerDiscovered>(_onPeerDiscovered);
    on<AnchorDropPeerIdMigrated>(_onPeerIdMigrated);

    // Subscribe to incoming anchor drop signals from transport layer.
    _anchorDropSub = _transportManager.anchorDropReceivedStream.listen(
      (drop) => add(AnchorDropReceived(fromPeerId: drop.fromPeerId)),
    );

    _peerIdChangedSub = _transportManager.peerIdChangedStream.listen(
      (change) => add(AnchorDropPeerIdMigrated(
        oldPeerId: change.oldPeerId,
        newPeerId: change.newPeerId,
      ),),
    );

    // Listen to peer discovery — retry pending drops when a peer reappears.
    _peerDiscoveredSub = _transportManager.peerDiscoveredStream.listen(
      (peer) {
        if (!isClosed) add(_PeerDiscovered(peer.peerId));
      },
    );

    // Expire stale pending drops on startup.
    _anchorDropRepository.expireStalePendingDrops();
  }

  final AnchorDropRepositoryInterface _anchorDropRepository;
  final PeerRepositoryInterface _peerRepository;
  final TransportManager _transportManager;
  final NotificationService? _notificationService;

  StreamSubscription<ble.AnchorDropReceived>? _anchorDropSub;
  StreamSubscription<ble.PeerIdChanged>? _peerIdChangedSub;
  StreamSubscription<ble.DiscoveredPeer>? _peerDiscoveredSub;

  /// Prevent concurrent retry attempts for the same peer.
  final Set<String> _retryingPeerIds = {};

  Future<void> _onLoadHistory(
    LoadAnchorDropHistory event,
    Emitter<AnchorDropState> emit,
  ) async {
    final sentDropPeerIds =
        await _anchorDropRepository.getSentPeerIdsSince();
    emit(state.copyWith(droppedAnchorPeerIds: sentDropPeerIds));
  }

  Future<void> _onLoadReceivedDrops(
    LoadReceivedDrops event,
    Emitter<AnchorDropState> emit,
  ) async {
    emit(state.copyWith(receivedDropsLoading: true));
    try {
      final drops = await _anchorDropRepository.getReceivedDrops();
      // Deduplicate by peerId, keeping most recent per peer.
      final seen = <String>{};
      final unique = <AnchorDropEntry>[];
      for (final drop in drops) {
        if (seen.add(drop.peerId)) {
          unique.add(drop);
        }
      }
      emit(state.copyWith(
        receivedDrops: unique,
        receivedDropsLoading: false,
      ),);
    } on Exception catch (e) {
      Logger.error(
        'AnchorDropBloc: Failed to load received drops',
        e,
        null,
        'AnchorDrop',
      );
      emit(state.copyWith(receivedDropsLoading: false));
    }
  }

  Future<void> _onDropAnchor(
    DropAnchor event,
    Emitter<AnchorDropState> emit,
  ) async {
    try {
      // Optimistically update the UI badge.
      final updated = Set<String>.from(state.droppedAnchorPeerIds)
        ..add(event.peerId);
      emit(state.copyWith(droppedAnchorPeerIds: updated));

      // Try to send immediately.
      final success = await _transportManager.sendDropAnchor(event.peerId);

      // Record to DB with appropriate status.
      await _anchorDropRepository.recordDrop(
        peerId: event.peerId,
        peerName: event.peerName,
        direction: AnchorDropDirection.sent,
        status:
            success ? AnchorDropStatus.delivered : AnchorDropStatus.pending,
      );

      if (success) {
        Logger.info(
            'AnchorDropBloc: Anchor dropped on ${event.peerName}',
            'AnchorDrop',);
      } else {
        Logger.info(
            'AnchorDropBloc: Anchor queued for ${event.peerName} (peer unreachable)',
            'AnchorDrop',);
      }
    } on Exception catch (e) {
      Logger.error(
          'AnchorDropBloc: Failed to drop anchor', e, null, 'AnchorDrop',);
    }
  }

  Future<void> _onPeerDiscovered(
    _PeerDiscovered event,
    Emitter<AnchorDropState> emit,
  ) async {
    final peerId = event.peerId;

    // Guard against concurrent retries for the same peer.
    if (_retryingPeerIds.contains(peerId)) return;
    _retryingPeerIds.add(peerId);

    try {
      final pendingDrops =
          await _anchorDropRepository.getPendingDropsForPeer(peerId);
      if (pendingDrops.isEmpty) return;

      for (final drop in pendingDrops) {
        final success = await _transportManager.sendDropAnchor(drop.peerId);
        if (success) {
          await _anchorDropRepository.markDelivered(drop.id);
          Logger.info(
            'AnchorDropBloc: Pending anchor delivered to ${drop.peerName}',
            'AnchorDrop',
          );
        }
      }
    } on Exception catch (e) {
      Logger.error(
          'AnchorDropBloc: Retry failed', e, null, 'AnchorDrop',);
    } finally {
      _retryingPeerIds.remove(peerId);
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
      if (peer?.isBlocked ?? false) return;

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

      Logger.info(
          'AnchorDropBloc: Received anchor drop from $peerName',
          'AnchorDrop',);
    } on Exception catch (e) {
      Logger.error('AnchorDropBloc: Failed to handle anchor drop', e, null,
          'AnchorDrop',);
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
    _peerDiscoveredSub?.cancel();
    return super.close();
  }
}
