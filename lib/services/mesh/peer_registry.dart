import 'dart:async';

import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/data/local_database/database.dart';
import 'package:anchor/services/transport/transport_enums.dart';

/// Single source of truth for all peer identity resolution.
///
/// ## Canonical Identity = userId
///
/// The canonical peer ID is ALWAYS the peer's app-level userId (a stable UUID
/// generated at profile creation). This ID never changes regardless of:
///   - BLE MAC rotation
///   - Transport switches (BLE ↔ LAN ↔ Wi-Fi Aware)
///   - App restarts or reconnections
///
/// Transport-specific IDs (BLE peripheral UUID, LAN session UUID, etc.) are
/// stored as aliases and used ONLY for routing — never as identity.
///
/// ## Maps
///
///   - `_byUserId`    — userId → PeerIdentity (primary lookup)
///   - `_toUserId`    — any transport-specific ID → userId (alias map)
///   - `_byCanonical` — alias for `_byUserId` (same data, keyed by userId)
///
/// ## Invariants
///
/// - Every alias `A → userId` has a corresponding PeerIdentity with that userId.
/// - No two PeerIdentities share the same userId.
/// - canonicalId == userId for every PeerIdentity.
class PeerRegistry {
  PeerRegistry();

  // ==================== Core Maps ====================

  /// userId → PeerIdentity (THE single source of truth)
  final Map<String, PeerIdentity> _byUserId = {};

  /// Any transport-specific ID → userId (alias map for routing lookups)
  final Map<String, String> _toUserId = {};

  // ==================== Streams ====================

  final _peerIdChangedController =
      StreamController<PeerIdChangedEvent>.broadcast();

  /// Emitted when a peer's transport IDs change (for consumers that cache
  /// transport-specific state like BLE connections).
  Stream<PeerIdChangedEvent> get peerIdChangedStream =>
      _peerIdChangedController.stream;

  // ==================== Public API ====================

  /// Resolve ANY transport-specific ID to the canonical userId.
  ///
  /// Returns null if the ID is completely unknown.
  String? resolveCanonical(String transportId) {
    // Already a userId?
    if (_byUserId.containsKey(transportId)) return transportId;
    // Alias?
    return _toUserId[transportId];
  }

  /// Resolve a canonical peer ID to the BLE peripheral UUID.
  ///
  /// Needed when TransportManager wants to fall back to BLE for a peer
  /// whose canonical ID is a userId.
  String? bleIdFor(String userId) {
    final identity = _byUserId[userId];
    if (identity == null) return null;
    return identity.transportIds[TransportType.ble];
  }

  /// Get the canonical userId for a known app userId (identity function).
  String? canonicalIdForUser(String userId) {
    return _byUserId.containsKey(userId) ? userId : null;
  }

  /// Get the userId for a canonical peer ID (identity function).
  String? userIdForCanonical(String canonicalId) {
    return _byUserId[canonicalId]?.userId;
  }

  /// Get the full PeerIdentity by userId.
  PeerIdentity? getByCanonical(String userId) {
    return _byUserId[userId];
  }

  /// Get the full PeerIdentity by userId.
  PeerIdentity? getByUserId(String userId) {
    return _byUserId[userId];
  }

  /// All known canonical peer IDs (userIds).
  Iterable<String> get allCanonicalIds => _byUserId.keys;

  /// All known PeerIdentities.
  Iterable<PeerIdentity> get allPeers => _byUserId.values;

