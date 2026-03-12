import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_nearby_connections_plus/flutter_nearby_connections_plus.dart';

import '../../core/utils/logger.dart';
import 'high_speed_transfer_service.dart';
import 'nearby_models.dart';

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
  StreamSubscription? _deviceSubscription;
  StreamSubscription? _dataSubscription;

  // Device tracking
  final Map<String, Device> _connectedDevices = {};
  final Map<String, Device> _discoveredDevices = {};

  // Prevent duplicate invitations
  final Set<String> _pendingInvites = {};

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
    _deviceSubscription?.cancel();
    _dataSubscription?.cancel();
    _nearbyService ??= NearbyService();

    try {
      await _nearbyService!.init(
        serviceType: _serviceType,
        deviceName: _ownUserId,
        strategy: Strategy.P2P_STAR, // star allows 1 advertiser + N browsers
        callback: (isRunning) {
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
          } else if (device.state == SessionState.notConnected) {
            _discoveredDevices[device.deviceId] = device;
            _connectedDevices.remove(device.deviceId);
            _pendingInvites.remove(device.deviceId);
          }
        }
      });

      _dataSubscription =
          _nearbyService!.dataReceivedSubscription(callback: (data) {
        _handleReceivedData(data);
      });

      _initialized = true;
      Logger.info('NearbyTransferService ready ($_ownUserId)', _tag);
    } catch (e) {
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
      // 1. Advertise with our userId so the receiver can find us.
      await _nearbyService!.startAdvertisingPeer(deviceName: _ownUserId);
      Logger.info('sendPayload: advertising as $_ownUserId', _tag);

      // 2. Wait for the receiver to browse → discover us → invite → connect.
      final connected = await _waitForPeerConnected(peerId, timeout);
      if (!connected) {
        Logger.warning('sendPayload: connection timeout', _tag);
        _emitProgress(transferId, peerId, NearbyTransferStatus.failed, 0,
            error: 'Connection timeout');
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
            error: 'Device lost');
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
            transferId, peerId, NearbyTransferStatus.transferring, progress);

        // Yield between every chunk to let the native message channel deliver
        // data to the receiver.  Without this, the sender can outpace the
        // platform channel and messages pile up or get dropped.
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // Footer
      await _sendJson(deviceId, {
        'type': 'transfer_complete',
        'transfer_id': transferId,
      });

      Logger.info('sendPayload: transfer complete', _tag);
      _emitProgress(transferId, peerId, NearbyTransferStatus.completed, 1.0);
      _outgoing.remove(transferId);

      // Give the native message channel time to flush all pending messages
      // to the receiver before tearing down the connection. Without this
      // delay, _stopNearby() disconnects the session and the receiver may
      // not receive the final chunks or the transfer_complete message.
      await Future.delayed(const Duration(seconds: 3));
      await _stopNearby();
      return true;
    } catch (e) {
      Logger.error('sendPayload failed', e, null, _tag);
      _emitProgress(transferId, peerId, NearbyTransferStatus.failed, 0,
          error: e.toString());
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
              error: 'Transfer timeout');
          return false;
        },
      );

      _incoming.remove(transferId);
      await _stopNearby();
      return result;
    } catch (e) {
      Logger.error('receivePayload failed', e, null, _tag);
      _emitProgress(transferId, peerId, NearbyTransferStatus.failed, 0,
          error: e.toString());
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
    ));
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
    _deviceSubscription?.cancel();
    _dataSubscription?.cancel();
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
    ));
  }

  Future<void> _sendJson(String deviceId, Map<String, dynamic> json) async {
    await _nearbyService!.sendMessage(deviceId, jsonEncode(json));
  }

  /// Wait until any device is connected.
  /// Used by the SENDER (advertiser) side — it just waits for the receiver
  /// to browse, discover, invite, and connect.
  ///
  /// We don't filter by [peerId] because the sender only knows the receiver's
  /// BLE device ID, while the receiver's Nearby device name is its userId
  /// (a completely different identifier).  Since the Nearby session is
  /// ephemeral (one transfer at a time), the first connected device is
  /// the expected receiver.
  Future<bool> _waitForPeerConnected(String peerId, Duration timeout) async {
    if (_connectedDevices.isNotEmpty) return true;

    final completer = Completer<bool>();

    late Timer timer;
    timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_connectedDevices.isNotEmpty) {
        if (!completer.isCompleted) completer.complete(true);
        timer.cancel();
      }
    });

    try {
      return await completer.future.timeout(timeout, onTimeout: () {
        timer.cancel();
        return false;
      });
    } catch (_) {
      timer.cancel();
      return false;
    }
  }

  /// Periodically check discovered devices and invite the target peer.
  /// Used by the RECEIVER (browser) side. Only invites each device ONCE to
  /// avoid spamming the native layer with duplicate requestConnection calls.
  void _startInvitingPeer(String peerId) {
    final prefix = peerId.length >= 8 ? peerId.substring(0, 8) : peerId;

    // Poll discovered devices and invite matching ones.
    Timer.periodic(const Duration(milliseconds: 500), (timer) {
      // Stop polling once connected.
      if (_findDeviceIdForPeer(peerId) != null) {
        timer.cancel();
        return;
      }

      for (final device in _discoveredDevices.values) {
        if (device.deviceName.contains(prefix) &&
            !_pendingInvites.contains(device.deviceId)) {
          Logger.info(
            'Inviting ${device.deviceName} (${device.deviceId})',
            _tag,
          );
          _pendingInvites.add(device.deviceId);
          _nearbyService?.invitePeer(
            deviceID: device.deviceId,
            deviceName: device.deviceName,
          );
        }
      }
    });
  }

  /// Find the first connected device, optionally matching [peerId] prefix.
  ///
  /// Tries name-based matching first (works when receiver passes sender's
  /// Nearby ID).  Falls back to the first connected device — safe because
  /// the Nearby session is ephemeral (one transfer at a time).
  String? _findDeviceIdForPeer(String peerId) {
    if (_connectedDevices.isEmpty) return null;

    // Try name-based match first.
    final prefix = peerId.length >= 8 ? peerId.substring(0, 8) : peerId;
    for (final entry in _connectedDevices.entries) {
      if (entry.value.deviceName.contains(prefix)) {
        return entry.key;
      }
    }

    // Fall back to first connected device (sender doesn't know receiver's
    // Nearby name, only its BLE device ID).
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
              NearbyTransferStatus.transferring, 0);
          break;

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
          break;

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
            ));
            _emitProgress(transferId, incoming.peerId,
                NearbyTransferStatus.completed, 1.0);
            if (!incoming.completer.isCompleted) {
              incoming.completer.complete(true);
            }
          } catch (e) {
            Logger.error('Decode failed for $transferId', e, null, _tag);
            _emitProgress(transferId, incoming.peerId,
                NearbyTransferStatus.failed, 0,
                error: 'Decode error');
            if (!incoming.completer.isCompleted) {
              incoming.completer.complete(false);
            }
          }
          break;
      }
    } catch (e) {
      Logger.error('_handleReceivedData error', e, null, _tag);
    }
  }

  Future<void> _stopNearby() async {
    try {
      await _nearbyService?.stopAdvertisingPeer();
      await _nearbyService?.stopBrowsingForPeers();
    } catch (e) {
      Logger.warning('_stopNearby error: $e', _tag);
    }
    _discoveredDevices.clear();
    _connectedDevices.clear();
    _pendingInvites.clear();
    // Reset so the next transfer triggers a fresh native init via _doInit().
    // Without this, stale native state from the previous session causes the
    // second transfer to fail (advertising/browsing won't start properly).
    _initialized = false;
    _initFuture = null;
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
