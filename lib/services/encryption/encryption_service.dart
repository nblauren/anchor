import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/utils/logger.dart';
import '../../data/local_database/database.dart';
import 'encryption_models.dart';
import 'noise_handshake.dart';

// ---------------------------------------------------------------------------
// EncryptionService
//
// Manages long-term X25519 key pairs, Noise_XK handshakes, and per-session
// XChaCha20-Poly1305 message encryption for Anchor's BLE P2P chat.
//
// SECURITY CONTRACT:
//   • Long-term private key is ONLY stored in flutter_secure_storage
//     (Android Keystore / iOS Secure Enclave-backed Keychain).
//   • Private key bytes are NEVER written to SharedPreferences, Drift, or logs.
//   • Session keys are ephemeral — in memory only.  Cleared on dispose() or
//     when a new handshake for the same peer overwrites the old session.
//   • Per-message nonces are randomly generated (24 bytes, XChaCha20 space).
//     A 24-byte random nonce has a birthday-bound collision probability of
//     ~2^−48 at 10^9 messages — negligible for our use case.
//   • All crypto is delegated to the `cryptography` package (dart:typed_data
//     based, constant-time implementations from libsodium on mobile).
//
// THREAT MODEL (cruise ship BLE environment):
//   • Passive eavesdropper capturing BLE advertisements → ciphertext only,
//     no plaintext leakage.
//   • Active MITM during handshake → blocked by Noise_XK authentication
//     (initiator authenticates responder via pre-known public key in msg1;
//      responder authenticates initiator via encrypted static key in msg3).
//   • Attacker who compromises session key → cannot decrypt past messages
//     (forward secrecy via per-session ephemeral DH).
//   • Physical device compromise → long-term private key in secure enclave,
//     not directly accessible to attacker.
// ---------------------------------------------------------------------------

const _kPrivateKeyStorageKey = 'anchor_e2ee_private_key_hex';
const _kPublicKeyStorageKey = 'anchor_e2ee_public_key_hex';

/// Timeout for a pending Noise handshake (peer must respond within 30 s).
const _kHandshakeTimeout = Duration(seconds: 30);

class EncryptionService {
  EncryptionService({
    required AppDatabase database,
    FlutterSecureStorage? secureStorage,
  })  : _database = database,
        _secureStorage = secureStorage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  final AppDatabase _database;
  final FlutterSecureStorage _secureStorage;
  final _xchacha = Xchacha20.poly1305Aead();
  final _x25519 = X25519();
  final _random = Random.secure();

  // Long-term key pair loaded once from secure storage.
  Uint8List? _localPrivateKey;
  Uint8List? _localPublicKey;

  // Active sessions: peerId → NoiseSession
  final Map<String, NoiseSession> _sessions = {};

  // Pending handshakes: peerId → PendingHandshake
  final Map<String, PendingHandshake> _pending = {};

  // Handshake timeout timers
  final Map<String, Timer> _handshakeTimers = {};

  // Stream: emits handshake messages that BleService must send to peers.
  final _outboundHandshakeController =
      StreamController<HandshakeMessageOut>.broadcast();
  Stream<HandshakeMessageOut> get outboundHandshakeStream =>
      _outboundHandshakeController.stream;

  // Stream: emits peerIds when a session is successfully established.
  final _sessionEstablishedController = StreamController<String>.broadcast();
  Stream<String> get sessionEstablishedStream =>
      _sessionEstablishedController.stream;

  // Stream: emits peerIds when a new (or updated) public key is stored.
  // ChatBloc listens to this to retry handshake initiation for the currently
  // open conversation when the peer's key arrives after conversation open.
  final _peerKeyStoredController = StreamController<String>.broadcast();
  Stream<String> get peerKeyStoredStream => _peerKeyStoredController.stream;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Must be called once at app start (after secure storage is available).
  Future<void> initialize() async {
    await _loadOrGenerateKeyPair();
    Logger.info(
        'EncryptionService initialised — pubkey: ${_publicKeyHex().substring(0, 12)}…',
        'E2EE');
  }

  Future<void> dispose() async {
    for (final t in _handshakeTimers.values) {
      t.cancel();
    }
    _handshakeTimers.clear();
    _sessions.clear();
    _pending.clear();
    await _outboundHandshakeController.close();
    await _sessionEstablishedController.close();
    await _peerKeyStoredController.close();
  }

