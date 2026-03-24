import 'dart:typed_data';

import 'package:anchor/core/constants/profile_constants.dart';
import 'package:anchor/data/local_database/database.dart';
import 'package:anchor/services/transport/transport_enums.dart';
import 'package:equatable/equatable.dart';

enum DiscoveryStatus {
  initial,
  loading,
  loaded,
  error,
}

/// Wrapper for discovered peer with computed properties
class DiscoveredPeer extends Equatable {
  const DiscoveredPeer({
    required this.peerId,
    required this.name,
    required this.lastSeenAt, this.age,
    this.bio,
    this.position,
    this.interests,
    this.thumbnailData,
    this.photoThumbnails,
    this.rssi,
    this.isBlocked = false,
    this.isRelayed = false,
    this.hopCount = 0,
    this.fullPhotoCount = 0,
    this.isOnline = true,
  });

  final String peerId;
  final String name;
  final int? age;
  final String? bio;
  /// Position preference ID from peer's BLE profile. null = not shared.
  final int? position;
  /// Comma-separated interest IDs from peer's BLE profile. null = not shared.
  final String? interests;
  final Uint8List? thumbnailData;
  /// All profile photo thumbnails in display order (up to 4). In-memory only — not persisted to DB.
  final List<Uint8List>? photoThumbnails;
  final DateTime lastSeenAt;
  final int? rssi;
  final bool isBlocked;
  /// True when this peer was discovered via mesh relay, not direct BLE scan.
  final bool isRelayed;
  /// Number of relay hops from origin (0 = direct).
  final int hopCount;
  /// Total number of profile photos available from this peer via fff4.
  /// 0 = unknown, 1 = primary only, >1 = extra photos available on-demand.
  final int fullPhotoCount;
  /// Whether the peer is currently reachable via BLE. When false the tile is
  /// shown greyed-out in the Discovery grid instead of being removed.
  final bool isOnline;

  /// Decoded position label, or null when not shared.
  String? get positionLabel => ProfileConstants.positionLabel(position);

  /// Decoded interest labels from comma-separated ID string.
  List<String> get interestLabels => ProfileConstants.decodeInterests(interests);

  /// Parsed interest IDs list.
  List<int> get interestIds => ProfileConstants.parseInterests(interests);

  /// Factory from Drift entry
  factory DiscoveredPeer.fromEntry(DiscoveredPeerEntry entry) {
    return DiscoveredPeer(
      peerId: entry.peerId,
      name: entry.name,
      age: entry.age,
      bio: entry.bio,
      position: entry.position,
      interests: entry.interests,
      thumbnailData: entry.thumbnailData,
      lastSeenAt: entry.lastSeenAt,
      rssi: entry.rssi,
      isBlocked: entry.isBlocked,
    );
  }

  /// Whether peer was seen in last 60 seconds
  bool get isRecent {
    return DateTime.now().difference(lastSeenAt).inSeconds <= 60;
  }

  /// Whether peer was seen in last 5 minutes
  bool get isNearby {
    return DateTime.now().difference(lastSeenAt).inMinutes <= 5;
  }

  /// Human-readable last seen text
  String get lastSeenText {
    final diff = DateTime.now().difference(lastSeenAt);
    if (diff.inSeconds < 60) {
      return 'Just now';
    } else if (diff.inMinutes < 60) {
      final mins = diff.inMinutes;
      return '$mins ${mins == 1 ? 'min' : 'mins'} ago';
    } else if (diff.inHours < 24) {
      final hours = diff.inHours;
      return '$hours ${hours == 1 ? 'hour' : 'hours'} ago';
    } else {
      final days = diff.inDays;
      return '$days ${days == 1 ? 'day' : 'days'} ago';
    }
  }

  /// Signal strength description
  String? get signalStrengthText {
    if (rssi == null) return null;
    if (rssi! >= -50) return 'Excellent';
    if (rssi! >= -60) return 'Good';
    if (rssi! >= -70) return 'Fair';
    return 'Weak';
  }

