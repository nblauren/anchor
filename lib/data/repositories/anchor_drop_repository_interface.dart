import 'package:anchor/data/local_database/database.dart';

/// Abstract interface for [AnchorDropRepository].
///
/// Consumers should depend on this interface rather than the concrete
/// implementation so that repositories can be easily swapped for testing
/// or alternative storage backends.
abstract class AnchorDropRepositoryInterface {
  Future<void> recordDrop({
    required String peerId,
    required String peerName,
    required AnchorDropDirection direction,
    AnchorDropStatus status = AnchorDropStatus.delivered,
  });

  Future<void> markDelivered(String dropId);

  Future<List<AnchorDropEntry>> getPendingDropsForPeer(
    String peerId, {
    int hours = 24,
  });

  Future<void> expireStalePendingDrops({int hours = 24});

  Future<bool> hasDroppedToPeerToday(String peerId);

  Future<int> getTodaySentCount();

  Future<List<AnchorDropEntry>> getRecentDrops({int limit = 50});

  Future<Set<String>> getSentPeerIdsSince({int hours = 24});

  Future<List<AnchorDropEntry>> getReceivedDrops({int limit = 50});
}
