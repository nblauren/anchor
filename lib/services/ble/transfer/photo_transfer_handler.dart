import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:anchor/core/constants/message_keys.dart';
import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/services/ble/ble_config.dart';
import 'package:anchor/services/ble/ble_models.dart';
import 'package:anchor/services/ble/connection/connection_manager.dart';
import 'package:anchor/services/ble/connection/peer_connection.dart';
import 'package:anchor/services/ble/gatt/gatt_write_queue.dart';
import 'package:anchor/services/ble/photo_chunker.dart';
import 'package:anchor/services/encryption/encryption.dart';

/// Handles all BLE photo transfer: sending photos/previews/requests and
/// receiving binary photo chunks, preview thumbnails, and photo requests.
///
/// Extracted from the monolithic BLE service (now [BleFacade]) to:
/// - Separate photo transfer protocol from connection/scan lifecycle
/// - Encapsulate incoming transfer state (reassembler, chunk buffers)
/// - Make photo transfer independently testable
/// - Isolate the binary protocol (0x02/0x03 markers) in one place
class PhotoTransferHandler {
  PhotoTransferHandler({
    required ConnectionManager connectionManager,
    required GattWriteQueue writeQueue,
    required BleConfig config,
    EncryptionService? encryptionService,
  })  : _connectionManager = connectionManager,
        _writeQueue = writeQueue,
        _config = config,
        _encryptionService = encryptionService,
        _photoReassembler = PhotoReassembler();

  final ConnectionManager _connectionManager;
  final GattWriteQueue _writeQueue;
  final BleConfig _config;
  final EncryptionService? _encryptionService;
  final PhotoReassembler _photoReassembler;

  // ==================== State ====================

  /// Track cancelled transfers so in-flight sends stop early.
  final Set<String> _cancelledTransfers = {};

  /// Active incoming binary photo transfers (keyed by resolved peerId).
  final Map<String, _IncomingPhotoTransfer> _incomingPhotoTransfers = {};

  /// Timers that expire stale incoming transfers. If no chunk arrives within
  /// [_receiveTimeout], the partial transfer is discarded and a failure is
  /// emitted. Without this, a dropped connection mid-transfer would leave the
  /// transfer hanging forever.
  final Map<String, Timer> _receiveTimeoutTimers = {};

  /// Base timeout per chunk — scales with remaining chunks.
  /// Small transfers (< 10 chunks): 15s per chunk.
  /// Large transfers (100+ chunks): 30s per chunk (BLE congestion likely).
  static Duration _receiveTimeoutFor(int remainingChunks) {
    if (remainingChunks > 50) return const Duration(seconds: 30);
    if (remainingChunks > 10) return const Duration(seconds: 20);
    return const Duration(seconds: 15);
  }

  /// Maps raw Central UUID → resolved peerId for binary chunk routing.
  /// On iOS, the Central UUID ≠ Peripheral UUID for the same device.
  /// `photo_start` JSON arrives with a resolved `fromPeerId` (via sender_id),
  /// but binary chunks (0x02/0x03) also carry the first 8 bytes of the
  /// sender's userId as a secondary identification mechanism.
  final Map<String, String> _centralToResolvedId = {};

  /// Maps sender tag (first 8 bytes of userId) → resolved peerId.
  /// Used as a fallback when Central UUID lookup fails (iOS UUID mismatch).
  final Map<String, String> _senderTagToResolvedId = {};

  /// Active incoming thumbnail transfers for the photo-preview consent flow.
  final Map<String, _IncomingThumbnailTransfer> _incomingThumbnailTransfers =
      {};

  // ==================== Callbacks ====================

  /// Returns this device's own app userId.
  String Function()? getOwnUserId;

  /// Called when photo transfer progress changes (send or receive side).
  void Function(PhotoTransferProgress progress)? onProgress;

  /// Called when a complete photo is received (binary or legacy chunk).
  void Function(ReceivedPhoto photo)? onPhotoReceived;

  /// Called when a complete photo preview is received.
  void Function(ReceivedPhotoPreview preview)? onPhotoPreviewReceived;

  /// Called when a photo request is received.
  void Function(ReceivedPhotoRequest request)? onPhotoRequestReceived;

  // ==================== Send: Photo ====================

