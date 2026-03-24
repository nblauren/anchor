import 'dart:async';

import 'package:anchor/core/constants/app_constants.dart';
import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/services/ble/ble_models.dart' as ble;
import 'package:anchor/services/transport/transport_enums.dart';
import 'package:anchor/services/transport/transport_manager.dart';

/// Type of pending send (determines how to re-send).
enum PendingSendType { text, photo, reaction, readReceipt, dropAnchor }

/// An in-memory pending send waiting to be retried when a transport becomes
/// available.
class PendingSend {
  PendingSend({
    required this.peerId,
    required this.messageId,
    required this.type,
    required this.payload,
    DateTime? enqueuedAt,
  })  : enqueuedAt = enqueuedAt ?? DateTime.now(),
        attempts = 0;

  final String peerId;
  final String messageId;
  final PendingSendType type;

  /// The [MessagePayload] to re-send. For photos this is the preview/request,
  /// not the full photo data.
  final ble.MessagePayload payload;

  final DateTime enqueuedAt;
  int attempts;

  bool get isExpired {
    final elapsed = DateTime.now().difference(enqueuedAt);
    return elapsed.inMinutes >= AppConstants.retryQueueExpiryMinutes;
  }

  bool get isMaxAttempts => attempts >= AppConstants.maxInSessionRetries;
}

/// Emitted when a retry succeeds or is abandoned.
class RetryDeliveryUpdate {
  const RetryDeliveryUpdate({
    required this.messageId,
    required this.delivered,
  });

  final String messageId;
  final bool delivered;
}

/// In-memory retry queue for messages that failed on all transports.
///
/// Subscribes to [TransportManager.peerTransportChangedStream] and
/// [peerDiscoveredStream] to flush pending sends when a peer's transport
/// becomes available.
///
/// Complements (does not replace) [StoreAndForwardService] which handles
/// cross-session persistence.
class TransportRetryQueue {
  TransportRetryQueue({
    required TransportManager transportManager,
  }) : _transportManager = transportManager {
    _transportChangedSub =
        _transportManager.peerTransportChangedStream.listen(_onTransportChanged);
    _peerDiscoveredSub =
        _transportManager.peerDiscoveredStream.listen(_onPeerDiscovered);
  }

  final TransportManager _transportManager;

  /// Pending sends keyed by peerId.
  final Map<String, List<PendingSend>> _pending = {};

  StreamSubscription<PeerTransportChanged>? _transportChangedSub;
  StreamSubscription<ble.DiscoveredPeer>? _peerDiscoveredSub;

  final _deliveryController =
      StreamController<RetryDeliveryUpdate>.broadcast();

  /// Emits when a retry succeeds or a message is abandoned.
  Stream<RetryDeliveryUpdate> get deliveryStream =>
      _deliveryController.stream;

  /// Number of items currently queued.
  int get length {
    var count = 0;
    for (final list in _pending.values) {
      count += list.length;
    }
    return count;
  }

  /// Enqueue a message for retry. Drops the oldest item if the queue exceeds
  /// [AppConstants.maxRetryQueueSize].
  void enqueue(PendingSend item) {
    // Prune expired items first
    _pruneExpired();

    // Cap total queue size
    if (length >= AppConstants.maxRetryQueueSize) {
      _dropOldest();
    }

    final list = _pending.putIfAbsent(item.peerId, () => []);

    // Deduplicate by messageId
    if (list.any((p) => p.messageId == item.messageId)) return;

    list.add(item);
    Logger.info(
      'RetryQueue: enqueued ${item.messageId.substring(0, 8)}… '
      'for ${item.peerId.substring(0, 8)}… (queue=$length)',
      'Transport',
    );
  }

  /// Remove a specific message from the queue (e.g. if user deletes it).
  void remove(String messageId) {
    for (final list in _pending.values) {
      list.removeWhere((p) => p.messageId == messageId);
    }
    _pending.removeWhere((_, list) => list.isEmpty);
  }

  void _onTransportChanged(PeerTransportChanged event) {
    _flushPeer(event.peerId);
  }

  void _onPeerDiscovered(ble.DiscoveredPeer peer) {
    _flushPeer(peer.peerId);
  }

  /// Attempt to send all pending messages for [peerId].
  Future<void> _flushPeer(String peerId) async {
    final list = _pending[peerId];
    if (list == null || list.isEmpty) return;

    // Take a snapshot and clear immediately to prevent double-flush
    final snapshot = List<PendingSend>.from(list);
    list.clear();

    for (final item in snapshot) {
      if (item.isExpired || item.isMaxAttempts) {
        _deliveryController.add(RetryDeliveryUpdate(
          messageId: item.messageId,
          delivered: false,
        ),);
        continue;
      }

      item.attempts++;
      try {
        final success =
            await _transportManager.sendMessage(peerId, item.payload);
        if (success) {
          _deliveryController.add(RetryDeliveryUpdate(
            messageId: item.messageId,
            delivered: true,
          ),);
          Logger.info(
            'RetryQueue: delivered ${item.messageId.substring(0, 8)}… '
            'on attempt ${item.attempts}',
            'Transport',
          );
        } else {
          // Re-enqueue for next opportunity
          list.add(item);
        }
      } catch (e) {
        Logger.warning(
          'RetryQueue: retry failed for ${item.messageId.substring(0, 8)}…: $e',
          'Transport',
        );
        list.add(item);
      }
    }

    if (list.isEmpty) {
      _pending.remove(peerId);
    }
  }

  void _pruneExpired() {
    for (final list in _pending.values) {
      list.removeWhere((item) {
        if (item.isExpired || item.isMaxAttempts) {
          _deliveryController.add(RetryDeliveryUpdate(
            messageId: item.messageId,
            delivered: false,
          ),);
          return true;
        }
        return false;
      });
    }
    _pending.removeWhere((_, list) => list.isEmpty);
  }

  void _dropOldest() {
    PendingSend? oldest;
    String? oldestPeerId;
    for (final entry in _pending.entries) {
      for (final item in entry.value) {
        if (oldest == null || item.enqueuedAt.isBefore(oldest.enqueuedAt)) {
          oldest = item;
          oldestPeerId = entry.key;
        }
      }
    }
    if (oldest != null && oldestPeerId != null) {
      _pending[oldestPeerId]?.remove(oldest);
      if (_pending[oldestPeerId]?.isEmpty ?? false) {
        _pending.remove(oldestPeerId);
      }
      _deliveryController.add(RetryDeliveryUpdate(
        messageId: oldest.messageId,
        delivered: false,
      ),);
    }
  }

  Future<void> dispose() async {
    await _transportChangedSub?.cancel();
    await _peerDiscoveredSub?.cancel();
    await _deliveryController.close();
  }
}