  /// Register a transport endpoint for a peer.
  ///
  /// [userId] is REQUIRED for identity. If null, the registration is stored
  /// as an orphan alias that will be adopted when userId becomes known.
  ///
  /// This is the ONLY method that mutates peer identity state. It handles:
  /// - First discovery (creates new PeerIdentity)
  /// - Additional transport discovery (adds transport to existing peer)
  /// - BLE MAC rotation (same userId, new BLE UUID)
  ///
  /// Returns a [RegistrationResult] indicating what happened.
  RegistrationResult registerTransport({
    required String transportId,
    required TransportType transport,
    String? userId,
    String? publicKeyHex,
    String? signingPublicKeyHex,
  }) {
    // Case 1: Known userId — find or create identity
    if (userId != null && userId.isNotEmpty) {
      final existing = _byUserId[userId];
      if (existing != null) {
        final result = _updateExistingPeer(
            existing, transportId, transport, publicKeyHex,);
        if (signingPublicKeyHex != null) {
          _updateSigningKey(userId, signingPublicKeyHex);
        }
        return result;
      }

      // Check if this transportId was previously registered as an orphan
      final oldUserId = _toUserId[transportId];
      if (oldUserId != null) {
        final oldIdentity = _byUserId[oldUserId];
        if (oldIdentity != null && oldIdentity.userId == null) {
          // Adopt: attach userId to the existing orphan identity
          _byUserId.remove(oldUserId);
          final updated = PeerIdentity(
            userId: userId,
            canonicalId: userId,
            transportIds: {...oldIdentity.transportIds, transport: transportId},
            publicKeyHex: publicKeyHex ?? oldIdentity.publicKeyHex,
            signingPublicKeyHex:
                signingPublicKeyHex ?? oldIdentity.signingPublicKeyHex,
            lastSeen: DateTime.now(),
          );
          _byUserId[userId] = updated;
          // Re-point all transport aliases to the real userId
          for (final tid in updated.transportIds.values) {
            _toUserId[tid] = userId;
          }
          Logger.info(
            'PeerRegistry: Adopted userId $userId for orphan transport $transportId',
            'Mesh',
          );
          return RegistrationResult(
            type: RegistrationType.updated,
            canonicalId: userId,
            identity: updated,
          );
        }
      }

      // Brand new peer
      final result =
          _createNewPeer(transportId, transport, userId, publicKeyHex);
      if (signingPublicKeyHex != null) {
        _updateSigningKey(userId, signingPublicKeyHex);
      }
      return result;
    }

    // Case 2: No userId — register as orphan (will be adopted later)
    final existingUserId = _toUserId[transportId];
    if (existingUserId != null) {
      final identity = _byUserId[existingUserId]!;
      if (!identity.transportIds.containsKey(transport)) {
        final updated = identity.withTransport(transport, transportId);
        _byUserId[existingUserId] = updated;
      }
      if (signingPublicKeyHex != null) {
        _updateSigningKey(existingUserId, signingPublicKeyHex);
      }
      return RegistrationResult(
        type: RegistrationType.updated,
        canonicalId: existingUserId,
        identity: _byUserId[existingUserId]!,
      );
    }

    // Brand new orphan peer (no userId yet)
    final orphanId = transportId; // temporary canonical
    final identity = PeerIdentity(
      canonicalId: orphanId,
      transportIds: {transport: transportId},
      publicKeyHex: publicKeyHex,
      signingPublicKeyHex: signingPublicKeyHex,
      lastSeen: DateTime.now(),
    );
    _byUserId[orphanId] = identity;
    _toUserId[transportId] = orphanId;

    Logger.info(
      'PeerRegistry: Orphan peer $transportId (${transport.name}, no userId yet)',
      'Mesh',
    );

    return RegistrationResult(
      type: RegistrationType.created,
      canonicalId: orphanId,
      identity: identity,
    );
  }

  void _updateSigningKey(String userId, String signingPublicKeyHex) {
    final identity = _byUserId[userId];
    if (identity == null) return;
    final updated = identity.copyWith(signingPublicKeyHex: signingPublicKeyHex);
    _byUserId[userId] = updated;
  }

  /// Remove a transport endpoint for a peer.
  ///
  /// If no transports remain, removes the peer entirely.
  /// Returns the canonical ID that was affected, or null if unknown.
  String? removeTransport(String transportId, TransportType transport) {
    final userId = resolveCanonical(transportId);
    if (userId == null) return null;

    final identity = _byUserId[userId];
    if (identity == null) return null;

    final updated = identity.withoutTransport(transport);

    if (updated.transportIds.isEmpty) {
      // No transports left — remove peer entirely
      _removePeer(identity);
      return userId;
    }

    _byUserId[userId] = updated;
    _toUserId.remove(transportId);
    return userId;
  }

  /// Record a Central UUID → userId mapping for iOS cross-platform resolution.
  ///
  /// On iOS, Central and Peripheral UUIDs differ for the same device. When we
  /// receive a message from a Central connection before scanning the
  /// Peripheral, we record this mapping so that later Peripheral discovery
  /// can resolve the association.
  void recordCentralUuid(String centralUuid, String userId) {
    final existing = _byUserId[userId];
    if (existing != null) {
      // Already know this user — add Central as a transport alias
      _toUserId[centralUuid] = userId;
      Logger.debug(
        'PeerRegistry: Aliased Central $centralUuid → userId $userId',
        'Mesh',
      );
    } else {
      // Don't know this user yet — create identity with userId as canonical
      final identity = PeerIdentity(
        userId: userId,
        canonicalId: userId,
        transportIds: {TransportType.ble: centralUuid},
        lastSeen: DateTime.now(),
      );
      _byUserId[userId] = identity;
      _toUserId[centralUuid] = userId;
      Logger.debug(
        'PeerRegistry: Placeholder for Central $centralUuid (userId $userId)',
        'Mesh',
      );
    }
  }

