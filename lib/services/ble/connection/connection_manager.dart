import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;

import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/services/ble/ble_config.dart';
import 'package:anchor/services/ble/connection/peer_connection.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

/// Manages BLE GATT connections with pooling, lifecycle tracking, and reconnection.
///
/// This is the single source of truth for:
/// - "Is peer X connected?"
/// - "Give me peer X's characteristics"
/// - "How many concurrent connections do we have?"
///
/// Extracted from the monolithic BLE service (now [BleFacade]) to fix:
/// - Connection storms (scan triggering 50 concurrent connects)
/// - Stale handle bugs (16+ maps needing manual cleanup on disconnect)
/// - Race conditions (concurrent connect calls to the same peer)
/// - iOS connection limit violations (~8-10 max)
class ConnectionManager {
  ConnectionManager({
    required CentralManager central,
  })  : _central = central;

  final CentralManager _central;

  // ==================== Connection Pool ====================

  /// Per-peer connection records — THE single source of truth for connection state.
  final Map<String, PeerConnection> _connections = {};

  /// Peers currently being connected to — prevents concurrent connect calls
  /// on the same peripheral which cause iOS Core Bluetooth to disconnect.
  final Set<String> _connectingPeers = {};

  /// Completers so callers can await an in-progress connection attempt
  /// instead of starting a duplicate one.
  final Map<String, Completer<PeerConnection?>> _connectCompleters = {};

  /// Peers confirmed gone (app closed / out of range). Scan results from
  /// the iOS Core Bluetooth cache still arrive after the peer is gone, so we
  /// suppress re-discovery until a GATT connection actually succeeds.
  /// Each entry expires after [_deadPeerCooldown].
  final Map<String, DateTime> _deadPeers = {};

  /// Discovered peripherals that haven't been connected yet.
  /// Stored so that sendMessage can trigger a connect on-demand.
  final Map<String, Peripheral> _knownPeripherals = {};

  /// Maximum concurrent GATT connections.
  /// iOS supports ~8-10, Android ~20-50. We use a conservative limit.
  static const _maxConnections = 5;

  /// Cooldown before allowing re-connection to a dead peer.
  static const _deadPeerCooldown = Duration(seconds: 60);

  /// Maximum consecutive failures before declaring peer unreachable.
  static const _maxConsecutiveFailures = 2;

  /// Queue of pending connection requests when pool is full.
  final Queue<_ConnectRequest> _connectQueue = Queue();

  /// Number of connection attempts currently in flight.
  int _activeConnectAttempts = 0;

  /// Maximum concurrent connection attempts (separate from pool size).
  /// Kept at 3 to avoid overwhelming the BLE stack — non-Anchor devices
  /// waste slots and increasing this causes more failed attempts.
  static const _maxConcurrentConnectAttempts = 3;

  // ==================== Streams ====================

  final _disconnectedController = StreamController<String>.broadcast();
  final _connectedController = StreamController<String>.broadcast();
  final _peerUnreachableController = StreamController<String>.broadcast();

  /// Emitted when a peer disconnects (GATT connection lost).
  Stream<String> get onDisconnected => _disconnectedController.stream;

  /// Emitted when a GATT connection is successfully established with a peer.
  Stream<String> get onConnected => _connectedController.stream;

  /// Emitted when a peer is declared unreachable after consecutive failures.
  Stream<String> get onPeerUnreachable => _peerUnreachableController.stream;

  // ==================== Connection State Subscription ====================

  StreamSubscription<PeripheralConnectionStateChangedEventArgs>? _connectionStateSubscription;

  /// Start listening to central manager connection state changes.
  /// Call once after CentralManager is initialized.
  void startListening() {
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription =
        _central.connectionStateChanged.listen(_onConnectionStateChanged);
  }

  // ==================== Public API ====================

  /// Register a peripheral we've seen via scan but haven't connected to yet.
  /// This allows on-demand connection when sendMessage needs it.
  void registerPeripheral(String peerId, Peripheral peripheral) {
    _knownPeripherals[peerId] = peripheral;
  }