  DiscoveredPeer copyWith({
    String? peerId,
    String? name,
    int? age,
    String? bio,
    Object? position = _peerSentinel,
    Object? interests = _peerSentinel,
    Uint8List? thumbnailData,
    List<Uint8List>? photoThumbnails,
    DateTime? lastSeenAt,
    int? rssi,
    bool? isBlocked,
    bool? isRelayed,
    int? hopCount,
    int? fullPhotoCount,
    bool? isOnline,
  }) {
    return DiscoveredPeer(
      peerId: peerId ?? this.peerId,
      name: name ?? this.name,
      age: age ?? this.age,
      bio: bio ?? this.bio,
      position: position == _peerSentinel ? this.position : position as int?,
      interests: interests == _peerSentinel ? this.interests : interests as String?,
      thumbnailData: thumbnailData ?? this.thumbnailData,
      photoThumbnails: photoThumbnails ?? this.photoThumbnails,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      rssi: rssi ?? this.rssi,
      isBlocked: isBlocked ?? this.isBlocked,
      isRelayed: isRelayed ?? this.isRelayed,
      hopCount: hopCount ?? this.hopCount,
      fullPhotoCount: fullPhotoCount ?? this.fullPhotoCount,
      isOnline: isOnline ?? this.isOnline,
    );
  }

  @override
  List<Object?> get props => [
        peerId,
        name,
        age,
        bio,
        position,
        interests,
        thumbnailData,
        photoThumbnails,
        lastSeenAt,
        rssi,
        isBlocked,
        isRelayed,
        hopCount,
        fullPhotoCount,
        isOnline,
      ];
}

const _peerSentinel = Object();

class DiscoveryState extends Equatable {
  const DiscoveryState({
    this.status = DiscoveryStatus.initial,
    this.peers = const [],
    this.errorMessage,
    this.lastRefreshed,
    this.isScanning = false,
    this.activeTransport = TransportType.ble,
  });

  final DiscoveryStatus status;
  final List<DiscoveredPeer> peers;
  final String? errorMessage;
  final DateTime? lastRefreshed;
  final bool isScanning;
  /// Which transport layer is currently active.
  final TransportType activeTransport;

  /// Visible peers (excluding blocked), sorted by recency: recent first,
  /// then nearby (seen within 5 min), then stale.
  /// Deduplicates by peerId (= canonical userId) for safety.
  /// Insertion order is preserved within each group so RSSI fluctuations
  /// do not cause tiles to shuffle. New peers are prepended by the bloc,
  /// so recently discovered peers naturally appear first.
  List<DiscoveredPeer> get visiblePeers {
    final seen = <String>{};
    final filtered = peers
        .where((p) => !p.isBlocked && seen.add(p.peerId))
        .toList();

    // Partition into online and offline first
    final online = filtered.where((p) => p.isOnline).toList();
    final offline = filtered.where((p) => !p.isOnline).toList();

    // Within each group, sort by recency tiers
    List<DiscoveredPeer> sortByRecency(List<DiscoveredPeer> list) {
      final recent = list.where((p) => p.isRecent).toList();
      final nearby = list.where((p) => !p.isRecent && p.isNearby).toList();
      final stale = list.where((p) => !p.isNearby).toList();
      return [...recent, ...nearby, ...stale];
    }

    return [...sortByRecency(online), ...sortByRecency(offline)];
  }

  /// Peers seen recently (within last 60 seconds)
  List<DiscoveredPeer> get recentPeers {
    return visiblePeers.where((p) => p.isRecent).toList();
  }

  /// Peers seen in last 5 minutes
  List<DiscoveredPeer> get nearbyPeers {
    return visiblePeers.where((p) => p.isNearby).toList();
  }

  /// Count of visible peers
  int get peerCount => visiblePeers.length;

  /// Has any peers to display
  bool get hasPeers => visiblePeers.isNotEmpty;

  DiscoveryState copyWith({
    DiscoveryStatus? status,
    List<DiscoveredPeer>? peers,
    String? errorMessage,
    DateTime? lastRefreshed,
    bool? isScanning,
    TransportType? activeTransport,
  }) {
    return DiscoveryState(
      status: status ?? this.status,
      peers: peers ?? this.peers,
      errorMessage: errorMessage,
      lastRefreshed: lastRefreshed ?? this.lastRefreshed,
      isScanning: isScanning ?? this.isScanning,
      activeTransport: activeTransport ?? this.activeTransport,
    );
  }

  @override
  List<Object?> get props => [
        status,
        peers,
        errorMessage,
        lastRefreshed,
        isScanning,
        activeTransport,
      ];
}