  // ── Key management ────────────────────────────────────────────────────────

  /// Our 32-byte X25519 public key to embed in BLE profile (fff1).
  ///
  /// Returns null only during the very first call before [initialize()] completes.
  Uint8List? get localPublicKey => _localPublicKey;

  /// Returns the local public key as a hex string for JSON embedding.
  String? get localPublicKeyHex {
    final pk = _localPublicKey;
    if (pk == null) return null;
    return _bytesToHex(pk);
  }

  /// Store a peer's public key received from their BLE profile.
  ///
  /// Called by BleFacade._onProfileReadResult() when the peer's fff1
  /// characteristic JSON includes a `pk` field (32-byte X25519 key, hex).
  ///
  /// If the key changed (peer re-generated their keypair), any existing
  /// session for that peer is invalidated — they will need to re-handshake.
  Future<void> storePeerPublicKey(String peerId, String publicKeyHex) async {
    // Validate: must be exactly 32 bytes = 64 hex chars.
    if (publicKeyHex.length != 64) {
      Logger.warning(
          'Ignoring invalid peer public key for $peerId (wrong length)',
          'E2EE');
      return;
    }

    final existing = await _getPeerPublicKeyHex(peerId);
    if (existing == publicKeyHex) return; // unchanged

    if (existing != null) {
      // Key rotated — invalidate existing session and pending handshake.
      Logger.info(
          'Peer $peerId rotated their public key — invalidating session',
          'E2EE');
      _sessions.remove(peerId);
      _cancelPendingHandshake(peerId);
    }

    await _database.into(_database.peerPublicKeys).insertOnConflictUpdate(
          PeerPublicKeysCompanion.insert(
            peerId: peerId,
            publicKeyHex: publicKeyHex,
            receivedAt: DateTime.now(),
          ),
        );

    Logger.info(
        'Stored public key for peer $peerId (${publicKeyHex.substring(0, 8)}…) — handshake can now proceed',
        'E2EE');
    _peerKeyStoredController.add(peerId);
  }

  /// Whether we have a valid E2EE session with [peerId].
  bool hasSession(String peerId) => _sessions.containsKey(peerId);

  /// Whether a Noise handshake is in progress with [peerId].
  bool hasPendingHandshake(String peerId) => _pending.containsKey(peerId);

  /// Migrate a session or pending handshake from [oldPeerId] to [newPeerId].
  ///
  /// Called when a BLE Central UUID is resolved to the peer's Peripheral UUID
  /// (iOS Core Bluetooth assigns different UUIDs for Central vs Peripheral
  /// roles on the same physical device).  Also called on transport migration
  /// (e.g. BLE peer upgraded to LAN/Wi-Fi Aware).
  ///
  /// If a session was established under [oldPeerId] it is moved to [newPeerId]
  /// and [sessionEstablishedStream] fires with the new peerId so that ChatBloc
  /// can update [isE2eeActive].  Any pending (in-flight) handshake is also
  /// re-keyed so subsequent messages from [newPeerId] continue the exchange.
  void migratePeerId(String oldPeerId, String newPeerId) {
    if (oldPeerId == newPeerId && !_sessions.containsKey(newPeerId)) return;

    // Migrate established session.
    final session = _sessions.remove(oldPeerId);
    if (session != null) {
      _sessions[newPeerId] = NoiseSession(
        peerId: newPeerId,
        sendKey: session.sendKey,
        receiveKey: session.receiveKey,
        establishedAt: session.establishedAt,
      );
      Logger.info('Migrated E2EE session $oldPeerId → $newPeerId', 'E2EE');
      _sessionEstablishedController.add(newPeerId);
    }

    // Migrate pending handshake (covers the mid-handshake race where Central
    // UUID arrives before the Peripheral UUID is known).
    final pending = _pending.remove(oldPeerId);
    if (pending != null) {
      _pending[newPeerId] = PendingHandshake(
        peerId: newPeerId,
        role: pending.role,
        state: pending.state,
        localEphemeralPrivate: pending.localEphemeralPrivate,
        localEphemeralPublic: pending.localEphemeralPublic,
        remoteEphemeralPublic: pending.remoteEphemeralPublic,
        h: pending.h,
        ck: pending.ck,
        k: pending.k,
        n: pending.n,
        startedAt: pending.startedAt,
      );
      final timer = _handshakeTimers.remove(oldPeerId);
      if (timer != null) _handshakeTimers[newPeerId] = timer;
      Logger.info(
          'Migrated pending E2EE handshake $oldPeerId → $newPeerId', 'E2EE');
    }
  }

