import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import '../../../data/local_database/database.dart';

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
    this.age,
    this.bio,
    this.thumbnailData,
    this.photoThumbnails,
    required this.lastSeenAt,
    this.rssi,
    this.isBlocked = false,
    this.isRelayed = false,
    this.hopCount = 0,
    this.fullPhotoCount = 0,
  });

  final String peerId;
  final String name;
  final int? age;
  final String? bio;
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

  /// Factory from Drift entry
  factory DiscoveredPeer.fromEntry(DiscoveredPeerEntry entry) {
    return DiscoveredPeer(
      peerId: entry.peerId,
      name: entry.name,
      age: entry.age,
      bio: entry.bio,
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
    Uint8List? thumbnailData,
    List<Uint8List>? photoThumbnails,
    DateTime? lastSeenAt,
    int? rssi,
    bool? isBlocked,
    bool? isRelayed,
    int? hopCount,
    int? fullPhotoCount,
  }) {
    return DiscoveredPeer(
      peerId: peerId ?? this.peerId,
      name: name ?? this.name,
      age: age ?? this.age,
      bio: bio ?? this.bio,
      thumbnailData: thumbnailData ?? this.thumbnailData,
      photoThumbnails: photoThumbnails ?? this.photoThumbnails,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      rssi: rssi ?? this.rssi,
      isBlocked: isBlocked ?? this.isBlocked,
      isRelayed: isRelayed ?? this.isRelayed,
      hopCount: hopCount ?? this.hopCount,
      fullPhotoCount: fullPhotoCount ?? this.fullPhotoCount,
    );
  }

  @override
  List<Object?> get props => [
        peerId,
        name,
        age,
        bio,
        thumbnailData,
        photoThumbnails,
        lastSeenAt,
        rssi,
        isBlocked,
        isRelayed,
        hopCount,
        fullPhotoCount,
      ];
}

class DiscoveryState extends Equatable {
  const DiscoveryState({
    this.status = DiscoveryStatus.initial,
    this.peers = const [],
    this.errorMessage,
    this.lastRefreshed,
    this.isScanning = false,
  });

  final DiscoveryStatus status;
  final List<DiscoveredPeer> peers;
  final String? errorMessage;
  final DateTime? lastRefreshed;
  final bool isScanning;

  /// Visible peers (excluding blocked), sorted by last seen.
  /// Deduplicates by peerId in case a MAC rotation briefly produces two entries.
  List<DiscoveredPeer> get visiblePeers {
    final seen = <String>{};
    return peers
        .where((p) => !p.isBlocked && seen.add(p.peerId))
        .toList()
      ..sort((a, b) => b.lastSeenAt.compareTo(a.lastSeenAt));
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
  }) {
    return DiscoveryState(
      status: status ?? this.status,
      peers: peers ?? this.peers,
      errorMessage: errorMessage,
      lastRefreshed: lastRefreshed ?? this.lastRefreshed,
      isScanning: isScanning ?? this.isScanning,
    );
  }

  @override
  List<Object?> get props => [status, peers, errorMessage, lastRefreshed, isScanning];
}
