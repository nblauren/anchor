import 'package:equatable/equatable.dart';

import '../../../data/models/discovered_user.dart';

abstract class DiscoveryEvent extends Equatable {
  const DiscoveryEvent();

  @override
  List<Object?> get props => [];
}

/// Start scanning for nearby users
class StartDiscovery extends DiscoveryEvent {
  const StartDiscovery();
}

/// Stop scanning
class StopDiscovery extends DiscoveryEvent {
  const StopDiscovery();
}

/// A new user was discovered nearby
class UserDiscovered extends DiscoveryEvent {
  const UserDiscovered(this.user);
  final DiscoveredUser user;

  @override
  List<Object?> get props => [user];
}

/// A user is no longer nearby
class UserLost extends DiscoveryEvent {
  const UserLost(this.userId);
  final String userId;

  @override
  List<Object?> get props => [userId];
}

/// Refresh discovered users from local storage
class RefreshDiscoveredUsers extends DiscoveryEvent {
  const RefreshDiscoveredUsers();
}

/// View a discovered user's profile
class ViewUserProfile extends DiscoveryEvent {
  const ViewUserProfile(this.userId);
  final String userId;

  @override
  List<Object?> get props => [userId];
}

/// Clear all discovered users
class ClearDiscoveredUsers extends DiscoveryEvent {
  const ClearDiscoveredUsers();
}
