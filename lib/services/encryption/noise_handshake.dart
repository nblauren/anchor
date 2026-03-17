import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

// ---------------------------------------------------------------------------
// Noise_XK Handshake State Machine
//
// Implements the Noise Protocol Framework (revision 34) XK pattern:
//
//   XK:
//     <- s          (pre-message: initiator knows responder's static key)
//     ...
//     -> e, es      (msg1: initiator → responder, 48 bytes)
//     <- e, ee      (msg2: responder → initiator, 48 bytes)
//     -> s, se      (msg3: initiator → responder, 64 bytes)
//
// References:
//   https://noiseprotocol.org/noise.html
//   https://pub.dev/packages/cryptography
//
// SECURITY NOTES:
//   • Private keys NEVER leave this file as plaintext.  They are held as
//     [SimpleKeyPair] objects that the cryptography package keeps opaque.
//   • Nonces in the handshake phase are sequential uint64 counters, encoded
//     as Noise specifies: 4 zero bytes || 8-byte little-endian uint64.
//   • After Split(), session keys are returned as raw [Uint8List] so the caller
//     (EncryptionService) can store them and we can discard the handshake state.
//   • The ephemeral key pair is discarded as soon as Split() succeeds.
// ---------------------------------------------------------------------------

/// Protocol name that seeds the initial hash and chaining key.
/// Exactly 32 ASCII bytes — equal to SHA-256 HASHLEN — so it's used directly
/// as h and ck without hashing (per Noise spec §5.2).
const _kProtocolName = 'Noise_XK_25519_ChaChaPoly_SHA256';

/// Noise HKDF: custom construction defined in Noise spec §4.
/// NOT the RFC 5869 HKDF; uses single-byte counter labels.
///
/// Returns [numOutputs] × 32-byte outputs.
Future<List<Uint8List>> _noiseHkdf(
  Uint8List chainingKey,
  Uint8List inputKeyMaterial,
  int numOutputs,
) async {
  final hmac = Hmac.sha256();

  // temp_key = HMAC-SHA256(chaining_key, input_key_material)
  final tempKeyMac = await hmac.calculateMac(
    inputKeyMaterial,
    secretKey: SecretKey(chainingKey),
  );
  final tempKey = Uint8List.fromList(tempKeyMac.bytes);

  // output1 = HMAC-SHA256(temp_key, 0x01)
  final out1Mac = await hmac.calculateMac(
    Uint8List.fromList([0x01]),
    secretKey: SecretKey(tempKey),
  );
  final out1 = Uint8List.fromList(out1Mac.bytes);
  if (numOutputs == 1) return [out1];

  // output2 = HMAC-SHA256(temp_key, output1 || 0x02)
  final out2Mac = await hmac.calculateMac(
    Uint8List.fromList([...out1, 0x02]),
    secretKey: SecretKey(tempKey),
  );
  final out2 = Uint8List.fromList(out2Mac.bytes);
  if (numOutputs == 2) return [out1, out2];

  // output3 = HMAC-SHA256(temp_key, output2 || 0x03)
  final out3Mac = await hmac.calculateMac(
    Uint8List.fromList([...out2, 0x03]),
    secretKey: SecretKey(tempKey),
  );
  return [out1, out2, Uint8List.fromList(out3Mac.bytes)];
}

/// Encode nonce [n] as the 12-byte Noise ChaCha20-Poly1305 nonce:
///   [0, 0, 0, 0] || little-endian uint64(n)
Uint8List _noiseNonce(int n) {
  final nonce = Uint8List(12);
  final bd = ByteData.sublistView(nonce);
  // 4 leading zero bytes; little-endian uint64 at offset 4
  bd.setUint32(0, 0, Endian.big);
  bd.setUint32(4, n & 0xFFFFFFFF, Endian.little);
  bd.setUint32(8, (n >> 32) & 0xFFFFFFFF, Endian.little);
  return nonce;
}

// ---------------------------------------------------------------------------
// HandshakeProcessor — pure async functions, no mutable class state.
// EncryptionService owns the mutable PendingHandshake records.
// ---------------------------------------------------------------------------