  /// Send a photo via the binary two-phase protocol.
  ///
  /// Phase 1: JSON `photo_start` metadata.
  /// Phase 2: Binary chunks with `[0x02][uint16 index][raw data]`.
  Future<bool> sendPhoto(
    String peerId,
    Uint8List photoData,
    String messageId, {
    String? photoId,
  }) async {
    if (photoData.length > _config.maxPhotoSize) {
      Logger.error(
        'PhotoTransfer: Photo too large '
        '(${photoData.length} > ${_config.maxPhotoSize})',
        null,
        null,
        'BLE',
      );
      return false;
    }

    Logger.info(
      'PhotoTransfer: Starting transfer $messageId '
      '(${photoData.length}B) to ${peerId.substring(0, min(8, peerId.length))}',
      'BLE',
    );

    try {
      final conn = await _ensureConnection(peerId);
      if (conn == null) {
        _emitProgress(messageId, peerId, 0, PhotoTransferStatus.failed,
            errorMessage: 'Peer not reachable',);
        return false;
      }

      // Optionally encrypt the photo bytes before chunking.
      // The nonce is sent in photo_start; the binary chunks carry ciphertext.
      var transferData = photoData;
      String? nonceB64;
      final enc = _encryptionService;
      if (enc != null && enc.hasSession(peerId)) {
        final encrypted = await enc.encryptBytes(peerId, photoData);
        if (encrypted != null) {
          transferData = encrypted.ciphertext;
          nonceB64 = base64.encode(encrypted.nonce);
          Logger.debug(
            'PhotoTransfer: Encrypted ${photoData.length}B → '
            '${transferData.length}B for $messageId',
            'E2EE',
          );
        }
      }

      final maxWriteLen = conn.maxWriteLength;
      const binaryOverhead = 3;
      final rawChunkSize = max(20, maxWriteLen - binaryOverhead);
      final totalChunks =
          (transferData.length + rawChunkSize - 1) ~/ rawChunkSize;

      Logger.info(
        'PhotoTransfer: Binary transfer: ${transferData.length}B, '
        '$totalChunks chunks (${rawChunkSize}B each, maxWrite=$maxWriteLen)',
        'BLE',
      );

      // Phase 1: JSON metadata
      final startPayload = utf8.encode(jsonEncode({
        MessageKeys.type: MessageTypes.photoStart,
        MessageKeys.senderId: getOwnUserId?.call() ?? '',
        MessageKeys.messageId: messageId,
        if (photoId != null) MessageKeys.photoId: photoId,
        MessageKeys.totalChunks: totalChunks,
        MessageKeys.totalSize: transferData.length,
        if (nonceB64 != null) ...{MessageKeys.version: 1, MessageKeys.nonce: nonceB64},
      }),);

      final startSuccess = await _writeQueue.enqueue(
        peerId: peerId,
        peripheral: conn.peripheral,
        characteristic: conn.messagingChar!,
        data: Uint8List.fromList(startPayload),
      );

      if (!startSuccess) {
        _emitProgress(messageId, peerId, 0, PhotoTransferStatus.failed,
            errorMessage: 'Failed to send photo_start',);
        return false;
      }

      _emitProgress(messageId, peerId, 0, PhotoTransferStatus.starting);

      // Phase 2: Binary chunks (of ciphertext when encrypted).
      // v2 binary format: [0x02][uint16 index][8-byte sender tag][raw data]
      // The sender tag is the first 8 bytes of our userId (UTF-8), allowing
      // the receiver to resolve the sender even when Central UUID lookup fails.
      final ownUserId = getOwnUserId?.call() ?? '';
      final senderTag = _makeSenderTag(ownUserId);
      const senderTagLen = 8;
      const v2Overhead = 3 + senderTagLen; // marker + index + tag

      for (var i = 0; i < totalChunks; i++) {
        if (_cancelledTransfers.contains(messageId)) {
          _cancelledTransfers.remove(messageId);
          _emitProgress(
              messageId, peerId, i / totalChunks, PhotoTransferStatus.cancelled,);
          return false;
        }

        final dataStart = i * rawChunkSize;
        final dataEnd = min(dataStart + rawChunkSize, transferData.length);
        final chunkData = transferData.sublist(dataStart, dataEnd);

        final chunkPayload = Uint8List(v2Overhead + chunkData.length)
          ..[0] = 0x02
          ..[1] = (i >> 8) & 0xFF
          ..[2] = i & 0xFF
          ..setRange(3, 3 + senderTagLen, senderTag)
          ..setRange(v2Overhead, v2Overhead + chunkData.length, chunkData);

        final chunkSuccess = await _writeQueue.enqueue(
          peerId: peerId,
          peripheral: conn.peripheral,
          characteristic: conn.messagingChar!,
          data: chunkPayload,
          priority: WritePriority.photoChunk,
        );

        if (!chunkSuccess) {
          _emitProgress(messageId, peerId, i / totalChunks,
              PhotoTransferStatus.failed,
              errorMessage: 'Chunk $i write failed',);
          return false;
        }

        final progress = (i + 1) / totalChunks;
        _emitProgress(
          messageId,
          peerId,
          progress,
          i == totalChunks - 1
              ? PhotoTransferStatus.completed
              : PhotoTransferStatus.inProgress,
        );
      }

      Logger.info('PhotoTransfer: Transfer completed: $messageId', 'BLE');
      return true;
    } on Exception catch (e) {
      Logger.error('PhotoTransfer: Transfer failed', e, null, 'BLE');
      _connectionManager.disconnect(peerId);
      _emitProgress(messageId, peerId, 0, PhotoTransferStatus.failed,
          errorMessage: e.toString(),);
      return false;
    }
  }

