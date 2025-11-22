import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/utils/logger.dart';
import '../../../data/models/discovered_user.dart';
import '../../../data/models/user_profile.dart';
import '../../../services/ble_service.dart';
import '../../../services/database_service.dart';
import 'discovery_event.dart';
import 'discovery_state.dart';

class DiscoveryBloc extends Bloc<DiscoveryEvent, DiscoveryState> {
  DiscoveryBloc({
    required BleService bleService,
    required DatabaseService databaseService,
  })  : _bleService = bleService,
        _databaseService = databaseService,
        super(const DiscoveryState()) {
    on<StartDiscovery>(_onStartDiscovery);
    on<StopDiscovery>(_onStopDiscovery);
    on<UserDiscovered>(_onUserDiscovered);
    on<UserLost>(_onUserLost);
    on<RefreshDiscoveredUsers>(_onRefreshDiscoveredUsers);
    on<ViewUserProfile>(_onViewUserProfile);
    on<ClearDiscoveredUsers>(_onClearDiscoveredUsers);

    _setupBleListeners();
  }

  final BleService _bleService;
  final DatabaseService _databaseService;
  StreamSubscription? _discoveredUsersSubscription;

  void _setupBleListeners() {
    _discoveredUsersSubscription = _bleService.discoveredUsers.listen(
      (profile) {
        final discoveredUser = DiscoveredUser(
          profile: profile,
          discoveredAt: DateTime.now(),
        );
        add(UserDiscovered(discoveredUser));
      },
    );
  }

  Future<void> _onStartDiscovery(
    StartDiscovery event,
    Emitter<DiscoveryState> emit,
  ) async {
    emit(state.copyWith(status: DiscoveryStatus.loading));

    try {
      // Check Bluetooth availability
      final isAvailable = await _bleService.isBluetoothAvailable();
      if (!isAvailable) {
        emit(state.copyWith(
          status: DiscoveryStatus.error,
          errorMessage: 'Bluetooth is not available',
          isBluetoothAvailable: false,
        ));
        return;
      }

      // Load previously discovered users from database
      final savedProfiles =
          await _databaseService.profileRepository.getAllDiscoveredProfiles();
      final discoveredUsers = savedProfiles.map((profile) {
        return DiscoveredUser(
          profile: profile,
          discoveredAt: profile.lastSeenAt ?? profile.updatedAt,
          isNearby: false,
        );
      }).toList();

      emit(state.copyWith(
        isBluetoothAvailable: true,
        discoveredUsers: discoveredUsers,
      ));

      // Start BLE scanning
      await _bleService.startScanning();
      emit(state.copyWith(status: DiscoveryStatus.scanning));
    } catch (e) {
      Logger.error('Failed to start discovery', e, null, 'DiscoveryBloc');
      emit(state.copyWith(
        status: DiscoveryStatus.error,
        errorMessage: 'Failed to start discovery',
      ));
    }
  }

  Future<void> _onStopDiscovery(
    StopDiscovery event,
    Emitter<DiscoveryState> emit,
  ) async {
    try {
      await _bleService.stopScanning();
      emit(state.copyWith(status: DiscoveryStatus.idle));
    } catch (e) {
      Logger.error('Failed to stop discovery', e, null, 'DiscoveryBloc');
    }
  }

  Future<void> _onUserDiscovered(
    UserDiscovered event,
    Emitter<DiscoveryState> emit,
  ) async {
    try {
      // Save to database
      await _databaseService.profileRepository.saveDiscoveredProfile(
        event.user.profile.copyWith(
          lastSeenAt: event.user.discoveredAt,
        ),
      );

      // Update state
      final existingIndex = state.discoveredUsers
          .indexWhere((u) => u.profile.id == event.user.profile.id);

      List<DiscoveredUser> updatedUsers;
      if (existingIndex >= 0) {
        updatedUsers = [...state.discoveredUsers];
        updatedUsers[existingIndex] = event.user;
      } else {
        updatedUsers = [event.user, ...state.discoveredUsers];
      }

      emit(state.copyWith(discoveredUsers: updatedUsers));
    } catch (e) {
      Logger.error('Failed to process discovered user', e, null, 'DiscoveryBloc');
    }
  }

  Future<void> _onUserLost(
    UserLost event,
    Emitter<DiscoveryState> emit,
  ) async {
    final updatedUsers = state.discoveredUsers.map((user) {
      if (user.profile.id == event.userId) {
        return user.copyWith(isNearby: false);
      }
      return user;
    }).toList();

    emit(state.copyWith(discoveredUsers: updatedUsers));
  }

  Future<void> _onRefreshDiscoveredUsers(
    RefreshDiscoveredUsers event,
    Emitter<DiscoveryState> emit,
  ) async {
    emit(state.copyWith(status: DiscoveryStatus.loading));

    try {
      final savedProfiles =
          await _databaseService.profileRepository.getAllDiscoveredProfiles();
      final discoveredUsers = savedProfiles.map((profile) {
        return DiscoveredUser(
          profile: profile,
          discoveredAt: profile.lastSeenAt ?? profile.updatedAt,
          isNearby: false,
        );
      }).toList();

      emit(state.copyWith(
        status: DiscoveryStatus.idle,
        discoveredUsers: discoveredUsers,
      ));
    } catch (e) {
      Logger.error('Failed to refresh discovered users', e, null, 'DiscoveryBloc');
      emit(state.copyWith(
        status: DiscoveryStatus.error,
        errorMessage: 'Failed to load users',
      ));
    }
  }

  Future<void> _onViewUserProfile(
    ViewUserProfile event,
    Emitter<DiscoveryState> emit,
  ) async {
    try {
      final profile =
          await _databaseService.profileRepository.getProfileById(event.userId);
      emit(state.copyWith(selectedUser: profile));
    } catch (e) {
      Logger.error('Failed to load user profile', e, null, 'DiscoveryBloc');
    }
  }

  Future<void> _onClearDiscoveredUsers(
    ClearDiscoveredUsers event,
    Emitter<DiscoveryState> emit,
  ) async {
    emit(state.copyWith(discoveredUsers: []));
  }

  @override
  Future<void> close() {
    _discoveredUsersSubscription?.cancel();
    return super.close();
  }
}
