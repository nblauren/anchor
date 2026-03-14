import 'dart:async';
import 'dart:math';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../core/utils/logger.dart';
import '../../../data/local_database/database.dart';
import '../../../data/repositories/anchor_drop_repository.dart';
import '../../../data/repositories/peer_repository.dart';
import '../../../services/ble/ble.dart' as ble;
import '../../../services/notification_service.dart';
import '../../../services/transport/transport.dart';
import 'discovery_event.dart';
import 'discovery_state.dart';

/// Private event used to apply debounced state updates safely via add()
class _ApplyDebouncedState extends DiscoveryEvent {
  const _ApplyDebouncedState(this.newState);
  final DiscoveryState newState;

  @override
  List<Object?> get props => [newState];
}

/// Private event to clear the in-app anchor drop notification
class _ClearAnchorDropNotification extends DiscoveryEvent {
  @override
  List<Object?> get props => [];
}

/// Manages the peer discovery grid.
///
/// Listens to [BleServiceInterface.peerDiscoveredStream] and
/// [BleServiceInterface.peerLostStream] to keep the grid up-to-date.
/// All filtering (position, interests) is done locally — no network required.
/// Peers are sorted by RSSI (closest first) and state updates are debounced
/// to avoid excessive rebuilds in high-density environments.
///
/// Also handles:
///   - Blocking/unblocking peers (stored in [PeerRepository])
///   - Drop Anchor ⚓ signals (sent/received via [BleServiceInterface])
///   - Full profile photo fetch (on-demand via fff4 characteristic)
class DiscoveryBloc extends Bloc<DiscoveryEvent, DiscoveryState> {
  DiscoveryBloc({
    required PeerRepository peerRepository,
    required TransportManager transportManager,
    required AnchorDropRepository anchorDropRepository,
    NotificationService? notificationService,
  })  : _peerRepository = peerRepository,
        _transportManager = transportManager,
        _anchorDropRepository = anchorDropRepository,
        _notificationService = notificationService,
        super(const DiscoveryState()) {
    on<LoadDiscoveredPeers>(_onLoadDiscoveredPeers);
    on<StartDiscovery>(_onStartDiscovery);
    on<StopDiscovery>(_onStopDiscovery);
    on<PeerDiscovered>(_onPeerDiscovered);
    on<PeerUpdated>(_onPeerUpdated);
    on<PeerLost>(_onPeerLost);
    on<BlockPeer>(_onBlockPeer);
    on<UnblockPeer>(_onUnblockPeer);
    on<RefreshPeers>(_onRefreshPeers);
    on<LoadMockPeers>(_onLoadMockPeers);
    on<ClearDiscoveryError>(_onClearError);
    on<FetchPeerFullPhotos>(_onFetchPeerFullPhotos);
    on<DropAnchorOnPeer>(_onDropAnchorOnPeer);
    on<AnchorDropSignalReceived>(_onAnchorDropSignalReceived);
    on<_ClearAnchorDropNotification>(
      (event, emit) => emit(state.copyWith(incomingAnchorDropName: null)),
    );
    on<_ApplyDebouncedState>((event, emit) {
      // Merge debounced state into current state instead of replacing wholesale.
      // This prevents stale snapshots from re-adding peers that were removed
      // by PeerLost or PeerIdChanged events that fired between scheduling and
      // debounce expiry.
      final currentPeerIds = {for (final p in state.peers) p.peerId};
      final debouncedPeerMap = {
        for (final p in event.newState.peers) p.peerId: p
      };

      // Update existing current peers with debounced data
      final merged = state.peers.map((p) {
        final debounced = debouncedPeerMap[p.peerId];
        return debounced ?? p;
      }).toList();

      // Add genuinely new peers from debounced state
      for (final p in event.newState.peers) {
        if (!currentPeerIds.contains(p.peerId)) {
          merged.insert(0, p);
        }
      }

      emit(state.copyWith(peers: merged));
    });
    on<TogglePositionFilter>(_onTogglePositionFilter);
    on<ToggleInterestFilter>(_onToggleInterestFilter);
    on<PeerIdChangedEvent>(_onPeerIdChanged);
    on<ClearFilters>(
      (event, emit) => emit(state.copyWith(
        filterPositionIds: const {},
        filterInterestIds: const {},
      )),
    );

    // Subscribe to transport manager streams (Wi-Fi Aware or BLE)
    _peerDiscoveredSubscription = _transportManager.peerDiscoveredStream.listen(
      _onBlePeerDiscovered,
    );

    _peerLostSubscription = _transportManager.peerLostStream.listen(
      (peerId) => add(PeerLost(peerId)),
    );

    _anchorDropSubscription = _transportManager.anchorDropReceivedStream.listen(
      (drop) => add(AnchorDropSignalReceived(fromPeerId: drop.fromPeerId)),
    );

    _peerIdChangedSubscription =
        _transportManager.peerIdChangedStream.listen(
      (change) => add(PeerIdChangedEvent(
        oldPeerId: change.oldPeerId,
        newPeerId: change.newPeerId,
        userId: change.userId,
      )),
    );

    // Debounce timer for batching peer updates
    _debounceTimer?.cancel();
  }