  // ==================== Send: Photo Preview ====================

  /// Send a photo preview (thumbnail) via binary two-phase protocol.
  Future<bool> sendPhotoPreview({
    required String peerId,
    required String messageId,
    required String photoId,
    required Uint8List thumbnailBytes,
    required int originalSize,
  }) async {
    Logger.info(
      'PhotoTransfer: Sending preview $photoId '
      '(${thumbnailBytes.length}B) to '
      '${peerId.substring(0, min(8, peerId.length))}',
      'BLE',
    );

    try {
      final conn = await _ensureConnection(peerId);
      if (conn == null) {
        Logger.info(
            'PhotoTransfer: Peer not reachable for preview: $peerId', 'BLE',);
        return false;
      }

      // Optionally encrypt the thumbnail before chunking.
      var transferThumb = thumbnailBytes;
      String? thumbNonceB64;
      final enc = _encryptionService;
      if (enc != null && enc.hasSession(peerId)) {
        final encrypted = await enc.encryptBytes(peerId, thumbnailBytes);
        if (encrypted != null) {
          transferThumb = encrypted.ciphertext;
          thumbNonceB64 = base64.encode(encrypted.nonce);
        }
      }

      final maxWriteLen = conn.maxWriteLength;
      const binaryOverhead = 3;
      final rawChunkSize = max(20, maxWriteLen - binaryOverhead);
      final totalChunks =
          (transferThumb.length + rawChunkSize - 1) ~/ rawChunkSize;

      // Phase 1: JSON metadata
      final startPayload = utf8.encode(jsonEncode({
        MessageKeys.type: MessageTypes.photoPreview,
        MessageKeys.senderId: getOwnUserId?.call() ?? '',
        MessageKeys.messageId: messageId,
        MessageKeys.photoId: photoId,
        MessageKeys.originalSize: originalSize,
        MessageKeys.thumbnailChunks: totalChunks,
        if (thumbNonceB64 != null) ...{MessageKeys.version: 1, MessageKeys.nonce: thumbNonceB64},
      }),);

      final startSuccess = await _writeQueue.enqueue(
        peerId: peerId,
        peripheral: conn.peripheral,
        characteristic: conn.messagingChar!,
        data: Uint8List.fromList(startPayload),
      );

      if (!startSuccess) return false;

      // Phase 2: Binary thumbnail chunks (0x03 marker, ciphertext when encrypted).
      // Same v2 format as photo chunks: [0x03][index][8-byte sender tag][data]
      final ownUserId = getOwnUserId?.call() ?? '';
      final senderTag = _makeSenderTag(ownUserId);
      const senderTagLen = 8;
      const v2Overhead = 3 + senderTagLen;

      for (var i = 0; i < totalChunks; i++) {
        if (_cancelledTransfers.contains(messageId)) {
          _cancelledTransfers.remove(messageId);
          return false;
        }

        final dataStart = i * rawChunkSize;
        final dataEnd = min(dataStart + rawChunkSize, transferThumb.length);
        final chunkData = transferThumb.sublist(dataStart, dataEnd);

        final chunkPayload = Uint8List(v2Overhead + chunkData.length)
          ..[0] = 0x03
          ..[1] = (i >> 8) & 0xFF
          ..[2] = i & 0xFF
          ..setRange(3, 3 + senderTagLen, senderTag)
          ..setRange(v2Overhead, v2Overhead + chunkData.length, chunkData);

        final chunkSuccess = await _writeQueue.enqueue(
          peerId: peerId,
          peripheral: conn.peripheral,
          characteristic: conn.messagingChar!,
          data: chunkPayload,
          priority: WritePriority.photoChunk,
        );

        if (!chunkSuccess) return false;
      }

      Logger.info('PhotoTransfer: Preview sent: $photoId', 'BLE');
      return true;
    } on Exception catch (e) {
      Logger.error('PhotoTransfer: Preview send failed', e, null, 'BLE');
      _connectionManager.disconnect(peerId);
      return false;
    }
  }

  // ==================== Send: Photo Request ====================