  // ── Handshake initiation ──────────────────────────────────────────────────

  /// Begin a Noise_XK handshake as INITIATOR.
  ///
  /// Call this when opening a chat with a peer if [hasSession(peerId)] is false.
  ///
  /// The result contains a [HandshakeMessageOut] that must be sent via BLE.
  /// The service will also emit subsequent messages on [outboundHandshakeStream]
  /// as the handshake progresses.
  ///
  /// Returns null if:
  ///   • We don't have the peer's public key yet (call after profile read).
  ///   • A handshake is already in progress.
  Future<HandshakeResult> initiateHandshake(String peerId) async {
    if (_pending.containsKey(peerId)) {
      return const HandshakeResult(error: 'Handshake already in progress');
    }

    final peerKeyHex = await _getPeerPublicKeyHex(peerId);
    if (peerKeyHex == null) {
      return const HandshakeResult(
          error: 'No public key for peer — cannot initiate E2EE');
    }

    final peerPublicKey = _hexToBytes(peerKeyHex);

    // Initialize Noise symmetric state
    final symState =
        await NoiseHandshakeProcessor.initSymmetricState(peerPublicKey);

    // Write Message 1: -> e, es
    final msg1Result = await NoiseHandshakeProcessor.writeMessage1(
      symState.h,
      symState.ck,
      null, // k starts null
      0,
      peerPublicKey,
    );

    final pending = PendingHandshake(
      peerId: peerId,
      role: NoiseRole.initiator,
      state: HandshakeState.awaitingMessage2,
      localEphemeralPrivate: msg1Result.localEphPriv,
      localEphemeralPublic: msg1Result.localEphPub,
      h: msg1Result.h,
      ck: msg1Result.ck,
      k: msg1Result.k,
      n: msg1Result.n,
      startedAt: DateTime.now(),
    );
    _pending[peerId] = pending;

    _startHandshakeTimeout(peerId);

    final outbound = HandshakeMessageOut(
      peerId: peerId,
      step: 1,
      payload: msg1Result.payload,
    );

    _outboundHandshakeController.add(outbound);
    Logger.info(
        'Noise_XK handshake initiated with $peerId (msg1, ${msg1Result.payload.length} bytes)',
        'E2EE');
    return HandshakeResult(messageToSend: outbound);
  }

  // ── Incoming handshake message handling ───────────────────────────────────

  /// Process an incoming handshake message from [peerId].
  ///
  /// Call this from BleFacade._handleReceivedMessage() when
  /// `type == "noise_hs"`.  Returns a [HandshakeResult] which may contain
  /// a reply message to send, or signal session establishment.
  Future<HandshakeResult> processHandshakeMessage(
    String peerId,
    int step,
    Uint8List payload,
  ) async {
    switch (step) {
      case 1:
        return _onMessage1Received(peerId, payload);
      case 2:
        return _onMessage2Received(peerId, payload);
      case 3:
        return _onMessage3Received(peerId, payload);
      default:
        return HandshakeResult(error: 'Unknown handshake step: $step');
    }
  }

