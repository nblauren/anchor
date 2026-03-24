import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/services/nearby/high_speed_transfer_service.dart';
import 'package:anchor/services/nearby/nearby_models.dart';
import 'package:flutter_nearby_connections_plus/flutter_nearby_connections_plus.dart';

/// Production implementation of [HighSpeedTransferService] using
/// flutter_nearby_connections_plus.
///
/// ## Coordination protocol
///
///   1. **Sender** starts ADVERTISING immediately on receiving the consent
///      photo_request (already visible before the BLE signal is sent).
///   2. Sender sends `wifiTransferReady` BLE signal to receiver.
///   3. **Receiver** gets the BLE signal and starts BROWSING.
///   4. Receiver discovers the sender → invites → connection established.
///   5. Sender streams base64-encoded chunks over the text message channel.
///   6. Both sides stop Nearby when done.
///
/// Binary data is base64-encoded and split into 24 KB chunks (~32 KB base64).
/// Even with 33 % overhead a 5 MB photo transfers in < 1 s over Wi-Fi Direct
/// vs. ~3 min over BLE.
class NearbyTransferServiceImpl implements HighSpeedTransferService {
  NearbyTransferServiceImpl();

  static const String _tag = 'NearbyTransfer';
  static const String _serviceType = 'anchor-xfer';

  /// Max raw bytes per chunk (24 KB → ~32 KB base64).
  static const int _chunkSize = 24 * 1024;

  NearbyService? _nearbyService;
  String _ownUserId = 'anchor-user';
  bool _initialized = false;
  Future<void>? _initFuture;

  // Transfer tracking
  final Map<String, _OutgoingTransfer> _outgoing = {};
  final Map<String, _IncomingTransfer> _incoming = {};

  // Public streams
  final _progressController =
      StreamController<NearbyTransferProgress>.broadcast();
  final _payloadController =
      StreamController<NearbyPayloadReceived>.broadcast();

  // Native subscriptions
  StreamSubscription<dynamic>? _deviceSubscription;
  StreamSubscription<dynamic>? _dataSubscription;

  // Device tracking
  final Map<String, Device> _connectedDevices = {};
  final Map<String, Device> _discoveredDevices = {};

  // Prevent duplicate invitations
  final Set<String> _pendingInvites = {};

  // Timer for browse restart (iOS Multipeer workaround).
  Timer? _inviteTimer;

  // The peerId we're currently trying to invite (set during receivePayload).
  String? _targetInvitePeerId;

  // ---------------------------------------------------------------------------
  // Initialization
  // ---------------------------------------------------------------------------

  @override
  Future<void> initialize({required String ownUserId}) async {
    _ownUserId = ownUserId;
    if (_initialized) return;
    // Deduplicate concurrent init calls.
    _initFuture ??= _doInit();
    await _initFuture;
  }

  Future<bool> _ensureInitialized() async {
    if (_initialized) return true;
    _initFuture ??= _doInit();
    await _initFuture;
    return _initialized;
  }