  /// Send a photo_request to a peer to trigger full photo transfer.
  Future<bool> sendPhotoRequest({
    required String peerId,
    required String messageId,
    required String photoId,
  }) async {
    Logger.info(
      'PhotoTransfer: Sending photo_request $photoId to '
      '${peerId.substring(0, min(8, peerId.length))}',
      'BLE',
    );

    try {
      final conn = await _ensureConnection(peerId);
      if (conn == null) {
        Logger.info(
            'PhotoTransfer: Peer not reachable for photo_request: $peerId',
            'BLE',);
        return false;
      }

      final requestPayload = Uint8List.fromList(utf8.encode(jsonEncode({
        MessageKeys.type: MessageTypes.photoRequest,
        MessageKeys.senderId: getOwnUserId?.call() ?? '',
        MessageKeys.messageId: messageId,
        MessageKeys.photoId: photoId,
      }),),);

      final success = await _writeQueue.enqueue(
        peerId: peerId,
        peripheral: conn.peripheral,
        characteristic: conn.messagingChar!,
        data: requestPayload,
      );

      if (success) {
        Logger.info('PhotoTransfer: photo_request sent: $photoId', 'BLE');
      }
      return success;
    } on Exception catch (e) {
      Logger.error('PhotoTransfer: photo_request send failed', e, null, 'BLE');
      return false;
    }
  }

  // ==================== Cancel ====================

  void cancelTransfer(String messageId) {
    Logger.info('PhotoTransfer: Cancelling transfer $messageId', 'BLE');
    _cancelledTransfers.add(messageId);
    _photoReassembler.cancel(messageId);
  }

  // ==================== Receive: Photo (binary 0x02) ====================

  /// Handle photo_start JSON — stores metadata for the binary chunk stream.
  ///
  /// [fromPeerId] is the resolved peer ID (from sender_id → Peripheral UUID).
  /// [centralId] is the raw Central UUID from the GATT write — binary chunks
  /// (0x02) only carry this ID, so we record the mapping for chunk lookup.
  void handlePhotoStart(Map<String, dynamic> json, String fromPeerId,
      {String? centralId,}) {
    final messageId = json[MessageKeys.messageId] as String? ?? '';
    final photoId = json[MessageKeys.photoId] as String?;
    final totalChunks = json[MessageKeys.totalChunks] as int? ?? 0;
    final totalSize = json[MessageKeys.totalSize] as int? ?? 0;

    Uint8List? nonce;
    if (json[MessageKeys.version] == 1) {
      final nStr = json[MessageKeys.nonce] as String?;
      if (nStr != null) nonce = Uint8List.fromList(base64.decode(nStr));
    }

    _incomingPhotoTransfers[fromPeerId] = _IncomingPhotoTransfer(
      messageId: messageId,
      photoId: photoId,
      totalChunks: totalChunks,
      totalSize: totalSize,
      receivedData: BytesBuilder(copy: false),
      receivedCount: 0,
      nonce: nonce,
    );

    // Record Central UUID → resolved ID mapping so binary chunks can find
    // the transfer even when Central UUID ≠ Peripheral UUID (iOS).
    if (centralId != null && centralId != fromPeerId) {
      _centralToResolvedId[centralId] = fromPeerId;
    }

    // Also record the sender tag (first 8 chars of sender_id) for v2 binary
    // chunk identification. This provides a timing-independent fallback when
    // the Central UUID lookup fails.
    final senderId = json[MessageKeys.senderId] as String?;
    if (senderId != null && senderId.length >= 8) {
      _senderTagToResolvedId[senderId.substring(0, 8)] = fromPeerId;
    }

    Logger.info(
      'PhotoTransfer: Incoming photo from '
      '${fromPeerId.substring(0, min(8, fromPeerId.length))}: '
      '$totalChunks chunks, $totalSize bytes '
      '(centralId=${centralId?.substring(0, min(8, centralId.length)) ?? "n/a"}, '
      'senderId=${senderId != null ? senderId.substring(0, min(8, senderId.length)) : "n/a"})',
      'BLE',
    );

    _emitProgress(messageId, fromPeerId, 0, PhotoTransferStatus.starting);

    // Start receive timeout — if no chunks arrive within the window, the
    // transfer is considered stale and cleaned up.
    _resetReceiveTimeout(fromPeerId);
  }