  /// RESPONDER: received Message 1, must send Message 2.
  Future<HandshakeResult> _onMessage1Received(
    String peerId,
    Uint8List message1,
  ) async {
    if (_sessions.containsKey(peerId)) {
      // Already have a session — initiator may have reconnected.
      // Accept the re-handshake (gives forward secrecy for the new session).
      Logger.info('Peer $peerId re-initiating handshake — dropping old session',
          'E2EE');
      _sessions.remove(peerId);
    }

    // We are the responder: our static key is already known to them.
    // Initialize Noise state with OUR public key as the pre-message "s".
    final symState =
        await NoiseHandshakeProcessor.initSymmetricState(_localPublicKey!);

    try {
      // Read Message 1
      final readResult = await NoiseHandshakeProcessor.readMessage1(
        symState.h,
        symState.ck,
        null,
        0,
        message1,
        _localPrivateKey!,
      );

      // Write Message 2: <- e, ee
      final msg2Result = await NoiseHandshakeProcessor.writeMessage2(
        readResult.h,
        readResult.ck,
        readResult.k,
        readResult.n,
        readResult.initiatorEphPublic,
      );

      final pending = PendingHandshake(
        peerId: peerId,
        role: NoiseRole.responder,
        state: HandshakeState.awaitingMessage3,
        localEphemeralPrivate: msg2Result.localEphPriv,
        localEphemeralPublic: msg2Result.localEphPub,
        remoteEphemeralPublic: readResult.initiatorEphPublic,
        h: msg2Result.h,
        ck: msg2Result.ck,
        k: msg2Result.k,
        n: msg2Result.n,
        startedAt: DateTime.now(),
      );
      _pending[peerId] = pending;

      _startHandshakeTimeout(peerId);

      final outbound = HandshakeMessageOut(
        peerId: peerId,
        step: 2,
        payload: msg2Result.payload,
      );

      _outboundHandshakeController.add(outbound);
      Logger.info(
          'Noise_XK msg1 OK — sending msg2 to $peerId (${msg2Result.payload.length} bytes)',
          'E2EE');
      return HandshakeResult(messageToSend: outbound);
    } on NoiseHandshakeException catch (e) {
      _cancelPendingHandshake(peerId);
      Logger.error('Crypto operation failed for $peerId: $e', e, null, 'E2EE');
      return HandshakeResult(error: e.message);
    }
  }

  /// INITIATOR: received Message 2, must send Message 3.
  Future<HandshakeResult> _onMessage2Received(
    String peerId,
    Uint8List message2,
  ) async {
    final pending = _pending[peerId];
    if (pending == null || pending.role != NoiseRole.initiator) {
      return const HandshakeResult(
          error: 'Unexpected message 2 — not waiting as initiator');
    }
    if (pending.state != HandshakeState.awaitingMessage2) {
      return HandshakeResult(
          error: 'Wrong handshake state for msg2: ${pending.state}');
    }

    try {
      // Read Message 2
      final readResult = await NoiseHandshakeProcessor.readMessage2(
        pending.h,
        pending.ck,
        pending.k,
        pending.n,
        message2,
        pending.localEphemeralPrivate,
      );

      // Write Message 3: -> s, se
      final msg3Result = await NoiseHandshakeProcessor.writeMessage3(
        readResult.h,
        readResult.ck,
        readResult.k,
        readResult.n,
        _localPrivateKey!,
        _localPublicKey!,
        readResult.responderEphPublic,
      );

      // Split — derive session keys
      final keys = await NoiseHandshakeProcessor.split(msg3Result.ck);
      _establishSession(
        peerId,
        sendKey: keys.initiatorSend,
        receiveKey: keys.initiatorRecv,
      );

      final outbound = HandshakeMessageOut(
        peerId: peerId,
        step: 3,
        payload: msg3Result.payload,
      );

      _outboundHandshakeController.add(outbound);
      Logger.info(
          'Noise_XK complete (initiator) — session established with $peerId',
          'E2EE');
      return HandshakeResult(messageToSend: outbound, sessionEstablished: true);
    } on NoiseHandshakeException catch (e) {
      _cancelPendingHandshake(peerId);
      Logger.error('Crypto operation failed for $peerId: $e', e, null, 'E2EE');
      return HandshakeResult(error: e.message);
    }
  }

