import 'dart:typed_data';

import 'package:anchor/data/local_database/database.dart';

/// Abstract interface for [PeerRepository].
///
/// Consumers should depend on this interface rather than the concrete
/// implementation so that repositories can be easily swapped for testing
/// or alternative storage backends.
abstract class PeerRepositoryInterface {
  // ==================== Peer CRUD ====================

  Future<List<DiscoveredPeerEntry>> getAllPeers({bool includeBlocked = false});

  Future<DiscoveredPeerEntry?> getPeerById(String peerId);

  Future<List<DiscoveredPeerEntry>> getRecentPeers(Duration window);

  Future<DiscoveredPeerEntry> upsertPeer({
    required String peerId,
    required String name,
    int? age,
    String? bio,
    int? position,
    String? interests,
    Uint8List? thumbnailData,
    int? rssi,
    String? publicKeyHex,
    String? transportId,
    String? transportType,
  });

  Future<void> updatePeerPresence(String peerId, {int? rssi});

  Future<void> deletePeer(String peerId);

  Stream<List<DiscoveredPeerEntry>> watchPeers({bool includeBlocked = false});

  // ==================== Blocking Logic ====================

  Future<void> blockPeer(String peerId);

  Future<void> unblockPeer(String peerId);

  Future<bool> isPeerBlocked(String peerId);

  Future<List<BlockedUserEntry>> getBlockedPeers();

  Future<List<DiscoveredPeerEntry>> getBlockedPeerDetails();

  Stream<List<BlockedUserEntry>> watchBlockedPeers();

  // ==================== Utility Methods ====================

  Future<int> getPeerCount({bool includeBlocked = false});

  Future<int> clearOldPeers(Duration olderThan);

  Future<List<DiscoveredPeerEntry>> searchPeers(String query);

  // ==================== Peer Aliases ====================

  Future<String?> resolveAlias(String transportId);

  Future<void> registerAlias(
    String transportId,
    String canonicalPeerId,
    String transportType,
  );

  Future<List<PeerAliasEntry>> getAllAliases();

  Future<void> deleteAliasesForPeer(String canonicalPeerId);
}
