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
  static final _thumbnailCharUuid =
      UUID.fromString('0000fff2-0000-1000-8000-00805f9b34fb');
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
  static const _scanDuration = Duration(seconds: 5);
  static const _scanPause = Duration(seconds: 15);

  // Subscriptions
  StreamSubscription? _centralStateSubscription;
  StreamSubscription? _peripheralStateSubscription;
  StreamSubscription? _discoveredSubscription;
  StreamSubscription? _charReadSubscription;
  StreamSubscription? _charWriteSubscription;
  StreamSubscription? _charNotifyStateSubscription;
  StreamSubscription? _charNotifiedSubscription;

  // In-memory message ID deduplication — prevents the same BLE write
  // from being processed twice if the transport retransmits it.
  final Set<String> _seenMessageIds = {};

  // GATT characteristics (server side)
  GATTCharacteristic? _serverProfileChar;
  GATTCharacteristic? _serverThumbnailChar;
  GATTCharacteristic? _serverMessagingChar;
  bool _gattServerReady = false; // true once addService succeeds
  bool _settingUpGatt = false; // prevents concurrent _setupGattServer calls
  bool _startCalled = false; // true after start() has been called at least once

  // Cached profile data for GATT server read requests
  Uint8List _profileData = Uint8List(0);
  // Raw thumbnail bytes served via the dedicated thumbnail characteristic (fff2).
  // Kept separate from _profileData so the profile JSON stays small (<512 bytes).
  Uint8List _thumbnailData = Uint8List(0);
  BroadcastPayload? _pendingPayload;

  // Per-peer characteristic cache (central side — for reading remote profiles)
  final Map<String, GATTCharacteristic> _profileChars = {};
  final Map<String, GATTCharacteristic> _thumbnailChars = {};
  // Throttle profile re-reads to once per 60 s per peer
  final Map<String, DateTime> _lastProfileReadTime = {};

  // Per-peer thumbnail assembly buffers (notification-based chunked delivery)
  final Map<String, List<int>> _thumbnailBuffers = {};
  final Map<String, int> _thumbnailExpectedSizes = {};

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

      // Listen to peripheral manager state so we can set up the GATT server
      // and retry advertising once the peripheral is powered on.
      _peripheralStateSubscription = _peripheral.stateChanged
          .listen((e) => _onPeripheralStateChanged(e.state));

      _isInitialized = true;

      // Check initial state
      _onStateChanged(_central.state);
      _onPeripheralStateChanged(_peripheral.state);

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
      _startCalled = true;
      await _setupGattServer(force: true);
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

    _gattServerReady = false;
    _settingUpGatt = false;
    _startCalled = false;
    _discoveredPeripherals.clear();
    _messagingChars.clear();
    _profileChars.clear();
    _thumbnailChars.clear();
    _maxWriteLengths.clear();
    _lastProfileReadTime.clear();
    _userIdToPeerId.clear();
    _thumbnailBuffers.clear();
    _thumbnailExpectedSizes.clear();
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
    await _charReadSubscription?.cancel();
    await _charWriteSubscription?.cancel();
    await _charNotifyStateSubscription?.cancel();
    await _charNotifiedSubscription?.cancel();

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
    Logger.info('BleService: Central state changed: $state', 'BLE');

    switch (state) {
      case BluetoothLowEnergyState.poweredOn:
        if (_status == BleStatus.disabled) {
          _setStatus(BleStatus.ready);
        }
        // Retry pending advertising (central ready — peripheral may already be ready too)
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

  /// Called when the PeripheralManager state changes.
  ///
  /// The peripheral and central managers share the same Bluetooth adapter on
  /// iOS/Android, but their state callbacks can fire at slightly different times.
  /// Listening here ensures the GATT server is (re-)registered and pending
  /// advertising is retried as soon as the peripheral is ready — even if
  /// [_onStateChanged] (central) already fired.
  void _onPeripheralStateChanged(BluetoothLowEnergyState state) {
    Logger.info('BleService: Peripheral state changed: $state', 'BLE');

    if (state == BluetoothLowEnergyState.poweredOn &&
        _startCalled &&
        !_gattServerReady) {
      // start() was called but the GATT server setup failed because the
      // peripheral wasn't ready yet. Retry now that it's powered on.
      _setupGattServer().then((_) {
        if (_pendingPayload != null && !_isBroadcasting) {
          _startAdvertisingAndGatt(_pendingPayload!);
        }
      });
    }
  }

  // ==================== GATT Server ====================

  Future<void> _setupGattServer({bool force = false}) async {
    if (_settingUpGatt && !force) return; // skip if already in progress
    _settingUpGatt = true;
    _gattServerReady = false;
    Logger.info('BleService: Setting up GATT server...', 'BLE');

    try {
      await _peripheral.removeAllServices();

      // Profile characteristic: centrals read this to get our profile metadata
      // Kept small (userId/name/age/bio, <512 bytes) to stay within ATT limits.
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

      // Thumbnail characteristic: centrals read this to get our profile photo.
      // Also has notify so the peripheral can push the thumbnail in chunks
      // when the central subscribes — bypassing the single-packet ATT read limit.
      _serverThumbnailChar = GATTCharacteristic.mutable(
        uuid: _thumbnailCharUuid,
        properties: [
          GATTCharacteristicProperty.read,
          GATTCharacteristicProperty.notify,
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
        characteristics: [
          _serverProfileChar!,
          _serverThumbnailChar!,
          _serverMessagingChar!,
        ],
      );

      await _peripheral.addService(service);

      // Handle profile + thumbnail read requests (single stream, dispatch by UUID)
      await _charReadSubscription?.cancel();
      _charReadSubscription = _peripheral.characteristicReadRequested
          .listen(_onCharacteristicReadRequested);

      // Handle incoming messages (writes to messaging characteristic)
      await _charWriteSubscription?.cancel();
      _charWriteSubscription = _peripheral.characteristicWriteRequested
          .listen(_onMessageWriteReceived);

      // Handle thumbnail characteristic notify subscriptions from centrals.
      // When a central subscribes, push the thumbnail in chunks.
      await _charNotifyStateSubscription?.cancel();
      _charNotifyStateSubscription = _peripheral
          .characteristicNotifyStateChanged
          .listen(_onThumbnailNotifyStateChanged);

      // Handle thumbnail notification chunks arriving at the central side.
      await _charNotifiedSubscription?.cancel();
      _charNotifiedSubscription =
          _central.characteristicNotified.listen(_onCharacteristicNotified);

      _gattServerReady = true;
      Logger.info('BleService: GATT server ready', 'BLE');
    } catch (e) {
      Logger.error('BleService: GATT server setup failed', e, null, 'BLE');
    } finally {
      _settingUpGatt = false;
    }
  }

  /// Handles read requests for ALL readable characteristics.
  /// Dispatches by UUID so both the profile char (fff1) and the thumbnail
  /// char (fff2) are served from the correct data buffer.
  ///
  /// iOS issues Read Blob Requests with increasing offsets for data > ATT MTU.
  /// We respond with the slice starting at `offset`; CoreBluetooth clips the
  /// response to MTU-1 bytes and issues the next request automatically.
  void _onCharacteristicReadRequested(
      GATTCharacteristicReadRequestedEventArgs args) async {
    try {
      final charUuid = args.characteristic.uuid;
      final offset = args.request.offset;

      final Uint8List sourceData;
      final String charName;
      if (charUuid == _profileCharUuid) {
        sourceData = _profileData;
        charName = 'profile';
      } else if (charUuid == _thumbnailCharUuid) {
        sourceData = _thumbnailData;
        charName = 'thumbnail';
      } else {
        await _peripheral.respondReadRequestWithValue(
          args.request,
          value: Uint8List(0),
        );
        return;
      }

      final slice = offset < sourceData.length
          ? sourceData.sublist(offset)
          : Uint8List(0);

      Logger.info(
        'BleService: Read request [$charName] offset=$offset '
            'total=${sourceData.length}B responding=${slice.length}B',
        'BLE',
      );

      await _peripheral.respondReadRequestWithValue(
        args.request,
        value: slice,
      );
    } catch (e) {
      Logger.error(
          'BleService: Characteristic read response failed', e, null, 'BLE');
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
    final messageId = json['message_id'] as String? ?? '';

    // Deduplicate — BLE transport can retransmit the same write
    if (messageId.isNotEmpty) {
      if (_seenMessageIds.contains(messageId)) {
        Logger.info('BleService: Duplicate message ignored: $messageId', 'BLE');
        return;
      }
      _seenMessageIds.add(messageId);
      // Evict after 5 minutes to avoid unbounded growth
      Future.delayed(
          const Duration(minutes: 5), () => _seenMessageIds.remove(messageId));
    }

    final message = ReceivedMessage(
      fromPeerId: fromPeerId,
      messageId: messageId,
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

  void _handleReceivedPhotoChunk(Map<String, dynamic> json, String fromPeerId) {
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

    // Set thumbnail data FIRST so _encodeProfileData can include thumbnail_size.
    _thumbnailData = payload.thumbnailBytes ?? Uint8List(0);
    _profileData = _encodeProfileData(payload);

    Logger.info(
      'BleService: Broadcasting profile for ${payload.name} '
          '(profileData=${_profileData.length}B, thumbnailData=${_thumbnailData.length}B)',
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
        serviceUUIDs: [
          _serviceUuid,
          _messagingCharUuid,
          _profileCharUuid,
          _thumbnailCharUuid
        ],
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
    final name =
        payload.name.length > 8 ? payload.name.substring(0, 8) : payload.name;
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

  /// Encode profile metadata as a small JSON for the profile characteristic.
  ///
  /// Intentionally excludes the thumbnail — that is served separately via the
  /// dedicated thumbnail characteristic (fff2) as raw binary bytes, avoiding
  /// the base64 inflation that would push the JSON well past the 512-byte
  /// ATT attribute value limit.
  Uint8List _encodeProfileData(BroadcastPayload payload) {
    final json = <String, dynamic>{
      'userId': payload.userId,
      'name': payload.name,
      'age': payload.age,
      'bio': payload.bio,
      // Include thumbnail size so the central knows how many notification bytes
      // to accumulate before the thumbnail is fully reassembled.
      if (_thumbnailData.isNotEmpty) 'thumbnail_size': _thumbnailData.length,
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

      await _central.startDiscovery(serviceUUIDs: [_serviceUuid]);

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

  final Map<String, int> _lastRssi = {}; // peerId → last seen RSSI
  final Map<String, DateTime> _lastEmit = {}; // peerId → last emit time

  void _onDeviceDiscovered(DiscoveredEventArgs event) {
    final peripheral = event.peripheral;
    final deviceId = peripheral.uuid.toString();
    final adv = event.advertisement;
    final rssi = event.rssi;
    final now = DateTime.now();

    // Skip if same peer and RSSI change < 5 dBm within 3 seconds
    if (_lastEmit.containsKey(deviceId)) {
      final timeSince = now.difference(_lastEmit[deviceId]!);
      final rssiDelta = (_lastRssi[deviceId]! - rssi).abs();
      if (timeSince < const Duration(seconds: 3) && rssiDelta < 5) {
        return;
      }
    }

    _lastRssi[deviceId] = rssi;
    _lastEmit[deviceId] = now;

    // Check service UUID
    final hasAnchorService = adv.serviceUUIDs.contains(_serviceUuid);

    // Check local name prefix
    final advName = adv.name ?? '';
    final decoded = advName.isNotEmpty ? _decodeLocalName(advName) : null;

    // Not an Anchor device if neither marker is present
    if (!hasAnchorService && decoded == null) return;

    final name =
        decoded?.name ?? (advName.isNotEmpty ? advName : 'Anchor User');
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

  /// Connect to a discovered peer to read their profile + thumbnail from GATT.
  ///
  /// On first contact: connects, negotiates MTU, discovers services, caches
  /// all characteristics. On subsequent sightings (peer already connected):
  /// skips the connect step and re-reads the profile + thumbnail directly,
  /// throttled to once every 60 seconds so a peer updating their photo is
  /// picked up without excessive GATT traffic.
  // Cached maximum write lengths per peripheral (avoids repeated queries)
  final Map<String, int> _maxWriteLengths = {};

  Future<void> _connectAndReadProfile(
      String peerId, Peripheral peripheral) async {
    final isAlreadyConnected = _messagingChars.containsKey(peerId);

    if (!isAlreadyConnected) {
      // ── First contact: full connect + GATT discovery ──
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

        // Query the safe write length for photo transfers
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
        final anchorService =
            services.where((s) => s.uuid == _serviceUuid).firstOrNull;

        if (anchorService == null) {
          await _central.disconnect(peripheral);
          return;
        }

        // Cache all readable/writable characteristics for future use
        for (final char in anchorService.characteristics) {
          if (char.uuid == _profileCharUuid) {
            _profileChars[peerId] = char;
          } else if (char.uuid == _thumbnailCharUuid) {
            _thumbnailChars[peerId] = char;
          } else if (char.uuid == _messagingCharUuid) {
            _messagingChars[peerId] = char;
            Logger.info('BleService: Messaging ready for $peerId', 'BLE');
          }
        }

      } catch (e) {
        Logger.warning(
          'BleService: Connect to $peerId failed: $e',
          'BLE',
        );
        return;
      }
    }

    // ── Throttled profile + thumbnail re-read ──
    // Always read on first contact; re-read at most once per 30 s thereafter
    // so devices pick up profile updates (e.g. newly added photo) quickly.
    final lastRead = _lastProfileReadTime[peerId];
    final shouldReread = lastRead == null ||
        DateTime.now().difference(lastRead) > const Duration(seconds: 30);

    Logger.info(
      'BleService: _connectAndReadProfile $peerId '
          'alreadyConnected=$isAlreadyConnected '
          'hasProfileChar=${_profileChars.containsKey(peerId)} '
          'hasThumbnailChar=${_thumbnailChars.containsKey(peerId)} '
          'shouldReread=$shouldReread',
      'BLE',
    );

    if (!shouldReread) return;
    _lastProfileReadTime[peerId] = DateTime.now();

    // Read profile metadata (small JSON: userId/name/age/bio)
    final profileChar = _profileChars[peerId];
    if (profileChar != null) {
      try {
        final data = await _central.readCharacteristic(peripheral, profileChar);
        Logger.info(
          'BleService: Profile char read → ${data.length}B from $peerId',
          'BLE',
        );
        _updatePeerFromProfile(peerId, data);
      } catch (e) {
        Logger.warning(
            'BleService: Profile read failed for $peerId: $e', 'BLE');
      }
    } else {
      Logger.warning(
        'BleService: No profile char cached for $peerId — skip profile read',
        'BLE',
      );
    }

    // Subscribe to thumbnail char notifications AFTER the profile read so that
    // _thumbnailExpectedSizes[peerId] is already set when chunks arrive.
    // Unsubscribe first to guarantee the peripheral sees a state-change event
    // (false → true) and re-pushes the thumbnail, even if we were already
    // subscribed from a prior attempt.
    final thumbnailChar = _thumbnailChars[peerId];
    if (thumbnailChar != null) {
      try {
        // Clear any stale buffer so we accumulate a fresh delivery.
        _thumbnailBuffers.remove(peerId);

        try {
          await _central.setCharacteristicNotifyState(
            peripheral,
            thumbnailChar,
            state: false,
          );
        } catch (_) {
          // Ignore — may not have been subscribed yet
        }

        await _central.setCharacteristicNotifyState(
          peripheral,
          thumbnailChar,
          state: true,
        );
        Logger.info(
          'BleService: Subscribed to thumbnail notifications from $peerId',
          'BLE',
        );
      } catch (e) {
        Logger.warning(
          'BleService: Failed to subscribe to thumbnail notifications from $peerId: $e',
          'BLE',
        );
      }
    } else {
      Logger.warning(
        'BleService: No thumbnail char found for $peerId '
            '— peer may be running old code without fff2',
        'BLE',
      );
    }
  }

  void _updatePeerFromProfile(String peerId, Uint8List data) {
    try {
      final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      final existingPeer = _visiblePeers[peerId];
      if (existingPeer == null) return;

      // Prepare thumbnail assembly buffer if the peer has a thumbnail.
      // The central will subscribe to thumbnail char notifications and accumulate
      // notification chunks until it has received thumbnail_size bytes.
      final thumbnailSize = json['thumbnail_size'] as int?;
      if (thumbnailSize != null && thumbnailSize > 0) {
        _thumbnailExpectedSizes[peerId] = thumbnailSize;
        // Preserve any chunks already buffered — they may have arrived before
        // this profile read completed. Only create the buffer if absent.
        final buffer = _thumbnailBuffers.putIfAbsent(peerId, () => []);
        Logger.info(
          'BleService: Expecting ${thumbnailSize}B thumbnail from $peerId '
              '(${buffer.length}B already buffered)',
          'BLE',
        );
        // If chunks arrived early and we already have everything, reassemble now.
        if (buffer.length >= thumbnailSize) {
          final thumbnailBytes =
              Uint8List.fromList(buffer.sublist(0, thumbnailSize));
          _thumbnailBuffers.remove(peerId);
          _thumbnailExpectedSizes.remove(peerId);
          _updatePeerThumbnail(peerId, thumbnailBytes);
        }
      }

      final userId = json['userId'] as String?;

      // Record userId → BLE peerId mapping so incoming messages (which carry
      // the sender's app userId) can be routed to the correct peer.
      if (userId != null && userId.isNotEmpty) {
        _userIdToPeerId[userId] = peerId;
      }

      // Update the existing peer entry in-place — keep the BLE peripheral UUID
      // as the stable peerId to avoid creating duplicate database records.
      // Thumbnail is NOT in the profile JSON (lives in the fff2 characteristic).
      // Preserve any thumbnail bytes we have already read.
      final updatedPeer = DiscoveredPeer(
        peerId: peerId,
        name: json['name'] as String? ?? existingPeer.name,
        age: json['age'] as int? ?? existingPeer.age,
        bio: json['bio'] as String?,
        thumbnailBytes: existingPeer.thumbnailBytes,
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

  /// Update an existing visible peer's thumbnail bytes after reading the
  /// dedicated thumbnail characteristic (fff2).
  void _updatePeerThumbnail(String peerId, Uint8List thumbnailBytes) {
    final existingPeer = _visiblePeers[peerId];
    if (existingPeer == null) return;

    final updatedPeer = existingPeer.copyWith(
      thumbnailBytes: thumbnailBytes,
      timestamp: DateTime.now(),
    );
    _emitPeer(updatedPeer);
    Logger.info(
      'BleService: Updated thumbnail for "${updatedPeer.name}" '
          '(${thumbnailBytes.length}B)',
      'BLE',
    );
  }

  /// Called on the PERIPHERAL side when a central subscribes to the thumbnail
  /// characteristic.  Push the thumbnail in MTU-sized chunks so the central can
  /// reassemble the full JPEG without being limited by a single ATT read payload.
  void _onThumbnailNotifyStateChanged(
      GATTCharacteristicNotifyStateChangedEventArgs args) async {
    if (args.characteristic.uuid != _thumbnailCharUuid) return;
    if (!args.state) return; // Unsubscribed — nothing to do

    final data = _thumbnailData;
    if (data.isEmpty) return;

    final central = args.central;
    int maxChunk;
    try {
      maxChunk = await _peripheral.getMaximumNotifyLength(central);
    } catch (_) {
      maxChunk = 500; // Conservative fallback
    }

    Logger.info(
      'BleService: Central subscribed to thumbnail — pushing '
          '${data.length}B in ≤${maxChunk}B chunks',
      'BLE',
    );

    var offset = 0;
    while (offset < data.length) {
      final end = min(offset + maxChunk, data.length);
      final chunk = data.sublist(offset, end);
      try {
        await _peripheral.notifyCharacteristic(
          central,
          _serverThumbnailChar!,
          value: chunk,
        );
        offset = end;
      } catch (e) {
        Logger.warning(
          'BleService: Thumbnail chunk failed at offset $offset: $e',
          'BLE',
        );
        break;
      }
    }
    Logger.info(
      'BleService: Thumbnail push complete (${data.length}B sent)',
      'BLE',
    );
  }

  /// Called on the CENTRAL side when a notification arrives on any characteristic.
  /// Accumulates thumbnail chunks and calls [_updatePeerThumbnail] when complete.
  void _onCharacteristicNotified(GATTCharacteristicNotifiedEventArgs args) {
    if (args.characteristic.uuid != _thumbnailCharUuid) return;

    final peerId = args.peripheral.uuid.toString();
    var buffer = _thumbnailBuffers[peerId] ??= []; // create if missing
    var expected = _thumbnailExpectedSizes[peerId];

    buffer.addAll(args.value);

    // If we still don't know expected size, but buffer is getting big → log warning
    if (expected == null && buffer.length > 32000) {
      Logger.warning(
          'Receiving thumbnail chunks without knowing size – possible race',
          'BLE');
      // Optionally: keep buffering anyway and wait for late profile read
    }

    if (expected != null && buffer.length >= expected) {
      final thumbnailBytes = Uint8List.fromList(buffer.sublist(0, expected));
      _thumbnailBuffers.remove(peerId);
      _thumbnailExpectedSizes.remove(peerId);
      _updatePeerThumbnail(peerId, thumbnailBytes);
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
      _profileChars.remove(peerId);
      _thumbnailChars.remove(peerId);
      _maxWriteLengths.remove(peerId);
      _lastProfileReadTime.remove(peerId);
      _thumbnailBuffers.remove(peerId);
      _thumbnailExpectedSizes.remove(peerId);
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
