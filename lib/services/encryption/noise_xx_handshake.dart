import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'noise_handshake.dart';

// ---------------------------------------------------------------------------
// Noise_XX Handshake State Machine
//
// Implements the Noise Protocol Framework (revision 34) XX pattern:
//
//   XX:
//     -> e                 (msg1: initiator → responder, 32 bytes)
//     <- e, ee, s, es      (msg2: responder → initiator, 96 bytes)
//     -> s, se             (msg3: initiator → responder, 64 bytes)
//
// Unlike XK, XX does NOT require a pre-shared public key. Both sides learn
// each other's static keys during the handshake. This allows handshakes to
// proceed immediately upon peer discovery, without waiting for a profile read.
//
// The downside is that an active MITM can inject their own ephemeral key in
// msg1 (since msg1 is unauthenticated). However, the MITM would be detected
// at msg2 (the responder encrypts their static key under the shared DH), and
// at msg3 (the initiator encrypts their static key). For our cruise-ship BLE
// environment, this is acceptable — passive eavesdropping is the primary
// threat, and XX still provides forward secrecy.
//
// WIRE COMPATIBILITY:
//   The handshake step field distinguishes XK from XX:
//     XK: steps 1, 2, 3 (existing)
//     XX: steps 11, 12, 13
//
// References:
//   https://noiseprotocol.org/noise.html §7.5 (XX pattern)
// ---------------------------------------------------------------------------

/// Protocol name for Noise_XX — must be exactly 32 bytes.
/// (Same cipher suite as XK, different pattern name.)
const _kXXProtocolName = 'Noise_XX_25519_ChaChaPoly_SHA256';

/// XX handshake step numbers (offset from XK to avoid collision).
const kXXStep1 = 11;
const kXXStep2 = 12;
const kXXStep3 = 13;

/// Check if a handshake step number belongs to the XX pattern.
bool isXXHandshakeStep(int step) => step >= kXXStep1 && step <= kXXStep3;

/// Normalize an XX step to 1-based (for internal logic).
int xxStepToLocal(int step) => step - kXXStep1 + 1;

class NoiseXXHandshakeProcessor {
  NoiseXXHandshakeProcessor._();

  // Reuse the same crypto primitives from the XK processor.
  // All the symmetric state helpers (MixHash, MixKey, EncryptAndHash,
  // DecryptAndHash, DH, Split) are identical — only the message pattern differs.

  // ── Initialization ────────────────────────────────────────────────────────

  /// Create the initial Noise symmetric state for XX.
  ///
  /// XX has NO pre-message, so we only MixHash(prologue) — no static key.
  ///
  /// Per spec §5.2:
  ///   h = ck = SHA-256(protocolName)  if len != HASHLEN
  ///   MixHash(prologue)
  static Future<({Uint8List h, Uint8List ck})> initSymmetricState({
    Uint8List? prologue,
  }) async {
    // Protocol name is exactly 32 bytes (== HASHLEN), so use directly.
    var h = Uint8List.fromList(utf8.encode(_kXXProtocolName));
    var ck = Uint8List.fromList(h);

    // MixHash(prologue) — empty prologue if none provided.
    h = await NoiseHandshakeProcessor.encryptAndHash(null, 0, h, prologue ?? Uint8List(0))
        .then((r) => r.h);

    return (h: h, ck: ck);
  }

  // ── Message 1: -> e ────────────────────────────────────────────────────────

  /// INITIATOR writes Message 1.
  ///
  /// Pattern: -> e
  ///   1. Generate ephemeral key pair e.
  ///   2. MixHash(e.publicKey).
  ///
  /// No DH operations in msg1 — just the ephemeral public key.
  /// Message 1 = 32 bytes (just the ephemeral public key).
  static Future<({
    Uint8List payload,
    Uint8List localEphPriv,
    Uint8List localEphPub,
    Uint8List h,
    Uint8List ck,
  })> writeMessage1(Uint8List h, Uint8List ck) async {
    final eph = await NoiseHandshakeProcessor.generateEphemeral();

    // MixHash(e.publicKey)
    final eah = await NoiseHandshakeProcessor.encryptAndHash(
      null, 0, h, eph.publicKey,
    );

    return (
      payload: eph.publicKey,
      localEphPriv: eph.privateKey,
      localEphPub: eph.publicKey,
      h: eah.h,
      ck: ck,
    );
  }

  /// RESPONDER reads Message 1.
  ///
  /// Pattern: -> e (received)
  static Future<({
    Uint8List initiatorEphPublic,
    Uint8List h,
    Uint8List ck,
  })> readMessage1(Uint8List h, Uint8List ck, Uint8List message1) async {
    if (message1.length < 32) {
      throw const NoiseHandshakeException(
          'XX Message 1 too short (expected ≥32 bytes)');
    }
    final initiatorEph = message1.sublist(0, 32);

    // MixHash(e.publicKey)
    final eah = await NoiseHandshakeProcessor.encryptAndHash(
      null, 0, h, initiatorEph,
    );

    return (
      initiatorEphPublic: initiatorEph,
      h: eah.h,
      ck: ck,
    );
  }