  final PeerRepository _peerRepository;
  final TransportManager _transportManager;
  final AnchorDropRepository _anchorDropRepository;
  final NotificationService? _notificationService;
  Timer? _debounceTimer;
  bool _pendingUpdate = false;
  StreamSubscription<ble.DiscoveredPeer>? _peerDiscoveredSubscription;
  StreamSubscription<String>? _peerLostSubscription;
  StreamSubscription<ble.AnchorDropReceived>? _anchorDropSubscription;
  StreamSubscription<ble.PeerIdChanged>? _peerIdChangedSubscription;

  /// Handle BLE peer discovered event - convert to bloc event
  void _onBlePeerDiscovered(ble.DiscoveredPeer peer) {
    // Check if peer is blocked before processing
    _peerRepository.isPeerBlocked(peer.peerId).then((isBlocked) {
      if (!isBlocked) {
        add(PeerDiscovered(
          peerId: peer.peerId,
          name: peer.name,
          age: peer.age,
          bio: peer.bio,
          position: peer.position,
          interests: peer.interests,
          thumbnailData: peer.thumbnailBytes,
          photoThumbnails: peer.photoThumbnails,
          rssi: peer.rssi,
          isRelayed: peer.isRelayed,
          hopCount: peer.hopCount,
          fullPhotoCount: peer.fullPhotoCount,
        ));
      }
    });
  }

  /// Start BLE discovery scanning
  Future<void> _onStartDiscovery(
    StartDiscovery event,
    Emitter<DiscoveryState> emit,
  ) async {
    try {
      emit(state.copyWith(isScanning: true));
      await _transportManager.startScanning();
      Logger.info('Discovery scanning started', 'DiscoveryBloc');
    } catch (e) {
      Logger.error('Failed to start BLE scanning', e, null, 'DiscoveryBloc');
      emit(state.copyWith(
        isScanning: false,
        errorMessage: 'Failed to start discovery',
      ));
    }
  }

  /// Stop BLE discovery scanning
  Future<void> _onStopDiscovery(
    StopDiscovery event,
    Emitter<DiscoveryState> emit,
  ) async {
    try {
      await _transportManager.stopScanning();
      emit(state.copyWith(isScanning: false));
      Logger.info('Discovery scanning stopped', 'DiscoveryBloc');
    } catch (e) {
      Logger.error('Failed to stop BLE scanning', e, null, 'DiscoveryBloc');
    }
  }

  /// Load peers from database
  Future<void> _onLoadDiscoveredPeers(
    LoadDiscoveredPeers event,
    Emitter<DiscoveryState> emit,
  ) async {
    emit(state.copyWith(status: DiscoveryStatus.loading));

    try {
      final entries = await _peerRepository.getAllPeers(includeBlocked: false);
      final peers = entries.map(DiscoveredPeer.fromEntry).toList();

      // Restore anchor drop badges from DB (persists across restarts).
      final sentDropPeerIds =
          await _anchorDropRepository.getSentPeerIdsSince(hours: 24);

      emit(state.copyWith(
        status: DiscoveryStatus.loaded,
        peers: peers,
        lastRefreshed: DateTime.now(),
        droppedAnchorPeerIds: sentDropPeerIds,
      ));
    } catch (e) {
      Logger.error('Failed to load peers', e, null, 'DiscoveryBloc');
      emit(state.copyWith(
        status: DiscoveryStatus.error,
        errorMessage: 'Failed to load discovered peers',
      ));
    }
  }

