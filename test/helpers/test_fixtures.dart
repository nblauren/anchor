import 'dart:typed_data';

import 'package:anchor/data/local_database/database.dart';
import 'package:anchor/features/discovery/bloc/discovery_state.dart' as ds;
import 'package:anchor/services/ble/ble_models.dart' as ble;

/// Factory methods for creating test data objects.
///
/// Reduces boilerplate in tests — call [makePeer], [makeEntry], etc.
/// instead of constructing full objects in every test.
class TestFixtures {
  TestFixtures._();

  // ── DiscoveredPeer (state model) ──────────────────────────────────────────

  /// Create a [ds.DiscoveredPeer] with sensible test defaults.
  static ds.DiscoveredPeer makePeer({
    String peerId = 'peer-1',
    String name = 'Alice',
    int? age = 30,
    String? bio = 'Test bio',
    int? position,
    String? interests,
    Uint8List? thumbnailData,
    int? rssi = -60,
    bool isBlocked = false,
    bool isRelayed = false,
    int hopCount = 0,
    int fullPhotoCount = 0,
    bool isOnline = true,
    DateTime? lastSeenAt,
  }) {
    return ds.DiscoveredPeer(
      peerId: peerId,
      name: name,
      age: age,
      bio: bio,
      position: position,
      interests: interests,
      thumbnailData: thumbnailData,
      lastSeenAt: lastSeenAt ?? DateTime.now(),
      rssi: rssi,
      isBlocked: isBlocked,
      isRelayed: isRelayed,
      hopCount: hopCount,
      fullPhotoCount: fullPhotoCount,
      isOnline: isOnline,
    );
  }

  /// Create a [DiscoveredPeerEntry] (Drift model) with sensible test defaults.
  static DiscoveredPeerEntry makeEntry({
    String peerId = 'peer-1',
    String name = 'Alice',
    int? age = 30,
    String? bio = 'Test bio',
    Uint8List? thumbnailData,
    int? rssi = -60,
    bool isBlocked = false,
    int? position,
    String? interests,
    DateTime? lastSeenAt,
  }) {
    return DiscoveredPeerEntry(
      peerId: peerId,
      name: name,
      age: age,
      bio: bio,
      thumbnailData: thumbnailData,
      lastSeenAt: lastSeenAt ?? DateTime.now(),
      rssi: rssi,
      isBlocked: isBlocked,
      position: position,
      interests: interests,
    );
  }

  // ── BLE model: DiscoveredPeer ─────────────────────────────────────────────

  /// Create a BLE [ble.DiscoveredPeer] with sensible test defaults.
  static ble.DiscoveredPeer makeBlePeer({
    String peerId = 'peer-1',
    String? userId,
    String name = 'Alice',
    int? age = 30,
    String? bio,
    int? position,
    String? interests,
    Uint8List? thumbnailBytes,
    int? rssi = -60,
    bool isRelayed = false,
    int hopCount = 0,
    int fullPhotoCount = 0,
    DateTime? timestamp,
  }) {
    return ble.DiscoveredPeer(
      peerId: peerId,
      userId: userId ?? peerId,
      name: name,
      age: age,
      bio: bio,
      position: position,
      interests: interests,
      thumbnailBytes: thumbnailBytes,
      rssi: rssi,
      timestamp: timestamp ?? DateTime.now(),
      isRelayed: isRelayed,
      hopCount: hopCount,
      fullPhotoCount: fullPhotoCount,
    );
  }

  // ── BLE messages ──────────────────────────────────────────────────────────

  static ble.ReceivedMessage makeMessage({
    String fromPeerId = 'peer-1',
    String messageId = 'msg-1',
    ble.MessageType type = ble.MessageType.text,
    String content = 'Hello',
    DateTime? timestamp,
  }) {
    return ble.ReceivedMessage(
      fromPeerId: fromPeerId,
      messageId: messageId,
      type: type,
      content: content,
      timestamp: timestamp ?? DateTime.now(),
    );
  }

  static ble.AnchorDropReceived makeAnchorDrop({
    String fromPeerId = 'peer-1',
    DateTime? timestamp,
  }) {
    return ble.AnchorDropReceived(
      fromPeerId: fromPeerId,
      timestamp: timestamp ?? DateTime.now(),
    );
  }

  // ── Thumbnail helpers ─────────────────────────────────────────────────────

  /// 1×1 gray JPEG pixel — valid JPEG, tiny, passes NSFW checks in tests.
  static Uint8List get tinyThumbnail {
    // Minimal valid JPEG (1x1 gray)
    return Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
      0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
      0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09,
      0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
      0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
      0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29,
      0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32,
      0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
      0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00,
      0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
      0x09, 0x0A, 0x0B, 0xFF, 0xC4, 0x00, 0xB5, 0x10, 0x00, 0x02, 0x01, 0x03,
      0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00, 0x00, 0x01, 0x7D,
      0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0xFB, 0xD5,
      0xFF, 0xD9,
    ]);
  }
}