  /// Handle binary photo chunk.
  ///
  /// v2 format: [0x02][uint16 index][8-byte sender tag][raw data] (≥11 bytes)
  /// v1 format: [0x02][uint16 index][raw data] (≥3 bytes, no sender tag)
  ///
  /// The sender tag (first 8 bytes of the sender's userId) provides a
  /// timing-independent way to resolve which transfer this chunk belongs to,
  /// even when the Central UUID doesn't match any known Peripheral UUID (iOS).
  Future<void> handleBinaryPhotoChunk(Uint8List data, String centralId) async {
    if (data.length < 3) return;

    final chunkIndex = (data[1] << 8) | data[2];

    // Try to extract v2 sender tag: bytes 3..10 are the sender tag if the
    // chunk is large enough. We detect v2 by checking if the tag resolves
    // to a known sender — if not, treat as v1 (no tag, raw data starts at 3).
    String? senderTag;
    Uint8List chunkData;
    if (data.length >= 11) {
      senderTag = String.fromCharCodes(data.sublist(3, 11));
      chunkData = data.sublist(11);
    } else {
      chunkData = data.sublist(3);
    }

    // Try direct lookup by Central UUID first, then by sender tag, then by
    // the Central → Peripheral mapping recorded in handlePhotoStart.
    var fromPeerId = centralId;
    var transfer = _incomingPhotoTransfers[centralId];

    if (transfer == null) {
      final resolvedId = _centralToResolvedId[centralId];
      if (resolvedId != null) {
        transfer = _incomingPhotoTransfers[resolvedId];
        if (transfer != null) fromPeerId = resolvedId;
      }
    }

    // v2 sender tag fallback: resolve via the tag recorded in handlePhotoStart.
    if (transfer == null && senderTag != null) {
      final resolvedId = _senderTagToResolvedId[senderTag];
      if (resolvedId != null) {
        transfer = _incomingPhotoTransfers[resolvedId];
        if (transfer != null) {
          fromPeerId = resolvedId;
          // Record the mapping for future chunks from this Central.
          _centralToResolvedId[centralId] = resolvedId;
          Logger.info(
            'PhotoTransfer: Resolved chunk sender via tag "$senderTag" '
            '→ ${resolvedId.substring(0, min(8, resolvedId.length))} '
            '(centralId=${centralId.substring(0, min(8, centralId.length))})',
            'BLE',
          );
        }
      }
    }

    if (transfer == null) {
      // If v2 tag was present but didn't resolve, the raw data might have been
      // incorrectly split. Fall back to treating entire payload as v1 data.
      if (senderTag != null && data.length >= 11) {
        chunkData = data.sublist(3); // v1 fallback: no tag
        Logger.debug(
          'PhotoTransfer: Sender tag "$senderTag" unresolved — '
          'treating as v1 chunk from $centralId',
          'BLE',
        );
      }
      // Last-resort: check all active transfers
      if (_incomingPhotoTransfers.length == 1) {
        final entry = _incomingPhotoTransfers.entries.first;
        transfer = entry.value;
        fromPeerId = entry.key;
        _centralToResolvedId[centralId] = fromPeerId;
        Logger.debug(
          'PhotoTransfer: Single active transfer — attributing chunk '
          '$chunkIndex to ${fromPeerId.substring(0, min(8, fromPeerId.length))}',
          'BLE',
        );
      }
    }

    if (transfer == null) {
      Logger.warning(
        'PhotoTransfer: Binary chunk $chunkIndex received but no active '
        'transfer from centralId=${centralId.substring(0, min(8, centralId.length))}'
        '${senderTag != null ? " tag=$senderTag" : ""}',
        'BLE',
      );
      return;
    }

    transfer.receivedData.add(chunkData);
    transfer.receivedCount++;

    // Reset receive timeout — the transfer is still alive.
    _resetReceiveTimeout(fromPeerId);

    if (transfer.receivedCount % 50 == 0 ||
        transfer.receivedCount == transfer.totalChunks) {
      Logger.info(
        'PhotoTransfer: Chunk ${transfer.receivedCount}/${transfer.totalChunks} '
        'for ${transfer.messageId.substring(0, min(8, transfer.messageId.length))}',
        'BLE',
      );
    }

    _emitProgress(transfer.messageId, fromPeerId,
        transfer.receivedCount / transfer.totalChunks,
        PhotoTransferStatus.inProgress,);

    if (transfer.receivedCount >= transfer.totalChunks) {
      final rawBytes = transfer.receivedData.toBytes();

      Logger.info(
        'PhotoTransfer: Binary photo complete: ${transfer.messageId} '
        '(${rawBytes.length} bytes)',
        'BLE',
      );

      // Decrypt if the sender included an E2EE nonce.
      var photoBytes = rawBytes;
      final nonce = transfer.nonce;
      final enc = _encryptionService;
      if (nonce != null && enc != null) {
        final payload = EncryptedPayload(
          nonce: nonce,
          ciphertext: rawBytes,
        );
        final decrypted = await enc.decryptBytes(fromPeerId, payload);
        if (decrypted == null) {
          Logger.warning(
            'PhotoTransfer: Decryption failed for ${transfer.messageId} — dropping',
            'E2EE',
          );
          _incomingPhotoTransfers.remove(fromPeerId);
          return;
        }
        photoBytes = decrypted;
      }

      onPhotoReceived?.call(ReceivedPhoto(
        fromPeerId: fromPeerId,
        messageId: transfer.messageId,
        photoId: transfer.photoId,
        photoBytes: photoBytes,
        timestamp: DateTime.now(),
      ),);

      _emitProgress(
          transfer.messageId, fromPeerId, 1, PhotoTransferStatus.completed,);

      _cancelReceiveTimeout(fromPeerId);
      _incomingPhotoTransfers.remove(fromPeerId);
    }
  }