class NoiseHandshakeProcessor {
  NoiseHandshakeProcessor._();

  static final _x25519 = X25519();
  static final _chacha = Chacha20.poly1305Aead();
  static final _sha256 = Sha256();

  // ── Initialization ────────────────────────────────────────────────────────

  /// Create the initial Noise symmetric state for ANY role.
  ///
  /// Per spec §5.2:
  ///   h = ck = protocolName (32 bytes, equals HASHLEN so no hashing)
  ///   MixHash(prologue)
  ///   MixHash(rs.publicKey)   ← XK pre-message: responder's static is known
  static Future<({Uint8List h, Uint8List ck})> initSymmetricState(
    Uint8List responderStaticPublicKey, {
    Uint8List? prologue,
  }) async {
    // h = ck = ASCII bytes of protocol name (32 bytes exactly)
    var h = Uint8List.fromList(utf8.encode(_kProtocolName));
    var ck = Uint8List.fromList(h);

    // MixHash(prologue)
    if (prologue != null && prologue.isNotEmpty) {
      h = await _mixHash(h, prologue);
    } else {
      h = await _mixHash(h, Uint8List(0));
    }

    // XK pre-message: MixHash(rs.publicKey)
    h = await _mixHash(h, responderStaticPublicKey);

    return (h: h, ck: ck);
  }

  // ── Symmetric state helpers ───────────────────────────────────────────────

  static Future<Uint8List> _mixHash(Uint8List h, Uint8List data) async {
    final combined = Uint8List(h.length + data.length)
      ..setRange(0, h.length, h)
      ..setRange(h.length, h.length + data.length, data);
    final digest = await _sha256.hash(combined);
    return Uint8List.fromList(digest.bytes);
  }

  /// MixKey(inputKeyMaterial) → (newCk, newK, resetN=0)
  static Future<({Uint8List ck, Uint8List k})> _mixKey(
    Uint8List ck,
    Uint8List inputKeyMaterial,
  ) async {
    final outputs = await _noiseHkdf(ck, inputKeyMaterial, 2);
    // HKDF output1 → new chaining key, output2 → new cipher key (first 32 bytes)
    return (ck: outputs[0], k: outputs[1].sublist(0, 32));
  }

  /// ENCRYPT(k, n, ad=h, plaintext) → ciphertext || tag
  static Future<Uint8List> _encryptWithAd(
    Uint8List k,
    int n,
    Uint8List ad,
    Uint8List plaintext,
  ) async {
    final box = await _chacha.encrypt(
      plaintext,
      secretKey: SecretKey(k),
      nonce: _noiseNonce(n),
      aad: ad,
    );
    // Concatenate ciphertext + 16-byte Poly1305 tag
    final result = Uint8List(box.cipherText.length + box.mac.bytes.length);
    result.setRange(0, box.cipherText.length, box.cipherText);
    result.setRange(box.cipherText.length, result.length, box.mac.bytes);
    return result;
  }

  /// DECRYPT(k, n, ad=h, ciphertext||tag) → plaintext
  static Future<Uint8List> _decryptWithAd(
    Uint8List k,
    int n,
    Uint8List ad,
    Uint8List ciphertextWithTag,
  ) async {
    if (ciphertextWithTag.length < 16) {
      throw const NoiseHandshakeException('Ciphertext too short (< 16 bytes tag)');
    }
    final ctLen = ciphertextWithTag.length - 16;
    final ciphertext = ciphertextWithTag.sublist(0, ctLen);
    final tag = Mac(ciphertextWithTag.sublist(ctLen));

    final box = SecretBox(ciphertext, nonce: _noiseNonce(n), mac: tag);
    try {
      final plaintext = await _chacha.decrypt(
        box,
        secretKey: SecretKey(k),
        aad: ad,
      );
      return Uint8List.fromList(plaintext);
    } on SecretBoxAuthenticationError {
      throw const NoiseHandshakeException('Authentication tag mismatch — possible tampering');
    }
  }

