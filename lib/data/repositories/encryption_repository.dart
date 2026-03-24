import 'package:anchor/data/local_database/database.dart';
import 'package:anchor/data/repositories/encryption_repository_interface.dart';
import 'package:drift/drift.dart';

/// Concrete implementation of [EncryptionRepositoryInterface] backed by Drift.
///
/// Wraps all database operations that [EncryptionService] needs so that the
/// service itself never touches the database directly.
class EncryptionRepository implements EncryptionRepositoryInterface {
  EncryptionRepository(this._db);

  final AppDatabase _db;

  @override
  Future<void> deleteAllSessions() async {
    await _db.delete(_db.noiseSessions).go();
  }

  @override
  Future<void> updatePeerEd25519Key(
    String peerId,
    String ed25519PublicKeyHex,
  ) async {
    await (_db.update(_db.discoveredPeers)
          ..where((t) => t.peerId.equals(peerId)))
        .write(DiscoveredPeersCompanion(
      ed25519PublicKeyHex: Value(ed25519PublicKeyHex),
    ),);
  }

  @override
  Future<bool> peerExists(String peerId) async {
    final row = await (_db.select(_db.discoveredPeers)
          ..where((t) => t.peerId.equals(peerId)))
        .getSingleOrNull();
    return row != null;
  }

  @override
  Future<void> ensurePeerExists(String peerId) async {
    final exists = await peerExists(peerId);
    if (!exists) {
      await _db.into(_db.discoveredPeers).insert(
            DiscoveredPeersCompanion.insert(
              peerId: peerId,
              name: 'Unknown',
              lastSeenAt: DateTime.now(),
            ),
            mode: InsertMode.insertOrIgnore,
          );
    }
  }

  @override
  Future<void> storePeerPublicKeys(
    String peerId, {
    required String publicKeyHex,
    String? ed25519PublicKeyHex,
  }) async {
    await (_db.update(_db.discoveredPeers)
          ..where((t) => t.peerId.equals(peerId)))
        .write(DiscoveredPeersCompanion(
      publicKeyHex: Value(publicKeyHex),
      ed25519PublicKeyHex: Value(ed25519PublicKeyHex),
    ),);
  }

  @override
  Future<String?> getPeerPublicKey(String peerId) async {
    final row = await (_db.select(_db.discoveredPeers)
          ..where((t) => t.peerId.equals(peerId)))
        .getSingleOrNull();
    return row?.publicKeyHex;
  }

  @override
  Future<String?> getPeerEd25519Key(String peerId) async {
    final row = await (_db.select(_db.discoveredPeers)
          ..where((t) => t.peerId.equals(peerId)))
        .getSingleOrNull();
    return row?.ed25519PublicKeyHex;
  }

  @override
  Future<void> persistSession(
    String peerId, {
    required String sendKeyHex,
    required String receiveKeyHex,
    required DateTime establishedAt,
    int messageCount = 0,
  }) async {
    await _db.into(_db.noiseSessions).insertOnConflictUpdate(
          NoiseSessionsCompanion.insert(
            peerId: peerId,
            sendKeyHex: sendKeyHex,
            receiveKeyHex: receiveKeyHex,
            establishedAt: establishedAt,
            messageCount: Value(messageCount),
          ),
        );
  }

  @override
  Future<List<PersistedNoiseSessionEntry>> loadAllSessions() async {
    final rows = await _db.select(_db.noiseSessions).get();
    return rows
        .map((row) => PersistedNoiseSessionEntry(
              peerId: row.peerId,
              sendKeyHex: row.sendKeyHex,
              receiveKeyHex: row.receiveKeyHex,
              establishedAt: row.establishedAt,
              messageCount: row.messageCount,
            ),)
        .toList();
  }

  @override
  Future<void> deleteSession(String peerId) async {
    await (_db.delete(_db.noiseSessions)
          ..where((t) => t.peerId.equals(peerId)))
        .go();
  }

  @override
  Future<void> deleteAllSessionsForPanic() async {
    await _db.delete(_db.noiseSessions).go();
  }
}