  /// Handle legacy JSON photo_chunk.
  void handleReceivedPhotoChunk(
      Map<String, dynamic> json, String fromPeerId,) {
    final dataField = json[MessageKeys.data];
    Uint8List chunkData;
    if (dataField is String) {
      chunkData = base64Decode(dataField);
    } else if (dataField is List) {
      chunkData = Uint8List.fromList(dataField.cast<int>());
    } else {
      chunkData = Uint8List(0);
    }

    final chunk = PhotoChunk(
      messageId: json[MessageKeys.messageId] as String? ?? '',
      chunkIndex: json[MessageKeys.chunkIndex] as int? ?? 0,
      totalChunks: json[MessageKeys.totalChunks] as int? ?? 1,
      data: chunkData,
      totalSize: json[MessageKeys.totalSize] as int? ?? 0,
    );

    Logger.info(
      'PhotoTransfer: Received chunk ${chunk.chunkIndex + 1}/${chunk.totalChunks} '
      'for ${chunk.messageId.substring(0, min(8, chunk.messageId.length))}',
      'BLE',
    );

    _emitProgress(chunk.messageId, fromPeerId,
        (chunk.chunkIndex + 1) / chunk.totalChunks,
        PhotoTransferStatus.inProgress,);

    final result = _photoReassembler.addChunk(chunk);

    if (result.isComplete && result.photoData != null) {
      Logger.info(
        'PhotoTransfer: Reassembly complete: ${chunk.messageId} '
        '(${result.photoData!.length} bytes)',
        'BLE',
      );

      onPhotoReceived?.call(ReceivedPhoto(
        fromPeerId: fromPeerId,
        messageId: chunk.messageId,
        photoBytes: result.photoData!,
        timestamp: DateTime.now(),
      ),);

      _emitProgress(chunk.messageId, fromPeerId, 1,
          PhotoTransferStatus.completed,);
    }
  }

  // ==================== Receive: Photo Preview (binary 0x03) ====================

  /// Handle photo_preview JSON — stores metadata for incoming thumbnail chunks.
  void handlePhotoPreviewStart(
      Map<String, dynamic> json, String fromPeerId, {String? centralId,}) {
    final messageId = json[MessageKeys.messageId] as String? ?? '';
    final photoId = json[MessageKeys.photoId] as String? ?? '';
    final originalSize = json[MessageKeys.originalSize] as int? ?? 0;
    final totalChunks = json[MessageKeys.thumbnailChunks] as int? ?? 0;

    Logger.info(
      'PhotoTransfer: Preview starting from '
      '${fromPeerId.substring(0, min(8, fromPeerId.length))}: '
      '$totalChunks chunks, originalSize=$originalSize',
      'BLE',
    );

    if (totalChunks <= 0) {
      onPhotoPreviewReceived?.call(ReceivedPhotoPreview(
        fromPeerId: fromPeerId,
        messageId: messageId,
        photoId: photoId,
        thumbnailBytes: Uint8List(0),
        originalSize: originalSize,
        timestamp: DateTime.now(),
      ),);
      return;
    }

    Uint8List? thumbNonce;
    if (json[MessageKeys.version] == 1) {
      final nStr = json[MessageKeys.nonce] as String?;
      if (nStr != null) thumbNonce = Uint8List.fromList(base64.decode(nStr));
    }

    _incomingThumbnailTransfers[fromPeerId] = _IncomingThumbnailTransfer(
      messageId: messageId,
      photoId: photoId,
      originalSize: originalSize,
      totalChunks: totalChunks,
      receivedData: BytesBuilder(copy: false),
      receivedCount: 0,
      nonce: thumbNonce,
    );

    // Record Central UUID → resolved ID mapping for thumbnail chunk lookup.
    if (centralId != null && centralId != fromPeerId) {
      _centralToResolvedId[centralId] = fromPeerId;
    }

    // Record sender tag for v2 binary chunk identification.
    final senderId = json[MessageKeys.senderId] as String?;
    if (senderId != null && senderId.length >= 8) {
      _senderTagToResolvedId[senderId.substring(0, 8)] = fromPeerId;
    }
  }

