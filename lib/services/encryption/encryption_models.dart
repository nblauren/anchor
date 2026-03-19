import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Encryption Models
//
// Data classes for Noise_XK session management, handshake coordination, and
// encrypted wire payloads.  All are immutable value types.
// ---------------------------------------------------------------------------

/// The Noise pattern used for a handshake.
///
/// XK: requires pre-shared public key (from BLE profile or LAN beacon).
/// XX: no pre-shared key needed — static keys exchanged during handshake.
enum NoisePattern { xk, xx }

/// The role this device plays in a specific Noise handshake.
///
/// Initiator = the side that sends the first handshake message (msg1).
/// Responder = the side that receives msg1 and replies with msg2.
///
/// Tie-breaking rule: the peer whose app-userId is lexicographically
/// GREATER is always the initiator (avoids simultaneous-initiate conflicts).
enum NoiseRole { initiator, responder }

/// A fully established E2EE session with a peer.
///
/// Created by [EncryptionService] after the 3-message Noise_XK handshake
/// completes.  The session is ephemeral — it lives in memory only.  When the
/// BLE connection drops and reconnects, a new handshake is performed, giving
/// per-session forward secrecy.
///
/// Key sizes are 32 bytes (256-bit XChaCha20-Poly1305).
class NoiseSession {
  NoiseSession({
    required this.peerId,
    required this.sendKey,
    required this.receiveKey,
    required this.establishedAt,
  });

  final String peerId;

  /// Key used to ENCRYPT outbound messages to this peer.
  final Uint8List sendKey;

  /// Key used to DECRYPT inbound messages from this peer.
  final Uint8List receiveKey;

  final DateTime establishedAt;

  /// Number of messages encrypted with this session's send key.
  /// Used to trigger automatic rekeying after [rekeyThreshold] messages.
  int messageCount = 0;

  /// Maximum messages before a rekey is recommended.
  /// 1000 messages provides good forward secrecy without excessive handshakes.
  static const int rekeyThreshold = 1000;

  /// Whether this session has exceeded the rekey threshold.
  bool get needsRekey => messageCount >= rekeyThreshold;

  // SECURITY: nonces must never repeat.  We use random 24-byte nonces
  // (XChaCha20 extended nonce space) transmitted alongside the ciphertext,
  // so we don't need a stateful counter here — the randomness makes
  // collision probability negligible (~2^96 birthday bound over 2^64 messages).
}

/// A pending (incomplete) Noise handshake with a peer.
///
/// Stored in-memory while waiting for the next round-trip message.
enum HandshakeState { awaitingMessage2, awaitingMessage3 }

class PendingHandshake {
  PendingHandshake({
    required this.peerId,
    required this.role,
    required this.state,
    this.pattern = NoisePattern.xk,
    required this.localEphemeralPrivate,
    required this.localEphemeralPublic,
    this.remoteEphemeralPublic,
    required this.h,
    required this.ck,
    this.k,
    this.n = 0,
    required this.startedAt,
  });

  final String peerId;
  final NoiseRole role;
  final HandshakeState state;
  final NoisePattern pattern;

  // Ephemeral key pair for this handshake (discarded after Split()).
  final Uint8List localEphemeralPrivate;
  final Uint8List localEphemeralPublic;
  Uint8List? remoteEphemeralPublic;

  // Noise symmetric state: hash h and chaining key ck (both 32 bytes).
  Uint8List h;
  Uint8List ck;

  // Current cipher key (null until first MixKey call).
  Uint8List? k;

  // Nonce counter for EncryptAndHash / DecryptAndHash during handshake.
  int n;

  final DateTime startedAt;

  PendingHandshake copyWith({
    HandshakeState? state,
    Uint8List? remoteEphemeralPublic,
    Uint8List? h,
    Uint8List? ck,
    Uint8List? k,
    int? n,
  }) {
    return PendingHandshake(
      peerId: peerId,
      role: role,
      state: state ?? this.state,
      pattern: pattern,
      localEphemeralPrivate: localEphemeralPrivate,
      localEphemeralPublic: localEphemeralPublic,
      remoteEphemeralPublic: remoteEphemeralPublic ?? this.remoteEphemeralPublic,
      h: h ?? this.h,
      ck: ck ?? this.ck,
      k: k ?? this.k,
      n: n ?? this.n,
      startedAt: startedAt,
    );
  }
}

/// An outbound handshake message to send over BLE.
class HandshakeMessageOut {
  const HandshakeMessageOut({
    required this.peerId,
    required this.step,
    required this.payload,
  });

  final String peerId;

  /// 1, 2, or 3 (maps to Noise_XK messages 1–3).
  final int step;

  /// Raw handshake bytes to transmit.
  final Uint8List payload;
}

/// Represents an encrypted message payload for wire transmission.
///
/// Wire JSON fields:
///   "v": 1                         ← version / encryption flag
///   "n": base64(nonce, 24 bytes)   ← XChaCha20 random nonce
///   "c": base64(ciphertext + tag)  ← ciphertext || Poly1305 tag (16 bytes)
class EncryptedPayload {
  const EncryptedPayload({
    required this.nonce,
    required this.ciphertext,
  });

  /// 24-byte XChaCha20 nonce (randomly generated per message).
  final Uint8List nonce;

  /// Ciphertext with 16-byte Poly1305 auth tag appended.
  final Uint8List ciphertext;
}

/// Decrypted inner envelope — the plaintext JSON carried inside the ciphertext.
///
/// Keeping the sensitive content (text, replyToId) inside the ciphertext means
/// that an eavesdropper who captures BLE packets learns NOTHING about message
/// content, length hints, or reply chains.
class DecryptedEnvelope {
  const DecryptedEnvelope({
    required this.content,
    this.msgType,
    this.replyToId,
  });

  final String content;
  final String? msgType;
  final String? replyToId;
}

/// Result of [EncryptionService.initiateHandshake] / [processHandshakeMessage].
class HandshakeResult {
  const HandshakeResult({
    this.messageToSend,
    this.sessionEstablished = false,
    this.error,
  });

  /// If non-null, this handshake message must be sent to the peer via BLE.
  final HandshakeMessageOut? messageToSend;

  /// True when the handshake completed and a session is now active.
  final bool sessionEstablished;

  final String? error;

  bool get hasError => error != null;
}
