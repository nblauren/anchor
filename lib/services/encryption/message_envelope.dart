import 'dart:convert';
import 'dart:typed_data';

import 'package:anchor/services/encryption/encryption_models.dart';
import 'package:anchor/services/encryption/encryption_service.dart';

/// Shared message encryption/decryption logic used by ALL transports.
///
/// This is the SINGLE source of truth for:
///   - Building the inner plaintext envelope: `{"content":"...","reply_to_id":"..."}`
///   - Encrypting it → `{"v":1,"n":"<b64>","c":"<b64>"}`
///   - Decrypting and parsing the inner envelope back
///   - Encrypting/decrypting raw photo bytes (magic-byte wire format)
///
/// Both [TransportManager] (LAN/Wi-Fi Aware) and [BleFacade] (BLE) call
/// these functions to eliminate the encryption split-brain.

/// Magic byte prepended to encrypted photo bytes on the wire.
const kEncPhotoMagic = 0x01;

/// Nonce length for XChaCha20-Poly1305 (24 bytes).
const kNonceLen = 24;

/// Result of encrypting a message's content.
class EncryptedEnvelope {
  const EncryptedEnvelope({
    required this.nonce,
    required this.ciphertext,
  });

  final Uint8List nonce;
  final Uint8List ciphertext;

  /// JSON fields suitable for merging into any outer message JSON.
  Map<String, dynamic> toJsonFields() => {
        'v': 1,
        'n': base64.encode(nonce),
        'c': base64.encode(ciphertext),
      };
}

/// Result of decrypting a message's content.
class DecryptedMessageContent {
  const DecryptedMessageContent({
    required this.content,
    this.replyToId,
  });

  final String content;
  final String? replyToId;
}

// ==================== Message Content ====================

/// Encrypt message content + replyToId into an [EncryptedEnvelope].
///
/// Returns null if no session exists, service is unavailable, or encryption
/// fails. Callers should fall back to plaintext in that case.
///
/// The inner plaintext is: `{"content":"<text>","reply_to_id":"<id>"}`
Future<EncryptedEnvelope?> encryptMessageContent({
  required String peerId,
  required String content,
  required EncryptionService encService, String? replyToId,
}) async {
  if (!encService.hasSession(peerId)) return null;

  final inner = jsonEncode({
    'content': content,
    if (replyToId != null) 'reply_to_id': replyToId,
  });

  final result = await encService.encrypt(peerId, utf8.encode(inner));
  if (result == null) return null;

  return EncryptedEnvelope(
    nonce: result.nonce,
    ciphertext: result.ciphertext,
  );
}

/// Decrypt an encrypted envelope back into content + replyToId.
///
/// Accepts either:
///   - A JSON map with `v`, `n`, `c` keys (parsed from any transport), or
///   - A content string that is itself JSON `{"v":1,"n":"...","c":"..."}`
///
/// Returns null if decryption fails, format is wrong, or not encrypted.
Future<DecryptedMessageContent?> decryptMessageContent({
  required String peerId,
  required Map<String, dynamic> json,
  required EncryptionService encService,
}) async {
  final v = json['v'] as int?;
  if (v != 1) return null;

  final nStr = json['n'] as String?;
  final cStr = json['c'] as String?;
  if (nStr == null || cStr == null) return null;

  final encPayload = EncryptedPayload(
    nonce: Uint8List.fromList(base64.decode(nStr)),
    ciphertext: Uint8List.fromList(base64.decode(cStr)),
  );

  final plaintextBytes = await encService.decrypt(peerId, encPayload);
  if (plaintextBytes == null) return null;

  final inner = jsonDecode(utf8.decode(plaintextBytes)) as Map<String, dynamic>;
  return DecryptedMessageContent(
    content: inner['content'] as String? ?? '',
    replyToId: inner['reply_to_id'] as String?,
  );
}

/// Try to parse a content string as encrypted JSON `{"v":1,"n":"...","c":"..."}`.
///
/// Used by transports that receive encrypted content as a string in a JSON
/// field rather than as top-level fields.
Map<String, dynamic>? tryParseEncryptedContent(String content) {
  if (content.isEmpty || !content.startsWith('{')) return null;
  try {
    final parsed = jsonDecode(content) as Map<String, dynamic>;
    if (parsed['v'] == 1 && parsed['n'] != null && parsed['c'] != null) {
      return parsed;
    }
  } catch (_) {}
  return null;
}

// ==================== Photo Bytes ====================

/// Encrypt raw photo bytes for wire transmission.
///
/// Wire format: `[0x01 (magic)] + [24-byte nonce] + [ciphertext+tag]`
///
/// Returns the original bytes unchanged if no session exists or encryption
/// fails.
Future<Uint8List> encryptPhotoBytes({
  required String peerId,
  required Uint8List bytes,
  required EncryptionService encService,
}) async {
  if (!encService.hasSession(peerId)) return bytes;

  final encPayload = await encService.encryptBytes(peerId, bytes);
  if (encPayload == null) return bytes;

  return Uint8List.fromList(
      [kEncPhotoMagic, ...encPayload.nonce, ...encPayload.ciphertext],);
}

/// Decrypt photo bytes from wire format.
///
/// Detects the magic byte header. Returns the original bytes if not encrypted
/// or decryption fails.
Future<Uint8List> decryptPhotoBytes({
  required String peerId,
  required Uint8List bytes,
  required EncryptionService encService,
}) async {
  if (bytes.isEmpty || bytes[0] != kEncPhotoMagic) return bytes;

  // Minimum valid: 1 (magic) + 24 (nonce) + 16 (tag) = 41 bytes
  if (bytes.length < 41) return bytes;

  final encPayload = EncryptedPayload(
    nonce: bytes.sublist(1, 1 + kNonceLen),
    ciphertext: bytes.sublist(1 + kNonceLen),
  );

  final plaintext = await encService.decryptBytes(peerId, encPayload);
  return plaintext ?? bytes;
}