  /// Get the Peripheral reference for a peer (connected or just discovered).
  Peripheral? getPeripheral(String peerId) {
    return _connections[peerId]?.peripheral ?? _knownPeripherals[peerId];
  }

  /// Connect to a peer, returning a [PeerConnection] with cached characteristics.
  ///
  /// - If already connected, returns existing connection (updates LRU).
  /// - If another call is connecting the same peer, awaits that result.
  /// - If pool is full, evicts the LRU peer first.
  /// - If concurrent connect limit is reached, queues the request.
  /// - Returns null if connection fails.
  Future<PeerConnection?> connect(String peerId, Peripheral peripheral) async {
    // Return existing if alive
    final existing = _connections[peerId];
    if (existing != null && existing.isConnected && existing.messagingChar != null) {
      existing.touch();
      return existing;
    }

    // If another call is already connecting this peer, await it
    if (_connectingPeers.contains(peerId)) {
      final completer = _connectCompleters[peerId];
      if (completer != null && !completer.isCompleted) {
        return completer.future;
      }
      return null;
    }

    // Check dead peer cooldown
    if (isDeadPeer(peerId)) {
      return null;
    }

    // Store peripheral reference
    _knownPeripherals[peerId] = peripheral;

    // If too many concurrent connect attempts, queue this one
    if (_activeConnectAttempts >= _maxConcurrentConnectAttempts) {
      final completer = Completer<PeerConnection?>();
      _connectQueue.add(_ConnectRequest(peerId, peripheral, completer));
      return completer.future;
    }

    return _doConnect(peerId, peripheral);
  }

  /// Disconnect and fully clean up a single peer.
  ///
  /// This is the ONE place that cleans up connection state — not 16 scattered
  /// map removals. Call this instead of manually clearing maps.
  void disconnect(String peerId, {bool markDead = false}) {
    final conn = _connections.remove(peerId);
    _connectingPeers.remove(peerId);

    final completer = _connectCompleters.remove(peerId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(null);
    }

    if (conn != null) {
      final wasConnected = conn.isConnected;
      conn.markDisconnected();

      if (wasConnected) {
        _central.disconnect(conn.peripheral).catchError((_) {});
      }

      if (wasConnected) {
        Logger.info(
          'ConnectionManager: Disconnected peer $peerId',
          'BLE',
        );
        _disconnectedController.add(peerId);
      }
    }

    if (markDead) {
      _deadPeers[peerId] = DateTime.now();
    }

    // Process queued connection requests now that a slot opened
    _processQueue();
  }

  /// Check if a peer is in the dead-peer cooldown period.
  bool isDeadPeer(String peerId) {
    final deadSince = _deadPeers[peerId];
    if (deadSince == null) return false;
    if (DateTime.now().difference(deadSince) >= _deadPeerCooldown) {
      _deadPeers.remove(peerId);
      return false;
    }
    return true;
  }

  /// Clear a peer's dead status (e.g., after successful GATT activity proves they're alive).
  void clearDeadStatus(String peerId) {
    _deadPeers.remove(peerId);
  }

  /// Get the connection for a peer, or null if not connected.
  PeerConnection? getConnection(String peerId) {
    final conn = _connections[peerId];
    if (conn != null && conn.isConnected) return conn;
    return null;
  }

  /// Get the messaging characteristic for a peer, or null if not connected.
  GATTCharacteristic? getMessagingChar(String peerId) =>
      _connections[peerId]?.messagingChar;

  /// Whether a peer has an active connection with messaging capability.
  bool canSendTo(String peerId) =>
      _connections[peerId]?.canSendMessages ?? false;

  /// Whether a peer is currently connected (may not have messaging char yet).
  bool isConnected(String peerId) =>
      _connections[peerId]?.isConnected ?? false;

  /// List of all currently connected peer IDs.
  List<String> get connectedPeerIds =>
      _connections.entries
          .where((e) => e.value.isConnected)
          .map((e) => e.key)
          .toList();

  /// Number of active connections.
  int get activeConnectionCount =>
      _connections.values.where((c) => c.isConnected).length;