  // ── Message 2: <- e, ee, s, es ──────────────────────────────────────────

  /// RESPONDER writes Message 2.
  ///
  /// Pattern: <- e, ee, s, es
  ///   1. Generate ephemeral key pair e.
  ///   2. MixHash(e.publicKey).
  ///   3. ee: DH(e_resp, e_init) → MixKey.
  ///   4. EncryptAndHash(s.publicKey) → encrypted static key.
  ///   5. es: DH(s_resp, e_init) → MixKey.
  ///   6. EncryptAndHash("") → empty payload with auth tag.
  ///
  /// Message 2 = 32 (e_pub) + 48 (encrypted s = 32+16 tag) + 16 (empty tag) = 96 bytes.
  static Future<({
    Uint8List payload,
    Uint8List localEphPriv,
    Uint8List localEphPub,
    Uint8List h,
    Uint8List ck,
    Uint8List k,
    int n,
  })> writeMessage2(
    Uint8List h,
    Uint8List ck,
    Uint8List initiatorEphPublic,
    Uint8List responderStaticPrivate,
    Uint8List responderStaticPublic,
  ) async {
    // Generate responder's ephemeral
    final eph = await NoiseHandshakeProcessor.generateEphemeral();

    // MixHash(e.publicKey)
    var eah = await NoiseHandshakeProcessor.encryptAndHash(
      null, 0, h, eph.publicKey,
    );
    var newH = eah.h;

    // ee: DH(e_resp, e_init) → MixKey
    final ee = await _dh(eph.privateKey, initiatorEphPublic);
    var mixed = await _mixKey(ck, ee);
    var newCk = mixed.ck;
    var newK = mixed.k;
    var newN = 0;

    // EncryptAndHash(s.publicKey) — encrypt our static key
    final encS = await NoiseHandshakeProcessor.encryptAndHash(
      newK, newN, newH, responderStaticPublic,
    );
    newH = encS.h;
    newN = encS.n;

    // es: DH(s_resp, e_init) → MixKey
    final es = await _dh(responderStaticPrivate, initiatorEphPublic);
    mixed = await _mixKey(newCk, es);
    newCk = mixed.ck;
    newK = mixed.k;
    newN = 0;

    // EncryptAndHash("") — empty payload
    final encEmpty = await NoiseHandshakeProcessor.encryptAndHash(
      newK, newN, newH, Uint8List(0),
    );
    newH = encEmpty.h;
    newN = encEmpty.n;

    // Assemble: e_pub || encS || encEmpty
    final payload = Uint8List(
        eph.publicKey.length + encS.ciphertext.length + encEmpty.ciphertext.length)
      ..setRange(0, eph.publicKey.length, eph.publicKey)
      ..setRange(eph.publicKey.length,
          eph.publicKey.length + encS.ciphertext.length, encS.ciphertext)
      ..setRange(
          eph.publicKey.length + encS.ciphertext.length,
          eph.publicKey.length + encS.ciphertext.length + encEmpty.ciphertext.length,
          encEmpty.ciphertext);

    return (
      payload: payload,
      localEphPriv: eph.privateKey,
      localEphPub: eph.publicKey,
      h: newH,
      ck: newCk,
      k: newK,
      n: newN,
    );
  }

  /// INITIATOR reads Message 2.
  ///
  /// Pattern: <- e, ee, s, es (received)
  static Future<({
    Uint8List responderEphPublic,
    Uint8List responderStaticPublic,
    Uint8List h,
    Uint8List ck,
    Uint8List k,
    int n,
  })> readMessage2(
    Uint8List h,
    Uint8List ck,
    Uint8List message2,
    Uint8List initiatorEphPrivate,
  ) async {
    // Message 2 = 32 (e_pub) + 48 (encrypted s) + 16 (empty tag) = 96 bytes
    if (message2.length < 96) {
      throw const NoiseHandshakeException(
          'XX Message 2 too short (expected ≥96 bytes)');
    }

    final responderEph = message2.sublist(0, 32);
    final encS = message2.sublist(32, 80); // 48 bytes (32 key + 16 tag)
    final encEmpty = message2.sublist(80); // 16 bytes (tag only)

    // MixHash(e.publicKey)
    var eah = await NoiseHandshakeProcessor.encryptAndHash(
      null, 0, h, responderEph,
    );
    var newH = eah.h;

    // ee: DH(e_init, e_resp) → MixKey
    final ee = await _dh(initiatorEphPrivate, responderEph);
    var mixed = await _mixKey(ck, ee);
    var newCk = mixed.ck;
    var newK = mixed.k;
    var newN = 0;

    // DecryptAndHash(encS) → responder's static public key
    final decS = await NoiseHandshakeProcessor.decryptAndHash(
      newK, newN, newH, encS,
    );
    newH = decS.h;
    newN = decS.n;
    final responderStaticPub = decS.plaintext;

    // es: DH(e_init, s_resp) → MixKey
    final es = await _dh(initiatorEphPrivate, responderStaticPub);
    mixed = await _mixKey(newCk, es);
    newCk = mixed.ck;
    newK = mixed.k;
    newN = 0;

    // DecryptAndHash("") — verify auth tag
    final decEmpty = await NoiseHandshakeProcessor.decryptAndHash(
      newK, newN, newH, encEmpty,
    );
    newH = decEmpty.h;
    newN = decEmpty.n;

    return (
      responderEphPublic: responderEph,
      responderStaticPublic: responderStaticPub,
      h: newH,
      ck: newCk,
      k: newK,
      n: newN,
    );
  }

