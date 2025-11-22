import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../core/utils/logger.dart';
import 'ble_config.dart';
import 'ble_models.dart';
import 'ble_service_interface.dart';
import 'photo_chunker.dart';

/// BLE service implementation using Bridgefy SDK for real mesh networking
///
/// NOTE: This requires the bridgefy_sdk package to be added to pubspec.yaml
/// and proper API key configuration. Until the SDK is added, this service
/// will throw UnsupportedError on initialization.
///
/// To use Bridgefy:
/// 1. Add bridgefy_sdk to pubspec.yaml
/// 2. Get API key from https://bridgefy.me
/// 3. Set BRIDGEFY_API_KEY environment variable or pass to BleConfig
/// 4. Configure iOS/Android permissions (see platform setup)
class BridgefyBleService implements BleServiceInterface {
  BridgefyBleService({
    required this.config,
  })  : _photoChunker = PhotoChunker(chunkSize: config.photoChunkSize),
        _photoReassembler = PhotoReassembler();

  final BleConfig config;
  final PhotoChunker _photoChunker;
  final PhotoReassembler _photoReassembler;
  final _uuid = const Uuid();

  // Bridgefy SDK instance would be stored here
  // late final Bridgefy _bridgefy;

  // Status
  BleStatus _status = BleStatus.disabled;
  bool _isScanning = false;
  bool _isBroadcasting = false;
  bool _isInitialized = false;

  // Stream controllers
  final _statusController = StreamController<BleStatus>.broadcast();
  final _peerDiscoveredController = StreamController<DiscoveredPeer>.broadcast();
  final _peerLostController = StreamController<String>.broadcast();
  final _messageReceivedController = StreamController<ReceivedMessage>.broadcast();
  final _photoProgressController = StreamController<PhotoTransferProgress>.broadcast();
  final _photoReceivedController = StreamController<ReceivedPhoto>.broadcast();

  // Peer tracking
  final Map<String, DiscoveredPeer> _visiblePeers = {};
  final Map<String, Timer> _peerTimeoutTimers = {};
  final Map<String, _PendingPhotoTransfer> _pendingTransfers = {};

  // Reconnection
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 5;
  static const _reconnectDelay = Duration(seconds: 5);

  // ==================== Lifecycle ====================

  @override
  Future<void> initialize() async {
    if (_isInitialized) return;

    Logger.info('BridgefyBleService: Initializing with config: $config', 'BLE');

    if (!config.canUseBridgefy) {
      throw StateError(
        'BridgefyBleService requires valid API key. '
        'Set BRIDGEFY_API_KEY environment variable.',
      );
    }

    try {
      // TODO: Initialize Bridgefy SDK when package is added
      // _bridgefy = await Bridgefy.initialize(
      //   apiKey: config.bridgefyApiKey!,
      //   delegate: _BridgefyDelegate(this),
      //   options: BridgefyOptions(
      //     meshEnabled: config.enableMeshRelay,
      //     ttl: config.meshTtl,
      //   ),
      // );

      // For now, throw to indicate SDK not available
      throw UnsupportedError(
        'Bridgefy SDK not yet integrated. Add bridgefy_sdk package to pubspec.yaml '
        'and uncomment SDK initialization code.',
      );

      // _isInitialized = true;
      // _setStatus(BleStatus.ready);
      // Logger.info('BridgefyBleService: Initialized successfully', 'BLE');
    } catch (e) {
      Logger.error('BridgefyBleService: Initialization failed', e, null, 'BLE');
      _setStatus(BleStatus.error);
      rethrow;
    }
  }