  /// Touch a peer's LRU timestamp after confirmed GATT activity.
  void touchPeer(String peerId) {
    final conn = _connections[peerId];
    if (conn != null) {
      conn
        ..touch()
        ..resetFailures();
      clearDeadStatus(peerId);
    }
  }

  /// Clear all state. Called on BLE service stop/dispose.
  void clear() {
    for (final completer in _connectCompleters.values) {
      if (!completer.isCompleted) completer.complete(null);
    }
    _connectCompleters.clear();
    _connectingPeers.clear();
    _connections.clear();
    _knownPeripherals.clear();
    _deadPeers.clear();
    _connectQueue.clear();
    _activeConnectAttempts = 0;
  }

  /// Dispose streams.
  Future<void> dispose() async {
    clear();
    await _connectionStateSubscription?.cancel();
    await _disconnectedController.close();
    await _connectedController.close();
    await _peerUnreachableController.close();
  }

  // ==================== Internal ====================

  Future<PeerConnection?> _doConnect(String peerId, Peripheral peripheral) async {
    _connectingPeers.add(peerId);
    final completer = Completer<PeerConnection?>();
    _connectCompleters[peerId] = completer;
    _activeConnectAttempts++;

    try {
      final conn = await _connectImpl(peerId, peripheral);
      if (!completer.isCompleted) completer.complete(conn);
      return conn;
    } on Exception {
      if (!completer.isCompleted) completer.complete(null);
      return null;
    } finally {
      _connectingPeers.remove(peerId);
      _connectCompleters.remove(peerId);
      _activeConnectAttempts--;
      _processQueue();
    }
  }

  Future<PeerConnection?> _connectImpl(
      String peerId, Peripheral peripheral,) async {
    // Evict LRU if pool is full
    if (activeConnectionCount >= _maxConnections) {
      _evictLru(excludePeerId: peerId);
    }

    try {
      await _central.connect(peripheral);

      // Negotiate MTU on Android (iOS auto-negotiates)
      if (Platform.isAndroid) {
        try {
          await _central.requestMTU(peripheral, mtu: 517);
        } on Exception {
          Logger.warning(
              'ConnectionManager: MTU request failed for $peerId', 'BLE',);
        }
      }

      // Query safe write length
      var maxWriteLen = 182; // conservative default
      try {
        maxWriteLen = await _central.getMaximumWriteLength(
          peripheral,
          type: GATTCharacteristicWriteType.withResponse,
        );
      } on Exception {
        Logger.warning(
            'ConnectionManager: getMaximumWriteLength failed for $peerId',
            'BLE',);
      }

      // Discover GATT services
      final services = await _central.discoverGATT(peripheral);
      final anchorService = services
          .where((s) => s.uuid == _serviceUuid)
          .firstOrNull;

      if (anchorService == null) {
        Logger.info(
            'ConnectionManager: No Anchor service on $peerId — disconnecting',
            'BLE',);
        await _central.disconnect(peripheral);
        return null;
      }

      // Build PeerConnection with cached characteristics
      final conn = PeerConnection(
        peerId: peerId,
        peripheral: peripheral,
        maxWriteLength: maxWriteLen,
      );

      for (final char in anchorService.characteristics) {
        if (char.uuid == _profileCharUuid) {
          conn.profileChar = char;
        } else if (char.uuid == _thumbnailCharUuid) {
          conn.thumbnailChar = char;
        } else if (char.uuid == _messagingCharUuid) {
          conn.messagingChar = char;
        } else if (char.uuid == _fullPhotosCharUuid) {
          conn.fullPhotosChar = char;
        } else if (char.uuid == _reversePathCharUuid) {
          conn.reversePathChar = char;
        }
      }

      conn.resetFailures();
      _connections[peerId] = conn;
      clearDeadStatus(peerId);
      _connectedController.add(peerId);

      Logger.info(
        'ConnectionManager: [CONNECTED] $peerId '
        '(maxWrite=$maxWriteLen, '
        'fff1=${conn.profileChar != null}, '
        'fff2=${conn.thumbnailChar != null}, '
        'fff3=${conn.messagingChar != null}, '
        'fff4=${conn.fullPhotosChar != null}, '
        'fff5=${conn.reversePathChar != null}, '
        'pool=$activeConnectionCount/$_maxConnections)',
        'BLE',
      );

      return conn;
    } on Exception catch (e) {
      // Track consecutive failures
      final existing = _connections[peerId];
      final failures = existing?.recordFailure() ??
          (_getOrCreateStubConnection(peerId, peripheral).recordFailure());

      Logger.warning(
        'ConnectionManager: Connect to $peerId failed '
        '($failures consecutive): $e',
        'BLE',
      );

      if (failures >= _maxConsecutiveFailures) {
        Logger.info(
          'ConnectionManager: Peer $peerId unreachable after $failures failures',
          'BLE',
        );
        _deadPeers[peerId] = DateTime.now();
        _connections.remove(peerId);
        _peerUnreachableController.add(peerId);
      }

      return null;
    }
  }

