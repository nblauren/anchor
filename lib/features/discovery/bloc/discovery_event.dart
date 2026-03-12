import 'dart:typed_data';

import 'package:equatable/equatable.dart';

abstract class DiscoveryEvent extends Equatable {
  const DiscoveryEvent();

  @override
  List<Object?> get props => [];
}

/// Load discovered peers from local database
class LoadDiscoveredPeers extends DiscoveryEvent {
  const LoadDiscoveredPeers();
}

/// Start BLE discovery scanning
class StartDiscovery extends DiscoveryEvent {
  const StartDiscovery();
}

/// Stop BLE discovery scanning
class StopDiscovery extends DiscoveryEvent {
  const StopDiscovery();
}

/// A new peer was discovered via BLE (called by BLE service later)
class PeerDiscovered extends DiscoveryEvent {
  const PeerDiscovered({
    required this.peerId,
    required this.name,
    this.age,
    this.bio,
    this.position,
    this.interests,
    this.thumbnailData,
    this.photoThumbnails,
    this.rssi,
    this.isRelayed = false,
    this.hopCount = 0,
    this.fullPhotoCount = 0,
  });

  final String peerId;
  final String name;
  final int? age;
  final String? bio;
  /// Position ID from peer BLE profile characteristic. null = not shared.
  final int? position;
  /// Comma-separated interest IDs from peer BLE profile. null = not shared.
  final String? interests;
  final Uint8List? thumbnailData;
  final List<Uint8List>? photoThumbnails;
  final int? rssi;
  /// True when discovered via mesh relay rather than direct BLE.
  final bool isRelayed;
  /// Number of hops from origin (0 = direct).
  final int hopCount;
  /// Total number of profile photos available via fff4.
  final int fullPhotoCount;

  @override
  List<Object?> get props =>
      [peerId, name, age, bio, position, interests, thumbnailData, photoThumbnails, rssi, isRelayed, hopCount, fullPhotoCount];
}

/// Peer data updated (signal strength, new info)
class PeerUpdated extends DiscoveryEvent {
  const PeerUpdated({
    required this.peerId,
    this.name,
    this.age,
    this.bio,
    this.thumbnailData,
    this.rssi,
  });

  final String peerId;
  final String? name;
  final int? age;
  final String? bio;
  final Uint8List? thumbnailData;
  final int? rssi;

  @override
  List<Object?> get props => [peerId, name, age, bio, thumbnailData, rssi];
}

/// A peer hasn't been seen for a while
class PeerLost extends DiscoveryEvent {
  const PeerLost(this.peerId);
  final String peerId;

  @override
  List<Object?> get props => [peerId];
}

/// Block a peer
class BlockPeer extends DiscoveryEvent {
  const BlockPeer(this.peerId);
  final String peerId;

  @override
  List<Object?> get props => [peerId];
}

/// Unblock a peer
class UnblockPeer extends DiscoveryEvent {
  const UnblockPeer(this.peerId);
  final String peerId;

  @override
  List<Object?> get props => [peerId];
}

/// Refresh peers list (pull to refresh)
class RefreshPeers extends DiscoveryEvent {
  const RefreshPeers();
}

/// Load mock data for testing
class LoadMockPeers extends DiscoveryEvent {
  const LoadMockPeers();
}

/// Clear error state
class ClearDiscoveryError extends DiscoveryEvent {
  const ClearDiscoveryError();
}

/// Fetch all full-size profile photos for a peer via fff4 (direct range only).
/// Photos arrive asynchronously — the state updates when they land.
class FetchPeerFullPhotos extends DiscoveryEvent {
  const FetchPeerFullPhotos(this.peerId);
  final String peerId;

  @override
  List<Object?> get props => [peerId];
}

/// User tapped the ⚓ button to drop anchor on a peer
class DropAnchorOnPeer extends DiscoveryEvent {
  const DropAnchorOnPeer({required this.peerId, required this.peerName});
  final String peerId;
  final String peerName;

  @override
  List<Object?> get props => [peerId, peerName];
}

/// A peer dropped anchor on us (received via BLE)
class AnchorDropSignalReceived extends DiscoveryEvent {
  const AnchorDropSignalReceived({required this.fromPeerId});
  final String fromPeerId;

  @override
  List<Object?> get props => [fromPeerId];
}

/// Toggle a position ID in the local-only multi-select position filter.
class TogglePositionFilter extends DiscoveryEvent {
  const TogglePositionFilter(this.positionId);
  final int positionId;

  @override
  List<Object?> get props => [positionId];
}

/// Toggle an interest ID in the local-only multi-select interest filter.
class ToggleInterestFilter extends DiscoveryEvent {
  const ToggleInterestFilter(this.interestId);
  final int interestId;

  @override
  List<Object?> get props => [interestId];
}

/// Clear all active discovery filters.
class ClearFilters extends DiscoveryEvent {
  const ClearFilters();
}