  /// EncryptAndHash(plaintext) → (ciphertext, newH, newN)
  ///
  /// If [k] is null (no key yet), this is a no-op hash pass-through.
  static Future<({Uint8List ciphertext, Uint8List h, int n})> encryptAndHash(
    Uint8List? k,
    int n,
    Uint8List h,
    Uint8List plaintext,
  ) async {
    if (k == null) {
      // No key yet: just MixHash(plaintext) and return plaintext unchanged
      final newH = await _mixHash(h, plaintext);
      return (ciphertext: plaintext, h: newH, n: n);
    }
    final ciphertext = await _encryptWithAd(k, n, h, plaintext);
    final newH = await _mixHash(h, ciphertext);
    return (ciphertext: ciphertext, h: newH, n: n + 1);
  }

  /// DecryptAndHash(ciphertext) → (plaintext, newH, newN)
  static Future<({Uint8List plaintext, Uint8List h, int n})> decryptAndHash(
    Uint8List? k,
    int n,
    Uint8List h,
    Uint8List ciphertext,
  ) async {
    if (k == null) {
      final newH = await _mixHash(h, ciphertext);
      return (plaintext: ciphertext, h: newH, n: n);
    }
    final plaintext = await _decryptWithAd(k, n, h, ciphertext);
    final newH = await _mixHash(h, ciphertext);
    return (plaintext: plaintext, h: newH, n: n + 1);
  }

  // ── DH helper ────────────────────────────────────────────────────────────

  static Future<Uint8List> _dh(
    Uint8List privateKeyBytes,
    Uint8List remotePublicKeyBytes,
  ) async {
    final kp = await _x25519.newKeyPairFromSeed(privateKeyBytes);
    final remotePub = SimplePublicKey(remotePublicKeyBytes, type: KeyPairType.x25519);
    final shared = await _x25519.sharedSecretKey(keyPair: kp, remotePublicKey: remotePub);
    return Uint8List.fromList(await shared.extractBytes());
  }

  // ── Key generation ────────────────────────────────────────────────────────

  /// Generate a new ephemeral X25519 key pair, returning raw byte arrays.
  static Future<({Uint8List privateKey, Uint8List publicKey})> generateEphemeral() async {
    final kp = await _x25519.newKeyPair();
    final pub = await kp.extractPublicKey();
    final priv = await kp.extractPrivateKeyBytes();
    return (
      privateKey: Uint8List.fromList(priv),
      publicKey: Uint8List.fromList(pub.bytes),
    );
  }

  // ── Split ─────────────────────────────────────────────────────────────────

  /// Noise Split(): derive two 32-byte session keys from the final chaining key.
  ///
  /// Returns (sendKey, recvKey) from the INITIATOR's perspective.
  /// Responder swaps them.
  static Future<({Uint8List initiatorSend, Uint8List initiatorRecv})> split(
    Uint8List ck,
  ) async {
    final outputs = await _noiseHkdf(ck, Uint8List(0), 2);
    return (initiatorSend: outputs[0], initiatorRecv: outputs[1]);
  }

  // ── Handshake message writers ─────────────────────────────────────────────

