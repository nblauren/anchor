import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/utils/logger.dart';
import 'ble_config.dart';
import 'ble_models.dart';
import 'ble_service_interface.dart';
import 'photo_chunker.dart';

/// BLE service using `bluetooth_low_energy` which provides both Central
/// (scanning/connecting) and Peripheral (GATT server/advertising) in one
/// package — enabling real peer-to-peer discovery AND messaging on iOS & Android.
///
/// Each device:
///   1. Runs a GATT server with profile metadata + messaging characteristics.
///   2. Advertises the Anchor service UUID + local name.
///   3. Scans for other Anchor devices.
///   4. Connects to discovered peers to read profile / send messages.
class FlutterBluePlusBleService implements BleServiceInterface {
  FlutterBluePlusBleService({
    required this.config,
  }) : _photoReassembler = PhotoReassembler();

  final BleConfig config;
  final PhotoReassembler _photoReassembler;

  // Managers
  late final CentralManager _central;
  late final PeripheralManager _peripheral;

  // UUIDs
  static final _serviceUuid =
      UUID.fromString('0000fff0-0000-1000-8000-00805f9b34fb');
  static final _profileCharUuid =
      UUID.fromString('0000fff1-0000-1000-8000-00805f9b34fb');
  static final _messagingCharUuid =
      UUID.fromString('0000fff3-0000-1000-8000-00805f9b34fb');

  // Status
  BleStatus _status = BleStatus.disabled;
  bool _isScanning = false;
  bool _isBroadcasting = false;
  bool _isInitialized = false;

  // Stream controllers
  final _statusController = StreamController<BleStatus>.broadcast();
  final _peerDiscoveredController =
      StreamController<DiscoveredPeer>.broadcast();
  final _peerLostController = StreamController<String>.broadcast();
  final _messageReceivedController =
      StreamController<ReceivedMessage>.broadcast();
  final _photoProgressController =
      StreamController<PhotoTransferProgress>.broadcast();
  final _photoReceivedController = StreamController<ReceivedPhoto>.broadcast();

  // Peer tracking
  final Map<String, DiscoveredPeer> _visiblePeers = {};
  final Map<String, Timer> _peerTimeoutTimers = {};

  // Connected peripherals (for sending messages as central)
  final Map<String, Peripheral> _discoveredPeripherals = {};
  final Map<String, GATTCharacteristic> _messagingChars = {};

  // Map from app userId → BLE peerId (peripheral UUID) so incoming messages
  // (which carry the sender's app userId) can be routed to the correct peer.
  final Map<String, String> _userIdToPeerId = {};

  // Scan lifecycle
  Timer? _scanRestartTimer;
  static const _scanDuration = Duration(seconds: 8);
  static const _scanPause = Duration(seconds: 4);

  // Subscriptions
  StreamSubscription? _centralStateSubscription;
  StreamSubscription? _peripheralStateSubscription;
  StreamSubscription? _discoveredSubscription;
  StreamSubscription? _charWriteSubscription;

  // GATT characteristics (server side)
  GATTCharacteristic? _serverProfileChar;
  GATTCharacteristic? _serverMessagingChar;

  // Cached profile data for GATT server read requests
  Uint8List _profileData = Uint8List(0);
  BroadcastPayload? _pendingPayload;

  // Active incoming binary photo transfers (keyed by centralUuid)
  // Stores metadata from the photo_start message so binary chunks
  // can be correlated without carrying their own metadata.
  final Map<String, _IncomingPhotoTransfer> _incomingPhotoTransfers = {};

  // ==================== Lifecycle ====================

  @override
  Future<void> initialize() async {
    if (_isInitialized) return;

    Logger.info('BleService: Initializing...', 'BLE');

    try {
      _central = CentralManager();
      _peripheral = PeripheralManager();

      // Listen to central manager state
      _centralStateSubscription =
          _central.stateChanged.listen((e) => _onStateChanged(e.state));

      _isInitialized = true;

      // Check initial state
      _onStateChanged(_central.state);

      Logger.info('BleService: Initialized successfully', 'BLE');
    } catch (e) {
      Logger.error('BleService: Initialization failed', e, null, 'BLE');
      _setStatus(BleStatus.error);
      rethrow;
    }
  }