  Future<void> _doInit() async {
    // Cancel old stream subscriptions but REUSE the NearbyService instance if
    // it already exists — creating multiple instances leaks native resources on
    // Android because each init() call creates fresh ServiceBindManager objects.
    await _deviceSubscription?.cancel();
    await _dataSubscription?.cancel();
    _nearbyService ??= NearbyService();

    try {
      await _nearbyService!.init(
        serviceType: _serviceType,
        deviceName: _ownUserId,
        strategy: Strategy.P2P_STAR, // star allows 1 advertiser + N browsers
        callback: (bool isRunning) {
          Logger.info('Nearby running: $isRunning', _tag);
        },
      );

      _deviceSubscription =
          _nearbyService!.stateChangedSubscription(callback: (devices) {
        for (final device in devices) {
          Logger.info(
            'Nearby state: ${device.deviceName} → ${device.state}',
            _tag,
          );
          if (device.state == SessionState.connected) {
            _connectedDevices[device.deviceId] = device;
            _discoveredDevices.remove(device.deviceId);
            _pendingInvites.remove(device.deviceId);
            // Resolve the connection completer if anyone is waiting.
            if (_connectionCompleter != null &&
                !_connectionCompleter!.isCompleted) {
              _connectionCompleter!.complete(true);
            }
          } else if (device.state == SessionState.notConnected) {
            _discoveredDevices[device.deviceId] = device;
            _connectedDevices.remove(device.deviceId);
            _pendingInvites.remove(device.deviceId);
            // A new device was discovered — try inviting if we have a target.
            if (_targetInvitePeerId != null) {
              Logger.debug(
                'Discovered device: name="${device.deviceName}" '
                'id=${device.deviceId} (target=$_targetInvitePeerId)',
                _tag,
              );
              _tryInvitePeer(_targetInvitePeerId!);
            }
          }
        }
      },);

      _dataSubscription =
          _nearbyService!.dataReceivedSubscription(callback: (data) {
        _handleReceivedData(data);
      },);

      _initialized = true;
      Logger.info('NearbyTransferService ready ($_ownUserId)', _tag);
    } on Exception catch (e) {
      _initialized = false;
      _initFuture = null; // Allow retry on next call.
      Logger.error('NearbyTransferService init failed', e, null, _tag);
    }
  }

  @override
  Future<bool> get isAvailable async {
    if (!_initialized) await _ensureInitialized();
    return _initialized;
  }

  // ---------------------------------------------------------------------------
  // Send  (sender = ADVERTISER)
  // ---------------------------------------------------------------------------

