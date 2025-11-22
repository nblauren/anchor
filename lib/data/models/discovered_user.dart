import 'package:equatable/equatable.dart';

import 'user_profile.dart';

/// Represents a user discovered via BLE mesh network
class DiscoveredUser extends Equatable {
  const DiscoveredUser({
    required this.profile,
    required this.discoveredAt,
    this.signalStrength,
    this.distance,
    this.isNearby = true,
  });

  final UserProfile profile;
  final DateTime discoveredAt;
  final int? signalStrength; // RSSI value
  final double? distance; // Estimated distance in meters
  final bool isNearby;

  DiscoveredUser copyWith({
    UserProfile? profile,
    DateTime? discoveredAt,
    int? signalStrength,
    double? distance,
    bool? isNearby,
  }) {
    return DiscoveredUser(
      profile: profile ?? this.profile,
      discoveredAt: discoveredAt ?? this.discoveredAt,
      signalStrength: signalStrength ?? this.signalStrength,
      distance: distance ?? this.distance,
      isNearby: isNearby ?? this.isNearby,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'profile': profile.toJson(),
      'discoveredAt': discoveredAt.toIso8601String(),
      'signalStrength': signalStrength,
      'distance': distance,
      'isNearby': isNearby,
    };
  }

  factory DiscoveredUser.fromJson(Map<String, dynamic> json) {
    return DiscoveredUser(
      profile: UserProfile.fromJson(json['profile'] as Map<String, dynamic>),
      discoveredAt: DateTime.parse(json['discoveredAt'] as String),
      signalStrength: json['signalStrength'] as int?,
      distance: json['distance'] as double?,
      isNearby: json['isNearby'] as bool? ?? true,
    );
  }

  @override
  List<Object?> get props => [
        profile,
        discoveredAt,
        signalStrength,
        distance,
        isNearby,
      ];
}
