import 'dart:collection';

import '../../core/utils/logger.dart';

// ---------------------------------------------------------------------------
// HandshakeRateLimiter
//
// Prevents Noise handshake abuse (DoS) by rate-limiting handshake attempts
// both per-peer and globally.
//
// Without rate limiting, an attacker could:
//   • Flood a device with handshake initiations, exhausting CPU on DH ops.
//   • Rapidly subscribe/unsubscribe to enumerate all nearby Anchor users.
//   • Trigger repeated handshake timeouts that block legitimate sessions.
//
// Limits (matching Bitchat's security constants):
//   • Per-peer:  max 10 handshakes per 60-second sliding window.
//   • Global:    max 30 handshakes per 60-second sliding window.
//
// Both windows use a sliding-window approach: each attempt is timestamped,
// and expired entries are pruned on every check.  Memory is bounded because
// at most (maxGlobalPerMinute) entries exist in the global window, and
// each peer window holds at most (maxPerPeerPerMinute) entries.
// ---------------------------------------------------------------------------

class HandshakeRateLimiter {
  HandshakeRateLimiter({
    this.maxPerPeerPerMinute = 10,
    this.maxGlobalPerMinute = 30,
  });

  /// Maximum handshake attempts per peer per 60-second window.
  final int maxPerPeerPerMinute;

  /// Maximum handshake attempts across all peers per 60-second window.
  final int maxGlobalPerMinute;

  static const _window = Duration(seconds: 60);

  /// Per-peer sliding window of attempt timestamps.
  final Map<String, Queue<DateTime>> _perPeer = {};

  /// Global sliding window of attempt timestamps.
  final Queue<DateTime> _global = Queue<DateTime>();

  /// Check whether a handshake attempt for [peerId] is allowed.
  ///
  /// Returns `true` if the attempt is within rate limits and has been
  /// recorded.  Returns `false` if rate-limited (attempt NOT recorded).
  bool tryAcquire(String peerId) {
    final now = DateTime.now();
    _pruneExpired(now);

    // Check global limit.
    if (_global.length >= maxGlobalPerMinute) {
      Logger.warning(
        'Handshake rate-limited (global): ${_global.length}/$maxGlobalPerMinute '
        'in last 60s — rejecting for $peerId',
        'E2EE',
      );
      return false;
    }

    // Check per-peer limit.
    final peerWindow = _perPeer[peerId] ??= Queue<DateTime>();
    if (peerWindow.length >= maxPerPeerPerMinute) {
      Logger.warning(
        'Handshake rate-limited (per-peer): ${peerWindow.length}/$maxPerPeerPerMinute '
        'in last 60s for $peerId',
        'E2EE',
      );
      return false;
    }

    // Record the attempt.
    peerWindow.add(now);
    _global.add(now);
    return true;
  }

  /// Check if a handshake attempt would be allowed without recording it.
  bool isAllowed(String peerId) {
    final now = DateTime.now();
    _pruneExpired(now);

    if (_global.length >= maxGlobalPerMinute) return false;

    final peerWindow = _perPeer[peerId];
    if (peerWindow != null && peerWindow.length >= maxPerPeerPerMinute) {
      return false;
    }

    return true;
  }

  /// Number of remaining attempts for [peerId] before rate-limited.
  int remainingForPeer(String peerId) {
    _pruneExpired(DateTime.now());
    final peerWindow = _perPeer[peerId];
    final peerUsed = peerWindow?.length ?? 0;
    final globalRemaining = maxGlobalPerMinute - _global.length;
    final peerRemaining = maxPerPeerPerMinute - peerUsed;
    return globalRemaining < peerRemaining ? globalRemaining : peerRemaining;
  }

  /// Remove expired entries (older than 60 seconds).
  void _pruneExpired(DateTime now) {
    final cutoff = now.subtract(_window);

    while (_global.isNotEmpty && _global.first.isBefore(cutoff)) {
      _global.removeFirst();
    }

    final emptyPeers = <String>[];
    for (final entry in _perPeer.entries) {
      final window = entry.value;
      while (window.isNotEmpty && window.first.isBefore(cutoff)) {
        window.removeFirst();
      }
      if (window.isEmpty) emptyPeers.add(entry.key);
    }

    // Clean up empty peer windows to prevent unbounded map growth.
    for (final peerId in emptyPeers) {
      _perPeer.remove(peerId);
    }
  }

  /// Reset all rate limit state.  Used in tests or when BLE restarts.
  void clear() {
    _perPeer.clear();
    _global.clear();
  }
}
