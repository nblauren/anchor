import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/utils/logger.dart';
import '../connection/connection_manager.dart';

/// Result of a profile read — emitted to the BLE service for peer updates.
class ProfileReadResult {
  const ProfileReadResult({
    required this.peerId,
    required this.profileJson,
    this.thumbnailExpectedSize,
    this.fullPhotoSizes,
    this.legacyPhotoSizes,
  });

  final String peerId;
  final Map<String, dynamic> profileJson;
  /// Expected total size of the primary thumbnail (from `thumbnail_size` field).
  final int? thumbnailExpectedSize;
  /// Per-photo sizes for fff4 full-photo set (from `full_photo_sizes` field).
  final List<int>? fullPhotoSizes;
  /// Legacy per-photo sizes for fff2 multi-photo delivery (from `photo_sizes` field).
  final List<int>? legacyPhotoSizes;
}

/// Handles GATT profile reads and thumbnail/photo assembly for discovered peers.
///
/// Extracted from the monolithic BLE service (now [BleFacade]) to:
/// - Separate profile reading from scan lifecycle
/// - Encapsulate thumbnail assembly buffer management
/// - Make thumbnail reassembly independently testable
/// - Fix the thumbnail race condition (chunks arriving before expected size is known)
///
/// The ProfileReader connects via [ConnectionManager], reads profile metadata
/// from fff1, and subscribes to fff2 (thumbnail) and fff4 (full photos)
/// notifications. Assembled thumbnails are emitted via callbacks.
class ProfileReader {
  ProfileReader({
    required CentralManager central,
    required ConnectionManager connectionManager,
    SharedPreferences? prefs,
  })  : _central = central,
        _connectionManager = connectionManager,
        _prefs = prefs;

  final CentralManager _central;
  final ConnectionManager _connectionManager;
  final SharedPreferences? _prefs;

  static const _prefsKey = 'thumbnail_received_sizes';

  // ==================== Throttling ====================

  /// Throttle profile re-reads to once per 30s per peer.
  final Map<String, DateTime> _lastProfileReadTime = {};

  // ==================== Thumbnail Assembly ====================

  /// Per-peer thumbnail assembly buffers (fff2 notification chunks).
  final Map<String, List<int>> _thumbnailBuffers = {};

  /// Per-peer expected total thumbnail size (set from profile JSON).
  final Map<String, int> _thumbnailExpectedSizes = {};

  /// Per-peer photo sizes for splitting old-format fff2 data (backward compat).
  final Map<String, List<int>> _peerPhotoSizes = {};

  /// Per-peer thumbnail checksums for dedup.
  final Map<String, int> _peerThumbnailChecksums = {};

  /// Per-peer size of the thumbnail we successfully received.
  /// Persisted to SharedPreferences so the skip-check survives app restarts.
  final Map<String, int> _peerThumbnailReceivedSizes = {};

  /// Peers for which we've already subscribed to fff5 (reverse-path) notifications.
  /// Prevents redundant subscribe calls on every 30s profile re-read cycle.
  final Set<String> _reversePathNotifySubscribed = {};

