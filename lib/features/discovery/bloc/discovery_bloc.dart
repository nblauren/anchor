import 'dart:async';
import 'dart:math';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../core/utils/logger.dart';
import '../../../data/repositories/peer_repository.dart';
import 'discovery_event.dart';
import 'discovery_state.dart';

class DiscoveryBloc extends Bloc<DiscoveryEvent, DiscoveryState> {
  DiscoveryBloc({
    required PeerRepository peerRepository,
  })  : _peerRepository = peerRepository,
        super(const DiscoveryState()) {
    on<LoadDiscoveredPeers>(_onLoadDiscoveredPeers);
    on<PeerDiscovered>(_onPeerDiscovered);
    on<PeerUpdated>(_onPeerUpdated);
    on<PeerLost>(_onPeerLost);
    on<BlockPeer>(_onBlockPeer);
    on<UnblockPeer>(_onUnblockPeer);
    on<RefreshPeers>(_onRefreshPeers);
    on<LoadMockPeers>(_onLoadMockPeers);
    on<ClearDiscoveryError>(_onClearError);

    // Debounce timer for batching peer updates
    _debounceTimer?.cancel();
  }

  final PeerRepository _peerRepository;
  Timer? _debounceTimer;
  bool _pendingUpdate = false;

  /// Load peers from database
  Future<void> _onLoadDiscoveredPeers(
    LoadDiscoveredPeers event,
    Emitter<DiscoveryState> emit,
  ) async {
    emit(state.copyWith(status: DiscoveryStatus.loading));

    try {
      final entries = await _peerRepository.getAllPeers(includeBlocked: false);
      final peers = entries.map(DiscoveredPeer.fromEntry).toList();

      emit(state.copyWith(
        status: DiscoveryStatus.loaded,
        peers: peers,
        lastRefreshed: DateTime.now(),
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
      // Save to database
      final entry = await _peerRepository.upsertPeer(
        peerId: event.peerId,
        name: event.name,
        age: event.age,
        bio: event.bio,
        thumbnailData: event.thumbnailData,
        rssi: event.rssi,
      );

      final peer = DiscoveredPeer.fromEntry(entry);

      // Update state with debouncing
      _scheduleUpdate(emit, () {
        final existingIndex = state.peers.indexWhere((p) => p.peerId == event.peerId);
        List<DiscoveredPeer> updatedPeers;

        if (existingIndex >= 0) {
          updatedPeers = [...state.peers];
          updatedPeers[existingIndex] = peer;
        } else {
          updatedPeers = [peer, ...state.peers];
        }

        return state.copyWith(
          status: DiscoveryStatus.loaded,
          peers: updatedPeers,
        );
      });
    } catch (e) {
      Logger.error('Failed to process discovered peer', e, null, 'DiscoveryBloc');
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

  /// Handle peer lost (not seen for a while)
  Future<void> _onPeerLost(
    PeerLost event,
    Emitter<DiscoveryState> emit,
  ) async {
    // Just update UI indicator - peer stays in database
    final updatedPeers = state.peers.map((p) {
      if (p.peerId == event.peerId) {
        // Mark as not recently seen by keeping the old lastSeenAt
        return p;
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

  /// Refresh peers from database
  Future<void> _onRefreshPeers(
    RefreshPeers event,
    Emitter<DiscoveryState> emit,
  ) async {
    // Don't show loading indicator for refresh
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

  /// Debounce UI updates to batch rapid changes
  void _scheduleUpdate(
    Emitter<DiscoveryState> emit,
    DiscoveryState Function() stateBuilder,
  ) {
    _pendingUpdate = true;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      if (_pendingUpdate) {
        emit(stateBuilder());
        _pendingUpdate = false;
      }
    });

    // Also emit immediately for first update
    if (state.status != DiscoveryStatus.loaded) {
      emit(stateBuilder());
    }
  }

  /// Generate mock peer data for testing
  List<DiscoveredPeer> _generateMockPeers() {
    final uuid = const Uuid();
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

  @override
  Future<void> close() {
    _debounceTimer?.cancel();
    return super.close();
  }
}