  @override
  Future<void> start() async {
    _ensureInitialized();
    Logger.info('BleService: Starting...', 'BLE');

    try {
      await _setupGattServer();
      await startScanning();
      _setStatus(BleStatus.ready);
    } catch (e) {
      Logger.error('BleService: Start failed', e, null, 'BLE');
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    Logger.info('BleService: Stopping...', 'BLE');

    await stopScanning();
    await stopBroadcasting();

    try {
      await _peripheral.removeAllServices();
    } catch (e) {
      Logger.error('BleService: Remove services failed', e, null, 'BLE');
    }

    _discoveredPeripherals.clear();
    _messagingChars.clear();
    _userIdToPeerId.clear();
    _setStatus(BleStatus.ready);
  }

  @override
  Future<void> dispose() async {
    Logger.info('BleService: Disposing...', 'BLE');

    await stop();

    for (final timer in _peerTimeoutTimers.values) {
      timer.cancel();
    }

    await _centralStateSubscription?.cancel();
    await _peripheralStateSubscription?.cancel();
    await _discoveredSubscription?.cancel();
    await _charWriteSubscription?.cancel();

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
      throw StateError('BleService not initialized. Call initialize() first.');
    }
  }

  void _onStateChanged(BluetoothLowEnergyState state) {
    Logger.info('BleService: State changed: $state', 'BLE');

    switch (state) {
      case BluetoothLowEnergyState.poweredOn:
        if (_status == BleStatus.disabled) {
          _setStatus(BleStatus.ready);
        }
        // Retry pending advertising
        if (_pendingPayload != null && !_isBroadcasting) {
          _startAdvertisingAndGatt(_pendingPayload!);
        }
        break;
      case BluetoothLowEnergyState.poweredOff:
        _setStatus(BleStatus.disabled);
        _isScanning = false;
        _isBroadcasting = false;
        break;
      case BluetoothLowEnergyState.unauthorized:
        _setStatus(BleStatus.noPermission);
        break;
      case BluetoothLowEnergyState.unsupported:
        _setStatus(BleStatus.disabled);
        break;
      default:
        break;
    }
  }

  // ==================== GATT Server ====================

  Future<void> _setupGattServer() async {
    Logger.info('BleService: Setting up GATT server...', 'BLE');

    try {
      await _peripheral.removeAllServices();

      // Profile characteristic: centrals read this to get our profile
      _serverProfileChar = GATTCharacteristic.mutable(
        uuid: _profileCharUuid,
        properties: [
          GATTCharacteristicProperty.read,
        ],
        permissions: [
          GATTCharacteristicPermission.read,
        ],
        descriptors: [],
      );

      // Messaging characteristic: centrals write to this to send us messages
      _serverMessagingChar = GATTCharacteristic.mutable(
        uuid: _messagingCharUuid,
        properties: [
          GATTCharacteristicProperty.write,
          GATTCharacteristicProperty.writeWithoutResponse,
        ],
        permissions: [
          GATTCharacteristicPermission.write,
        ],
        descriptors: [],
      );

      final service = GATTService(
        uuid: _serviceUuid,
        isPrimary: true,
        includedServices: [],
        characteristics: [_serverProfileChar!, _serverMessagingChar!],
      );

      await _peripheral.addService(service);

      // Handle profile read requests
      _peripheral.characteristicReadRequested.listen(_onProfileReadRequested);

      // Handle incoming messages (writes to messaging characteristic)
      await _charWriteSubscription?.cancel();
      _charWriteSubscription =
          _peripheral.characteristicWriteRequested.listen(_onMessageWriteReceived);

      Logger.info('BleService: GATT server ready', 'BLE');
    } catch (e) {
      Logger.error('BleService: GATT server setup failed', e, null, 'BLE');
    }
  }

  void _onProfileReadRequested(
      GATTCharacteristicReadRequestedEventArgs args) async {
    try {
      await _peripheral.respondReadRequestWithValue(
        args.request,
        value: _profileData,
      );
    } catch (e) {
      Logger.error('BleService: Profile read response failed', e, null, 'BLE');
    }
  }

  void _onMessageWriteReceived(
      GATTCharacteristicWriteRequestedEventArgs args) async {
    try {
      // Respond to the write request
      await _peripheral.respondWriteRequest(args.request);

      final data = args.request.value;
      if (data.isEmpty) return;

      // Binary photo chunk: first byte is 0x02
      if (data[0] == 0x02) {
        _handleBinaryPhotoChunk(data, args.central.uuid);
        return;
      }

      // JSON payload (text messages, photo_start, legacy photo_chunk)
      final jsonStr = utf8.decode(data);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;

      final fromPeerId = _resolveSenderPeerId(json, args.central.uuid);
      final type = json['type'] as String? ?? 'message';

      if (type == 'photo_start') {
        _handlePhotoStart(json, fromPeerId);
      } else if (type == 'photo_chunk') {
        _handleReceivedPhotoChunk(json, fromPeerId);
      } else {
        _handleReceivedMessage(json, fromPeerId);
      }
    } catch (e) {
      Logger.error('BleService: Write receive failed', e, null, 'BLE');
    }
  }