  /// Handle new peer discovery from BLE
  Future<void> _onPeerDiscovered(
    PeerDiscovered event,
    Emitter<DiscoveryState> emit,
  ) async {
    try {
      DiscoveredPeer peer;

      if (event.isRelayed) {
        // Relayed peers are not persisted — in-memory only.
        // Don't overwrite a directly-seen peer with a stale relayed version.
        final existing =
            state.peers.where((p) => p.peerId == event.peerId).firstOrNull;
        if (existing != null && !existing.isRelayed) return;

        peer = DiscoveredPeer(
          peerId: event.peerId,
          name: event.name,
          age: event.age,
          bio: event.bio,
          position: event.position,
          interests: event.interests,
          thumbnailData: event.thumbnailData,
          photoThumbnails: event.photoThumbnails,
          lastSeenAt: DateTime.now(),
          rssi: null,
          isRelayed: true,
          hopCount: event.hopCount,
          fullPhotoCount: event.fullPhotoCount,
        );
      } else {
        // Direct peer: persist to database
        final entry = await _peerRepository.upsertPeer(
          peerId: event.peerId,
          name: event.name,
          age: event.age,
          bio: event.bio,
          position: event.position,
          interests: event.interests,
          thumbnailData: event.thumbnailData,
          rssi: event.rssi,
        );

        peer = DiscoveredPeer.fromEntry(entry);

        // Carry over in-memory-only fields not stored in DB
        final existing =
            state.peers.where((p) => p.peerId == event.peerId).firstOrNull;
        if (event.photoThumbnails != null) {
          peer = peer.copyWith(
            photoThumbnails: event.photoThumbnails,
            fullPhotoCount: event.fullPhotoCount > 0
                ? event.fullPhotoCount
                : existing?.fullPhotoCount ?? 0,
          );
        } else {
          peer = peer.copyWith(
            photoThumbnails: existing?.photoThumbnails,
            fullPhotoCount: event.fullPhotoCount > 0
                ? event.fullPhotoCount
                : existing?.fullPhotoCount ?? 0,
          );
        }
      }

      // Always ensure re-discovered peers are marked online
      peer = peer.copyWith(isOnline: true);

      final existingIndex =
          state.peers.indexWhere((p) => p.peerId == event.peerId);
      final isNewPeer = existingIndex < 0;
      List<DiscoveredPeer> updatedPeers;
      if (!isNewPeer) {
        updatedPeers = [...state.peers];
        updatedPeers[existingIndex] = peer;
      } else {
        updatedPeers = [peer, ...state.peers];
        // Notify user about new peer (useful when app is backgrounded on iOS)
        _notificationService?.showPeerDiscoveredNotification(
          peerId: peer.peerId,
          peerName: peer.name,
        );
      }
      final newState = state.copyWith(
        status: DiscoveryStatus.loaded,
        peers: updatedPeers,
      );

      // Thumbnail/photo arrivals must reach the UI immediately — no debounce.
      // All other updates (RSSI refresh, profile re-reads) use debouncing
      // to avoid excessive rebuilds when many peers update in rapid succession.
      if (event.thumbnailData != null || event.photoThumbnails != null) {
        emit(newState);
      } else {
        _scheduleUpdate(emit, () => newState);
      }
    } catch (e) {
      Logger.error(
          'Failed to process discovered peer', e, null, 'DiscoveryBloc');
    }
  }