  @override
  Future<bool> sendPayload({
    required String transferId,
    required String peerId,
    required Uint8List data,
    Duration timeout = const Duration(seconds: 15),
    void Function()? onAdvertising,
  }) async {
    if (!await _ensureInitialized()) {
      Logger.error('sendPayload: init failed', null, null, _tag);
      return false;
    }

    Logger.info(
      'sendPayload: id=$transferId peer=$peerId size=${data.length}',
      _tag,
    );
    _emitProgress(transferId, peerId, NearbyTransferStatus.discovering, 0);

    try {
      // Clean up stale state from any previous transfer before starting.
      try {
        await _nearbyService!.stopAdvertisingPeer();
        await _nearbyService!.stopBrowsingForPeers();
      } on Exception catch (_) {}
      _connectedDevices.clear();
      _discoveredDevices.clear();
      _pendingInvites.clear();

      // 1. Advertise with our userId so the receiver can find us.
      await _nearbyService!.startAdvertisingPeer(deviceName: _ownUserId);
      Logger.info('sendPayload: advertising as $_ownUserId', _tag);

      // Signal to caller that advertising is active — safe to tell receiver
      // to start browsing now.
      onAdvertising?.call();

      // 2. Wait for the receiver to browse → discover us → invite → connect.
      final connected = await _waitForPeerConnected(peerId, timeout);
      if (!connected) {
        Logger.warning('sendPayload: connection timeout', _tag);
        _emitProgress(transferId, peerId, NearbyTransferStatus.failed, 0,
            error: 'Connection timeout',);
        await _stopNearby();
        return false;
      }

      Logger.info('sendPayload: connected to peer, starting transfer', _tag);
      _emitProgress(transferId, peerId, NearbyTransferStatus.transferring, 0);

      // 3. Find the connected device and send chunks.
      final deviceId = _findDeviceIdForPeer(peerId);
      if (deviceId == null) {
        Logger.error('sendPayload: device lost after connect', null, null, _tag);
        _emitProgress(transferId, peerId, NearbyTransferStatus.failed, 0,
            error: 'Device lost',);
        await _stopNearby();
        return false;
      }

      final base64Data = base64Encode(data);
      final totalChunks = (base64Data.length / _chunkSize).ceil();

      _outgoing[transferId] = _OutgoingTransfer(
        transferId: transferId,
        totalChunks: totalChunks,
      );

      // Header
      await _sendJson(deviceId, {
        'type': 'transfer_header',
        'transfer_id': transferId,
        'sender_id': _ownUserId,
        'total_chunks': totalChunks,
        'total_size': data.length,
      });

      // Chunks
      for (var i = 0; i < totalChunks; i++) {
        final start = i * _chunkSize;
        final end = (start + _chunkSize).clamp(0, base64Data.length);

        await _sendJson(deviceId, {
          'type': 'transfer_chunk',
          'transfer_id': transferId,
          'chunk_index': i,
          'data': base64Data.substring(start, end),
        });

        final progress = (i + 1) / totalChunks;
        _emitProgress(
            transferId, peerId, NearbyTransferStatus.transferring, progress,);

        // Yield between every chunk to let the native message channel deliver
        // data to the receiver.  Without this, the sender can outpace the
        // platform channel and messages pile up or get dropped.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      // Footer
      await _sendJson(deviceId, {
        'type': 'transfer_complete',
        'transfer_id': transferId,
      });

      Logger.info('sendPayload: transfer complete', _tag);
      _emitProgress(transferId, peerId, NearbyTransferStatus.completed, 1);
      _outgoing.remove(transferId);

      // Wait for the receiver to acknowledge the transfer before tearing
      // down the connection. This replaces the old 3-second hardcoded delay
      // with a deterministic signal from the receiver.
      await _waitForTransferAck(transferId, deviceId)
          .timeout(const Duration(seconds: 10), onTimeout: () {
        Logger.warning(
          'sendPayload: No ACK from receiver — disconnecting anyway',
          _tag,
        );
      },);
      await _stopNearby();
      return true;
    } on Exception catch (e) {
      Logger.error('sendPayload failed', e, null, _tag);
      _emitProgress(transferId, peerId, NearbyTransferStatus.failed, 0,
          error: e.toString(),);
      _outgoing.remove(transferId);
      await _stopNearby();
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Receive  (receiver = BROWSER)
  // ---------------------------------------------------------------------------

  @override
  Future<bool> receivePayload({
    required String transferId,
    required String peerId,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (!await _ensureInitialized()) {
      Logger.error('receivePayload: init failed', null, null, _tag);
      return false;
    }

    Logger.info('receivePayload: id=$transferId peer=$peerId', _tag);
    _emitProgress(transferId, peerId, NearbyTransferStatus.discovering, 0);

    try {
      // Clean up stale state from any previous transfer before starting.
      try {
        await _nearbyService!.stopAdvertisingPeer();
        await _nearbyService!.stopBrowsingForPeers();
      } on Exception catch (_) {}
      _connectedDevices.clear();
      _discoveredDevices.clear();
      _pendingInvites.clear();

      // 1. Register incoming transfer BEFORE browsing so arriving chunks are
      //    captured even if the connection is made very quickly.
      final completer = Completer<bool>();
      _incoming[transferId] = _IncomingTransfer(
        transferId: transferId,
        peerId: peerId,
        completer: completer,
      );

      // 2. Browse for the sender who is already advertising.
      await _nearbyService!.startBrowsingForPeers();
      Logger.info('receivePayload: browsing for $peerId', _tag);

      // 3. Discover → invite → connect.
      _startInvitingPeer(peerId);

      _emitProgress(transferId, peerId, NearbyTransferStatus.connecting, 0);

      // 4. Wait for data to arrive and be reassembled.
      final result = await completer.future.timeout(
        timeout + const Duration(seconds: 30),
        onTimeout: () {
          Logger.warning('receivePayload: timeout for $transferId', _tag);
          _emitProgress(transferId, peerId, NearbyTransferStatus.failed, 0,
              error: 'Transfer timeout',);
          return false;
        },
      );

      _incoming.remove(transferId);
      await _stopNearby();
      return result;
    } on Exception catch (e) {
      Logger.error('receivePayload failed', e, null, _tag);
      _emitProgress(transferId, peerId, NearbyTransferStatus.failed, 0,
          error: e.toString(),);
      _incoming.remove(transferId);
      await _stopNearby();
      return false;
    }
  }

  @override
  Future<void> cancelTransfer(String transferId) async {
    _outgoing.remove(transferId);
    final incoming = _incoming.remove(transferId);
    if (incoming != null && !incoming.completer.isCompleted) {
      incoming.completer.complete(false);
    }
    _progressController.add(NearbyTransferProgress(
      transferId: transferId,
      peerId: '',
      status: NearbyTransferStatus.cancelled,
      progress: 0,
    ),);
    await _stopNearby();
  }

  @override
  Stream<NearbyTransferProgress> get transferProgressStream =>
      _progressController.stream;

  @override
  Stream<NearbyPayloadReceived> get payloadReceivedStream =>
      _payloadController.stream;

  @override
  Future<void> dispose() async {
    await _stopNearby();
    await _deviceSubscription?.cancel();
    await _dataSubscription?.cancel();
    await _progressController.close();
    await _payloadController.close();
    _nearbyService = null;
    _initialized = false;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void _emitProgress(
    String transferId,
    String peerId,
    NearbyTransferStatus status,
    double progress, {
    String? error,
  }) {
    _progressController.add(NearbyTransferProgress(
      transferId: transferId,
      peerId: peerId,
      status: status,
      progress: progress,
      errorMessage: error,
    ),);
  }

  Future<void> _sendJson(String deviceId, Map<String, dynamic> json) async {
    await _nearbyService!.sendMessage(deviceId, jsonEncode(json));
  }

  /// Wait for the receiver to send a `transfer_ack` message confirming
  /// they received and reassembled all chunks. This replaces the old
  /// hardcoded 3-second post-transfer delay.
  Future<void> _waitForTransferAck(String transferId, String deviceId) {
    final completer = Completer<void>();
    _pendingAcks[transferId] = completer;
    return completer.future;
  }

  /// Pending transfer ACK completers: transferId → Completer.
  final Map<String, Completer<void>> _pendingAcks = {};

  /// Completer that resolves when a Nearby device connects.
  /// Used by the SENDER (advertiser) side — resolves on first connection.
  Completer<bool>? _connectionCompleter;

  /// Wait until any device is connected.
  /// Uses a Completer that is resolved from the state-change subscription
  /// instead of polling with a Timer.
  Future<bool> _waitForPeerConnected(String peerId, Duration timeout) async {
    if (_connectedDevices.isNotEmpty) return true;

    _connectionCompleter = Completer<bool>();
    try {
      return await _connectionCompleter!.future.timeout(timeout, onTimeout: () {
        return false;
      },);
    } on Exception catch (_) {
      return false;
    } finally {
      _connectionCompleter = null;
    }
  }

  /// Check discovered devices and invite the target peer.
  /// Used by the RECEIVER (browser) side. Invites are triggered reactively
  /// from the state-change subscription. A single timer restarts browsing
  /// if no devices are discovered after 5 seconds (iOS Multipeer workaround).
  Timer? _browseRestartTimer;

  void _startInvitingPeer(String peerId) {
    _inviteTimer?.cancel();
    _browseRestartTimer?.cancel();
    _targetInvitePeerId = peerId;

    // Attempt immediate invite from already-discovered devices.
    _tryInvitePeer(peerId);

    // Schedule a browse restart if no devices are discovered within 5s.
    // This handles the iOS Multipeer edge case where advertisers started
    // after the initial browse aren't visible.
    _browseRestartTimer = Timer(const Duration(seconds: 5), () {
      if (_discoveredDevices.isEmpty && _connectedDevices.isEmpty) {
        Logger.info('Re-starting browse (no devices after 5s)', _tag);
        _restartBrowsing();
        // Schedule one more restart in case the first didn't work.
        _browseRestartTimer = Timer(const Duration(seconds: 5), () {
          if (_discoveredDevices.isEmpty && _connectedDevices.isEmpty) {
            Logger.info('Re-starting browse (still no devices after 10s)', _tag);
            _restartBrowsing();
          }
        });
      }
    });
  }

  /// Try to invite a discovered peer. Called from state-change subscription
  /// when new devices are discovered.
  ///
  /// Prefers an exact name match (sender advertises with userId), but falls
  /// back to inviting *any* discovered device. This is safe because the Nearby
  /// session is ephemeral (one transfer at a time) and works around Android
  /// Nearby Connections which may report a platform-internal name instead of
  /// the advertised deviceName.
  void _tryInvitePeer(String peerId) {
    // 1. Try exact name match first.
    for (final device in _discoveredDevices.values) {
      if (device.deviceName == peerId &&
          !_pendingInvites.contains(device.deviceId)) {
        Logger.info(
          'Inviting exact match ${device.deviceName} (${device.deviceId})',
          _tag,
        );
        _pendingInvites.add(device.deviceId);
        _nearbyService?.invitePeer(
          deviceID: device.deviceId,
          deviceName: device.deviceName,
        );
        return;
      }
    }

    // 2. Fallback: invite any discovered device not yet invited.
    //    On Android the discovered deviceName may differ from the advertised
    //    userId, so exact matching fails. Since only one transfer runs at a
    //    time, the first discovered device is the sender.
    for (final device in _discoveredDevices.values) {
      if (!_pendingInvites.contains(device.deviceId)) {
        Logger.info(
          'Inviting fallback device ${device.deviceName} (${device.deviceId}) '
          'for target $peerId',
          _tag,
        );
        _pendingInvites.add(device.deviceId);
        _nearbyService?.invitePeer(
          deviceID: device.deviceId,
          deviceName: device.deviceName,
        );
        return;
      }
    }
  }

  /// Restart browsing to force re-discovery of advertisers that started
  /// after the initial browse (common on iOS Multipeer Connectivity).
  Future<void> _restartBrowsing() async {
    try {
      await _nearbyService!.stopBrowsingForPeers();
      await _nearbyService!.startBrowsingForPeers();
    } on Exception catch (_) {}
  }

  /// Find the first connected device matching [peerId] by exact deviceName.
  ///
  /// [peerId] is the app-level userId. The sender advertises with userId as
  /// the device name, so we match by exact equality. Falls back to the first
  /// connected device when no name match is found — safe because the Nearby
  /// session is ephemeral (one transfer at a time).
  String? _findDeviceIdForPeer(String peerId) {
    if (_connectedDevices.isEmpty) return null;

    // Try exact name match first (peerId == userId == advertised device name).
    for (final entry in _connectedDevices.entries) {
      if (entry.value.deviceName == peerId) {
        return entry.key;
      }
    }

    // Fall back to first connected device (sender doesn't know receiver's
    // Nearby name, only its userId).
    return _connectedDevices.keys.first;
  }

  /// Handle incoming data and reassemble chunked transfers.
  void _handleReceivedData(dynamic data) {
    try {
      String messageStr;
      if (data is String) {
        final parsed = jsonDecode(data) as Map<String, dynamic>;
        messageStr = parsed['message'] as String;
      } else if (data is Map) {
        messageStr = data['message'] as String;
      } else {
        messageStr = (data as dynamic).message as String;
      }

      final json = jsonDecode(messageStr) as Map<String, dynamic>;
      final type = json['type'] as String;
      final transferId = json['transfer_id'] as String;

      final incoming = _incoming[transferId];

      switch (type) {
        case 'transfer_header':
          if (incoming == null) {
            Logger.warning('Header for unknown transfer $transferId', _tag);
            return;
          }
          incoming.totalChunks = json['total_chunks'] as int;
          incoming.totalSize = json['total_size'] as int;
          incoming.senderId = json['sender_id'] as String? ?? '';
          incoming.chunks = List<String?>.filled(incoming.totalChunks, null);
          _emitProgress(transferId, incoming.peerId,
              NearbyTransferStatus.transferring, 0,);

        case 'transfer_chunk':
          if (incoming?.chunks == null) return;
          final idx = json['chunk_index'] as int;
          incoming!.chunks![idx] = json['data'] as String;
          incoming.receivedChunks++;
          _emitProgress(
            transferId,
            incoming.peerId,
            NearbyTransferStatus.transferring,
            incoming.receivedChunks / incoming.totalChunks,
          );

        case 'transfer_complete':
          if (incoming?.chunks == null) return;
          final allBase64 = incoming!.chunks!.whereType<String>().join();
          try {
            final bytes = base64Decode(allBase64);
            Logger.info(
              'Transfer $transferId complete: ${bytes.length} bytes',
              _tag,
            );
            _payloadController.add(NearbyPayloadReceived(
              transferId: transferId,
              fromPeerId: incoming.senderId ?? incoming.peerId,
              data: Uint8List.fromList(bytes),
              timestamp: DateTime.now(),
            ),);
            _emitProgress(transferId, incoming.peerId,
                NearbyTransferStatus.completed, 1,);
            if (!incoming.completer.isCompleted) {
              incoming.completer.complete(true);
            }
            // Send ACK to the sender so they know we received everything.
            _sendTransferAck(transferId);
          } on Exception catch (e) {
            Logger.error('Decode failed for $transferId', e, null, _tag);
            _emitProgress(transferId, incoming.peerId,
                NearbyTransferStatus.failed, 0,
                error: 'Decode error',);
            if (!incoming.completer.isCompleted) {
              incoming.completer.complete(false);
            }
          }

        case 'transfer_ack':
          // Sender receives this from the receiver confirming data was received.
          final ackCompleter = _pendingAcks.remove(transferId);
          if (ackCompleter != null && !ackCompleter.isCompleted) {
            ackCompleter.complete();
            Logger.info('Received transfer ACK for $transferId', _tag);
          }
      }
    } on Exception catch (e) {
      Logger.error('_handleReceivedData error', e, null, _tag);
    }
  }

  /// Send a transfer_ack message to the sender confirming data was received.
  void _sendTransferAck(String transferId) {
    // Send to any connected device (sender is the only one in this session).
    for (final deviceId in _connectedDevices.keys) {
      try {
        _sendJson(deviceId, {
          'type': 'transfer_ack',
          'transfer_id': transferId,
        });
        Logger.info('Sent transfer ACK for $transferId', _tag);
      } on Exception catch (e) {
        Logger.warning('Failed to send transfer ACK: $e', _tag);
      }
      break; // Only one peer in the session.
    }
  }

  Future<void> _stopNearby() async {
    _inviteTimer?.cancel();
    _inviteTimer = null;
    _browseRestartTimer?.cancel();
    _browseRestartTimer = null;
    _targetInvitePeerId = null;
    _connectionCompleter = null;
    try {
      await _nearbyService?.stopAdvertisingPeer();
      await _nearbyService?.stopBrowsingForPeers();
    } on Exception catch (e) {
      Logger.warning('_stopNearby error: $e', _tag);
    }
    _discoveredDevices.clear();
    _connectedDevices.clear();
    _pendingInvites.clear();
    // Complete any pending ACK waiters (transfer is over).
    for (final completer in _pendingAcks.values) {
      if (!completer.isCompleted) completer.complete();
    }
    _pendingAcks.clear();
    // NOTE: We intentionally do NOT reset _initialized or _initFuture here.
    // Re-calling init() on the same NearbyService instance is unreliable on
    // iOS (Multipeer Connectivity doesn't properly recreate native session
    // objects). Instead, we just stop advertising/browsing and clear state.
    // The next sendPayload/receivePayload can directly start advertising/
    // browsing on the already-initialized service.
  }
}

// ---------------------------------------------------------------------------
// Transfer tracking
// ---------------------------------------------------------------------------

class _OutgoingTransfer {
  _OutgoingTransfer({required this.transferId, required this.totalChunks});
  final String transferId;
  final int totalChunks;
}

class _IncomingTransfer {
  _IncomingTransfer({
    required this.transferId,
    required this.peerId,
    required this.completer,
  });

  final String transferId;
  final String peerId;
  final Completer<bool> completer;

  int totalChunks = 0;
  int totalSize = 0;
  int receivedChunks = 0;
  String? senderId;
  List<String?>? chunks;
}