  /// Handle binary thumbnail chunk.
  ///
  /// v2 format: [0x03][uint16 index][8-byte sender tag][raw data] (≥11 bytes)
  /// v1 format: [0x03][uint16 index][raw data] (≥3 bytes)
  Future<void> handleBinaryThumbnailChunk(Uint8List data, String centralId) async {
    if (data.length < 3) return;

    // Extract v2 sender tag if present, same logic as photo chunks.
    String? senderTag;
    Uint8List chunkData;
    if (data.length >= 11) {
      senderTag = String.fromCharCodes(data.sublist(3, 11));
      chunkData = data.sublist(11);
    } else {
      chunkData = data.sublist(3);
    }

    // Try direct lookup, then Central → Peripheral, then sender tag.
    var transfer =
        _incomingThumbnailTransfers[centralId];
    var resolvedPeerId = centralId;

    if (transfer == null) {
      final mapped = _centralToResolvedId[centralId];
      if (mapped != null) {
        transfer = _incomingThumbnailTransfers[mapped];
        if (transfer != null) resolvedPeerId = mapped;
      }
    }

    if (transfer == null && senderTag != null) {
      final mapped = _senderTagToResolvedId[senderTag];
      if (mapped != null) {
        transfer = _incomingThumbnailTransfers[mapped];
        if (transfer != null) {
          resolvedPeerId = mapped;
          _centralToResolvedId[centralId] = mapped;
        }
      }
    }

    if (transfer == null) {
      // v1 fallback
      if (senderTag != null && data.length >= 11) {
        chunkData = data.sublist(3);
      }
      // Single-transfer last resort
      if (_incomingThumbnailTransfers.length == 1) {
        final entry = _incomingThumbnailTransfers.entries.first;
        transfer = entry.value;
        resolvedPeerId = entry.key;
        _centralToResolvedId[centralId] = resolvedPeerId;
      }
    }

    if (transfer == null) {
      Logger.warning(
        'PhotoTransfer: Thumbnail chunk but no active preview transfer '
        'from centralId=${centralId.substring(0, min(8, centralId.length))}'
        '${senderTag != null ? " tag=$senderTag" : ""}',
        'BLE',
      );
      return;
    }
    transfer.receivedData.add(chunkData);
    transfer.receivedCount++;

    if (transfer.receivedCount >= transfer.totalChunks) {
      final rawThumb = transfer.receivedData.toBytes();

      Logger.info(
        'PhotoTransfer: Thumbnail complete: ${transfer.messageId} '
        '(${rawThumb.length} bytes)',
        'BLE',
      );

      // Decrypt if the sender included an E2EE nonce.
      var thumbnailBytes = rawThumb;
      final thumbNonce = transfer.nonce;
      final enc = _encryptionService;
      if (thumbNonce != null && enc != null) {
        final payload = EncryptedPayload(
          nonce: thumbNonce,
          ciphertext: rawThumb,
        );
        final decrypted = await enc.decryptBytes(resolvedPeerId, payload);
        if (decrypted == null) {
          Logger.warning(
            'PhotoTransfer: Thumbnail decryption failed for '
            '${transfer.messageId} — dropping',
            'E2EE',
          );
          _incomingThumbnailTransfers.remove(resolvedPeerId);
          return;
        }
        thumbnailBytes = decrypted;
      }

      onPhotoPreviewReceived?.call(ReceivedPhotoPreview(
        fromPeerId: resolvedPeerId,
        messageId: transfer.messageId,
        photoId: transfer.photoId,
        thumbnailBytes: thumbnailBytes,
        originalSize: transfer.originalSize,
        timestamp: DateTime.now(),
      ),);

      _incomingThumbnailTransfers.remove(resolvedPeerId);
    }
  }

  // ==================== Receive: Photo Request ====================

  /// Handle incoming photo_request JSON.
  void handlePhotoRequest(Map<String, dynamic> json, String fromPeerId) {
    final messageId = json[MessageKeys.messageId] as String? ?? '';
    final photoId = json[MessageKeys.photoId] as String? ?? '';

    Logger.info(
      'PhotoTransfer: photo_request from '
      '${fromPeerId.substring(0, min(8, fromPeerId.length))}: $photoId',
      'BLE',
    );

    onPhotoRequestReceived?.call(ReceivedPhotoRequest(
      fromPeerId: fromPeerId,
      messageId: messageId,
      photoId: photoId,
      timestamp: DateTime.now(),
    ),);
  }