  /// INITIATOR writes Message 1 → returns (payload, updatedState)
  ///
  /// Pattern: -> e, es
  ///   1. Generate ephemeral key pair e.
  ///   2. MixHash(e.publicKey).
  ///   3. DH(e, rs) → MixKey.
  ///   4. EncryptAndHash("") → append empty ciphertext (just Poly1305 tag if key exists).
  ///
  /// Message 1 bytes: e.publicKey (32) || EncryptAndHash("") (0 bytes, but no key yet)
  /// = 32 bytes total (no tag since k is still null after es MixKey... wait)
  ///
  /// Actually: after MixKey(DH(e,rs)), k IS set.  EncryptAndHash("") with k set
  /// → empty plaintext → just 16-byte tag.  So Message 1 = 32 + 16 = 48 bytes.
  static Future<({
    Uint8List payload,
    Uint8List localEphPriv,
    Uint8List localEphPub,
    Uint8List h,
    Uint8List ck,
    Uint8List k,
    int n,
  })> writeMessage1(
    Uint8List h,
    Uint8List ck,
    Uint8List? k,
    int n,
    Uint8List responderStaticPublic,
  ) async {
    // Generate ephemeral
    final eph = await generateEphemeral();

    // MixHash(e.publicKey)
    var newH = await _mixHash(h, eph.publicKey);

    // es: DH(e, rs) → MixKey
    final es = await _dh(eph.privateKey, responderStaticPublic);
    final mixed = await _mixKey(ck, es);
    var newCk = mixed.ck;
    var newK = mixed.k;
    var newN = 0; // MixKey resets n

    // EncryptAndHash("") — empty payload
    final encrypted = await encryptAndHash(newK, newN, newH, Uint8List(0));
    newH = encrypted.h;
    newN = encrypted.n;

    final payload = Uint8List(eph.publicKey.length + encrypted.ciphertext.length)
      ..setRange(0, eph.publicKey.length, eph.publicKey)
      ..setRange(eph.publicKey.length, eph.publicKey.length + encrypted.ciphertext.length, encrypted.ciphertext);

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

  /// RESPONDER reads Message 1 → (updatedState, initiatorEphPublic)
  ///
  /// Pattern: -> e, es (received)
  static Future<({
    Uint8List initiatorEphPublic,
    Uint8List h,
    Uint8List ck,
    Uint8List k,
    int n,
  })> readMessage1(
    Uint8List h,
    Uint8List ck,
    Uint8List? k,
    int n,
    Uint8List message1,
    Uint8List responderStaticPrivate,
  ) async {
    if (message1.length < 48) {
      throw const NoiseHandshakeException('Message 1 too short (expected ≥48 bytes)');
    }
    final initiatorEph = message1.sublist(0, 32);
    final encPayload = message1.sublist(32);

    // MixHash(e.publicKey)  (e = initiator's ephemeral)
    var newH = await _mixHash(h, initiatorEph);

    // es: DH(s, e) where s = responder's static private key
    // Note: in XK, "es" from initiator's view is DH(e_init, s_resp).
    //       From responder's view: DH(s_resp, e_init) — same result.
    final es = await _dh(responderStaticPrivate, initiatorEph);
    final mixed = await _mixKey(ck, es);
    var newCk = mixed.ck;
    var newK = mixed.k;
    var newN = 0;

    // DecryptAndHash(encPayload) — verifies auth tag, plaintext should be empty
    final decrypted = await decryptAndHash(newK, newN, newH, encPayload);
    newH = decrypted.h;
    newN = decrypted.n;

    return (
      initiatorEphPublic: initiatorEph,
      h: newH,
      ck: newCk,
      k: newK,
      n: newN,
    );
  }

  /// RESPONDER writes Message 2 → (payload, updatedState)
  ///
  /// Pattern: <- e, ee
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
    Uint8List? k,
    int n,
    Uint8List initiatorEphPublic,
  ) async {
    // Generate responder's ephemeral
    final eph = await generateEphemeral();

    // MixHash(e.publicKey)
    var newH = await _mixHash(h, eph.publicKey);

    // ee: DH(e_resp, e_init)
    final ee = await _dh(eph.privateKey, initiatorEphPublic);
    final mixed = await _mixKey(ck, ee);
    var newCk = mixed.ck;
    var newK = mixed.k;
    var newN = 0;

    // EncryptAndHash("") — empty payload → 16-byte tag
    final encrypted = await encryptAndHash(newK, newN, newH, Uint8List(0));
    newH = encrypted.h;
    newN = encrypted.n;

    final payload = Uint8List(eph.publicKey.length + encrypted.ciphertext.length)
      ..setRange(0, eph.publicKey.length, eph.publicKey)
      ..setRange(eph.publicKey.length, eph.publicKey.length + encrypted.ciphertext.length, encrypted.ciphertext);

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

  /// INITIATOR reads Message 2 → (updatedState)
  ///
  /// Pattern: <- e, ee (received)
  static Future<({
    Uint8List responderEphPublic,
    Uint8List h,
    Uint8List ck,
    Uint8List k,
    int n,
  })> readMessage2(
    Uint8List h,
    Uint8List ck,
    Uint8List? k,
    int n,
    Uint8List message2,
    Uint8List initiatorEphPrivate,
  ) async {
    if (message2.length < 48) {
      throw const NoiseHandshakeException('Message 2 too short (expected ≥48 bytes)');
    }
    final responderEph = message2.sublist(0, 32);
    final encPayload = message2.sublist(32);

    // MixHash(e.publicKey)  (e = responder's ephemeral)
    var newH = await _mixHash(h, responderEph);

    // ee: DH(e_init, e_resp)
    final ee = await _dh(initiatorEphPrivate, responderEph);
    final mixed = await _mixKey(ck, ee);
    var newCk = mixed.ck;
    var newK = mixed.k;
    var newN = 0;

    // DecryptAndHash(encPayload)
    final decrypted = await decryptAndHash(newK, newN, newH, encPayload);
    newH = decrypted.h;
    newN = decrypted.n;

    return (
      responderEphPublic: responderEph,
      h: newH,
      ck: newCk,
      k: newK,
      n: newN,
    );
  }

  /// INITIATOR writes Message 3 → (payload, updatedState)
  ///
  /// Pattern: -> s, se
  ///   1. EncryptAndHash(s.publicKey) → encrypted static key (32 + 16 = 48 bytes)
  ///   2. se: DH(s, re) where re = responder's ephemeral → MixKey
  ///   3. EncryptAndHash("") → 16-byte tag (payload)
  ///
  /// Message 3 = 48 (encrypted s) + 16 (empty tag) = 64 bytes
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
    var newH = h;
    var newCk = ck;
    var newK = k;
    var newN = n;

    // EncryptAndHash(s.publicKey)
    final encS = await encryptAndHash(newK, newN, newH, initiatorStaticPublic);
    newH = encS.h;
    newN = encS.n;

    // se: DH(s_init, e_resp)
    final se = await _dh(initiatorStaticPrivate, responderEphPublic);
    final mixed = await _mixKey(newCk, se);
    newCk = mixed.ck;
    newK = mixed.k;
    newN = 0;

    // EncryptAndHash("") — empty payload
    final encEmpty = await encryptAndHash(newK, newN, newH, Uint8List(0));
    newH = encEmpty.h;
    newN = encEmpty.n;

    final payload = Uint8List(encS.ciphertext.length + encEmpty.ciphertext.length)
      ..setRange(0, encS.ciphertext.length, encS.ciphertext)
      ..setRange(encS.ciphertext.length, encS.ciphertext.length + encEmpty.ciphertext.length, encEmpty.ciphertext);

    return (payload: payload, h: newH, ck: newCk, k: newK, n: newN);
  }

