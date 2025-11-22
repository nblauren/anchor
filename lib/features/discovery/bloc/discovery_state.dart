import 'package:equatable/equatable.dart';

import '../../../data/models/discovered_user.dart';
import '../../../data/models/user_profile.dart';

enum DiscoveryStatus {
  initial,
  loading,
  scanning,
  idle,
  error,
}

class DiscoveryState extends Equatable {
  const DiscoveryState({
    this.status = DiscoveryStatus.initial,
    this.discoveredUsers = const [],
    this.selectedUser,
    this.errorMessage,
    this.isBluetoothAvailable = false,
  });

  final DiscoveryStatus status;
  final List<DiscoveredUser> discoveredUsers;
  final UserProfile? selectedUser;
  final String? errorMessage;
  final bool isBluetoothAvailable;

  /// Users currently nearby (within last 5 minutes)
  List<DiscoveredUser> get nearbyUsers {
    final fiveMinutesAgo = DateTime.now().subtract(const Duration(minutes: 5));
    return discoveredUsers
        .where((u) => u.discoveredAt.isAfter(fiveMinutesAgo) && u.isNearby)
        .toList();
  }

  /// All users ever discovered
  int get totalDiscovered => discoveredUsers.length;

  DiscoveryState copyWith({
    DiscoveryStatus? status,
    List<DiscoveredUser>? discoveredUsers,
    UserProfile? selectedUser,
    String? errorMessage,
    bool? isBluetoothAvailable,
  }) {
    return DiscoveryState(
      status: status ?? this.status,
      discoveredUsers: discoveredUsers ?? this.discoveredUsers,
      selectedUser: selectedUser,
      errorMessage: errorMessage,
      isBluetoothAvailable: isBluetoothAvailable ?? this.isBluetoothAvailable,
    );
  }

  @override
  List<Object?> get props => [
        status,
        discoveredUsers,
        selectedUser,
        errorMessage,
        isBluetoothAvailable,
      ];
}