  /// Handle peer data update
  Future<void> _onPeerUpdated(
    PeerUpdated event,
    Emitter<DiscoveryState> emit,
  ) async {
    try {
      final existing = await _peerRepository.getPeerById(event.peerId);
      if (existing == null) return;

      // Update peer presence (last seen + rssi)
      await _peerRepository.updatePeerPresence(event.peerId, rssi: event.rssi);

      // Update local state
      _scheduleUpdate(emit, () {
        final updatedPeers = state.peers.map((p) {
          if (p.peerId == event.peerId) {
            return p.copyWith(
              name: event.name ?? p.name,
              age: event.age ?? p.age,
              bio: event.bio ?? p.bio,
              thumbnailData: event.thumbnailData ?? p.thumbnailData,
              rssi: event.rssi ?? p.rssi,
              lastSeenAt: DateTime.now(),
            );
          }
          return p;
        }).toList();

        return state.copyWith(peers: updatedPeers);
      });
    } catch (e) {
      Logger.error('Failed to update peer', e, null, 'DiscoveryBloc');
    }
  }

  /// Handle peer lost (not seen for a while).
  /// Marks the peer as offline in the Discovery grid instead of removing it.
  /// The peer stays visible (greyed out) so users can still see who was nearby.
  Future<void> _onPeerLost(
    PeerLost event,
    Emitter<DiscoveryState> emit,
  ) async {
    final updatedPeers = state.peers.map((p) {
      if (p.peerId == event.peerId) {
        return p.copyWith(isOnline: false);
      }
      return p;
    }).toList();
    emit(state.copyWith(peers: updatedPeers));
  }

  /// Block a peer
  Future<void> _onBlockPeer(
    BlockPeer event,
    Emitter<DiscoveryState> emit,
  ) async {
    try {
      await _peerRepository.blockPeer(event.peerId);

      // Update local state
      final updatedPeers = state.peers.map((p) {
        if (p.peerId == event.peerId) {
          return p.copyWith(isBlocked: true);
        }
        return p;
      }).toList();

      emit(state.copyWith(peers: updatedPeers));
    } catch (e) {
      Logger.error('Failed to block peer', e, null, 'DiscoveryBloc');
      emit(state.copyWith(errorMessage: 'Failed to block user'));
    }
  }

  /// Unblock a peer
  Future<void> _onUnblockPeer(
    UnblockPeer event,
    Emitter<DiscoveryState> emit,
  ) async {
    try {
      await _peerRepository.unblockPeer(event.peerId);

      // Update local state
      final updatedPeers = state.peers.map((p) {
        if (p.peerId == event.peerId) {
          return p.copyWith(isBlocked: false);
        }
        return p;
      }).toList();

      emit(state.copyWith(peers: updatedPeers));
    } catch (e) {
      Logger.error('Failed to unblock peer', e, null, 'DiscoveryBloc');
      emit(state.copyWith(errorMessage: 'Failed to unblock user'));
    }
  }

  /// Refresh peers from database and trigger BLE scan
  Future<void> _onRefreshPeers(
    RefreshPeers event,
    Emitter<DiscoveryState> emit,
  ) async {
    // Trigger BLE scan to discover new peers
    try {
      await _transportManager.startScanning();
      emit(state.copyWith(isScanning: true));
    } catch (e) {
      Logger.warning(
          'Could not start scan during refresh: $e', 'DiscoveryBloc');
    }

    // Load existing peers from database
    try {
      final entries = await _peerRepository.getAllPeers(includeBlocked: false);
      final peers = entries.map(DiscoveredPeer.fromEntry).toList();

      emit(state.copyWith(
        status: DiscoveryStatus.loaded,
        peers: peers,
        lastRefreshed: DateTime.now(),
      ));
    } catch (e) {
      Logger.error('Failed to refresh peers', e, null, 'DiscoveryBloc');
      emit(state.copyWith(errorMessage: 'Failed to refresh'));
    }
  }

  /// Load mock data for testing UI
  Future<void> _onLoadMockPeers(
    LoadMockPeers event,
    Emitter<DiscoveryState> emit,
  ) async {
    emit(state.copyWith(status: DiscoveryStatus.loading));

    try {
      final mockPeers = _generateMockPeers();

      // Save mock peers to database
      for (final mock in mockPeers) {
        await _peerRepository.upsertPeer(
          peerId: mock.peerId,
          name: mock.name,
          age: mock.age,
          bio: mock.bio,
          thumbnailData: mock.thumbnailData,
          rssi: mock.rssi,
        );
      }

      // Reload from database
      final entries = await _peerRepository.getAllPeers(includeBlocked: false);
      final peers = entries.map(DiscoveredPeer.fromEntry).toList();

      emit(state.copyWith(
        status: DiscoveryStatus.loaded,
        peers: peers,
        lastRefreshed: DateTime.now(),
      ));
    } catch (e) {
      Logger.error('Failed to load mock peers', e, null, 'DiscoveryBloc');
      emit(state.copyWith(
        status: DiscoveryStatus.error,
        errorMessage: 'Failed to load mock data',
      ));
    }
  }