  /// Resolve the sender's peerId from the payload's sender_id field,
  /// mapping their app userId back to the BLE peripheral UUID we use
  /// in our database.
  String _resolveSenderPeerId(Map<String, dynamic> json, UUID centralUuid) {
    final senderId = json['sender_id'] as String?;
    if (senderId != null &&
        senderId.isNotEmpty &&
        _userIdToPeerId.containsKey(senderId)) {
      return _userIdToPeerId[senderId]!;
    }
    return centralUuid.toString();
  }

  void _handleReceivedMessage(Map<String, dynamic> json, String fromPeerId) {
    final message = ReceivedMessage(
      fromPeerId: fromPeerId,
      messageId: json['message_id'] as String? ?? '',
      type: MessageType.values[json['message_type'] as int? ?? 0],
      content: json['content'] as String? ?? '',
      timestamp: DateTime.now(),
    );

    _messageReceivedController.add(message);

    Logger.info(
      'BleService: Received message from '
      '${fromPeerId.substring(0, min(8, fromPeerId.length))}',
      'BLE',
    );
  }

  void _handleReceivedPhotoChunk(
      Map<String, dynamic> json, String fromPeerId) {
    final dataField = json['data'];
    Uint8List chunkData;
    if (dataField is String) {
      // base64 encoded
      chunkData = base64Decode(dataField);
    } else if (dataField is List) {
      // legacy int array fallback
      chunkData = Uint8List.fromList(dataField.cast<int>());
    } else {
      chunkData = Uint8List(0);
    }

    final chunk = PhotoChunk(
      messageId: json['message_id'] as String? ?? '',
      chunkIndex: json['chunk_index'] as int? ?? 0,
      totalChunks: json['total_chunks'] as int? ?? 1,
      data: chunkData,
      totalSize: json['total_size'] as int? ?? 0,
    );

    Logger.info(
      'BleService: Received photo chunk ${chunk.chunkIndex + 1}/${chunk.totalChunks} '
      'for ${chunk.messageId.substring(0, min(8, chunk.messageId.length))}',
      'BLE',
    );

    // Emit receive-side progress
    _photoProgressController.add(PhotoTransferProgress(
      messageId: chunk.messageId,
      peerId: fromPeerId,
      progress: (chunk.chunkIndex + 1) / chunk.totalChunks,
      status: PhotoTransferStatus.inProgress,
    ));

    // Feed to reassembler
    final result = _photoReassembler.addChunk(chunk);

    if (result.isComplete && result.photoData != null) {
      Logger.info(
        'BleService: Photo reassembly complete: ${chunk.messageId} '
        '(${result.photoData!.length} bytes)',
        'BLE',
      );

      _photoReceivedController.add(ReceivedPhoto(
        fromPeerId: fromPeerId,
        messageId: chunk.messageId,
        photoBytes: result.photoData!,
        timestamp: DateTime.now(),
      ));

      _photoProgressController.add(PhotoTransferProgress(
        messageId: chunk.messageId,
        peerId: fromPeerId,
        progress: 1.0,
        status: PhotoTransferStatus.completed,
      ));
    }
  }

  /// Handle photo_start JSON message — stores metadata for the upcoming
  /// binary chunk stream from this central.
  void _handlePhotoStart(Map<String, dynamic> json, String fromPeerId) {
    final messageId = json['message_id'] as String? ?? '';
    final totalChunks = json['total_chunks'] as int? ?? 0;
    final totalSize = json['total_size'] as int? ?? 0;

    // Key by fromPeerId — one active transfer per peer
    _incomingPhotoTransfers[fromPeerId] = _IncomingPhotoTransfer(
      messageId: messageId,
      totalChunks: totalChunks,
      totalSize: totalSize,
      receivedData: BytesBuilder(copy: false),
      receivedCount: 0,
    );

    Logger.info(
      'BleService: Photo transfer starting from '
      '${fromPeerId.substring(0, min(8, fromPeerId.length))}: '
      '$totalChunks chunks, $totalSize bytes',
      'BLE',
    );

    _photoProgressController.add(PhotoTransferProgress(
      messageId: messageId,
      peerId: fromPeerId,
      progress: 0,
      status: PhotoTransferStatus.starting,
    ));
  }