  /// RESPONDER: received Message 3 — handshake complete.
  Future<HandshakeResult> _onMessage3Received(
    String peerId,
    Uint8List message3,
  ) async {
    final pending = _pending[peerId];
    if (pending == null || pending.role != NoiseRole.responder) {
      return const HandshakeResult(
          error: 'Unexpected message 3 — not waiting as responder');
    }
    if (pending.state != HandshakeState.awaitingMessage3) {
      return HandshakeResult(
          error: 'Wrong handshake state for msg3: ${pending.state}');
    }

    try {
      final readResult = await NoiseHandshakeProcessor.readMessage3(
        pending.h,
        pending.ck,
        pending.k,
        pending.n,
        message3,
        pending.localEphemeralPrivate,
      );

      // Optionally persist the initiator's authenticated static public key
      // (we now know who they are; could store/verify against DB).
      final authenticatedPeerPub =
          _bytesToHex(readResult.initiatorStaticPublic);
      Logger.debug(
          'Authenticated initiator static key for $peerId: ${authenticatedPeerPub.substring(0, 12)}…',
          'E2EE');

      // Split — responder: initiatorSend = our recv, initiatorRecv = our send
      final keys = await NoiseHandshakeProcessor.split(readResult.ck);
      _establishSession(
        peerId,
        sendKey: keys.initiatorRecv, // responder's send = initiator's recv
        receiveKey: keys.initiatorSend, // responder's recv = initiator's send
      );

      Logger.info(
          'Noise_XK complete (responder) — session established with $peerId',
          'E2EE');
      return const HandshakeResult(sessionEstablished: true);
    } on NoiseHandshakeException catch (e) {
      _cancelPendingHandshake(peerId);
      Logger.error('Crypto operation failed for $peerId: $e', e, null, 'E2EE');
      return HandshakeResult(error: e.message);
    }
  }

  // ── Message encryption / decryption ──────────────────────────────────────

  /// Encrypt [plaintext] for [peerId].
  ///
  /// Returns null if no session exists (caller should send unencrypted with v:0).
  ///
  /// XChaCha20-Poly1305 with a random 24-byte nonce.
  /// Wire format: nonce (24 bytes) || ciphertext || tag (16 bytes)
  Future<EncryptedPayload?> encrypt(String peerId, Uint8List plaintext) async {
    final session = _sessions[peerId];
    if (session == null) return null;

    final nonce = _randomNonce(24);

    try {
      final box = await _xchacha.encrypt(
        plaintext,
        secretKey: SecretKey(session.sendKey),
        nonce: nonce,
      );
      final ciphertext = Uint8List(box.cipherText.length + box.mac.bytes.length)
        ..setRange(0, box.cipherText.length, box.cipherText)
        ..setRange(box.cipherText.length,
            box.cipherText.length + box.mac.bytes.length, box.mac.bytes);

      return EncryptedPayload(
          nonce: Uint8List.fromList(nonce), ciphertext: ciphertext);
    } catch (e) {
      Logger.error('Crypto operation failed for $peerId: $e', e, null, 'E2EE');
      return null;
    }
  }

  /// Decrypt an [EncryptedPayload] received from [peerId].
  ///
  /// Returns null if no session or decryption fails (caller should drop message).
  ///
  /// SECURITY: failed decryption (wrong key or tampered ciphertext) throws
  /// [SecretBoxAuthenticationError].  We catch it and return null — do NOT
  /// log the plaintext or nonce on failure.
  Future<Uint8List?> decrypt(String peerId, EncryptedPayload payload) async {
    final session = _sessions[peerId];
    if (session == null) return null;

    if (payload.ciphertext.length < 16) {
      Logger.warning('Ciphertext too short for peer $peerId', 'E2EE');
      return null;
    }

    final ctLen = payload.ciphertext.length - 16;
    final ciphertext = payload.ciphertext.sublist(0, ctLen);
    final tag = Mac(payload.ciphertext.sublist(ctLen));
    final box = SecretBox(ciphertext, nonce: payload.nonce, mac: tag);

    try {
      final plaintext = await _xchacha.decrypt(
        box,
        secretKey: SecretKey(session.receiveKey),
      );
      return Uint8List.fromList(plaintext);
    } on SecretBoxAuthenticationError {
      // SECURITY: authentication tag mismatch — ciphertext was tampered or
      // wrong session key.  Drop the message silently (no error leakage).
      Logger.warning(
          'Auth tag mismatch from peer $peerId — message dropped', 'E2EE');
      return null;
    } catch (e) {
      Logger.error('Crypto operation failed for $peerId: $e', e, null, 'E2EE');
      return null;
    }
  }

  // ── Photo bytes encryption / decryption ──────────────────────────────────

