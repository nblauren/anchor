import 'dart:typed_data';

/// Utilities for chunking photos for BLE transfer
/// BLE has limited MTU, so photos must be sent in chunks
class PhotoChunker {
  PhotoChunker({
    this.chunkSize = 4096, // 4KB default, safe for most BLE connections
  });

  final int chunkSize;

  /// Split photo data into chunks for transfer
  List<PhotoChunk> chunkPhoto(Uint8List photoData, String messageId) {
    final totalChunks = (photoData.length / chunkSize).ceil();
    final chunks = <PhotoChunk>[];

    for (var i = 0; i < totalChunks; i++) {
      final start = i * chunkSize;
      final end = (start + chunkSize).clamp(0, photoData.length);
      final chunkData = photoData.sublist(start, end);

      chunks.add(PhotoChunk(
        messageId: messageId,
        chunkIndex: i,
        totalChunks: totalChunks,
        data: Uint8List.fromList(chunkData),
        totalSize: photoData.length,
      ),);
    }

    return chunks;
  }

  /// Calculate progress from received chunks
  static double calculateProgress(int receivedChunks, int totalChunks) {
    if (totalChunks == 0) return 0;
    return (receivedChunks / totalChunks).clamp(0.0, 1.0);
  }
}

/// A single chunk of photo data
class PhotoChunk {
  const PhotoChunk({
    required this.messageId,
    required this.chunkIndex,
    required this.totalChunks,
    required this.data,
    required this.totalSize,
  });

  final String messageId;
  final int chunkIndex;
  final int totalChunks;
  final Uint8List data;
  final int totalSize;

  bool get isFirst => chunkIndex == 0;
  bool get isLast => chunkIndex == totalChunks - 1;

  /// Serialize chunk for transmission
  Map<String, dynamic> toJson() => {
        'messageId': messageId,
        'chunkIndex': chunkIndex,
        'totalChunks': totalChunks,
        'data': data.toList(),
        'totalSize': totalSize,
      };

  /// Deserialize chunk from received data
  factory PhotoChunk.fromJson(Map<String, dynamic> json) {
    return PhotoChunk(
      messageId: json['messageId'] as String,
      chunkIndex: json['chunkIndex'] as int,
      totalChunks: json['totalChunks'] as int,
      data: Uint8List.fromList((json['data'] as List).cast<int>()),
      totalSize: json['totalSize'] as int,
    );
  }
}

/// Reassembles photo chunks back into complete photo
class PhotoReassembler {
  final Map<String, _PendingPhoto> _pendingPhotos = {};

  /// Add a received chunk
  /// Returns the complete photo data if all chunks received, null otherwise
  ReassemblyResult addChunk(PhotoChunk chunk) {
    final pending = _pendingPhotos.putIfAbsent(
      chunk.messageId,
      () => _PendingPhoto(
        messageId: chunk.messageId,
        totalChunks: chunk.totalChunks,
        totalSize: chunk.totalSize,
      ),
    )..addChunk(chunk);

    if (pending.isComplete) {
      final photo = pending.reassemble();
      _pendingPhotos.remove(chunk.messageId);
      return ReassemblyResult(
        messageId: chunk.messageId,
        isComplete: true,
        progress: 1,
        photoData: photo,
      );
    }

    return ReassemblyResult(
      messageId: chunk.messageId,
      isComplete: false,
      progress: pending.progress,
    );
  }

  /// Cancel pending photo reassembly
  void cancel(String messageId) {
    _pendingPhotos.remove(messageId);
  }

  /// Get progress for a pending photo
  double? getProgress(String messageId) {
    return _pendingPhotos[messageId]?.progress;
  }

  /// Check if a photo transfer is in progress
  bool isInProgress(String messageId) {
    return _pendingPhotos.containsKey(messageId);
  }

  /// Get list of pending message IDs
  List<String> get pendingMessageIds => _pendingPhotos.keys.toList();

  /// Clear all pending photos
  void clear() {
    _pendingPhotos.clear();
  }
}

/// Result of adding a chunk to reassembler
class ReassemblyResult {
  const ReassemblyResult({
    required this.messageId,
    required this.isComplete,
    required this.progress,
    this.photoData,
  });

  final String messageId;
  final bool isComplete;
  final double progress;
  final Uint8List? photoData;
}

/// Internal class to track pending photo reassembly
class _PendingPhoto {
  _PendingPhoto({
    required this.messageId,
    required this.totalChunks,
    required this.totalSize,
  }) : _chunks = List.filled(totalChunks, null);

  final String messageId;
  final int totalChunks;
  final int totalSize;
  final List<Uint8List?> _chunks;
  int _receivedCount = 0;

  void addChunk(PhotoChunk chunk) {
    if (_chunks[chunk.chunkIndex] == null) {
      _chunks[chunk.chunkIndex] = chunk.data;
      _receivedCount++;
    }
  }

  bool get isComplete => _receivedCount == totalChunks;

  double get progress =>
      PhotoChunker.calculateProgress(_receivedCount, totalChunks);

  Uint8List reassemble() {
    final buffer = BytesBuilder();
    for (final chunk in _chunks) {
      if (chunk != null) {
        buffer.add(chunk);
      }
    }
    return buffer.toBytes();
  }
}