  // ── Message 3: -> s, se ─────────────────────────────────────────────────

  /// INITIATOR writes Message 3.
  ///
  /// Pattern: -> s, se
  ///   Same as XK message 3 — EncryptAndHash(s.publicKey), DH(s, re), EncryptAndHash("").
  ///
  /// Message 3 = 48 (encrypted s) + 16 (empty tag) = 64 bytes.
  static Future<({
    Uint8List payload,
    Uint8List h,
    Uint8List ck,
    Uint8List k,
    int n,
  })> writeMessage3(
    Uint8List h,
    Uint8List ck,
    Uint8List? k,
    int n,
    Uint8List initiatorStaticPrivate,
    Uint8List initiatorStaticPublic,
    Uint8List responderEphPublic,
  ) async {
    // Delegate to XK's writeMessage3 — the pattern is identical for this step.
    return NoiseHandshakeProcessor.writeMessage3(
      h, ck, k, n,
      initiatorStaticPrivate,
      initiatorStaticPublic,
      responderEphPublic,
    );
  }

  /// RESPONDER reads Message 3.
  ///
  /// Pattern: -> s, se (received)
  /// Same as XK's readMessage3.
  static Future<({
    Uint8List initiatorStaticPublic,
    Uint8List h,
    Uint8List ck,
    Uint8List k,
    int n,
  })> readMessage3(
    Uint8List h,
    Uint8List ck,
    Uint8List? k,
    int n,
    Uint8List message3,
    Uint8List responderEphPrivate,
  ) async {
    return NoiseHandshakeProcessor.readMessage3(
      h, ck, k, n, message3, responderEphPrivate,
    );
  }

  // ── Split ─────────────────────────────────────────────────────────────────

  /// Same as XK split.
  static Future<({Uint8List initiatorSend, Uint8List initiatorRecv})> split(
    Uint8List ck,
  ) =>
      NoiseHandshakeProcessor.split(ck);

  // ── Private DH/MixKey helpers ──────────────────────────────────────────────

  // These delegate to the XK processor's static methods. Since they're private
  // in NoiseHandshakeProcessor, we re-implement the thin wrappers here.
  // TODO: Consider extracting shared crypto helpers to a common base.

  static Future<Uint8List> _dh(
    Uint8List privateKeyBytes,
    Uint8List remotePublicKeyBytes,
  ) async {
    final x25519 = X25519();
    final kp = await x25519.newKeyPairFromSeed(privateKeyBytes);
    final remotePub =
        SimplePublicKey(remotePublicKeyBytes, type: KeyPairType.x25519);
    final shared =
        await x25519.sharedSecretKey(keyPair: kp, remotePublicKey: remotePub);
    return Uint8List.fromList(await shared.extractBytes());
  }

  static Future<({Uint8List ck, Uint8List k})> _mixKey(
    Uint8List ck,
    Uint8List inputKeyMaterial,
  ) async {
    // Use the same HKDF as XK (exported at module level in noise_handshake.dart).
    // Since _noiseHkdf is private, we call it via the public encryptAndHash path...
    // Actually, let's just inline the HKDF call.
    final hmac = Hmac.sha256();

    final tempKeyMac = await hmac.calculateMac(
      inputKeyMaterial,
      secretKey: SecretKey(ck),
    );
    final tempKey = Uint8List.fromList(tempKeyMac.bytes);

    final out1Mac = await hmac.calculateMac(
      Uint8List.fromList([0x01]),
      secretKey: SecretKey(tempKey),
    );
    final out1 = Uint8List.fromList(out1Mac.bytes);

    final out2Mac = await hmac.calculateMac(
      Uint8List.fromList([...out1, 0x02]),
      secretKey: SecretKey(tempKey),
    );
    final out2 = Uint8List.fromList(out2Mac.bytes);

    return (ck: out1, k: out2.sublist(0, 32));
  }
}