  /// RESPONDER reads Message 3 → (updatedState)
  ///
  /// Pattern: -> s, se (received)
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
    if (message3.length < 64) {
      throw const NoiseHandshakeException('Message 3 too short (expected ≥64 bytes)');
    }
    var newH = h;
    var newCk = ck;
    var newK = k;
    var newN = n;

    // DecryptAndHash(encryptedS) → initiator's static public key
    final encS = message3.sublist(0, 48); // 32 bytes key + 16 bytes tag
    final encEmpty = message3.sublist(48);

    final decS = await decryptAndHash(newK, newN, newH, encS);
    newH = decS.h;
    newN = decS.n;
    final initiatorStaticPub = decS.plaintext; // 32 bytes

    // se: DH(e_resp, s_init)
    final se = await _dh(responderEphPrivate, initiatorStaticPub);
    final mixed = await _mixKey(newCk, se);
    newCk = mixed.ck;
    newK = mixed.k;
    newN = 0;

    // DecryptAndHash("") — verifies final auth tag
    final decEmpty = await decryptAndHash(newK, newN, newH, encEmpty);
    newH = decEmpty.h;
    newN = decEmpty.n;

    return (
      initiatorStaticPublic: initiatorStaticPub,
      h: newH,
      ck: newCk,
      k: newK,
      n: newN,
    );
  }
}

// ---------------------------------------------------------------------------
// Noise handshake exception
// ---------------------------------------------------------------------------

class NoiseHandshakeException implements Exception {
  const NoiseHandshakeException(this.message);
  final String message;

  @override
  String toString() => 'NoiseHandshakeException: $message';
}
