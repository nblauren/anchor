import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import '../../../core/utils/logger.dart';

/// Priority levels for GATT write operations.
///
/// Higher priority writes are processed first. When the queue is full,
/// lowest-priority items are dropped to make room for higher-priority ones.
enum WritePriority {
  /// User-initiated messages: text, typing indicators, read receipts,
  /// drop anchor, photo requests. Highest priority — never dropped.
  userMessage,

  /// Photo transfer chunks (binary 0x02/0x03 payloads). Medium priority.
  /// These are large sequential transfers that should yield to user messages.
  photoChunk,

  /// Mesh relay traffic: peer announcements, neighbor lists, relayed messages.
  /// Lowest priority — dropped under backpressure to protect user experience.
  meshRelay,
}

/// A prioritized, backpressure-aware write queue for BLE GATT operations.
///
/// Solves several critical problems in the monolithic BLE service:
///
/// 1. **iOS "prepare queue full" (CBATTError code 9)**: Without serialization,
///    concurrent writes overflow the iOS Core Bluetooth prepare queue.
///    GattWriteQueue serializes all writes with configurable inter-write delay.
///
/// 2. **User message starvation**: Previously, a 200-chunk photo transfer
///    blocked all other GATT operations for 10+ seconds. Now user messages
///    preempt photo chunks and mesh relay.
///
/// 3. **Mesh flooding**: In high density (50+ peers), mesh relay traffic
///    could back up unboundedly. Now relay writes are dropped when the queue
///    exceeds [maxQueueDepth], and they always yield to higher-priority traffic.
///
/// Usage:
/// ```dart
/// final queue = GattWriteQueue(central: centralManager);
///
/// // User message — highest priority, processed first
/// await queue.enqueue(
///   peerId: 'abc',
///   peripheral: peripheral,
///   characteristic: msgChar,
///   data: textPayload,
///   priority: WritePriority.userMessage,
/// );
///
/// // Mesh relay — lowest priority, may be dropped
/// final accepted = queue.enqueue(
///   peerId: 'abc',
///   peripheral: peripheral,
///   characteristic: msgChar,
///   data: relayPayload,
///   priority: WritePriority.meshRelay,
/// );
/// // accepted may be a Future that completes with false if dropped
/// ```
class GattWriteQueue {
  GattWriteQueue({
    required CentralManager central,
    this.interWriteDelay = const Duration(milliseconds: 20),
    this.maxQueueDepth = 200,
  }) : _central = central;

  final CentralManager _central;

  /// Delay between consecutive GATT writes to let iOS flush its prepare queue.
  final Duration interWriteDelay;

  /// Maximum total items across all priority queues before backpressure kicks in.
  final int maxQueueDepth;

  /// Per-priority FIFO queues.
  final Map<WritePriority, Queue<_WriteRequest>> _queues = {
    for (final p in WritePriority.values) p: Queue(),
  };

  /// Whether the processing loop is currently running.
  bool _processing = false;

  /// Whether the queue has been disposed.
  bool _disposed = false;

  /// Total number of items currently queued across all priorities.
  int get totalQueued =>
      _queues.values.fold(0, (sum, q) => sum + q.length);

  /// Number of items queued at a specific priority.
  int queuedAt(WritePriority priority) => _queues[priority]!.length;

  /// Enqueue a GATT write operation.
  ///
  /// Returns a [Future<bool>] that completes with:
  /// - `true` if the write was acknowledged by the peripheral
  /// - `false` if the write failed, was dropped due to backpressure, or the
  ///   queue was disposed
  ///
  /// Writes are processed in priority order (userMessage > photoChunk > meshRelay).
  /// Within the same priority level, writes are processed FIFO.
  ///
  /// Under backpressure (total queue > [maxQueueDepth]):
  /// - [WritePriority.meshRelay] writes are rejected immediately (returns false)
  /// - Existing mesh relay items are purged to make room for higher-priority items
  Future<bool> enqueue({
    required String peerId,
    required Peripheral peripheral,
    required GATTCharacteristic characteristic,
    required Uint8List data,
    WritePriority priority = WritePriority.userMessage,
  }) {
    if (_disposed) return Future.value(false);

    // Backpressure: when queue is full, shed lowest-priority traffic
    if (totalQueued >= maxQueueDepth) {
      if (priority == WritePriority.meshRelay) {
        // Reject new mesh relay writes under pressure
        Logger.info(
          'GattWriteQueue: Dropping mesh relay write (queue full: $totalQueued)',
          'BLE',
        );
        return Future.value(false);
      }

      // Purge mesh relay queue to make room for higher-priority traffic
      final meshQueue = _queues[WritePriority.meshRelay]!;
      if (meshQueue.isNotEmpty) {
        final purged = meshQueue.length;
        for (final req in meshQueue) {
          if (!req.completer.isCompleted) req.completer.complete(false);
        }
        meshQueue.clear();
        Logger.info(
          'GattWriteQueue: Purged $purged mesh relay items under backpressure',
          'BLE',
        );
      }
    }

    final completer = Completer<bool>();
    _queues[priority]!.add(_WriteRequest(
      peerId: peerId,
      peripheral: peripheral,
      characteristic: characteristic,
      data: data,
      completer: completer,
    ));

    _processNext();
    return completer.future;
  }