  /// Load previously persisted thumbnail sizes from SharedPreferences.
  /// Call once after construction (e.g. from BleFacade.initialize).
  void loadPersistedSizes() {
    final prefs = _prefs;
    if (prefs == null) return;
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in map.entries) {
        _peerThumbnailReceivedSizes[entry.key] = entry.value as int;
      }
      Logger.debug(
        'ProfileReader: Loaded ${map.length} persisted thumbnail sizes',
        'BLE',
      );
    } catch (_) {}
  }

  void _persistSizes() {
    final prefs = _prefs;
    if (prefs == null) return;
    prefs.setString(_prefsKey, jsonEncode(_peerThumbnailReceivedSizes));
  }

  // ==================== Full-Photo Assembly (fff4) ====================

  /// Per-peer full-photo assembly buffers.
  final Map<String, List<int>> _fullPhotoBuffers = {};

  /// Per-peer expected total full-photo size.
  final Map<String, int> _fullPhotoExpectedSizes = {};

  /// Per-peer photo sizes for splitting fff4 data.
  final Map<String, List<int>> _peerFullPhotoSizes = {};

  // ==================== Callbacks ====================

  /// Called when a profile is read from a peer.
  /// The BLE service uses this to update _visiblePeers and handle userId mapping.
  void Function(ProfileReadResult result)? onProfileRead;

  /// Called when a peer's primary thumbnail is fully assembled from fff2.
  void Function(String peerId, Uint8List thumbnailBytes)? onThumbnailAssembled;

  /// Called when a peer's multiple photos are assembled from fff2 (legacy format).
  void Function(String peerId, List<Uint8List> photos)? onPhotosAssembled;

  /// Called when a peer's full-photo set is assembled from fff4.
  void Function(String peerId, List<Uint8List> photos)? onFullPhotosAssembled;

  // ==================== Public API ====================

  /// Connect to a peer and read their profile + subscribe to thumbnail.
  ///
  /// Uses [ConnectionManager] for connection pooling and concurrency limits.
  /// Throttles re-reads to once per 30 seconds.
  Future<void> readProfile(String peerId, Peripheral peripheral) async {
    final conn = await _connectionManager.connect(peerId, peripheral);
    if (conn == null) return;

    // Connection succeeded — peer is genuinely alive.
    _connectionManager.touchPeer(peerId);

    // Throttled re-read check
    final lastRead = _lastProfileReadTime[peerId];
    final shouldReread = lastRead == null ||
        DateTime.now().difference(lastRead) > const Duration(seconds: 30);

    if (!shouldReread) return;
    _lastProfileReadTime[peerId] = DateTime.now();

    // Read profile metadata (small JSON: userId/name/age/bio)
    final profileChar = conn.profileChar;
    if (profileChar != null) {
      try {
        final data =
            await _central.readCharacteristic(conn.peripheral, profileChar);
        Logger.info(
          'ProfileReader: Profile char read → ${data.length}B from $peerId',
          'BLE',
        );
        _handleProfileData(peerId, data);
      } catch (e) {
        Logger.warning(
            'ProfileReader: Profile read failed for $peerId: $e', 'BLE');
      }
    } else {
      Logger.warning(
        'ProfileReader: No profile char cached for $peerId — skip read',
        'BLE',
      );
    }

    // Subscribe to thumbnail char notifications AFTER the profile read.
    // Skip if we already have the thumbnail and the server reports the same size
    // (peer hasn't changed their photo). This avoids pushing 60-70KB over BLE
    // on every 30s re-read cycle.
    final expectedSize = _thumbnailExpectedSizes[peerId];
    final alreadyHave = expectedSize != null &&
        _peerThumbnailReceivedSizes[peerId] == expectedSize;

    final thumbnailChar = conn.thumbnailChar;
    if (thumbnailChar != null && !alreadyHave) {
      try {
        // Clear any stale buffer so we accumulate a fresh delivery.
        _thumbnailBuffers.remove(peerId);

        try {
          await _central.setCharacteristicNotifyState(
            conn.peripheral,
            thumbnailChar,
            state: false,
          );
        } catch (_) {}

        await _central.setCharacteristicNotifyState(
          conn.peripheral,
          thumbnailChar,
          state: true,
        );
        Logger.info(
          'ProfileReader: Subscribed to thumbnail notifications from $peerId',
          'BLE',
        );
      } catch (e) {
        Logger.warning(
          'ProfileReader: Failed to subscribe to thumbnail from $peerId: $e',
          'BLE',
        );
      }
    } else if (alreadyHave) {
      Logger.debug(
        'ProfileReader: Thumbnail already cached for $peerId, skipping re-fetch',
        'BLE',
      );
    } else {
      Logger.warning(
        'ProfileReader: No thumbnail char found for $peerId',
        'BLE',
      );
    }

    // Subscribe to fff5 (reverse-path) notifications for cross-platform responses.
    // This enables cross-platform E2EE handshakes: when the remote Peripheral
    // needs to push a handshake response back to us (the Central), it uses
    // fff5 GATT notifications. Only subscribe once per connection.
    final reversePathChar = conn.reversePathChar;
    if (reversePathChar != null && !_reversePathNotifySubscribed.contains(peerId)) {
      try {
        await _central.setCharacteristicNotifyState(
          conn.peripheral,
          reversePathChar,
          state: true,
        );
        _reversePathNotifySubscribed.add(peerId);
        Logger.info(
          'ProfileReader: Subscribed to fff5 notifications from $peerId',
          'BLE',
        );
      } catch (e) {
        Logger.debug(
          'ProfileReader: fff5 notify subscribe failed for $peerId: $e',
          'BLE',
        );
      }
    }
  }

  /// Subscribe to fff4 (full-photos) for on-demand profile photo fetching.
  Future<bool> fetchFullProfilePhotos(String peerId) async {
    final conn = _connectionManager.getConnection(peerId);
    if (conn == null) {
      Logger.info(
          'ProfileReader: fetchFullProfilePhotos — peer $peerId not connected',
          'BLE');
      return false;
    }

    final fullPhotosChar = conn.fullPhotosChar;
    if (fullPhotosChar == null) {
      Logger.info(
          'ProfileReader: fetchFullProfilePhotos — no fff4 char for $peerId',
          'BLE');
      return false;
    }

    final photoSizes = _peerFullPhotoSizes[peerId];
    if (photoSizes == null || photoSizes.isEmpty) {
      Logger.info(
          'ProfileReader: fetchFullProfilePhotos — no photo sizes for $peerId',
          'BLE');
      return false;
    }

    final totalExpected = photoSizes.reduce((a, b) => a + b);
    _fullPhotoExpectedSizes[peerId] = totalExpected;
    _fullPhotoBuffers[peerId] = [];

    try {
      try {
        await _central.setCharacteristicNotifyState(
            conn.peripheral, fullPhotosChar,
            state: false);
      } catch (_) {}

      await _central.setCharacteristicNotifyState(
          conn.peripheral, fullPhotosChar,
          state: true);

      Logger.info(
        'ProfileReader: Subscribed to fff4 for $peerId '
        '(expecting ${totalExpected}B, ${photoSizes.length} photos)',
        'BLE',
      );
      return true;
    } catch (e) {
      Logger.error(
          'ProfileReader: fetchFullProfilePhotos failed for $peerId', e,
          null, 'BLE');
      _fullPhotoBuffers.remove(peerId);
      _fullPhotoExpectedSizes.remove(peerId);
      return false;
    }
  }

  // ==================== Notification Handlers ====================

  /// Handle an incoming fff2 (thumbnail) notification chunk on the CENTRAL side.
  /// Call this from the central.characteristicNotified listener.
  void handleThumbnailChunk(String peerId, List<int> value) {
    final buffer = _thumbnailBuffers[peerId] ??= [];
    final expected = _thumbnailExpectedSizes[peerId];

    buffer.addAll(value);

    if (expected == null && buffer.length > 32000) {
      Logger.warning(
          'ProfileReader: Thumbnail chunks without known size — possible race',
          'BLE');
    }

    if (expected != null && buffer.length >= expected) {
      final allBytes = Uint8List.fromList(buffer.sublist(0, expected));
      _thumbnailBuffers.remove(peerId);
      _thumbnailExpectedSizes.remove(peerId);
      _splitAndEmitPhotos(peerId, allBytes);
    }
  }

  /// Handle an incoming fff4 (full-photos) notification chunk on the CENTRAL side.
  void handleFullPhotosChunk(String peerId, List<int> value) {
    final buffer = _fullPhotoBuffers[peerId] ??= [];
    final expected = _fullPhotoExpectedSizes[peerId];

    buffer.addAll(value);

    if (expected != null && buffer.length >= expected) {
      final allBytes = Uint8List.fromList(buffer.sublist(0, expected));
      _fullPhotoBuffers.remove(peerId);
      _fullPhotoExpectedSizes.remove(peerId);
      _splitAndEmitFullPhotos(peerId, allBytes);
    }
  }

  // ==================== Cleanup ====================

  /// Clear all state for a specific peer.
  void clearPeer(String peerId) {
    _lastProfileReadTime.remove(peerId);
    _thumbnailBuffers.remove(peerId);
    _thumbnailExpectedSizes.remove(peerId);
    // _peerThumbnailChecksums and _peerThumbnailReceivedSizes are intentionally
    // kept across disconnects. If the peer reconnects with the same peerId and
    // an unchanged thumbnail_size, we skip the re-fetch. If they changed their
    // photo the size will differ and alreadyHave will be false.
    _peerPhotoSizes.remove(peerId);
    _fullPhotoBuffers.remove(peerId);
    _fullPhotoExpectedSizes.remove(peerId);
    _peerFullPhotoSizes.remove(peerId);
  }

  /// Clear all state.
  void clear() {
    _lastProfileReadTime.clear();
    _thumbnailBuffers.clear();
    _thumbnailExpectedSizes.clear();
    _peerThumbnailChecksums.clear();
    _peerThumbnailReceivedSizes.clear();
    _peerPhotoSizes.clear();
    _fullPhotoBuffers.clear();
    _fullPhotoExpectedSizes.clear();
    _peerFullPhotoSizes.clear();
  }

  // ==================== Internal ====================

  void _handleProfileData(String peerId, Uint8List data) {
    try {
      final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;

      // Parse thumbnail/photo size metadata
      int? thumbnailExpectedSize;
      List<int>? fullPhotoSizes;
      List<int>? legacyPhotoSizes;

      final rawPhotoSizes = json['photo_sizes'] as List?;
      if (rawPhotoSizes != null && rawPhotoSizes.isNotEmpty) {
        // Legacy: old peers broadcast all thumbnails via fff2
        legacyPhotoSizes = rawPhotoSizes.cast<int>();
        _peerPhotoSizes[peerId] = legacyPhotoSizes;
        final totalExpected = legacyPhotoSizes.reduce((a, b) => a + b);
        _thumbnailExpectedSizes[peerId] = totalExpected;
        final buffer = _thumbnailBuffers.putIfAbsent(peerId, () => []);
        Logger.info(
          'ProfileReader: [legacy] Expecting ${totalExpected}B from $peerId '
          '(${legacyPhotoSizes.length} photos, ${buffer.length}B buffered)',
          'BLE',
        );
        if (buffer.length >= totalExpected) {
          final allBytes =
              Uint8List.fromList(buffer.sublist(0, totalExpected));
          _thumbnailBuffers.remove(peerId);
          _thumbnailExpectedSizes.remove(peerId);
          _splitAndEmitPhotos(peerId, allBytes);
        }
      } else {
        // New protocol: fff2 carries primary thumbnail only
        final thumbSize = json['thumbnail_size'] as int?;
        if (thumbSize != null && thumbSize > 0) {
          thumbnailExpectedSize = thumbSize;
          _peerPhotoSizes.remove(peerId);
          _thumbnailExpectedSizes[peerId] = thumbSize;
          final buffer = _thumbnailBuffers.putIfAbsent(peerId, () => []);
          Logger.info(
            'ProfileReader: Expecting ${thumbSize}B thumbnail from $peerId '
            '(${buffer.length}B already buffered)',
            'BLE',
          );
          if (buffer.length >= thumbSize) {
            final allBytes = Uint8List.fromList(buffer.sublist(0, thumbSize));
            _thumbnailBuffers.remove(peerId);
            _thumbnailExpectedSizes.remove(peerId);
            _emitSingleThumbnail(peerId, allBytes);
          }
        }

        // fff4 full-photo metadata
        final photoCount = json['photo_count'] as int? ?? 0;
        final rawFullPhotoSizes = json['full_photo_sizes'] as List?;
        if (photoCount > 1 &&
            rawFullPhotoSizes != null &&
            rawFullPhotoSizes.isNotEmpty) {
          fullPhotoSizes = rawFullPhotoSizes.cast<int>();
          _peerFullPhotoSizes[peerId] = fullPhotoSizes;
          Logger.info(
            'ProfileReader: Peer $peerId has $photoCount photos via fff4',
            'BLE',
          );
        }
      }

      // Emit the profile read result to the BLE service
      onProfileRead?.call(ProfileReadResult(
        peerId: peerId,
        profileJson: json,
        thumbnailExpectedSize: thumbnailExpectedSize,
        fullPhotoSizes: fullPhotoSizes,
        legacyPhotoSizes: legacyPhotoSizes,
      ));
    } catch (e) {
      Logger.warning('ProfileReader: Profile decode failed for $peerId', 'BLE');
    }
  }

  /// Split reassembled thumbnail buffer by photo sizes and emit.
  void _splitAndEmitPhotos(String peerId, Uint8List allBytes) {
    final photoSizes = _peerPhotoSizes.remove(peerId);

    if (photoSizes != null && photoSizes.length > 1) {
      final photos = <Uint8List>[];
      var offset = 0;
      for (final size in photoSizes) {
        if (offset + size <= allBytes.length) {
          photos.add(allBytes.sublist(offset, offset + size));
          offset += size;
        }
      }
      if (photos.isNotEmpty) {
        onPhotosAssembled?.call(peerId, photos);
        return;
      }
    }

    // Single photo or size-split failed
    _emitSingleThumbnail(peerId, allBytes);
  }

  void _emitSingleThumbnail(String peerId, Uint8List thumbnailBytes) {
    // Skip update if thumbnail checksum is unchanged
    final newChecksum = _thumbnailChecksum(thumbnailBytes);
    final oldChecksum = _peerThumbnailChecksums[peerId];
    if (oldChecksum != null && oldChecksum == newChecksum) {
      Logger.debug(
        'ProfileReader: Thumbnail unchanged for $peerId, skipping',
        'BLE',
      );
      return;
    }
    _peerThumbnailChecksums[peerId] = newChecksum;
    _peerThumbnailReceivedSizes[peerId] = thumbnailBytes.length;
    _persistSizes();
    onThumbnailAssembled?.call(peerId, thumbnailBytes);
  }

  /// Split fff4 data and emit full-photos.
  void _splitAndEmitFullPhotos(String peerId, Uint8List allBytes) {
    final photoSizes = _peerFullPhotoSizes.remove(peerId);

    List<Uint8List> photos;
    if (photoSizes != null && photoSizes.length > 1) {
      photos = [];
      var offset = 0;
      for (final size in photoSizes) {
        if (offset + size <= allBytes.length) {
          photos.add(allBytes.sublist(offset, offset + size));
          offset += size;
        }
      }
      if (photos.isEmpty) photos = [allBytes];
    } else {
      photos = [allBytes];
    }

    onFullPhotosAssembled?.call(peerId, photos);
  }

  /// FNV-1a 32-bit hash for fast thumbnail dedup.
  static int _thumbnailChecksum(Uint8List bytes) {
    int hash = 0x811c9dc5;
    for (int i = 0; i < bytes.length; i++) {
      hash ^= bytes[i];
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }
}
