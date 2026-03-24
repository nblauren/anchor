import 'dart:async';

import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/services/transport/transport_enums.dart';
import 'package:flutter/foundation.dart' show immutable;

/// Per-peer, per-transport health metrics.
class TransportHealth {
  const TransportHealth({
    this.totalSends = 0,
    this.successfulSends = 0,
    this.avgRttMs = 0,
    this.lastRttMs = 0,
  });

  final int totalSends;
  final int successfulSends;
  final double avgRttMs;
  final int lastRttMs;

  double get successRate =>
      totalSends > 0 ? successfulSends / totalSends : 0.0;

  TransportHealth _updated({
    required bool success,
    required int rttMs,
  }) {
    final newTotal = totalSends + 1;
    final newSuccess = successfulSends + (success ? 1 : 0);
    final newAvg = success
        ? (avgRttMs * successfulSends + rttMs) / newSuccess
        : avgRttMs;
    return TransportHealth(
      totalSends: newTotal,
      successfulSends: newSuccess,
      avgRttMs: newAvg,
      lastRttMs: success ? rttMs : lastRttMs,
    );
  }

  @override
  String toString() =>
      'TransportHealth(sends=$totalSends, ok=$successfulSends, '
      'rate=${(successRate * 100).toStringAsFixed(0)}%, '
      'avgRtt=${avgRttMs.toStringAsFixed(0)}ms)';
}

/// Composite key for per-peer, per-transport tracking.
@immutable
class _HealthKey {
  const _HealthKey(this.peerId, this.transport);
  final String peerId;
  final TransportType transport;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _HealthKey &&
          peerId == other.peerId &&
          transport == other.transport;

  @override
  int get hashCode => Object.hash(peerId, transport);
}

/// Summary emitted on [healthStream] after each recorded send.
class TransportHealthSummary {
  const TransportHealthSummary({
    required this.peerId,
    required this.transport,
    required this.health,
  });

  final String peerId;
  final TransportType transport;
  final TransportHealth health;
}

/// Tracks per-peer, per-transport send metrics.
///
/// No timers or probes — piggybacks on real sends only. Call
/// [recordSendResult] after each transport attempt.
class TransportHealthTracker {
  final Map<_HealthKey, TransportHealth> _metrics = {};

  final _healthController =
      StreamController<TransportHealthSummary>.broadcast();

  /// Emits a summary after each recorded send.
  Stream<TransportHealthSummary> get healthStream => _healthController.stream;

  /// Record the outcome of a send attempt.
  void recordSendResult(
    String peerId,
    TransportType transport, {
    required bool success,
    required int rttMs,
  }) {
    final key = _HealthKey(peerId, transport);
    final current = _metrics[key] ?? const TransportHealth();
    final updated = current._updated(success: success, rttMs: rttMs);
    _metrics[key] = updated;

    _healthController.add(TransportHealthSummary(
      peerId: peerId,
      transport: transport,
      health: updated,
    ),);

    Logger.debug(
      'TransportHealth: ${transport.name} → '
      '${peerId.length > 8 ? peerId.substring(0, 8) : peerId}… $updated',
      'Transport',
    );
  }

  /// Get current health for a specific peer + transport, or null if no data.
  TransportHealth? healthFor(String peerId, TransportType transport) =>
      _metrics[_HealthKey(peerId, transport)];

  /// Get all health entries for a peer (all transports).
  Map<TransportType, TransportHealth> healthForPeer(String peerId) {
    final result = <TransportType, TransportHealth>{};
    for (final entry in _metrics.entries) {
      if (entry.key.peerId == peerId) {
        result[entry.key.transport] = entry.value;
      }
    }
    return result;
  }

  Future<void> dispose() async {
    await _healthController.close();
  }
}
