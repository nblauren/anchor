import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../../core/utils/logger.dart';
import 'ble_config.dart';
import 'ble_models.dart';
import 'ble_service_interface.dart';
import 'photo_chunker.dart';

/// BLE service implementation using flutter_blue_plus for direct peer-to-peer communication
class FlutterBluePlusBleService implements BleServiceInterface {
  FlutterBluePlusBleService({
    required this.config,
  })  : _photoChunker = PhotoChunker(chunkSize: config.photoChunkSize),
        _photoReassembler = PhotoReassembler();

  final BleConfig config;
  final PhotoChunker _photoChunker;
  final PhotoReassembler _photoReassembler;
  final _uuid = const Uuid();

  // UUIDs for Anchor BLE service
  static final _serviceUuid = Guid('0000fff0-0000-1000-8000-00805f9b34fb');
  static final _profileMetadataChar = Guid('0000fff1-0000-1000-8000-00805f9b34fb');
  static final _thumbnailDataChar = Guid('0000fff2-0000-1000-8000-00805f9b34fb');
  static final _messagingChar = Guid('0000fff3-0000-1000-8000-00805f9b34fb');

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
  final Map<String, BluetoothDevice> _discoveredDevices = {};
  final Map<String, BluetoothDevice> _connectedDevices = {};

  // Connection management
  final Map<String, StreamSubscription> _connectionSubscriptions = {};
  static const _maxConnections = 5;
  static const _connectionTimeout = Duration(seconds: 30);
  static const _idleTimeout = Duration(seconds: 60);

  // Current profile broadcast data
  BroadcastPayload? _currentProfile;

  // Subscriptions
  StreamSubscription? _scanSubscription;
  StreamSubscription? _adapterStateSubscription;

  // ==================== Lifecycle ====================

  @override
  Future<void> initialize() async {
    if (_isInitialized) return;

    Logger.info('FlutterBluePlusBleService: Initializing...', 'BLE');

    try {
      // Check if Bluetooth is available
      if (!await FlutterBluePlus.isAvailable) {
        _setStatus(BleStatus.unavailable);
        throw StateError('Bluetooth is not available on this device');
      }

      // Listen to adapter state changes
      _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
        _onAdapterStateChanged(state);
      });

      _isInitialized = true;

      // Check initial state
      final adapterState = await FlutterBluePlus.adapterState.first;
      _onAdapterStateChanged(adapterState);