  /// Handle a binary photo chunk: [0x02][uint16 chunk_index][raw data]
  void _handleBinaryPhotoChunk(Uint8List data, UUID centralUuid) {
    if (data.length < 3) return; // too short

    final chunkIndex = (data[1] << 8) | data[2];
    final chunkData = data.sublist(3);

    // Resolve peer ID from central UUID
    final centralId = centralUuid.toString();
    // Try to find the transfer by checking both the centralId directly and
    // via the userIdToPeerId mapping
    var fromPeerId = centralId;
    _IncomingPhotoTransfer? transfer = _incomingPhotoTransfers[centralId];

    if (transfer == null) {
      // Try resolving via known peer IDs — the photo_start may have been
      // stored under the resolved peerId
      for (final entry in _incomingPhotoTransfers.entries) {
        if (_userIdToPeerId.values.contains(entry.key) ||
            entry.key == centralId) {
          transfer = entry.value;
          fromPeerId = entry.key;
          break;
        }
      }
    } else {
      fromPeerId = centralId;
    }

    if (transfer == null) {
      Logger.warning(
        'BleService: Binary photo chunk received but no active transfer '
        'from $centralId (chunk $chunkIndex)',
        'BLE',
      );
      return;
    }

    transfer.receivedData.add(chunkData);
    transfer.receivedCount++;

    // Log every 50 chunks to avoid spam
    if (transfer.receivedCount % 50 == 0 ||
        transfer.receivedCount == transfer.totalChunks) {
      Logger.info(
        'BleService: Photo chunk ${transfer.receivedCount}/${transfer.totalChunks} '
        'for ${transfer.messageId.substring(0, min(8, transfer.messageId.length))}',
        'BLE',
      );
    }

    // Emit progress
    _photoProgressController.add(PhotoTransferProgress(
      messageId: transfer.messageId,
      peerId: fromPeerId,
      progress: transfer.receivedCount / transfer.totalChunks,
      status: PhotoTransferStatus.inProgress,
    ));

    // Check if transfer is complete
    if (transfer.receivedCount >= transfer.totalChunks) {
      final photoBytes = transfer.receivedData.toBytes();

      Logger.info(
        'BleService: Binary photo complete: ${transfer.messageId} '
        '(${photoBytes.length} bytes)',
        'BLE',
      );

      _photoReceivedController.add(ReceivedPhoto(
        fromPeerId: fromPeerId,
        messageId: transfer.messageId,
        photoBytes: photoBytes,
        timestamp: DateTime.now(),
      ));

      _photoProgressController.add(PhotoTransferProgress(
        messageId: transfer.messageId,
        peerId: fromPeerId,
        progress: 1.0,
        status: PhotoTransferStatus.completed,
      ));

      _incomingPhotoTransfers.remove(fromPeerId);
    }
  }

  // ==================== Status ====================

  @override
  BleStatus get status => _status;

  @override
  Stream<BleStatus> get statusStream => _statusController.stream;

  @override
  Future<bool> isBluetoothAvailable() async {
    return true; // If we got this far, BLE is available
  }

  @override
  Future<bool> isBluetoothEnabled() async {
    if (!_isInitialized) return false;
    final state = _central.state;
    return state == BluetoothLowEnergyState.poweredOn ||
        state == BluetoothLowEnergyState.unknown;
  }