  /// Get available transports for a peer (by userId).
  Set<TransportType> transportsFor(String userId) {
    return _byUserId[userId]?.transportIds.keys.toSet() ?? {};
  }

  /// Get the best (highest priority) transport for a peer.
  TransportType? bestTransportFor(String userId) {
    final identity = _byUserId[userId];
    if (identity == null) return null;
    return _bestTransportType(identity);
  }

  /// Update the public key for a peer (by userId).
  void updatePublicKey(String userId, String publicKeyHex) {
    final identity = _byUserId[userId];
    if (identity == null) return;
    _byUserId[userId] = identity.copyWith(publicKeyHex: publicKeyHex);
  }

  /// Update the last-seen timestamp for a peer.
  void touchPeer(String userId) {
    final identity = _byUserId[userId];
    if (identity == null) return;
    _byUserId[userId] = identity.copyWith(lastSeen: DateTime.now());
  }

  /// Clear all state (e.g., on BLE adapter restart).
  void clear() {
    _byUserId.clear();
    _toUserId.clear();
  }

  /// Populate in-memory maps from persisted [PeerAliasEntry] rows.
  ///
  /// Called once at startup so that transport ID → userId resolution works
  /// immediately, before any BLE/LAN discovery events arrive.
  void hydrateFromAliases(List<PeerAliasEntry> aliases) {
    for (final alias in aliases) {
      final transport = _parseTransportType(alias.transportType);
      if (transport == null) continue;

      registerTransport(
        transportId: alias.transportId,
        transport: transport,
        userId: alias.canonicalPeerId,
      );
    }
    if (aliases.isNotEmpty) {
      Logger.info(
        'PeerRegistry: Hydrated ${aliases.length} aliases → '
        '${_byUserId.length} peers',
        'Mesh',
      );
    }
  }

  static TransportType? _parseTransportType(String name) {
    for (final t in TransportType.values) {
      if (t.name == name) return t;
    }
    return null;
  }

  /// Remove a specific peer by userId.
  void removePeerByCanonical(String userId) {
    final identity = _byUserId[userId];
    if (identity != null) _removePeer(identity);
  }

  /// Get the transport-specific ID for a given transport type.
  String? transportIdFor(String userId, TransportType transport) {
    return _byUserId[userId]?.transportIds[transport];
  }

  // ==================== Internal ====================

  RegistrationResult _createNewPeer(
    String transportId,
    TransportType transport,
    String userId,
    String? publicKeyHex,
  ) {
    final identity = PeerIdentity(
      userId: userId,
      canonicalId: userId,
      transportIds: {transport: transportId},
      publicKeyHex: publicKeyHex,
      lastSeen: DateTime.now(),
    );

    _byUserId[userId] = identity;
    _toUserId[transportId] = userId;

    Logger.info(
      'PeerRegistry: New peer $userId (${transport.name}, transport=$transportId)',
      'Mesh',
    );

    return RegistrationResult(
      type: RegistrationType.created,
      canonicalId: userId,
      identity: identity,
    );
  }

  RegistrationResult _updateExistingPeer(
    PeerIdentity existing,
    String transportId,
    TransportType transport,
    String? publicKeyHex,
  ) {
    final userId = existing.userId!;
    final oldTransportId = existing.transportIds[transport];

    // Same transport, same ID — just touch
    if (oldTransportId == transportId) {
      final updated = existing.copyWith(
        lastSeen: DateTime.now(),
        publicKeyHex: publicKeyHex ?? existing.publicKeyHex,
      );
      _byUserId[userId] = updated;
      return RegistrationResult(
        type: RegistrationType.updated,
        canonicalId: userId,
        identity: updated,
      );
    }

    // Same transport, different ID — MAC rotation or transport session change
    if (oldTransportId != null) {
      Logger.info(
        'PeerRegistry: ${transport.name} ID changed for user $userId: '
        '$oldTransportId → $transportId',
        'Mesh',
      );
      // Remove old alias
      _toUserId.remove(oldTransportId);

      // Notify consumers that need to update transport-level state
      // (e.g., BLE connection caches). Canonical ID does NOT change.
      _peerIdChangedController.add(PeerIdChangedEvent(
        oldCanonicalId: oldTransportId,
        newCanonicalId: transportId,
        userId: userId,
      ),);
    }

    // Add new transport ID
    var updated = existing.withTransport(transport, transportId);
    updated = updated.copyWith(
      lastSeen: DateTime.now(),
      publicKeyHex: publicKeyHex ?? existing.publicKeyHex,
    );

    // Add alias for new transport ID
    _toUserId[transportId] = userId;
    _byUserId[userId] = updated;

    return RegistrationResult(
      type: RegistrationType.updated,
      canonicalId: userId,
      identity: updated,
    );
  }