  /// Clear error
  void _onClearError(
    ClearDiscoveryError event,
    Emitter<DiscoveryState> emit,
  ) {
    emit(state.copyWith(errorMessage: null));
  }

  /// Fetch all full-size profile photos for a peer via fff4.
  /// Photos arrive asynchronously via [peerDiscoveredStream] → [_onPeerDiscovered].
  Future<void> _onFetchPeerFullPhotos(
    FetchPeerFullPhotos event,
    Emitter<DiscoveryState> emit,
  ) async {
    await _transportManager.fetchFullProfilePhotos(event.peerId);
  }

  /// User tapped the ⚓ button — send a drop anchor signal via BLE
  Future<void> _onDropAnchorOnPeer(
    DropAnchorOnPeer event,
    Emitter<DiscoveryState> emit,
  ) async {
    try {
      // Record locally and update UI immediately — BLE send is best-effort
      await _anchorDropRepository.recordDrop(
        peerId: event.peerId,
        peerName: event.peerName,
        direction: AnchorDropDirection.sent,
      );

      final updated = Set<String>.from(state.droppedAnchorPeerIds)
        ..add(event.peerId);
      emit(state.copyWith(droppedAnchorPeerIds: updated));

      // Best-effort send — peer may not be reachable right now
      _transportManager.sendDropAnchor(event.peerId);

      Logger.info('DiscoveryBloc: Anchor dropped on ${event.peerName}', 'Discovery');
    } catch (e) {
      Logger.error('DiscoveryBloc: Failed to drop anchor', e, null, 'Discovery');
    }
  }

  /// Received an anchor drop signal from a peer — record and notify
  Future<void> _onAnchorDropSignalReceived(
    AnchorDropSignalReceived event,
    Emitter<DiscoveryState> emit,
  ) async {
    try {
      // Resolve peer name from known peers
      final peer = state.peers
          .where((p) => p.peerId == event.fromPeerId)
          .firstOrNull;
      final peerName = peer?.name ?? 'Someone';

      // Discard if blocked
      if (peer?.isBlocked == true) return;

      // Record in database
      await _anchorDropRepository.recordDrop(
        peerId: event.fromPeerId,
        peerName: peerName,
        direction: AnchorDropDirection.received,
      );

      // Show system notification
      await _notificationService?.showAnchorDropNotification(
        fromPeerId: event.fromPeerId,
        fromName: peerName,
      );

      // Update state for in-app SnackBar
      emit(state.copyWith(incomingAnchorDropName: '$peerName \u2693'));

      // Clear after a moment so the same name can re-trigger
      Future.delayed(const Duration(seconds: 2), () {
        if (!isClosed) {
          add(_ClearAnchorDropNotification());
        }
      });

      Logger.info('DiscoveryBloc: Received anchor drop from $peerName', 'Discovery');
    } catch (e) {
      Logger.error('DiscoveryBloc: Failed to handle anchor drop', e, null, 'Discovery');
    }
  }