  // ==================== Cleanup ====================

  void clear() {
    _cancelledTransfers.clear();
    _incomingPhotoTransfers.clear();
    _incomingThumbnailTransfers.clear();
    _centralToResolvedId.clear();
    _senderTagToResolvedId.clear();
    _photoReassembler.clear();
    for (final timer in _receiveTimeoutTimers.values) {
      timer.cancel();
    }
    _receiveTimeoutTimers.clear();
  }

  /// Produce an 8-byte sender tag from a userId (UTF-8, zero-padded).
  /// Used to identify the sender in binary photo/thumbnail chunks (v2 format).
  static Uint8List _makeSenderTag(String userId) {
    final tag = Uint8List(8);
    final src = utf8.encode(userId.length >= 8 ? userId.substring(0, 8) : userId);
    for (var i = 0; i < src.length && i < 8; i++) {
      tag[i] = src[i];
    }
    return tag;
  }

  // ==================== Internal ====================

  /// Reset (or start) the receive timeout for an incoming transfer.
  /// Each incoming chunk resets the timer. The timeout duration scales
  /// with the remaining chunk count — larger transfers get more time
  /// because BLE congestion is more likely.
  void _resetReceiveTimeout(String peerId) {
    _receiveTimeoutTimers[peerId]?.cancel();
    final transfer = _incomingPhotoTransfers[peerId];
    final remaining = transfer != null
        ? transfer.totalChunks - transfer.receivedCount
        : 10; // default for initial timeout before first chunk
    _receiveTimeoutTimers[peerId] = Timer(_receiveTimeoutFor(remaining), () {
      final transfer = _incomingPhotoTransfers.remove(peerId);
      _receiveTimeoutTimers.remove(peerId);
      if (transfer != null) {
        Logger.warning(
          'PhotoTransfer: Receive timeout for ${transfer.messageId} '
          'from ${peerId.substring(0, min(8, peerId.length))} '
          '(${transfer.receivedCount}/${transfer.totalChunks} chunks)',
          'BLE',
        );
        _emitProgress(transfer.messageId, peerId,
            transfer.receivedCount / transfer.totalChunks,
            PhotoTransferStatus.failed,
            errorMessage: 'Receive timeout — connection lost',);
      }
    });
  }

  /// Cancel the receive timeout for a completed or cancelled transfer.
  void _cancelReceiveTimeout(String peerId) {
    _receiveTimeoutTimers.remove(peerId)?.cancel();
  }

  /// Get or establish a connection to a peer, returning the connection
  /// if it can send messages, or null if unreachable.
  Future<PeerConnection?> _ensureConnection(String peerId) async {
    var conn = _connectionManager.getConnection(peerId);
    if (conn == null || !conn.canSendMessages) {
      final peripheral = _connectionManager.getPeripheral(peerId);
      if (peripheral != null) {
        conn = await _connectionManager.connect(peerId, peripheral);
      }
    }
    if (conn == null || !conn.canSendMessages) return null;
    return conn;
  }

  void _emitProgress(
    String messageId,
    String peerId,
    double progress,
    PhotoTransferStatus status, {
    String? errorMessage,
  }) {
    onProgress?.call(PhotoTransferProgress(
      messageId: messageId,
      peerId: peerId,
      progress: progress,
      status: status,
      errorMessage: errorMessage,
    ),);
  }
}

/// Tracks an incoming binary photo transfer from a specific peer.
class _IncomingPhotoTransfer {
  _IncomingPhotoTransfer({
    required this.messageId,
    required this.totalChunks,
    required this.totalSize,
    required this.receivedData,
    required this.receivedCount,
    this.photoId,
    this.nonce,
  });

  final String messageId;
  final String? photoId;
  final int totalChunks;
  final int totalSize;
  final BytesBuilder receivedData;
  int receivedCount;
  /// Non-null when the sender encrypted the photo (v:1 in photo_start).
  final Uint8List? nonce;
}

/// Tracks an incoming binary thumbnail transfer for the preview consent flow.
class _IncomingThumbnailTransfer {
  _IncomingThumbnailTransfer({
    required this.messageId,
    required this.photoId,
    required this.originalSize,
    required this.totalChunks,
    required this.receivedData,
    required this.receivedCount,
    this.nonce,
  });

  final String messageId;
  final String photoId;
  final int originalSize;
  final int totalChunks;
  final BytesBuilder receivedData;
  int receivedCount;
  /// Non-null when the sender encrypted the thumbnail (v:1 in photo_preview).
  final Uint8List? nonce;
}