      Logger.info('FlutterBluePlusBleService: Initialized successfully', 'BLE');
    } catch (e) {
      Logger.error('FlutterBluePlusBleService: Initialization failed', e, null, 'BLE');
      _setStatus(BleStatus.error);
      rethrow;
    }
  }

  @override
  Future<void> start() async {
    _ensureInitialized();
    Logger.info('FlutterBluePlusBleService: Starting...', 'BLE');

    try {
      // Start scanning
      await startScanning();

      // Broadcasting starts when broadcastProfile is called
      _setStatus(BleStatus.ready);
    } catch (e) {
      Logger.error('FlutterBluePlusBleService: Start failed', e, null, 'BLE');
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    Logger.info('FlutterBluePlusBleService: Stopping...', 'BLE');

    await stopScanning();
    await stopBroadcasting();

    // Disconnect all devices
    for (final device in _connectedDevices.values) {
      try {
        await device.disconnect();
      } catch (e) {
        Logger.error('FlutterBluePlusBleService: Disconnect failed', e, null, 'BLE');
      }
    }

    _connectedDevices.clear();
    _discoveredDevices.clear();
    _setStatus(BleStatus.ready);
  }

  @override
  Future<void> dispose() async {
    Logger.info('FlutterBluePlusBleService: Disposing...', 'BLE');

    await stop();

    for (final timer in _peerTimeoutTimers.values) {
      timer.cancel();
    }

    for (final sub in _connectionSubscriptions.values) {
      await sub.cancel();
    }

    await _scanSubscription?.cancel();
    await _adapterStateSubscription?.cancel();

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
      throw StateError('FlutterBluePlusBleService not initialized. Call initialize() first.');
    }
  }

  void _onAdapterStateChanged(BluetoothAdapterState state) {
    Logger.info('FlutterBluePlusBleService: Adapter state changed to ${state.name}', 'BLE');

    switch (state) {
      case BluetoothAdapterState.on:
        if (_status == BleStatus.disabled) {
          _setStatus(BleStatus.ready);
        }
        break;
      case BluetoothAdapterState.off:
        _setStatus(BleStatus.disabled);
        _isScanning = false;
        _isBroadcasting = false;
        break;
      case BluetoothAdapterState.unavailable:
        _setStatus(BleStatus.unavailable);
        break;
      case BluetoothAdapterState.unauthorized:
        _setStatus(BleStatus.noPermission);
        break;
      default:
        break;
    }
  }

  // ==================== Status ====================

  @override
  BleStatus get status => _status;

  @override
  Stream<BleStatus> get statusStream => _statusController.stream;

  @override
  Future<bool> isBluetoothAvailable() async {
    return await FlutterBluePlus.isAvailable;
  }

  @override
  Future<bool> isBluetoothEnabled() async {
    final state = await FlutterBluePlus.adapterState.first;
    return state == BluetoothAdapterState.on;
  }

  @override
  Future<bool> requestPermissions() async {
    try {
      final permissions = <Permission>[];

      if (Platform.isAndroid) {
        // Android 12+ requires new permissions
        if (await Permission.bluetoothScan.isDenied) {
          permissions.add(Permission.bluetoothScan);
        }
        if (await Permission.bluetoothConnect.isDenied) {
          permissions.add(Permission.bluetoothConnect);
        }
        if (await Permission.bluetoothAdvertise.isDenied) {
          permissions.add(Permission.bluetoothAdvertise);
        }
      }

      // Location permission required for BLE on both platforms
      if (await Permission.locationWhenInUse.isDenied) {
        permissions.add(Permission.locationWhenInUse);
      }

      if (permissions.isEmpty) {
        return true;
      }

      final statuses = await permissions.request();
      return statuses.values.every((status) => status.isGranted);
    } catch (e) {
      Logger.error('FlutterBluePlusBleService: Permission request failed', e, null, 'BLE');
      return false;
    }
  }

  @override
  Future<bool> hasPermissions() async {
    if (Platform.isAndroid) {
      return await Permission.bluetoothScan.isGranted &&
          await Permission.bluetoothConnect.isGranted &&
          await Permission.locationWhenInUse.isGranted;
    } else if (Platform.isIOS) {
      return await Permission.bluetooth.isGranted &&
          await Permission.locationWhenInUse.isGranted;
    }
    return false;
  }

  void _setStatus(BleStatus newStatus) {
    if (_status != newStatus) {
      _status = newStatus;
      _statusController.add(newStatus);
    }
  }

  // ==================== Broadcasting ====================

  @override
  Future<void> broadcastProfile(BroadcastPayload payload) async {
    _ensureInitialized();
    Logger.info('FlutterBluePlusBleService: Broadcasting profile for ${payload.name}', 'BLE');

    _currentProfile = payload;
    _isBroadcasting = true;

    // Note: flutter_blue_plus doesn't support peripheral mode easily on all devices
    // This is a limitation - we'll rely on connections from scanning
    // Real advertising would require platform channels or different approach

    Logger.info(
      'FlutterBluePlusBleService: Profile cached for connections (${payload.name})',
      'BLE',
    );
  }

  @override
  Future<void> stopBroadcasting() async {
    Logger.info('FlutterBluePlusBleService: Stopped broadcasting', 'BLE');
    _isBroadcasting = false;
    _currentProfile = null;
  }

  @override
  bool get isBroadcasting => _isBroadcasting;

  // ==================== Discovery ====================

  @override
  Stream<DiscoveredPeer> get peerDiscoveredStream => _peerDiscoveredController.stream;

  @override
  Stream<String> get peerLostStream => _peerLostController.stream;

  @override
  Future<void> startScanning() async {
    if (_isScanning) return;
    _ensureInitialized();

    Logger.info('FlutterBluePlusBleService: Starting scan...', 'BLE');

    try {
      // Cancel existing scan
      await _scanSubscription?.cancel();

      _isScanning = true;
      _setStatus(BleStatus.scanning);

      // Start scanning for devices with our service UUID
      _scanSubscription = FlutterBluePlus.onScanResults.listen(
        (results) {
          for (final result in results) {
            _onDeviceDiscovered(result);
          }
        },
        onError: (e) {
          Logger.error('FlutterBluePlusBleService: Scan error', e, null, 'BLE');
        },
      );

      await FlutterBluePlus.startScan(
        withServices: [_serviceUuid],
        timeout: const Duration(seconds: 10),
        androidUsesFineLocation: true,
      );

      Logger.info('FlutterBluePlusBleService: Scan started', 'BLE');
    } catch (e) {
      Logger.error('FlutterBluePlusBleService: Scan start failed', e, null, 'BLE');
      _isScanning = false;
      rethrow;
    }
  }

  @override
  Future<void> stopScanning() async {
    if (!_isScanning) return;

    Logger.info('FlutterBluePlusBleService: Stopping scan...', 'BLE');

    try {
      await FlutterBluePlus.stopScan();
      await _scanSubscription?.cancel();
      _scanSubscription = null;
    } catch (e) {
      Logger.error('FlutterBluePlusBleService: Scan stop failed', e, null, 'BLE');
    }

    _isScanning = false;
  }

  @override
  bool get isScanning => _isScanning;

  Future<void> _onDeviceDiscovered(ScanResult result) async {
    final device = result.device;
    final deviceId = device.remoteId.toString();

    // Skip if already processing this device
    if (_discoveredDevices.containsKey(deviceId)) {
      return;
    }

    _discoveredDevices[deviceId] = device;

    Logger.info(
      'FlutterBluePlusBleService: Discovered device ${device.platformName} (RSSI: ${result.rssi})',
      'BLE',
    );

    // Connect and read profile
    await _connectAndReadProfile(device, result.rssi);
  }

  Future<void> _connectAndReadProfile(BluetoothDevice device, int rssi) async {
    final deviceId = device.remoteId.toString();

    try {
      // Check connection limit
      if (_connectedDevices.length >= _maxConnections) {
        Logger.info('FlutterBluePlusBleService: Connection limit reached, skipping ${device.platformName}', 'BLE');
        return;
      }

      // Connect with timeout
      await device.connect(timeout: _connectionTimeout);
      _connectedDevices[deviceId] = device;

      Logger.info('FlutterBluePlusBleService: Connected to ${device.platformName}', 'BLE');

      // Discover services
      final services = await device.discoverServices();

      // Find our service
      final service = services.where((s) => s.serviceUuid == _serviceUuid).firstOrNull;
      if (service == null) {
        Logger.info('FlutterBluePlusBleService: Anchor service not found on ${device.platformName}', 'BLE');
        await device.disconnect();
        _connectedDevices.remove(deviceId);
        return;
      }

      // Read profile metadata
      final metadataChar = service.characteristics
          .where((c) => c.characteristicUuid == _profileMetadataChar)
          .firstOrNull;

      if (metadataChar == null) {
        Logger.info('FlutterBluePlusBleService: Metadata characteristic not found', 'BLE');
        await device.disconnect();
        _connectedDevices.remove(deviceId);
        return;
      }

      final metadataBytes = await metadataChar.read();
      final metadata = jsonDecode(utf8.decode(metadataBytes)) as Map<String, dynamic>;

      // Read thumbnail if available
      Uint8List? thumbnailBytes;
      final thumbnailChar = service.characteristics
          .where((c) => c.characteristicUuid == _thumbnailDataChar)
          .firstOrNull;

      if (thumbnailChar != null) {
        try {
          thumbnailBytes = Uint8List.fromList(await thumbnailChar.read());
        } catch (e) {
          Logger.error('FlutterBluePlusBleService: Thumbnail read failed', e, null, 'BLE');
        }
      }

      // Create discovered peer
      final peer = DiscoveredPeer(
        peerId: metadata['user_id'] as String,
        name: metadata['name'] as String,
        age: metadata['age'] as int?,
        bio: metadata['bio'] as String?,
        thumbnailBytes: thumbnailBytes,
        rssi: rssi,
        timestamp: DateTime.now(),
      );

      _visiblePeers[peer.peerId] = peer;
      _peerDiscoveredController.add(peer);

      // Set up peer timeout
      _peerTimeoutTimers[peer.peerId]?.cancel();
      _peerTimeoutTimers[peer.peerId] = Timer(
        config.peerLostTimeout,
        () => _onPeerLost(peer.peerId),
      );

      // Set up message subscription for this device
      await _subscribeToMessages(device, service);

      Logger.info(
        'FlutterBluePlusBleService: Discovered peer ${peer.name} (RSSI: $rssi)',
        'BLE',
      );

      // Disconnect after reading (or keep connected for priority peers)
      // For now, disconnect to save resources
      Timer(_idleTimeout, () async {
        try {
          await device.disconnect();
          _connectedDevices.remove(deviceId);
        } catch (e) {
          Logger.error('FlutterBluePlusBleService: Disconnect failed', e, null, 'BLE');
        }
      });
    } catch (e) {
      Logger.error('FlutterBluePlusBleService: Profile read failed for ${device.platformName}', e, null, 'BLE');
      try {
        await device.disconnect();
        _connectedDevices.remove(deviceId);
      } catch (_) {}
    }
  }

  Future<void> _subscribeToMessages(BluetoothDevice device, BluetoothService service) async {
    try {
      final messageChar = service.characteristics
          .where((c) => c.characteristicUuid == _messagingChar)
          .firstOrNull;

      if (messageChar == null) return;

      // Enable notifications
      await messageChar.setNotifyValue(true);

      // Listen for messages
      final subscription = messageChar.lastValueStream.listen((value) {
        if (value.isNotEmpty) {
          _onMessageDataReceived(device.remoteId.toString(), value);
        }
      });

      _connectionSubscriptions[device.remoteId.toString()] = subscription;
    } catch (e) {
      Logger.error('FlutterBluePlusBleService: Message subscription failed', e, null, 'BLE');
    }
  }

  void _onPeerLost(String peerId) {
    if (_visiblePeers.containsKey(peerId)) {
      final peer = _visiblePeers.remove(peerId);
      _peerTimeoutTimers.remove(peerId)?.cancel();
      _peerLostController.add(peerId);
      Logger.info('FlutterBluePlusBleService: Lost peer ${peer?.name}', 'BLE');
    }
  }

  // ==================== Messaging ====================

  @override
  Future<bool> sendMessage(String peerId, MessagePayload payload) async {
    _ensureInitialized();

    Logger.info(
      'FlutterBluePlusBleService: Sending ${payload.type.name} to ${peerId.substring(0, 8)}',
      'BLE',
    );

    try {
      // Find device for this peer
      final device = _connectedDevices.values
          .where((d) => _visiblePeers[peerId] != null)
          .firstOrNull;

      if (device == null) {
        Logger.info('FlutterBluePlusBleService: Peer not connected: $peerId', 'BLE');
        // TODO: Queue message for later delivery
        return false;
      }

      // Get service and characteristic
      final services = await device.discoverServices();
      final service = services.where((s) => s.serviceUuid == _serviceUuid).firstOrNull;
      if (service == null) return false;

      final messageChar = service.characteristics
          .where((c) => c.characteristicUuid == _messagingChar)
          .firstOrNull;
      if (messageChar == null) return false;

      // Serialize and send
      final data = _serializeMessagePayload(payload);
      await messageChar.write(data, withoutResponse: true);

      Logger.info('FlutterBluePlusBleService: Message sent successfully', 'BLE');
      return true;
    } catch (e) {
      Logger.error('FlutterBluePlusBleService: Message send failed', e, null, 'BLE');
      return false;
    }
  }

  @override
  Stream<ReceivedMessage> get messageReceivedStream => _messageReceivedController.stream;

  Uint8List _serializeMessagePayload(MessagePayload payload) {
    final json = {
      'type': 'message',
      'message_type': payload.type.index,
      'message_id': payload.messageId,
      'content': payload.content,
      'timestamp': payload.timestamp.toIso8601String(),
    };

    final jsonStr = jsonEncode(json);
    return Uint8List.fromList(utf8.encode(jsonStr));
  }

  void _onMessageDataReceived(String fromDeviceId, List<int> data) {
    try {
      final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;

      if (json['type'] == 'message') {
        final message = ReceivedMessage(
          fromPeerId: json['sender_id'] as String? ?? fromDeviceId,
          messageId: json['message_id'] as String,
          type: MessageType.values[json['message_type'] as int],
          content: json['content'] as String?,
          timestamp: DateTime.parse(json['timestamp'] as String),
        );

        _messageReceivedController.add(message);
        Logger.info(
          'FlutterBluePlusBleService: Received ${message.type.name}',
          'BLE',
        );
      }
    } catch (e) {
      Logger.error('FlutterBluePlusBleService: Message parse failed', e, null, 'BLE');
    }
  }

  // ==================== Photo Transfer ====================

  @override
  Future<bool> sendPhoto(String peerId, Uint8List photoData, String messageId) async {
    _ensureInitialized();

    if (photoData.length > config.maxPhotoSize) {
      Logger.error(
        'FlutterBluePlusBleService: Photo too large (${photoData.length} > ${config.maxPhotoSize})',
        null,
        null,
        'BLE',
      );
      return false;
    }

    Logger.info(
      'FlutterBluePlusBleService: Photo transfer not yet fully implemented',
      'BLE',
    );

    // TODO: Implement chunked photo transfer
    return false;
  }

  @override
  Stream<PhotoTransferProgress> get photoProgressStream => _photoProgressController.stream;

  @override
  Stream<ReceivedPhoto> get photoReceivedStream => _photoReceivedController.stream;

  @override
  Future<void> cancelPhotoTransfer(String messageId) async {
    Logger.info('FlutterBluePlusBleService: Cancelling photo transfer $messageId', 'BLE');
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
}