  @override
  Future<void> start() async {
    _ensureInitialized();
    Logger.info('BridgefyBleService: Starting...', 'BLE');

    try {
      await startScanning();
      // Broadcasting starts when broadcastProfile is called
      _resetReconnectAttempts();
    } catch (e) {
      Logger.error('BridgefyBleService: Start failed', e, null, 'BLE');
      _scheduleReconnect();
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    Logger.info('BridgefyBleService: Stopping...', 'BLE');
    _reconnectTimer?.cancel();

    await stopScanning();
    await stopBroadcasting();
    _setStatus(BleStatus.ready);
  }

  @override
  Future<void> dispose() async {
    Logger.info('BridgefyBleService: Disposing...', 'BLE');

    _reconnectTimer?.cancel();
    for (final timer in _peerTimeoutTimers.values) {
      timer.cancel();
    }

    // TODO: Dispose Bridgefy SDK
    // await _bridgefy.stop();

    await _statusController.close();
    await _peerDiscoveredController.close();
    await _peerLostController.close();
    await _messageReceivedController.close();
    await _photoProgressController.close();
    await _photoReceivedController.close();

    _photoReassembler.clear();
    _isInitialized = false;
  }

  void _ensureInitialized() {
    if (!_isInitialized) {
      throw StateError('BridgefyBleService not initialized. Call initialize() first.');
    }
  }

  // ==================== Status ====================

  @override
  BleStatus get status => _status;

  @override
  Stream<BleStatus> get statusStream => _statusController.stream;

  @override
  Future<bool> isBluetoothAvailable() async {
    // TODO: Check via Bridgefy SDK
    // return await _bridgefy.isBluetoothAvailable();
    return true;
  }

  @override
  Future<bool> isBluetoothEnabled() async {
    // TODO: Check via Bridgefy SDK
    // return await _bridgefy.isBluetoothEnabled();
    return true;
  }

  @override
  Future<bool> requestPermissions() async {
    // TODO: Request via Bridgefy SDK
    // return await _bridgefy.requestPermissions();
    return true;
  }

  @override
  Future<bool> hasPermissions() async {
    // TODO: Check via Bridgefy SDK
    // return await _bridgefy.hasPermissions();
    return true;
  }

  void _setStatus(BleStatus newStatus) {
    _status = newStatus;
    _statusController.add(newStatus);
  }

  void _updateActiveStatus() {
    if (_isScanning && _isBroadcasting) {
      _setStatus(BleStatus.active);
    } else if (_isScanning) {
      _setStatus(BleStatus.scanning);
    } else if (_isBroadcasting) {
      _setStatus(BleStatus.advertising);
    } else if (_isInitialized) {
      _setStatus(BleStatus.ready);
    }
  }

  // ==================== Broadcasting ====================

  @override
  Future<void> broadcastProfile(BroadcastPayload payload) async {
    _ensureInitialized();
    Logger.info('BridgefyBleService: Broadcasting profile for ${payload.name}', 'BLE');

    try {
      // Serialize payload for broadcasting
      final data = _serializeBroadcastPayload(payload);

      // TODO: Broadcast via Bridgefy SDK
      // await _bridgefy.broadcast(data);

      _isBroadcasting = true;
      _updateActiveStatus();
    } catch (e) {
      Logger.error('BridgefyBleService: Broadcast failed', e, null, 'BLE');
      rethrow;
    }
  }

  @override
  Future<void> stopBroadcasting() async {
    Logger.info('BridgefyBleService: Stopped broadcasting', 'BLE');

    // TODO: Stop broadcasting via Bridgefy SDK
    // await _bridgefy.stopBroadcasting();

    _isBroadcasting = false;
    _updateActiveStatus();
  }

  @override
  bool get isBroadcasting => _isBroadcasting;

  Uint8List _serializeBroadcastPayload(BroadcastPayload payload) {
    final json = {
      'type': 'profile',
      'userId': payload.userId,
      'name': payload.name,
      'age': payload.age,
      'bio': payload.bio,
      // Thumbnail sent separately if present
      'hasThumbnail': payload.thumbnailBytes != null,
    };

    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  // ==================== Discovery ====================

  @override
  Stream<DiscoveredPeer> get peerDiscoveredStream => _peerDiscoveredController.stream;

  @override
  Stream<String> get peerLostStream => _peerLostController.stream;

  @override
  Future<void> startScanning() async {
    if (_isScanning) return;
    _ensureInitialized();

    Logger.info('BridgefyBleService: Starting scan...', 'BLE');

    try {
      // TODO: Start scanning via Bridgefy SDK
      // await _bridgefy.startScanning();

      _isScanning = true;
      _updateActiveStatus();
    } catch (e) {
      Logger.error('BridgefyBleService: Scan start failed', e, null, 'BLE');
      rethrow;
    }
  }

  @override
  Future<void> stopScanning() async {
    Logger.info('BridgefyBleService: Stopping scan...', 'BLE');

    // TODO: Stop scanning via Bridgefy SDK
    // await _bridgefy.stopScanning();

    _isScanning = false;
    _updateActiveStatus();
  }

  @override
  bool get isScanning => _isScanning;

  /// Called by Bridgefy delegate when a peer is discovered
  void _onPeerDiscovered(String peerId, Uint8List data, int rssi) {
    try {
      final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;

      if (json['type'] == 'profile') {
        final peer = DiscoveredPeer(
          peerId: peerId,
          name: json['name'] as String,
          age: json['age'] as int?,
          bio: json['bio'] as String?,
          thumbnailBytes: null, // Thumbnail sent separately
          rssi: rssi,
          timestamp: DateTime.now(),
        );

        _visiblePeers[peerId] = peer;
        _peerDiscoveredController.add(peer);

        // Reset timeout for this peer
        _peerTimeoutTimers[peerId]?.cancel();
        _peerTimeoutTimers[peerId] = Timer(
          config.peerLostTimeout,
          () => _onPeerLost(peerId),
        );

        Logger.info(
          'BridgefyBleService: Discovered peer ${peer.name} (RSSI: $rssi)',
          'BLE',
        );
      }
    } catch (e) {
      Logger.error('BridgefyBleService: Failed to parse peer data', e, null, 'BLE');
    }
  }

  void _onPeerLost(String peerId) {
    if (_visiblePeers.containsKey(peerId)) {
      final peer = _visiblePeers.remove(peerId);
      _peerTimeoutTimers.remove(peerId)?.cancel();
      _peerLostController.add(peerId);
      Logger.info('BridgefyBleService: Lost peer ${peer?.name}', 'BLE');
    }
  }

  // ==================== Messaging ====================

  @override
  Future<bool> sendMessage(String peerId, MessagePayload payload) async {
    _ensureInitialized();

    Logger.info(
      'BridgefyBleService: Sending ${payload.type.name} to ${peerId.substring(0, 8)}',
      'BLE',
    );

    try {
      final data = _serializeMessagePayload(payload);

      // TODO: Send via Bridgefy SDK with mesh relay
      // final success = await _bridgefy.send(
      //   peerId: peerId,
      //   data: data,
      //   mode: config.enableMeshRelay ? SendMode.mesh : SendMode.direct,
      // );

      // For now, simulate success
      return true;
    } catch (e) {
      Logger.error('BridgefyBleService: Message send failed', e, null, 'BLE');
      return false;
    }
  }

  @override
  Stream<ReceivedMessage> get messageReceivedStream => _messageReceivedController.stream;

  Uint8List _serializeMessagePayload(MessagePayload payload) {
    final json = {
      'type': 'message',
      'messageType': payload.type.index,
      'messageId': payload.messageId,
      'content': payload.content,
      'timestamp': payload.timestamp.toIso8601String(),
    };

    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  /// Called by Bridgefy delegate when a message is received
  void _onMessageReceived(String fromPeerId, Uint8List data) {
    try {
      final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;

      if (json['type'] == 'message') {
        final message = ReceivedMessage(
          fromPeerId: fromPeerId,
          messageId: json['messageId'] as String,
          type: MessageType.values[json['messageType'] as int],
          content: json['content'] as String?,
          timestamp: DateTime.parse(json['timestamp'] as String),
        );

        _messageReceivedController.add(message);
        Logger.info(
          'BridgefyBleService: Received ${message.type.name} from ${fromPeerId.substring(0, 8)}',
          'BLE',
        );
      } else if (json['type'] == 'photoChunk') {
        _onPhotoChunkReceived(fromPeerId, json);
      }
    } catch (e) {
      Logger.error('BridgefyBleService: Failed to parse message', e, null, 'BLE');
    }
  }

  // ==================== Photo Transfer ====================

  @override
  Future<bool> sendPhoto(String peerId, Uint8List photoData, String messageId) async {
    _ensureInitialized();

    if (photoData.length > config.maxPhotoSize) {
      Logger.error(
        'BridgefyBleService: Photo too large (${photoData.length} > ${config.maxPhotoSize})',
        null,
        null,
        'BLE',
      );
      return false;
    }

    Logger.info(
      'BridgefyBleService: Starting photo transfer to ${peerId.substring(0, 8)} '
      '(${photoData.length} bytes)',
      'BLE',
    );

    // Chunk the photo
    final chunks = _photoChunker.chunkPhoto(photoData, messageId);

    _pendingTransfers[messageId] = _PendingPhotoTransfer(
      messageId: messageId,
      peerId: peerId,
      chunks: chunks,
    );

    // Emit starting status
    _photoProgressController.add(PhotoTransferProgress(
      messageId: messageId,
      peerId: peerId,
      progress: 0,
      status: PhotoTransferStatus.starting,
    ));

    // Start sending chunks
    _sendNextChunk(messageId);

    return true;
  }

  void _sendNextChunk(String messageId) async {
    final transfer = _pendingTransfers[messageId];
    if (transfer == null || transfer.isCancelled) return;

    if (transfer.currentChunkIndex >= transfer.chunks.length) {
      // All chunks sent
      _photoProgressController.add(PhotoTransferProgress(
        messageId: messageId,
        peerId: transfer.peerId,
        progress: 1.0,
        status: PhotoTransferStatus.completed,
      ));
      _pendingTransfers.remove(messageId);
      Logger.info('BridgefyBleService: Photo transfer completed', 'BLE');
      return;
    }

    final chunk = transfer.chunks[transfer.currentChunkIndex];

    try {
      final data = _serializePhotoChunk(chunk);

      // TODO: Send chunk via Bridgefy SDK
      // await _bridgefy.send(
      //   peerId: transfer.peerId,
      //   data: data,
      //   mode: SendMode.direct, // Photos sent directly for speed
      // );

      // Update progress
      final progress = (transfer.currentChunkIndex + 1) / transfer.chunks.length;
      _photoProgressController.add(PhotoTransferProgress(
        messageId: messageId,
        peerId: transfer.peerId,
        progress: progress,
        status: PhotoTransferStatus.inProgress,
      ));

      // Move to next chunk
      transfer.currentChunkIndex++;

      // Wait for ACK (simulated delay for now)
      await Future.delayed(const Duration(milliseconds: 50));

      // Send next chunk
      _sendNextChunk(messageId);
    } catch (e) {
      Logger.error('BridgefyBleService: Chunk send failed', e, null, 'BLE');
      _photoProgressController.add(PhotoTransferProgress(
        messageId: messageId,
        peerId: transfer.peerId,
        progress: transfer.currentChunkIndex / transfer.chunks.length,
        status: PhotoTransferStatus.failed,
        error: e.toString(),
      ));
      _pendingTransfers.remove(messageId);
    }
  }

  Uint8List _serializePhotoChunk(PhotoChunk chunk) {
    final json = {
      'type': 'photoChunk',
      ...chunk.toJson(),
    };

    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  void _onPhotoChunkReceived(String fromPeerId, Map<String, dynamic> json) {
    final chunk = PhotoChunk.fromJson(json);
    final result = _photoReassembler.addChunk(chunk);

    _photoProgressController.add(PhotoTransferProgress(
      messageId: result.messageId,
      peerId: fromPeerId,
      progress: result.progress,
      status: result.isComplete
          ? PhotoTransferStatus.completed
          : PhotoTransferStatus.inProgress,
    ));

    if (result.isComplete && result.photoData != null) {
      _photoReceivedController.add(ReceivedPhoto(
        fromPeerId: fromPeerId,
        messageId: result.messageId,
        photoData: result.photoData!,
        timestamp: DateTime.now(),
      ));
      Logger.info(
        'BridgefyBleService: Photo received from ${fromPeerId.substring(0, 8)}',
        'BLE',
      );
    }
  }

  @override
  Stream<PhotoTransferProgress> get photoProgressStream => _photoProgressController.stream;

  @override
  Stream<ReceivedPhoto> get photoReceivedStream => _photoReceivedController.stream;

  @override
  Future<void> cancelPhotoTransfer(String messageId) async {
    Logger.info('BridgefyBleService: Cancelling photo transfer $messageId', 'BLE');

    final transfer = _pendingTransfers[messageId];
    if (transfer != null) {
      transfer.isCancelled = true;
      _pendingTransfers.remove(messageId);

      _photoProgressController.add(PhotoTransferProgress(
        messageId: messageId,
        peerId: transfer.peerId,
        progress: transfer.currentChunkIndex / transfer.chunks.length,
        status: PhotoTransferStatus.cancelled,
      ));
    }

    // Also cancel any pending reassembly
    _photoReassembler.cancel(messageId);
  }

  // ==================== Utilities ====================

  @override
  int? getSignalStrength(String peerId) {
    return _visiblePeers[peerId]?.rssi;
  }

  @override
  bool isPeerReachable(String peerId) {
    return _visiblePeers.containsKey(peerId);
  }

  @override
  List<String> get visiblePeerIds => _visiblePeers.keys.toList();

  // ==================== Reconnection ====================

  void _scheduleReconnect() {
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      Logger.error(
        'BridgefyBleService: Max reconnect attempts reached',
        null,
        null,
        'BLE',
      );
      _setStatus(BleStatus.error);
      return;
    }

    _reconnectAttempts++;
    final delay = _reconnectDelay * _reconnectAttempts;

    Logger.info(
      'BridgefyBleService: Scheduling reconnect attempt $_reconnectAttempts '
      'in ${delay.inSeconds}s',
      'BLE',
    );

    _reconnectTimer = Timer(delay, () async {
      try {
        await start();
      } catch (e) {
        _scheduleReconnect();
      }
    });
  }

  void _resetReconnectAttempts() {
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
  }
}

/// Internal class to track pending photo transfers
class _PendingPhotoTransfer {
  _PendingPhotoTransfer({
    required this.messageId,
    required this.peerId,
    required this.chunks,
  });

  final String messageId;
  final String peerId;
  final List<PhotoChunk> chunks;
  int currentChunkIndex = 0;
  bool isCancelled = false;
}
