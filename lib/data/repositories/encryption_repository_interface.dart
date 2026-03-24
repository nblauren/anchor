import 'package:anchor/data/local_database/database.dart';

/// Data transfer object for persisted noise session entries.
///
/// Used to decouple the repository interface from the Drift-generated
/// [PersistedNoiseSession] class so that consumers don't depend on Drift.
class PersistedNoiseSessionEntry {
  const PersistedNoiseSessionEntry({
    required this.peerId,
    required this.sendKeyHex,
    required this.receiveKeyHex,
    required this.establishedAt,
    required this.messageCount,
  });

  final String peerId;
  final String sendKeyHex;
  final String receiveKeyHex;
  final DateTime establishedAt;
  final int messageCount;
}

/// Abstract interface for encryption-related database operations.
///
/// The [EncryptionService] should depend on this interface rather than
/// accessing the database directly, enabling easier testing and separation
/// of concerns.
abstract class EncryptionRepositoryInterface {
  /// Delete all persisted Noise sessions.
  Future<void> deleteAllSessions();

  /// Update a peer's Ed25519 signing public key.
  Future<void> updatePeerEd25519Key(
    String peerId,
    String ed25519PublicKeyHex,
  );

  /// Check whether a peer row exists in the database.
  Future<bool> peerExists(String peerId);

  /// Ensure a peer row exists in the database, inserting a placeholder if not.
  Future<void> ensurePeerExists(String peerId);

  /// Store a peer's X25519 public key (and optionally Ed25519 key).
  Future<void> storePeerPublicKeys(
    String peerId, {
    required String publicKeyHex,
    String? ed25519PublicKeyHex,
  });

  /// Get a peer's stored X25519 public key (hex), or null if not found.
  Future<String?> getPeerPublicKey(String peerId);

  /// Get a peer's stored Ed25519 signing public key (hex), or null if not found.
  Future<String?> getPeerEd25519Key(String peerId);

  /// Persist an E2EE session to the database (upsert by peerId).
  Future<void> persistSession(
    String peerId, {
    required String sendKeyHex,
    required String receiveKeyHex,
    required DateTime establishedAt,
    int messageCount = 0,
  });

  /// Load all persisted sessions from the database.
  Future<List<PersistedNoiseSessionEntry>> loadAllSessions();

  /// Delete a single persisted session by peer ID.
  Future<void> deleteSession(String peerId);

  /// Delete all sessions (used by panic mode).
  Future<void> deleteAllSessionsForPanic();
}