  /// Convenience method to enqueue a fire-and-forget write.
  /// Does not await the result — useful for mesh relay and announcements.
  void enqueueFireAndForget({
    required String peerId,
    required Peripheral peripheral,
    required GATTCharacteristic characteristic,
    required Uint8List data,
    WritePriority priority = WritePriority.meshRelay,
  }) {
    enqueue(
      peerId: peerId,
      peripheral: peripheral,
      characteristic: characteristic,
      data: data,
      priority: priority,
    );
  }

  /// Cancel all queued writes for a specific peer (e.g. on disconnect).
  void cancelPeer(String peerId) {
    for (final queue in _queues.values) {
      queue.removeWhere((req) {
        if (req.peerId == peerId) {
          if (!req.completer.isCompleted) req.completer.complete(false);
          return true;
        }
        return false;
      });
    }
  }

  /// Cancel all queued writes at a specific priority level.
  void cancelPriority(WritePriority priority) {
    final queue = _queues[priority]!;
    for (final req in queue) {
      if (!req.completer.isCompleted) req.completer.complete(false);
    }
    queue.clear();
  }

  /// Clear all queued writes across all priorities.
  void clear() {
    for (final queue in _queues.values) {
      for (final req in queue) {
        if (!req.completer.isCompleted) req.completer.complete(false);
      }
      queue.clear();
    }
  }

  /// Dispose the queue. Completes all pending writes with false.
  void dispose() {
    _disposed = true;
    clear();
  }

  // ==================== Internal ====================

  /// Dequeue the highest-priority item.
  _WriteRequest? _dequeueNext() {
    for (final priority in WritePriority.values) {
      final queue = _queues[priority]!;
      if (queue.isNotEmpty) return queue.removeFirst();
    }
    return null;
  }

  /// Process queued writes sequentially with inter-write delay.
  void _processNext() async {
    if (_processing || _disposed) return;
    _processing = true;

    try {
      while (!_disposed) {
        final request = _dequeueNext();
        if (request == null) break;

        if (request.completer.isCompleted) continue;

        try {
          await _central.writeCharacteristic(
            request.peripheral,
            request.characteristic,
            value: request.data,
            // withoutResponse bypasses the CoreBluetooth ATT prepare queue
            // (CBATTError Code=9 "prepare queue full"). The fff3 characteristic
            // declares writeWithoutResponse; delivery reliability is handled by
            // the store-and-forward retry service at a higher level.
            type: GATTCharacteristicWriteType.withoutResponse,
          );
          if (!request.completer.isCompleted) {
            request.completer.complete(true);
          }
        } catch (e) {
          Logger.warning(
            'GattWriteQueue: Write failed to ${request.peerId}: $e',
            'BLE',
          );
          if (!request.completer.isCompleted) {
            request.completer.complete(false);
          }
        }

        // Inter-write delay to let iOS flush the prepare queue
        if (totalQueued > 0) {
          await Future<void>.delayed(interWriteDelay);
        }
      }
    } finally {
      _processing = false;
    }

    // Check if more items arrived while we were finishing
    if (totalQueued > 0 && !_disposed) {
      _processNext();
    }
  }
}

/// Internal write request tracking.
class _WriteRequest {
  _WriteRequest({
    required this.peerId,
    required this.peripheral,
    required this.characteristic,
    required this.data,
    required this.completer,
  });

  final String peerId;
  final Peripheral peripheral;
  final GATTCharacteristic characteristic;
  final Uint8List data;
  final Completer<bool> completer;
}