  /// Create a stub connection to track failure count for peers we've never
  /// fully connected to.
  PeerConnection _getOrCreateStubConnection(
      String peerId, Peripheral peripheral,) {
    return _connections.putIfAbsent(
      peerId,
      () => PeerConnection(peerId: peerId, peripheral: peripheral)
        ..isConnected = false,
    );
  }

  /// Evict the least-recently-used connection to make room.
  void _evictLru({String? excludePeerId}) {
    PeerConnection? lru;
    for (final conn in _connections.values) {
      if (!conn.isConnected) continue;
      if (conn.peerId == excludePeerId) continue;
      if (lru == null || conn.lastActivity.isBefore(lru.lastActivity)) {
        lru = conn;
      }
    }

    if (lru != null) {
      Logger.info(
        'ConnectionManager: Evicting LRU peer ${lru.peerId}',
        'BLE',
      );
      disconnect(lru.peerId);
    }
  }

  /// Process queued connection requests.
  void _processQueue() {
    while (_connectQueue.isNotEmpty &&
        _activeConnectAttempts < _maxConcurrentConnectAttempts) {
      final request = _connectQueue.removeFirst();
      if (!request.completer.isCompleted) {
        _doConnect(request.peerId, request.peripheral).then((conn) {
          if (!request.completer.isCompleted) {
            request.completer.complete(conn);
          }
        });
      }
    }
  }

  /// Handle peripheral disconnection from the CentralManager.
  void _onConnectionStateChanged(
      PeripheralConnectionStateChangedEventArgs args,) {
    final peerId = args.peripheral.uuid.toString();
    if (args.state == ConnectionState.disconnected) {
      final conn = _connections[peerId];
      if (conn != null && conn.isConnected) {
        Logger.info(
          'ConnectionManager: [DISCONNECTED] $peerId '
          '(pool=${activeConnectionCount - 1}/$_maxConnections)',
          'BLE',
        );
        conn.markDisconnected();
        _connections.remove(peerId);
        _connectingPeers.remove(peerId);
        final completer = _connectCompleters.remove(peerId);
        if (completer != null && !completer.isCompleted) {
          completer.complete(null);
        }
        _disconnectedController.add(peerId);
      }
    } else {
      Logger.debug(
        'ConnectionManager: Peripheral $peerId state → ${args.state}',
        'BLE',
      );
    }
  }

  // ==================== UUIDs ====================
  // UUIDs — centralized in BleUuids (ble_config.dart)
  static final _serviceUuid = BleUuids.service;
  static final _profileCharUuid = BleUuids.profileChar;
  static final _thumbnailCharUuid = BleUuids.thumbnailChar;
  static final _messagingCharUuid = BleUuids.messagingChar;
  static final _fullPhotosCharUuid = BleUuids.fullPhotosChar;
  static final _reversePathCharUuid = BleUuids.reversePathChar;
}

/// Queued connection request when the concurrent limit is reached.
class _ConnectRequest {
  _ConnectRequest(this.peerId, this.peripheral, this.completer);

  final String peerId;
  final Peripheral peripheral;
  final Completer<PeerConnection?> completer;
}
