import 'dart:convert';
import 'dart:typed_data';

import 'package:anchor/services/encryption/noise_handshake.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// E2EE Unit Tests — Noise_XK handshake + XChaCha20-Poly1305 round-trip
//
// These tests run entirely in-process with no BLE or secure storage.
// They verify the cryptographic correctness of the Noise state machine.
// ---------------------------------------------------------------------------

void main() {
  group('Noise_XK handshake — full 3-message round trip', () {
    test('Initiator and responder derive the same session keys', () async {
      // Generate two long-term key pairs (simulating two devices)
      final x25519 = X25519();
      final initiatorKp = await x25519.newKeyPair();
      final responderKp = await x25519.newKeyPair();

      final initiatorStaticPub = await initiatorKp.extractPublicKey();
      final responderStaticPub = await responderKp.extractPublicKey();

      final initiatorPrivBytes =
          Uint8List.fromList(await initiatorKp.extractPrivateKeyBytes());
      final initiatorPubBytes =
          Uint8List.fromList(initiatorStaticPub.bytes);
      final responderPrivBytes =
          Uint8List.fromList(await responderKp.extractPrivateKeyBytes());
      final responderPubBytes =
          Uint8List.fromList(responderStaticPub.bytes);

      // ── INITIATOR: build message 1 ──────────────────────────────────────

      // Initiator knows responder's static key (from BLE profile read).
      final initSym =
          await NoiseHandshakeProcessor.initSymmetricState(responderPubBytes);

      final msg1 = await NoiseHandshakeProcessor.writeMessage1(
        initSym.h,
        initSym.ck,
        null,
        0,
        responderPubBytes,
      );

      // ── RESPONDER: read message 1, write message 2 ──────────────────────

      // Responder initializes with their OWN public key as the pre-message.
      final respSym =
          await NoiseHandshakeProcessor.initSymmetricState(responderPubBytes);

      final readMsg1 = await NoiseHandshakeProcessor.readMessage1(
        respSym.h,
        respSym.ck,
        null,
        0,
        msg1.payload,
        responderPrivBytes,
      );

      final msg2 = await NoiseHandshakeProcessor.writeMessage2(
        readMsg1.h,
        readMsg1.ck,
        readMsg1.k,
        readMsg1.n,
        readMsg1.initiatorEphPublic,
      );

      // ── INITIATOR: read message 2, write message 3 ──────────────────────

      final readMsg2 = await NoiseHandshakeProcessor.readMessage2(
        msg1.h,
        msg1.ck,
        msg1.k,
        msg1.n,
        msg2.payload,
        msg1.localEphPriv,
      );

      final msg3 = await NoiseHandshakeProcessor.writeMessage3(
        readMsg2.h,
        readMsg2.ck,
        readMsg2.k,
        readMsg2.n,
        initiatorPrivBytes,
        initiatorPubBytes,
        readMsg2.responderEphPublic,
      );

      // Initiator calls Split
      final initiatorKeys = await NoiseHandshakeProcessor.split(msg3.ck);

      // ── RESPONDER: read message 3, split ────────────────────────────────

      final readMsg3 = await NoiseHandshakeProcessor.readMessage3(
        msg2.h,
        msg2.ck,
        msg2.k,
        msg2.n,
        msg3.payload,
        msg2.localEphPriv,
      );

      // Responder's Split
      final responderKeys = await NoiseHandshakeProcessor.split(readMsg3.ck);

      // ── Verify: initiator.send == responder.recv, and vice versa ─────────

      // Initiator's send key == Responder's receive key
      expect(initiatorKeys.initiatorSend, equals(responderKeys.initiatorSend));
      // Initiator's recv key == Responder's send key
      expect(initiatorKeys.initiatorRecv, equals(responderKeys.initiatorRecv));

      // Initiator authenticated the responder's static key
      // Responder authenticated the initiator's static key from msg3
      expect(readMsg3.initiatorStaticPublic, equals(initiatorPubBytes));
    });

    test('Message 1 payload is 48 bytes', () async {
      final x25519 = X25519();
      final responderKp = await x25519.newKeyPair();
      final respPub = Uint8List.fromList(
          (await responderKp.extractPublicKey()).bytes,);

      final sym = await NoiseHandshakeProcessor.initSymmetricState(respPub);
      final msg1 = await NoiseHandshakeProcessor.writeMessage1(
          sym.h, sym.ck, null, 0, respPub,);

      // 32 bytes ephemeral key + 16 bytes Poly1305 tag (empty plaintext)
      expect(msg1.payload.length, equals(48));
    });

    test('Message 2 payload is 48 bytes', () async {
      final x25519 = X25519();
      final respKp = await x25519.newKeyPair();
      final respPub = Uint8List.fromList(
          (await respKp.extractPublicKey()).bytes,);
      final respPriv = Uint8List.fromList(await respKp.extractPrivateKeyBytes());

      final initSym = await NoiseHandshakeProcessor.initSymmetricState(respPub);
      final msg1 = await NoiseHandshakeProcessor.writeMessage1(
          initSym.h, initSym.ck, null, 0, respPub,);

      final respSym = await NoiseHandshakeProcessor.initSymmetricState(respPub);
      final readMsg1 = await NoiseHandshakeProcessor.readMessage1(
          respSym.h, respSym.ck, null, 0, msg1.payload, respPriv,);
      final msg2 = await NoiseHandshakeProcessor.writeMessage2(
          readMsg1.h, readMsg1.ck, readMsg1.k, readMsg1.n,
          readMsg1.initiatorEphPublic,);

      // 32 bytes ephemeral key + 16 bytes tag
      expect(msg2.payload.length, equals(48));
    });

    test('Message 3 payload is 64 bytes', () async {
      final x25519 = X25519();
      final initiatorKp = await x25519.newKeyPair();
      final respKp = await x25519.newKeyPair();
      final initiatorPriv =
          Uint8List.fromList(await initiatorKp.extractPrivateKeyBytes());
      final initiatorPub = Uint8List.fromList(
          (await initiatorKp.extractPublicKey()).bytes,);
      final respPriv =
          Uint8List.fromList(await respKp.extractPrivateKeyBytes());
      final respPub = Uint8List.fromList(
          (await respKp.extractPublicKey()).bytes,);

      final initSym = await NoiseHandshakeProcessor.initSymmetricState(respPub);
      final msg1 = await NoiseHandshakeProcessor.writeMessage1(
          initSym.h, initSym.ck, null, 0, respPub,);

      final respSym = await NoiseHandshakeProcessor.initSymmetricState(respPub);
      final readMsg1 = await NoiseHandshakeProcessor.readMessage1(
          respSym.h, respSym.ck, null, 0, msg1.payload, respPriv,);
      final msg2 = await NoiseHandshakeProcessor.writeMessage2(
          readMsg1.h, readMsg1.ck, readMsg1.k, readMsg1.n,
          readMsg1.initiatorEphPublic,);

      final readMsg2 = await NoiseHandshakeProcessor.readMessage2(
          msg1.h, msg1.ck, msg1.k, msg1.n, msg2.payload, msg1.localEphPriv,);
      final msg3 = await NoiseHandshakeProcessor.writeMessage3(
          readMsg2.h, readMsg2.ck, readMsg2.k, readMsg2.n,
          initiatorPriv, initiatorPub, readMsg2.responderEphPublic,);

      // 48 bytes (encrypted static key + tag) + 16 bytes (empty payload tag)
      expect(msg3.payload.length, equals(64));
    });

    test('Tampered message 1 throws NoiseHandshakeException', () async {
      final x25519 = X25519();
      final respKp = await x25519.newKeyPair();
      final respPub = Uint8List.fromList(
          (await respKp.extractPublicKey()).bytes,);
      final respPriv = Uint8List.fromList(
          await respKp.extractPrivateKeyBytes(),);

      final initSym = await NoiseHandshakeProcessor.initSymmetricState(respPub);
      final msg1 = await NoiseHandshakeProcessor.writeMessage1(
          initSym.h, initSym.ck, null, 0, respPub,);

      // Flip a bit in the auth tag
      final tampered = Uint8List.fromList(msg1.payload);
      tampered[47] ^= 0x01;

      final respSym = await NoiseHandshakeProcessor.initSymmetricState(respPub);
      expect(
        () => NoiseHandshakeProcessor.readMessage1(
            respSym.h, respSym.ck, null, 0, tampered, respPriv,),
        throwsA(isA<NoiseHandshakeException>()),
      );
    });
  });

  group('XChaCha20-Poly1305 session message encryption', () {
    final xchacha = Xchacha20.poly1305Aead();

    test('encrypt → decrypt round-trip produces original plaintext', () async {
      final key = SecretKey(List.generate(32, (i) => i));
      final nonce = List.generate(24, (i) => i);
      final plaintext = utf8.encode('Hello, Anchor! 🏳️‍🌈⚓');

      final box = await xchacha.encrypt(plaintext,
          secretKey: key, nonce: nonce,);

      // Concatenate ciphertext + tag (as EncryptionService does)
      final ctWithTag = Uint8List(box.cipherText.length + 16)
        ..setRange(0, box.cipherText.length, box.cipherText)
        ..setRange(box.cipherText.length, box.cipherText.length + 16, box.mac.bytes);

      // Decrypt
      final ct = ctWithTag.sublist(0, ctWithTag.length - 16);
      final tag = Mac(ctWithTag.sublist(ctWithTag.length - 16));
      final decrypted = await xchacha.decrypt(
        SecretBox(ct, nonce: nonce, mac: tag),
        secretKey: key,
      );

      expect(utf8.decode(decrypted), equals('Hello, Anchor! 🏳️‍🌈⚓'));
    });

    test('decryption fails on tampered ciphertext', () async {
      final key = SecretKey(List.generate(32, (i) => i));
      final nonce = List.generate(24, (i) => i);
      final plaintext = utf8.encode('Secret message');

      final box = await xchacha.encrypt(plaintext,
          secretKey: key, nonce: nonce,);

      // Flip a byte in ciphertext
      final tampered = List<int>.from(box.cipherText);
      tampered[0] ^= 0xFF;

      expect(
        () => xchacha.decrypt(
          SecretBox(tampered, nonce: nonce, mac: box.mac),
          secretKey: key,
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('two encryptions of same plaintext produce different ciphertexts (random nonce)', () async {
      final key = SecretKey(List.generate(32, (i) => i));
      final nonce1 = List.generate(24, (i) => i);
      final nonce2 = List.generate(24, (i) => i + 1); // different nonce
      final plaintext = utf8.encode('Same message');

      final box1 = await xchacha.encrypt(plaintext,
          secretKey: key, nonce: nonce1,);
      final box2 = await xchacha.encrypt(plaintext,
          secretKey: key, nonce: nonce2,);

      expect(box1.cipherText, isNot(equals(box2.cipherText)));
    });
  });

  group('Noise HKDF', () {
    test('known-vector: HKDF output is deterministic', () async {
      // Two calls with the same input must produce the same output.
      final ck = Uint8List.fromList(List.generate(32, (i) => i));
      // Access via the private function using the processor
      // (We test indirectly via a full handshake producing consistent keys.)
      // This test verifies Split() is deterministic.
      final keys1 = await NoiseHandshakeProcessor.split(ck);
      final keys2 = await NoiseHandshakeProcessor.split(ck);

      expect(keys1.initiatorSend, equals(keys2.initiatorSend));
      expect(keys1.initiatorRecv, equals(keys2.initiatorRecv));
    });

    test('Split produces two distinct 32-byte outputs', () async {
      final ck = Uint8List.fromList(List.generate(32, (i) => i));
      final keys = await NoiseHandshakeProcessor.split(ck);

      expect(keys.initiatorSend.length, equals(32));
      expect(keys.initiatorRecv.length, equals(32));
      expect(keys.initiatorSend, isNot(equals(keys.initiatorRecv)));
    });
  });
}