  /// Convenience wrappers for photo bytes (same algorithm as message text).
  ///
  /// PHOTO SECURITY NOTE: photo thumbnails and full-photo chunks are encrypted
  /// with the same session key as text messages.  The EncryptedPayload nonce
  /// is random per-call so encrypting the same photo twice yields different
  /// ciphertexts (no fingerprinting).
  Future<EncryptedPayload?> encryptBytes(String peerId, Uint8List bytes) =>
      encrypt(peerId, bytes);

  Future<Uint8List?> decryptBytes(String peerId, EncryptedPayload payload) =>
      decrypt(peerId, payload);

  // ── Wire encoding ─────────────────────────────────────────────────────────

  /// Build the JSON fields for an encrypted message.
  ///
  /// Usage:
  ///   final enc = await encryptionService.encrypt(peerId, utf8.encode(content));
  ///   final fields = encryptionService.encryptedFields(enc);
  ///   final json = {'type': 'message', 'messageId': id, ...fields};
  Map<String, dynamic> encryptedFields(EncryptedPayload payload) => {
        'v': 1,
        'n': base64.encode(payload.nonce),
        'c': base64.encode(payload.ciphertext),
      };

  /// Parse encrypted fields from a received JSON message.
  ///
  /// Returns null if the message is unencrypted (v == 0 or absent).
  EncryptedPayload? parseEncryptedFields(Map<String, dynamic> json) {
    final v = json['v'] as int?;
    if (v != 1) return null;
    final nStr = json['n'] as String?;
    final cStr = json['c'] as String?;
    if (nStr == null || cStr == null) return null;
    return EncryptedPayload(
      nonce: Uint8List.fromList(base64.decode(nStr)),
      ciphertext: Uint8List.fromList(base64.decode(cStr)),
    );
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  Future<void> _loadOrGenerateKeyPair() async {
    String? privHex = await _secureStorage.read(key: _kPrivateKeyStorageKey);
    String? pubHex = await _secureStorage.read(key: _kPublicKeyStorageKey);

    if (privHex == null || pubHex == null) {
      Logger.info('Generating new X25519 long-term key pair', 'E2EE');
      final kp = await _x25519.newKeyPair();
      final pub = await kp.extractPublicKey();
      final priv = await kp.extractPrivateKeyBytes();

      pubHex = _bytesToHex(Uint8List.fromList(pub.bytes));
      privHex = _bytesToHex(Uint8List.fromList(priv));

      // SECURITY: write private key ONLY to secure storage — never to DB or prefs.
      await _secureStorage.write(key: _kPrivateKeyStorageKey, value: privHex);
      await _secureStorage.write(key: _kPublicKeyStorageKey, value: pubHex);

      Logger.info('New X25519 key pair stored in secure storage', 'E2EE');
    }

    _localPrivateKey = _hexToBytes(privHex);
    _localPublicKey = _hexToBytes(pubHex);
  }

  Future<String?> _getPeerPublicKeyHex(String peerId) async {
    final row = await (_database.select(_database.peerPublicKeys)
          ..where((t) => t.peerId.equals(peerId)))
        .getSingleOrNull();
    return row?.publicKeyHex;
  }

  void _establishSession(
    String peerId, {
    required Uint8List sendKey,
    required Uint8List receiveKey,
  }) {
    _sessions[peerId] = NoiseSession(
      peerId: peerId,
      sendKey: sendKey,
      receiveKey: receiveKey,
      establishedAt: DateTime.now(),
    );
    _cancelPendingHandshake(peerId);
    _sessionEstablishedController.add(peerId);
  }

  void _cancelPendingHandshake(String peerId) {
    _pending.remove(peerId);
    _handshakeTimers.remove(peerId)?.cancel();
  }

  void _startHandshakeTimeout(String peerId) {
    _handshakeTimers.remove(peerId)?.cancel();
    _handshakeTimers[peerId] = Timer(_kHandshakeTimeout, () {
      if (_pending.containsKey(peerId)) {
        Logger.warning('Handshake timeout for peer $peerId', 'E2EE');
        _cancelPendingHandshake(peerId);
      }
    });
  }

  String _publicKeyHex() =>
      _localPublicKey != null ? _bytesToHex(_localPublicKey!) : '(none)';

  Uint8List _randomNonce(int length) {
    return Uint8List.fromList(
        List.generate(length, (_) => _random.nextInt(256)));
  }

  static String _bytesToHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}