  void _removePeer(PeerIdentity identity) {
    final userId = identity.userId ?? identity.canonicalId;
    _byUserId.remove(userId);
    // Remove all transport aliases
    for (final id in identity.transportIds.values) {
      _toUserId.remove(id);
    }
  }

  /// Pick the best transport TYPE for a peer.
  TransportType? _bestTransportType(PeerIdentity identity) {
    if (identity.transportIds.isEmpty) return null;
    final sorted = identity.transportIds.keys.toList()
      ..sort((a, b) => _priority(a).compareTo(_priority(b)));
    return sorted.first;
  }

  /// Transport priority (lower = higher priority).
  static int _priority(TransportType t) {
    switch (t) {
      case TransportType.lan:
        return 0;
      case TransportType.wifiAware:
        return 1;
      case TransportType.wifiDirect:
        return 2;
      case TransportType.ble:
        return 3;
    }
  }

  Future<void> dispose() async {
    await _peerIdChangedController.close();
  }
}

/// Immutable peer identity record.
class PeerIdentity {
  const PeerIdentity({
    required this.canonicalId, required this.transportIds, this.userId,
    this.publicKeyHex,
    this.signingPublicKeyHex,
    this.lastSeen,
  });

  /// App-level user ID (stable across transports and sessions).
  /// This IS the canonical identity once known.
  final String? userId;

  /// The canonical peer ID. Always equals [userId] when userId is known.
  final String canonicalId;

  /// Transport → transport-specific peer ID (for routing only).
  final Map<TransportType, String> transportIds;

  /// X25519 public key hex for E2EE.
  final String? publicKeyHex;

  /// Ed25519 signing public key hex for mesh announcement verification.
  final String? signingPublicKeyHex;

  /// Last time this peer was seen on any transport.
  final DateTime? lastSeen;

  PeerIdentity copyWith({
    String? userId,
    String? canonicalId,
    Map<TransportType, String>? transportIds,
    String? publicKeyHex,
    String? signingPublicKeyHex,
    DateTime? lastSeen,
  }) {
    return PeerIdentity(
      userId: userId ?? this.userId,
      canonicalId: canonicalId ?? this.canonicalId,
      transportIds: transportIds ?? this.transportIds,
      publicKeyHex: publicKeyHex ?? this.publicKeyHex,
      signingPublicKeyHex: signingPublicKeyHex ?? this.signingPublicKeyHex,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  PeerIdentity withTransport(TransportType transport, String id) {
    return copyWith(transportIds: {...transportIds, transport: id});
  }

  PeerIdentity withoutTransport(TransportType transport) {
    final newMap = Map<TransportType, String>.from(transportIds)
      ..remove(transport);
    return copyWith(transportIds: newMap);
  }

  @override
  String toString() =>
      'PeerIdentity(userId=$userId, canonical=$canonicalId, '
      'transports=${transportIds.map((k, v) => MapEntry(k.name, v))})';
}

/// Result of [PeerRegistry.registerTransport].
class RegistrationResult {
  const RegistrationResult({
    required this.type,
    required this.canonicalId,
    required this.identity, this.oldCanonicalId,
  });

  final RegistrationType type;
  final String canonicalId;

  /// Non-null only when [type] == [RegistrationType.migrated].
  final String? oldCanonicalId;

  final PeerIdentity identity;
}

enum RegistrationType {
  /// Brand new peer, never seen before.
  created,

  /// Existing peer, transport info updated.
  updated,

  /// Canonical ID changed (should not happen with userId-based identity).
  migrated,
}

/// Emitted when a peer's transport-level ID changes.
///
/// Note: With userId-based canonical identity, the canonical ID itself never
/// changes. This event signals transport-level changes (e.g., BLE MAC rotation)
/// so that consumers caching transport state can update accordingly.
class PeerIdChangedEvent {
  const PeerIdChangedEvent({
    required this.oldCanonicalId,
    required this.newCanonicalId,
    this.userId,
  });

  final String oldCanonicalId;
  final String newCanonicalId;
  final String? userId;
}
