import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../../core/utils/logger.dart';
import '../ble_config.dart';
import '../ble_models.dart';
import '../connection/connection_manager.dart';
import '../connection/peer_connection.dart';
import '../gatt/gatt_write_queue.dart';
import '../photo_chunker.dart';

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
  })  : _connectionManager = connectionManager,
        _writeQueue = writeQueue,
        _config = config,
        _photoReassembler = PhotoReassembler();

  final ConnectionManager _connectionManager;
  final GattWriteQueue _writeQueue;
  final BleConfig _config;
  final PhotoReassembler _photoReassembler;

  // ==================== State ====================

  /// Track cancelled transfers so in-flight sends stop early.
  final Set<String> _cancelledTransfers = {};

  /// Active incoming binary photo transfers (keyed by peerId/centralUuid).
  final Map<String, _IncomingPhotoTransfer> _incomingPhotoTransfers = {};

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
            errorMessage: 'Peer not reachable');
        return false;
      }

      final maxWriteLen = conn.maxWriteLength;
      const binaryOverhead = 3;
      final rawChunkSize = max(20, maxWriteLen - binaryOverhead);
      final totalChunks =
          (photoData.length + rawChunkSize - 1) ~/ rawChunkSize;

      Logger.info(
        'PhotoTransfer: Binary transfer: ${photoData.length}B, '
        '$totalChunks chunks (${rawChunkSize}B each, maxWrite=$maxWriteLen)',
        'BLE',
      );

      // Phase 1: JSON metadata
      final startPayload = utf8.encode(jsonEncode({
        'type': 'photo_start',
        'sender_id': getOwnUserId?.call() ?? '',
        'message_id': messageId,
        if (photoId != null) 'photo_id': photoId,
        'total_chunks': totalChunks,
        'total_size': photoData.length,
      }));

      final startSuccess = await _writeQueue.enqueue(
        peerId: peerId,
        peripheral: conn.peripheral,
        characteristic: conn.messagingChar!,
        data: Uint8List.fromList(startPayload),
        priority: WritePriority.userMessage,
      );

      if (!startSuccess) {
        _emitProgress(messageId, peerId, 0, PhotoTransferStatus.failed,
            errorMessage: 'Failed to send photo_start');
        return false;
      }

      _emitProgress(messageId, peerId, 0, PhotoTransferStatus.starting);

      // Phase 2: Binary chunks
      for (var i = 0; i < totalChunks; i++) {
        if (_cancelledTransfers.contains(messageId)) {
          _cancelledTransfers.remove(messageId);
          _emitProgress(
              messageId, peerId, i / totalChunks, PhotoTransferStatus.cancelled);
          return false;
        }

        final dataStart = i * rawChunkSize;
        final dataEnd = min(dataStart + rawChunkSize, photoData.length);
        final chunkData = photoData.sublist(dataStart, dataEnd);

        final chunkPayload = Uint8List(binaryOverhead + chunkData.length);
        chunkPayload[0] = 0x02;
        chunkPayload[1] = (i >> 8) & 0xFF;
        chunkPayload[2] = i & 0xFF;
        chunkPayload.setRange(binaryOverhead, chunkPayload.length, chunkData);

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
              errorMessage: 'Chunk $i write failed');
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
    } catch (e) {
      Logger.error('PhotoTransfer: Transfer failed', e, null, 'BLE');
      _connectionManager.disconnect(peerId);
      _emitProgress(messageId, peerId, 0, PhotoTransferStatus.failed,
          errorMessage: e.toString());
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
            'PhotoTransfer: Peer not reachable for preview: $peerId', 'BLE');
        return false;
      }

      final maxWriteLen = conn.maxWriteLength;
      const binaryOverhead = 3;
      final rawChunkSize = max(20, maxWriteLen - binaryOverhead);
      final totalChunks =
          (thumbnailBytes.length + rawChunkSize - 1) ~/ rawChunkSize;

      // Phase 1: JSON metadata
      final startPayload = utf8.encode(jsonEncode({
        'type': 'photo_preview',
        'sender_id': getOwnUserId?.call() ?? '',
        'message_id': messageId,
        'photo_id': photoId,
        'original_size': originalSize,
        'thumbnail_chunks': totalChunks,
      }));

      final startSuccess = await _writeQueue.enqueue(
        peerId: peerId,
        peripheral: conn.peripheral,
        characteristic: conn.messagingChar!,
        data: Uint8List.fromList(startPayload),
        priority: WritePriority.userMessage,
      );

      if (!startSuccess) return false;

      // Phase 2: Binary thumbnail chunks (0x03 marker)
      for (var i = 0; i < totalChunks; i++) {
        if (_cancelledTransfers.contains(messageId)) {
          _cancelledTransfers.remove(messageId);
          return false;
        }

        final dataStart = i * rawChunkSize;
        final dataEnd = min(dataStart + rawChunkSize, thumbnailBytes.length);
        final chunkData = thumbnailBytes.sublist(dataStart, dataEnd);

        final chunkPayload = Uint8List(binaryOverhead + chunkData.length);
        chunkPayload[0] = 0x03;
        chunkPayload[1] = (i >> 8) & 0xFF;
        chunkPayload[2] = i & 0xFF;
        chunkPayload.setRange(binaryOverhead, chunkPayload.length, chunkData);

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
    } catch (e) {
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
            'BLE');
        return false;
      }

      final requestPayload = Uint8List.fromList(utf8.encode(jsonEncode({
        'type': 'photo_request',
        'sender_id': getOwnUserId?.call() ?? '',
        'message_id': messageId,
        'photo_id': photoId,
      })));

      final success = await _writeQueue.enqueue(
        peerId: peerId,
        peripheral: conn.peripheral,
        characteristic: conn.messagingChar!,
        data: requestPayload,
        priority: WritePriority.userMessage,
      );

      if (success) {
        Logger.info('PhotoTransfer: photo_request sent: $photoId', 'BLE');
      }
      return success;
    } catch (e) {
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
  void handlePhotoStart(Map<String, dynamic> json, String fromPeerId) {
    final messageId = json['message_id'] as String? ?? '';
    final photoId = json['photo_id'] as String?;
    final totalChunks = json['total_chunks'] as int? ?? 0;
    final totalSize = json['total_size'] as int? ?? 0;

    _incomingPhotoTransfers[fromPeerId] = _IncomingPhotoTransfer(
      messageId: messageId,
      photoId: photoId,
      totalChunks: totalChunks,
      totalSize: totalSize,
      receivedData: BytesBuilder(copy: false),
      receivedCount: 0,
    );

    Logger.info(
      'PhotoTransfer: Incoming from '
      '${fromPeerId.substring(0, min(8, fromPeerId.length))}: '
      '$totalChunks chunks, $totalSize bytes',
      'BLE',
    );

    _emitProgress(messageId, fromPeerId, 0, PhotoTransferStatus.starting);
  }

  /// Handle binary photo chunk: [0x02][uint16 chunk_index][raw data]
  void handleBinaryPhotoChunk(Uint8List data, String centralId) {
    if (data.length < 3) return;

    final chunkIndex = (data[1] << 8) | data[2];
    final chunkData = data.sublist(3);

    var fromPeerId = centralId;
    _IncomingPhotoTransfer? transfer = _incomingPhotoTransfers[centralId];

    if (transfer == null) {
      for (final entry in _incomingPhotoTransfers.entries) {
        if (entry.key == centralId) {
          transfer = entry.value;
          fromPeerId = entry.key;
          break;
        }
      }
    }

    if (transfer == null) {
      Logger.warning(
        'PhotoTransfer: Binary chunk received but no active transfer '
        'from $centralId (chunk $chunkIndex)',
        'BLE',
      );
      return;
    }

    transfer.receivedData.add(chunkData);
    transfer.receivedCount++;

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
        PhotoTransferStatus.inProgress);

    if (transfer.receivedCount >= transfer.totalChunks) {
      final photoBytes = transfer.receivedData.toBytes();

      Logger.info(
        'PhotoTransfer: Binary photo complete: ${transfer.messageId} '
        '(${photoBytes.length} bytes)',
        'BLE',
      );

      onPhotoReceived?.call(ReceivedPhoto(
        fromPeerId: fromPeerId,
        messageId: transfer.messageId,
        photoId: transfer.photoId,
        photoBytes: photoBytes,
        timestamp: DateTime.now(),
      ));

      _emitProgress(
          transfer.messageId, fromPeerId, 1.0, PhotoTransferStatus.completed);

      _incomingPhotoTransfers.remove(fromPeerId);
    }
  }

  /// Handle legacy JSON photo_chunk.
  void handleReceivedPhotoChunk(
      Map<String, dynamic> json, String fromPeerId) {
    final dataField = json['data'];
    Uint8List chunkData;
    if (dataField is String) {
      chunkData = base64Decode(dataField);
    } else if (dataField is List) {
      chunkData = Uint8List.fromList(dataField.cast<int>());
    } else {
      chunkData = Uint8List(0);
    }

    final chunk = PhotoChunk(
      messageId: json['message_id'] as String? ?? '',
      chunkIndex: json['chunk_index'] as int? ?? 0,
      totalChunks: json['total_chunks'] as int? ?? 1,
      data: chunkData,
      totalSize: json['total_size'] as int? ?? 0,
    );

    Logger.info(
      'PhotoTransfer: Received chunk ${chunk.chunkIndex + 1}/${chunk.totalChunks} '
      'for ${chunk.messageId.substring(0, min(8, chunk.messageId.length))}',
      'BLE',
    );

    _emitProgress(chunk.messageId, fromPeerId,
        (chunk.chunkIndex + 1) / chunk.totalChunks,
        PhotoTransferStatus.inProgress);

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
      ));

      _emitProgress(chunk.messageId, fromPeerId, 1.0,
          PhotoTransferStatus.completed);
    }
  }

  // ==================== Receive: Photo Preview (binary 0x03) ====================

  /// Handle photo_preview JSON — stores metadata for incoming thumbnail chunks.
  void handlePhotoPreviewStart(
      Map<String, dynamic> json, String fromPeerId) {
    final messageId = json['message_id'] as String? ?? '';
    final photoId = json['photo_id'] as String? ?? '';
    final originalSize = json['original_size'] as int? ?? 0;
    final totalChunks = json['thumbnail_chunks'] as int? ?? 0;

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
      ));
      return;
    }

    _incomingThumbnailTransfers[fromPeerId] = _IncomingThumbnailTransfer(
      messageId: messageId,
      photoId: photoId,
      originalSize: originalSize,
      totalChunks: totalChunks,
      receivedData: BytesBuilder(copy: false),
      receivedCount: 0,
    );
  }

  /// Handle binary thumbnail chunk: [0x03][uint16 chunk_index][raw data]
  void handleBinaryThumbnailChunk(Uint8List data, String centralId) {
    if (data.length < 3) return;

    _IncomingThumbnailTransfer? transfer =
        _incomingThumbnailTransfers[centralId];

    if (transfer == null) {
      for (final entry in _incomingThumbnailTransfers.entries) {
        if (entry.key == centralId) {
          transfer = entry.value;
          break;
        }
      }
    }

    if (transfer == null) {
      Logger.warning(
        'PhotoTransfer: Thumbnail chunk but no active preview transfer '
        'from $centralId',
        'BLE',
      );
      return;
    }

    final chunkData = data.sublist(3);
    transfer.receivedData.add(chunkData);
    transfer.receivedCount++;

    if (transfer.receivedCount >= transfer.totalChunks) {
      final thumbnailBytes = transfer.receivedData.toBytes();

      Logger.info(
        'PhotoTransfer: Thumbnail complete: ${transfer.messageId} '
        '(${thumbnailBytes.length} bytes)',
        'BLE',
      );

      onPhotoPreviewReceived?.call(ReceivedPhotoPreview(
        fromPeerId: centralId,
        messageId: transfer.messageId,
        photoId: transfer.photoId,
        thumbnailBytes: thumbnailBytes,
        originalSize: transfer.originalSize,
        timestamp: DateTime.now(),
      ));

      _incomingThumbnailTransfers.remove(centralId);
    }
  }

  // ==================== Receive: Photo Request ====================

  /// Handle incoming photo_request JSON.
  void handlePhotoRequest(Map<String, dynamic> json, String fromPeerId) {
    final messageId = json['message_id'] as String? ?? '';
    final photoId = json['photo_id'] as String? ?? '';

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
    ));
  }

  // ==================== Cleanup ====================

  void clear() {
    _cancelledTransfers.clear();
    _incomingPhotoTransfers.clear();
    _incomingThumbnailTransfers.clear();
    _photoReassembler.clear();
  }

  // ==================== Internal ====================

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
    ));
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
  });

  final String messageId;
  final String? photoId;
  final int totalChunks;
  final int totalSize;
  final BytesBuilder receivedData;
  int receivedCount;
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
  });

  final String messageId;
  final String photoId;
  final int originalSize;
  final int totalChunks;
  final BytesBuilder receivedData;
  int receivedCount;
}