  @override
  Future<bool> requestPermissions() async {
    try {
      if (Platform.isAndroid) {
        final permissions = <Permission>[];

        if (await Permission.bluetoothScan.isDenied) {
          permissions.add(Permission.bluetoothScan);
        }
        if (await Permission.bluetoothConnect.isDenied) {
          permissions.add(Permission.bluetoothConnect);
        }
        if (await Permission.bluetoothAdvertise.isDenied) {
          permissions.add(Permission.bluetoothAdvertise);
        }
        if (await Permission.locationWhenInUse.isDenied) {
          permissions.add(Permission.locationWhenInUse);
        }

        if (permissions.isEmpty) return true;
        final statuses = await permissions.request();
        return statuses.values.every((s) => s.isGranted);
      }

      // iOS: permissions are requested implicitly by the BLE managers
      return true;
    } catch (e) {
      Logger.error('BleService: Permission request failed', e, null, 'BLE');
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
      if (!_isInitialized) return false;
      final state = _central.state;
      return state != BluetoothLowEnergyState.unauthorized &&
          state != BluetoothLowEnergyState.unknown;
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
    _pendingPayload = payload;

    // Encode profile data for GATT read requests
    _profileData = _encodeProfileData(payload);

    Logger.info(
      'BleService: Broadcasting profile for ${payload.name}',
      'BLE',
    );

    final state = _peripheral.state;
    if (state != BluetoothLowEnergyState.poweredOn) {
      Logger.warning(
        'BleService: Peripheral not ready ($state), will retry when ready',
        'BLE',
      );
      return;
    }

    await _startAdvertisingAndGatt(payload);
  }

  Future<void> _startAdvertisingAndGatt(BroadcastPayload payload) async {
    try {
      if (_isBroadcasting) {
        await _peripheral.stopAdvertising();
        _isBroadcasting = false;
      }

      // Encode compact name for advertisement
      final compactName = _encodeLocalName(payload);

      Logger.info(
        'BleService: Advertising with name="$compactName"',
        'BLE',
      );

      await _peripheral.startAdvertising(Advertisement(
        name: compactName,
        serviceUUIDs: [_serviceUuid],
      ));

      _isBroadcasting = true;
      Logger.info('BleService: Advertising started', 'BLE');
    } catch (e) {
      Logger.error('BleService: Advertising failed', e, null, 'BLE');
      _isBroadcasting = false;
    }
  }

  @override
  Future<void> stopBroadcasting() async {
    Logger.info('BleService: Stopped broadcasting', 'BLE');
    try {
      await _peripheral.stopAdvertising();
    } catch (e) {
      Logger.error('BleService: Stop advertising failed', e, null, 'BLE');
    }
    _isBroadcasting = false;
  }

  @override
  bool get isBroadcasting => _isBroadcasting;

  /// Encode local name: "A:<name>:<age>"
  String _encodeLocalName(BroadcastPayload payload) {
    final name = payload.name.length > 8
        ? payload.name.substring(0, 8)
        : payload.name;
    final age = payload.age ?? 0;
    return 'A:$name:$age';
  }

  /// Decode local name "A:<name>:<age>"
  ({String name, int? age})? _decodeLocalName(String advName) {
    if (!advName.startsWith('A:')) return null;
    final parts = advName.split(':');
    if (parts.length < 3) return null;
    final name = parts[1];
    final age = int.tryParse(parts[2]);
    return (
      name: name.isEmpty ? 'Anchor User' : name,
      age: age == 0 ? null : age
    );
  }

  /// Encode profile data as JSON for GATT characteristic reads.
  Uint8List _encodeProfileData(BroadcastPayload payload) {
    final json = {
      'userId': payload.userId,
      'name': payload.name,
      'age': payload.age,
      'bio': payload.bio,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  // ==================== Discovery ====================

  @override
  Stream<DiscoveredPeer> get peerDiscoveredStream =>
      _peerDiscoveredController.stream;

  @override
  Stream<String> get peerLostStream => _peerLostController.stream;

  @override
  Future<void> startScanning() async {
    if (_isScanning) return;
    _ensureInitialized();

    Logger.info('BleService: Starting periodic scan...', 'BLE');

    _isScanning = true;
    _setStatus(BleStatus.scanning);

    // Listen for discovered peripherals
    await _discoveredSubscription?.cancel();
    _discoveredSubscription = _central.discovered.listen(_onDeviceDiscovered);

    // Start first scan cycle
    _runScanCycle();
  }

  void _runScanCycle() async {
    if (!_isScanning) return;

    try {
      Logger.info('BleService: Scan cycle starting...', 'BLE');

      await _central.startDiscovery();

      // Stop after scan duration and schedule next cycle
      _scanRestartTimer?.cancel();
      _scanRestartTimer = Timer(_scanDuration, () async {
        if (!_isScanning) return;
        try {
          await _central.stopDiscovery();
        } catch (_) {}

        // Pause then restart
        if (_isScanning) {
          _scanRestartTimer = Timer(_scanPause, _runScanCycle);
        }
      });
    } catch (e) {
      Logger.error('BleService: Scan cycle failed', e, null, 'BLE');

      if (_isScanning) {
        _scanRestartTimer?.cancel();
        _scanRestartTimer = Timer(_scanPause, _runScanCycle);
      }
    }
  }

  @override
  Future<void> stopScanning() async {
    if (!_isScanning) return;

    Logger.info('BleService: Stopping scan...', 'BLE');

    _isScanning = false;
    _scanRestartTimer?.cancel();
    _scanRestartTimer = null;

    try {
      await _central.stopDiscovery();
      await _discoveredSubscription?.cancel();
      _discoveredSubscription = null;
    } catch (e) {
      Logger.error('BleService: Scan stop failed', e, null, 'BLE');
    }
  }

  @override
  bool get isScanning => _isScanning;

  void _onDeviceDiscovered(DiscoveredEventArgs event) {
    final peripheral = event.peripheral;
    final deviceId = peripheral.uuid.toString();
    final adv = event.advertisement;
    final rssi = event.rssi;

    // Check service UUID
    final hasAnchorService = adv.serviceUUIDs.contains(_serviceUuid);

    // Check local name prefix
    final advName = adv.name ?? '';
    final decoded = advName.isNotEmpty ? _decodeLocalName(advName) : null;

    // Not an Anchor device if neither marker is present
    if (!hasAnchorService && decoded == null) return;

    final name = decoded?.name ?? (advName.isNotEmpty ? advName : 'Anchor User');
    final age = decoded?.age;

    Logger.info(
      'BleService: Discovered peer "$name" '
      '(hasService: $hasAnchorService, RSSI: $rssi, id: $deviceId)',
      'BLE',
    );

    // Store the peripheral for later connection
    _discoveredPeripherals[deviceId] = peripheral;

    final peer = DiscoveredPeer(
      peerId: deviceId,
      name: name,
      age: age,
      bio: null,
      thumbnailBytes: null,
      rssi: rssi,
      timestamp: DateTime.now(),
    );
    _emitPeer(peer);

    // Try to connect and read full profile in the background
    _connectAndReadProfile(deviceId, peripheral);
  }

  /// Connect to a discovered peer to read their full profile from GATT.
  // Cached maximum write lengths per peripheral (avoids repeated queries)
  final Map<String, int> _maxWriteLengths = {};

  Future<void> _connectAndReadProfile(
      String peerId, Peripheral peripheral) async {
    // Don't re-connect if we already have messaging char cached
    if (_messagingChars.containsKey(peerId)) return;

    try {
      await _central.connect(peripheral);

      // Request larger MTU on Android (iOS auto-negotiates)
      if (Platform.isAndroid) {
        try {
          await _central.requestMTU(peripheral, mtu: 517);
        } catch (e) {
          Logger.warning('BleService: MTU request failed for $peerId', 'BLE');
        }
      }

      // Query the safe write length for this connection
      try {
        final maxLen = await _central.getMaximumWriteLength(
          peripheral,
          type: GATTCharacteristicWriteType.withResponse,
        );
        _maxWriteLengths[peerId] = maxLen;
        Logger.info(
          'BleService: Max write length for $peerId: $maxLen bytes',
          'BLE',
        );
      } catch (e) {
        Logger.warning(
          'BleService: getMaximumWriteLength failed for $peerId',
          'BLE',
        );
      }

      final services = await _central.discoverGATT(peripheral);
      final anchorService = services
          .where((s) => s.uuid == _serviceUuid)
          .firstOrNull;

      if (anchorService == null) {
        await _central.disconnect(peripheral);
        return;
      }

      // Read profile characteristic
      final profileChar = anchorService.characteristics
          .where((c) => c.uuid == _profileCharUuid)
          .firstOrNull;

      if (profileChar != null) {
        try {
          final data = await _central.readCharacteristic(
            peripheral,
            profileChar,
          );
          _updatePeerFromProfile(peerId, data);
        } catch (e) {
          Logger.warning('BleService: Profile read failed for $peerId', 'BLE');
        }
      }

      // Cache messaging characteristic for sending
      final msgChar = anchorService.characteristics
          .where((c) => c.uuid == _messagingCharUuid)
          .firstOrNull;

      if (msgChar != null) {
        _messagingChars[peerId] = msgChar;
        Logger.info('BleService: Messaging ready for $peerId', 'BLE');
      }

      // Keep connection alive for messaging
    } catch (e) {
      Logger.warning(
        'BleService: Connect to $peerId failed: $e',
        'BLE',
      );
    }
  }

  void _updatePeerFromProfile(String peerId, Uint8List data) {
    try {
      final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      final existingPeer = _visiblePeers[peerId];
      if (existingPeer == null) return;

      final userId = json['userId'] as String?;

      // Record userId → BLE peerId mapping so incoming messages (which carry
      // the sender's app userId) can be routed to the correct peer.
      if (userId != null && userId.isNotEmpty) {
        _userIdToPeerId[userId] = peerId;
      }

      // Update the existing peer entry in-place — keep the BLE peripheral UUID
      // as the stable peerId to avoid creating duplicate database records.
      final updatedPeer = DiscoveredPeer(
        peerId: peerId,
        name: json['name'] as String? ?? existingPeer.name,
        age: json['age'] as int? ?? existingPeer.age,
        bio: json['bio'] as String?,
        thumbnailBytes: null,
        rssi: existingPeer.rssi,
        timestamp: DateTime.now(),
      );

      _emitPeer(updatedPeer);
      Logger.info(
        'BleService: Updated profile for "${updatedPeer.name}"',
        'BLE',
      );
    } catch (e) {
      Logger.warning('BleService: Profile decode failed', 'BLE');
    }
  }

  void _emitPeer(DiscoveredPeer peer) {
    _visiblePeers[peer.peerId] = peer;
    _peerDiscoveredController.add(peer);

    _peerTimeoutTimers[peer.peerId]?.cancel();
    _peerTimeoutTimers[peer.peerId] = Timer(
      config.peerLostTimeout,
      () => _onPeerLost(peer.peerId),
    );
  }

  void _onPeerLost(String peerId) {
    if (_visiblePeers.containsKey(peerId)) {
      final peer = _visiblePeers.remove(peerId);
      _peerTimeoutTimers.remove(peerId)?.cancel();
      _peerLostController.add(peerId);
      _messagingChars.remove(peerId);
      _maxWriteLengths.remove(peerId);
      _userIdToPeerId.removeWhere((_, v) => v == peerId);
      Logger.info('BleService: Lost peer ${peer?.name}', 'BLE');
    }
  }

  // ==================== Messaging ====================

  @override
  Future<bool> sendMessage(String peerId, MessagePayload payload) async {
    _ensureInitialized();

    Logger.info(
      'BleService: Sending ${payload.type.name} to ${peerId.substring(0, min(8, peerId.length))}',
      'BLE',
    );

    try {
      // Find the messaging characteristic and peripheral
      var msgChar = _messagingChars[peerId];
      var peripheral = _discoveredPeripherals[peerId];

      // Try to connect if not already connected
      if (msgChar == null && peripheral != null) {
        await _connectAndReadProfile(peerId, peripheral);
        msgChar = _messagingChars[peerId];
      }

      if (msgChar == null || peripheral == null) {
        Logger.info('BleService: Peer not reachable: $peerId', 'BLE');
        return false;
      }

      final data = _serializeMessagePayload(payload);
      await _central.writeCharacteristic(
        peripheral,
        msgChar,
        value: data,
        type: GATTCharacteristicWriteType.withResponse,
      );

      Logger.info('BleService: Message sent successfully', 'BLE');
      return true;
    } catch (e) {
      Logger.error('BleService: Message send failed', e, null, 'BLE');
      // Clear cached connection so it retries next time
      _messagingChars.remove(peerId);
      return false;
    }
  }

  @override
  Stream<ReceivedMessage> get messageReceivedStream =>
      _messageReceivedController.stream;

  Uint8List _serializeMessagePayload(MessagePayload payload) {
    final json = {
      'type': 'message',
      'sender_id': _pendingPayload?.userId ?? '',
      'message_type': payload.type.index,
      'message_id': payload.messageId,
      'content': payload.content,
      'timestamp': DateTime.now().toIso8601String(),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  // ==================== Photo Transfer ====================

  // Track cancelled transfers so in-flight sends stop early
  final Set<String> _cancelledTransfers = {};

  @override
  Future<bool> sendPhoto(
      String peerId, Uint8List photoData, String messageId) async {
    _ensureInitialized();

    if (photoData.length > config.maxPhotoSize) {
      Logger.error(
        'BleService: Photo too large (${photoData.length} > ${config.maxPhotoSize})',
        null,
        null,
        'BLE',
      );
      return false;
    }

    Logger.info(
      'BleService: Starting photo transfer $messageId '
      '(${photoData.length} bytes) to ${peerId.substring(0, min(8, peerId.length))}',
      'BLE',
    );

    try {
      // Ensure we have a connection to this peer
      var msgChar = _messagingChars[peerId];
      var peripheral = _discoveredPeripherals[peerId];

      if (msgChar == null && peripheral != null) {
        await _connectAndReadProfile(peerId, peripheral);
        msgChar = _messagingChars[peerId];
      }

      if (msgChar == null || peripheral == null) {
        Logger.info('BleService: Peer not reachable for photo: $peerId', 'BLE');
        _photoProgressController.add(PhotoTransferProgress(
          messageId: messageId,
          peerId: peerId,
          progress: 0,
          status: PhotoTransferStatus.failed,
          errorMessage: 'Peer not reachable',
        ));
        return false;
      }

      // --- Binary photo transfer protocol ---
      //
      // iOS CoreBluetooth has a very limited "prepare queue" on the GATT
      // server side. Any writeWithResponse whose payload exceeds the ATT MTU
      // (~185 bytes iOS-to-iOS) gets split into Prepare Write + Execute Write
      // ATT operations, and the receiver's queue overflows (CBATTError code 9).
      //
      // To avoid this we use a two-phase binary protocol:
      //   Phase 1: Send a small JSON "photo_start" message with metadata.
      //   Phase 2: Send raw binary chunks with only 3 bytes overhead each:
      //            [0x02][uint16 chunk_index][raw photo bytes]
      //
      // This keeps every single write well under the ATT MTU.

      // Use a conservative max payload — iOS default ATT MTU is 185,
      // usable payload is MTU - 3 = 182 bytes.
      final maxWriteLen = _maxWriteLengths[peerId] ?? 182;
      // Binary chunk overhead: 1 (marker) + 2 (index) = 3 bytes
      const binaryOverhead = 3;
      final rawChunkSize = max(20, maxWriteLen - binaryOverhead);

      // Split photo into chunks
      final totalChunks = (photoData.length + rawChunkSize - 1) ~/ rawChunkSize;

      Logger.info(
        'BleService: Photo binary transfer: ${photoData.length}B, '
        '$totalChunks chunks (${rawChunkSize}B each, maxWrite=$maxWriteLen)',
        'BLE',
      );

      // Phase 1: Send photo_start metadata as JSON (no photo data, small payload)
      final startPayload = utf8.encode(jsonEncode({
        'type': 'photo_start',
        'sender_id': _pendingPayload?.userId ?? '',
        'message_id': messageId,
        'total_chunks': totalChunks,
        'total_size': photoData.length,
      }));

      await _central.writeCharacteristic(
        peripheral,
        msgChar,
        value: Uint8List.fromList(startPayload),
        type: GATTCharacteristicWriteType.withResponse,
      );

      await Future.delayed(const Duration(milliseconds: 50));

      // Emit starting progress
      _photoProgressController.add(PhotoTransferProgress(
        messageId: messageId,
        peerId: peerId,
        progress: 0,
        status: PhotoTransferStatus.starting,
      ));

      // Phase 2: Send binary chunks
      for (var i = 0; i < totalChunks; i++) {
        // Check if transfer was cancelled
        if (_cancelledTransfers.contains(messageId)) {
          _cancelledTransfers.remove(messageId);
          _photoProgressController.add(PhotoTransferProgress(
            messageId: messageId,
            peerId: peerId,
            progress: i / totalChunks,
            status: PhotoTransferStatus.cancelled,
          ));
          return false;
        }

        // Build binary payload: [0x02][uint16 chunk_index][raw data]
        final dataStart = i * rawChunkSize;
        final dataEnd = min(dataStart + rawChunkSize, photoData.length);
        final chunkData = photoData.sublist(dataStart, dataEnd);

        final payload = Uint8List(binaryOverhead + chunkData.length);
        payload[0] = 0x02; // photo chunk marker
        payload[1] = (i >> 8) & 0xFF; // chunk index high byte
        payload[2] = i & 0xFF; // chunk index low byte
        payload.setRange(binaryOverhead, payload.length, chunkData);

        await _central.writeCharacteristic(
          peripheral,
          msgChar,
          value: payload,
          type: GATTCharacteristicWriteType.withResponse,
        );

        // Pace writes to let the receiver's GATT server process each one
        if (i < totalChunks - 1) {
          await Future.delayed(const Duration(milliseconds: 50));
        }

        // Emit progress
        final progress = (i + 1) / totalChunks;
        _photoProgressController.add(PhotoTransferProgress(
          messageId: messageId,
          peerId: peerId,
          progress: progress,
          status: i == totalChunks - 1
              ? PhotoTransferStatus.completed
              : PhotoTransferStatus.inProgress,
        ));
      }

      Logger.info('BleService: Photo transfer completed: $messageId', 'BLE');
      return true;
    } catch (e) {
      Logger.error('BleService: Photo transfer failed', e, null, 'BLE');
      _messagingChars.remove(peerId);
      _photoProgressController.add(PhotoTransferProgress(
        messageId: messageId,
        peerId: peerId,
        progress: 0,
        status: PhotoTransferStatus.failed,
        errorMessage: e.toString(),
      ));
      return false;
    }
  }

  @override
  Stream<PhotoTransferProgress> get photoProgressStream =>
      _photoProgressController.stream;

  @override
  Stream<ReceivedPhoto> get photoReceivedStream =>
      _photoReceivedController.stream;

  @override
  Future<void> cancelPhotoTransfer(String messageId) async {
    Logger.info('BleService: Cancelling photo transfer $messageId', 'BLE');
    _cancelledTransfers.add(messageId);
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

/// Tracks an incoming binary photo transfer from a specific peer.
class _IncomingPhotoTransfer {
  _IncomingPhotoTransfer({
    required this.messageId,
    required this.totalChunks,
    required this.totalSize,
    required this.receivedData,
    required this.receivedCount,
  });

  final String messageId;
  final int totalChunks;
  final int totalSize;
  final BytesBuilder receivedData;
  int receivedCount;
}