  /// Handle BLE MAC rotation: migrate DB records and remove stale peer from UI.
  Future<void> _onPeerIdChanged(
    PeerIdChangedEvent event,
    Emitter<DiscoveryState> emit,
  ) async {
    try {
      // 1. Migrate DB records (conversations, peers, blocks, anchor drops)
      await _peerRepository.migratePeerId(
        oldPeerId: event.oldPeerId,
        newPeerId: event.newPeerId,
        userId: event.userId,
      );

      // 2. Remove stale peer from in-memory list (new peerId arrives via
      //    the normal peerDiscovered stream shortly after)
      final updatedPeers =
          state.peers.where((p) => p.peerId != event.oldPeerId).toList();

      // 3. Migrate droppedAnchorPeerIds
      final updatedDropped = Set<String>.from(state.droppedAnchorPeerIds);
      if (updatedDropped.remove(event.oldPeerId)) {
        updatedDropped.add(event.newPeerId);
      }

      emit(state.copyWith(
        peers: updatedPeers,
        droppedAnchorPeerIds: updatedDropped,
      ));

      Logger.info(
        'DiscoveryBloc: Migrated peer ${event.oldPeerId} → ${event.newPeerId}',
        'Discovery',
      );
    } catch (e) {
      Logger.error(
          'DiscoveryBloc: Failed to migrate peer ID', e, null, 'Discovery');
    }
  }

  /// Debounce UI updates to batch rapid changes.
  /// Uses add() for the timer callback to avoid calling emit after the
  /// event handler has completed (which would throw an AssertionError).
  void _scheduleUpdate(
    Emitter<DiscoveryState> emit,
    DiscoveryState Function() stateBuilder,
  ) {
    // Emit immediately for the first update while the handler is still active
    if (state.status != DiscoveryStatus.loaded) {
      emit(stateBuilder());
      return;
    }

    _pendingUpdate = true;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      if (_pendingUpdate && !isClosed) {
        add(_ApplyDebouncedState(stateBuilder()));
        _pendingUpdate = false;
      }
    });
  }

  /// Generate mock peer data for testing
  List<DiscoveredPeer> _generateMockPeers() {
    const uuid = Uuid();
    final random = Random();
    final now = DateTime.now();

    final names = [
      'Alex',
      'Jordan',
      'Taylor',
      'Morgan',
      'Casey',
      'Riley',
      'Quinn',
      'Avery',
      'Sage',
      'Phoenix',
    ];

    final bios = [
      'Love hiking and outdoor adventures!',
      'Coffee enthusiast. Dog person.',
      'Traveling the world one city at a time.',
      'Foodie looking for restaurant buddies.',
      'Tech nerd by day, gamer by night.',
      'Artist and creative soul.',
      'Fitness junkie. Early bird.',
      null,
      'Music lover. Concert goer.',
      'Bookworm with a sense of humor.',
    ];

    return List.generate(10, (index) {
      // Vary last seen times for testing
      final minutesAgo = index < 3
          ? random.nextInt(1) // First 3: seen in last minute (recent)
          : index < 6
              ? random.nextInt(4) + 1 // Next 3: seen 1-5 mins ago (nearby)
              : random.nextInt(60) + 10; // Rest: older

      return DiscoveredPeer(
        peerId: uuid.v4(),
        name: names[index],
        age: 22 + random.nextInt(15),
        bio: bios[index],
        thumbnailData: null, // No mock images
        lastSeenAt: now.subtract(Duration(minutes: minutesAgo)),
        rssi: -45 - random.nextInt(35), // -45 to -80
        isBlocked: false,
      );
    });
  }

  // ── Local filter handlers ─────────────────────────────────────────────────

  void _onTogglePositionFilter(
    TogglePositionFilter event,
    Emitter<DiscoveryState> emit,
  ) {
    final updated = Set<int>.from(state.filterPositionIds);
    if (updated.contains(event.positionId)) {
      updated.remove(event.positionId);
    } else {
      updated.add(event.positionId);
    }
    emit(state.copyWith(filterPositionIds: updated));
  }

  void _onToggleInterestFilter(
    ToggleInterestFilter event,
    Emitter<DiscoveryState> emit,
  ) {
    final updated = Set<int>.from(state.filterInterestIds);
    if (updated.contains(event.interestId)) {
      updated.remove(event.interestId);
    } else {
      updated.add(event.interestId);
    }
    emit(state.copyWith(filterInterestIds: updated));
  }

  @override
  Future<void> close() {
    _debounceTimer?.cancel();
    _peerDiscoveredSubscription?.cancel();
    _peerLostSubscription?.cancel();
    _anchorDropSubscription?.cancel();
    _peerIdChangedSubscription?.cancel();
    return super.close();
  }
}
