import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/utils/logger.dart';
import 'ble_config.dart';
import 'ble_models.dart';
import 'ble_service_interface.dart';
import 'photo_chunker.dart';

/// BLE service implementation using flutter_blue_plus (central/scan) +
/// flutter_ble_peripheral (peripheral/advertise) for direct peer-to-peer
/// communication.
///
/// **Discovery approach:**
///   - Each device advertises the Anchor service UUID so scanners can filter.
///   - On Android: profile data is encoded in manufacturer data.
///   - On iOS: only service UUID and local name are advertised (iOS drops
///     manufacturer data from CBPeripheralManager advertisements).
///   - The scanner uses `withServices` on iOS (required for overflow area
///     discovery) and no filter on Android (128-bit UUID may overflow to
///     scan response which the OS filter ignores).
class FlutterBluePlusBleService implements BleServiceInterface {
  FlutterBluePlusBleService({
    required this.config,
  })  : _photoReassembler = PhotoReassembler(),
        _peripheral = FlutterBlePeripheral();

  final BleConfig config;
  final PhotoReassembler _photoReassembler;
  final FlutterBlePeripheral _peripheral;

  // UUIDs for Anchor BLE service
  static const _serviceUuidStr = '0000fff0-0000-1000-8000-00805f9b34fb';
  static final _serviceUuid = Guid(_serviceUuidStr);
  static final _messagingChar = Guid('0000fff3-0000-1000-8000-00805f9b34fb');

  // Manufacturer company ID — 0xFFFF is reserved for internal/testing use.
  static const _manufacturerId = 0xFFFF;
  // Magic bytes that prefix manufacturer data so we can identify Anchor payloads.
  static const _anchorMagic = [0xAC, 0x01]; // "Anchor v1"

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
  final Map<String, BluetoothDevice> _connectedDevices = {};

  // Connection management
  final Map<String, StreamSubscription> _connectionSubscriptions = {};

  // Pending broadcast payload (for retry when peripheral becomes ready)
  BroadcastPayload? _pendingPayload;

  // Scan lifecycle
  Timer? _scanRestartTimer;
  static const _scanDuration = Duration(seconds: 8);
  static const _scanPause = Duration(seconds: 4);
  StreamSubscription? _scanSubscription;
  StreamSubscription? _adapterStateSubscription;

  // ==================== Lifecycle ====================

  @override
  Future<void> initialize() async {
    if (_isInitialized) return;

    Logger.info('FlutterBluePlusBleService: Initializing...', 'BLE');

    try {
      if (!await FlutterBluePlus.isSupported) {
        _setStatus(BleStatus.disabled);
        throw StateError('Bluetooth is not available on this device');
      }

      _adapterStateSubscription =
          FlutterBluePlus.adapterState.listen(_onAdapterStateChanged);

      _isInitialized = true;

      final adapterState = await FlutterBluePlus.adapterState.first;
      _onAdapterStateChanged(adapterState);

      Logger.info('FlutterBluePlusBleService: Initialized successfully', 'BLE');
    } catch (e) {
      Logger.error(
          'FlutterBluePlusBleService: Initialization failed', e, null, 'BLE');
      _setStatus(BleStatus.error);
      rethrow;
    }
  }

  @override
  Future<void> start() async {
    _ensureInitialized();
    Logger.info('FlutterBluePlusBleService: Starting...', 'BLE');

    try {
      await startScanning();
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

    for (final device in _connectedDevices.values) {
      try {
        await device.disconnect();
      } catch (e) {
        Logger.error(
            'FlutterBluePlusBleService: Disconnect failed', e, null, 'BLE');
      }
    }
    _connectedDevices.clear();
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
    await _peripheralStateSubscription?.cancel();

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
      throw StateError(
          'FlutterBluePlusBleService not initialized. Call initialize() first.');
    }
  }

  void _onAdapterStateChanged(BluetoothAdapterState state) {
    Logger.info(
        'FlutterBluePlusBleService: Adapter state: ${state.name}', 'BLE');

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
        _setStatus(BleStatus.disabled);
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
    return await FlutterBluePlus.isSupported;
  }

  @override
  Future<bool> isBluetoothEnabled() async {
    final state = await FlutterBluePlus.adapterState.first;
    return state == BluetoothAdapterState.on ||
        state == BluetoothAdapterState.unknown;
  }

  @override
  Future<bool> requestPermissions() async {
    try {
      final permissions = <Permission>[];

      if (Platform.isAndroid) {
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

      if (await Permission.locationWhenInUse.isDenied) {
        permissions.add(Permission.locationWhenInUse);
      }

      if (permissions.isEmpty) return true;

      final statuses = await permissions.request();
      return statuses.values.every((status) => status.isGranted);
    } catch (e) {
      Logger.error('FlutterBluePlusBleService: Permission request failed', e,
          null, 'BLE');
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
      final adapterState = await FlutterBluePlus.adapterState.first;
      return adapterState != BluetoothAdapterState.unauthorized &&
          adapterState != BluetoothAdapterState.unknown;
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

    Logger.info(
        'FlutterBluePlusBleService: Broadcasting profile for ${payload.name} (platform: ${Platform.operatingSystem})',
        'BLE');

    // Wait for peripheral manager to be ready (poweredOn).
    // On iOS, CBPeripheralManager silently drops startAdvertising calls
    // if it hasn't reached poweredOn yet.
    final isReady = await _peripheral.isBluetoothOn;
    if (!isReady) {
      Logger.warning(
        'FlutterBluePlusBleService: Peripheral not ready yet, will retry when ready',
        'BLE',
      );
      _startPeripheralStateListener();
      return;
    }

    await _startAdvertising(payload);
  }

  /// Actually start the BLE advertisement.
  Future<void> _startAdvertising(BroadcastPayload payload) async {
    try {
      if (_isBroadcasting) {
        await _peripheral.stop();
        _isBroadcasting = false;
      }

      if (Platform.isIOS) {
        // iOS: CBPeripheralManager silently drops manufacturer data.
        // Only service UUID and local name are supported.
        final compactName = _encodeLocalName(payload);

        Logger.info(
          'FlutterBluePlusBleService: iOS advertising with localName="$compactName", serviceUuid=$_serviceUuidStr',
          'BLE',
        );

        await _peripheral.start(
          advertiseData: AdvertiseData(
            serviceUuid: _serviceUuidStr,
            localName: compactName,
          ),
        );
      } else {
        // Android: use manufacturer data for full profile encoding.
        final mfgData = _encodeManufacturerData(payload);

        Logger.info(
          'FlutterBluePlusBleService: Android advertising with ${mfgData.length} bytes mfg data',
          'BLE',
        );

        await _peripheral.start(
          advertiseData: AdvertiseData(
            serviceUuid: _serviceUuidStr,
            manufacturerId: _manufacturerId,
            manufacturerData: mfgData,
            includeDeviceName: false,
          ),
          advertiseSettings: AdvertiseSettings(
            advertiseMode: AdvertiseMode.advertiseModeBalanced,
            txPowerLevel: AdvertiseTxPower.advertiseTxPowerMedium,
            connectable: true,
            timeout: 0,
          ),
        );
      }

      _isBroadcasting = true;

      // Verify advertising actually started on iOS
      final isAdvertising = await _peripheral.isAdvertising;
      Logger.info(
        'FlutterBluePlusBleService: Advertising started. isAdvertising=$isAdvertising',
        'BLE',
      );
    } catch (e, stack) {
      Logger.error(
          'FlutterBluePlusBleService: Advertising FAILED', e, stack, 'BLE');
      _isBroadcasting = false;
    }
  }

  /// Listen for peripheral manager state changes to retry advertising
  /// when Bluetooth becomes ready.
  StreamSubscription? _peripheralStateSubscription;

  void _startPeripheralStateListener() {
    _peripheralStateSubscription?.cancel();
    _peripheralStateSubscription =
        _peripheral.onPeripheralStateChanged?.listen((state) {
      Logger.info(
        'FlutterBluePlusBleService: Peripheral state changed: $state',
        'BLE',
      );
      if (state == PeripheralState.idle && _pendingPayload != null) {
        // idle = poweredOn and ready
        _startAdvertising(_pendingPayload!);
        _peripheralStateSubscription?.cancel();
        _peripheralStateSubscription = null;
      }
    });
  }

  @override
  Future<void> stopBroadcasting() async {
    Logger.info('FlutterBluePlusBleService: Stopped broadcasting', 'BLE');
    try {
      await _peripheral.stop();
    } catch (e) {
      Logger.error(
          'FlutterBluePlusBleService: Stop advertising failed', e, null, 'BLE');
    }
    _isBroadcasting = false;
  }

  @override
  bool get isBroadcasting => _isBroadcasting;

  /// Encode a compact local name for iOS advertisements.
  /// Format: "A:<name>:<age>" — kept short to fit BLE advertisement limits.
  /// "A:" prefix identifies this as an Anchor device.
  String _encodeLocalName(BroadcastPayload payload) {
    final name =
        payload.name.length > 8 ? payload.name.substring(0, 8) : payload.name;
    final age = payload.age ?? 0;
    return 'A:$name:$age';
  }

  /// Decode a compact local name from iOS advertisements.
  /// Returns (name, age) or null if not an Anchor local name.
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

  /// Encode profile as manufacturer data (Android only).
  ///
  /// Format: [magic:2][age:1][nameLen:1][name:N][userId:16]
  Uint8List _encodeManufacturerData(BroadcastPayload payload) {
    final nameBytes =
        utf8.encode(payload.name.substring(0, min(payload.name.length, 8)));

    final userIdHex = payload.userId.replaceAll('-', '');
    final userIdBytes = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      userIdBytes[i] =
          int.parse(userIdHex.substring(i * 2, i * 2 + 2), radix: 16);
    }

    final result = BytesBuilder();
    result.add(_anchorMagic); // 2 bytes magic
    result.addByte(payload.age ?? 0); // 1 byte age
    result.addByte(nameBytes.length); // 1 byte name length
    result.add(nameBytes); // N bytes name
    result.add(userIdBytes); // 16 bytes userId
    return result.toBytes(); // Total: 20 + nameLen (max 28)
  }

  /// Decode profile from manufacturer data (Android advertisers).
  DiscoveredPeer? _decodeManufacturerData(
      int companyId, List<int> bytes, int rssi) {
    if (companyId != _manufacturerId) return null;
    if (bytes.length < 20) return null;
    if (bytes[0] != _anchorMagic[0] || bytes[1] != _anchorMagic[1]) {
      return null;
    }

    try {
      final age = bytes[2] == 0 ? null : bytes[2] as int?;
      final nameLen = bytes[3];
      if (4 + nameLen + 16 > bytes.length) return null;

      final name = utf8.decode(bytes.sublist(4, 4 + nameLen));
      final userIdBytes = bytes.sublist(4 + nameLen, 4 + nameLen + 16);
      final userId = _bytesToUuid(userIdBytes);

      return DiscoveredPeer(
        peerId: userId,
        name: name.isEmpty ? 'Anchor User' : name,
        age: age,
        bio: null,
        thumbnailBytes: null,
        rssi: rssi,
        timestamp: DateTime.now(),
      );
    } catch (e) {
      Logger.error('FlutterBluePlusBleService: Manufacturer data decode failed',
          e, null, 'BLE');
      return null;
    }
  }

  String _bytesToUuid(List<int> bytes) {
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
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

    Logger.info('FlutterBluePlusBleService: Starting periodic scan...', 'BLE');

    _isScanning = true;
    _setStatus(BleStatus.scanning);

    // Set up the scan result listener once.
    await _scanSubscription?.cancel();
    _scanSubscription = FlutterBluePlus.onScanResults.listen(
      (results) {
        Logger.info(
          'FlutterBluePlusBleService: onScanResults fired with ${results.length} result(s)',
          'BLE',
        );
        for (final result in results) {
          Logger.info(
            'FlutterBluePlusBleService: Scan result: '
            'name="${result.advertisementData.advName}", '
            'remoteId=${result.device.remoteId}, '
            'serviceUuids=${result.advertisementData.serviceUuids.map((u) => u.toString()).toList()}, '
            'mfgData=${result.advertisementData.manufacturerData.keys.toList()}, '
            'rssi=${result.rssi}',
            'BLE',
          );
          _onDeviceDiscovered(result);
        }
      },
      onError: (e) {
        Logger.error('FlutterBluePlusBleService: Scan error', e, null, 'BLE');
      },
    );

    // Run the first scan cycle immediately.
    _runScanCycle();
  }

  /// One scan cycle: scan for [_scanDuration], pause for [_scanPause], repeat.
  void _runScanCycle() async {
    if (!_isScanning) return;

    try {
      Logger.info('FlutterBluePlusBleService: Scan cycle starting...', 'BLE');

      // Don't use withServices filter — on Android, 128-bit UUIDs may
      // overflow to scan response which the OS filter ignores. On iOS,
      // the filter can also miss devices if advertising hasn't fully
      // started. We identify Anchor devices in _onDeviceDiscovered.
      await FlutterBluePlus.startScan(
        timeout: _scanDuration,
        androidUsesFineLocation: true,
      );

      // startScan returns after the timeout. Schedule the next cycle.
      if (_isScanning) {
        _scanRestartTimer?.cancel();
        _scanRestartTimer = Timer(_scanPause, _runScanCycle);
      }
    } catch (e) {
      Logger.error(
          'FlutterBluePlusBleService: Scan cycle failed', e, null, 'BLE');

      // Retry after pause.
      if (_isScanning) {
        _scanRestartTimer?.cancel();
        _scanRestartTimer = Timer(_scanPause, _runScanCycle);
      }
    }
  }

  @override
  Future<void> stopScanning() async {
    if (!_isScanning) return;

    Logger.info('FlutterBluePlusBleService: Stopping scan...', 'BLE');

    _isScanning = false;
    _scanRestartTimer?.cancel();
    _scanRestartTimer = null;

    try {
      await FlutterBluePlus.stopScan();
      await _scanSubscription?.cancel();
      _scanSubscription = null;
    } catch (e) {
      Logger.error(
          'FlutterBluePlusBleService: Scan stop failed', e, null, 'BLE');
    }
  }

  @override
  bool get isScanning => _isScanning;

  void _onDeviceDiscovered(ScanResult result) {
    final device = result.device;
    final deviceId = device.remoteId.toString();
    final advData = result.advertisementData;

    // ---- Try manufacturer data (works when advertiser is Android) ----
    for (final entry in advData.manufacturerData.entries) {
      final peer = _decodeManufacturerData(entry.key, entry.value, result.rssi);
      if (peer != null) {
        Logger.info(
          'FlutterBluePlusBleService: Discovered Android peer "${peer.name}" via mfg data (RSSI: ${result.rssi})',
          'BLE',
        );
        _emitPeer(peer);
        return;
      }
    }

    // ---- Check for Anchor service UUID ----
    final hasAnchorService = advData.serviceUuids.any(
      (uuid) => uuid.toString().toLowerCase() == _serviceUuidStr.toLowerCase(),
    );

    // ---- Check for Anchor local name prefix ("A:name:age") ----
    // This is the primary identifier for iOS-to-iOS discovery, because
    // flutter_ble_peripheral on iOS may not reliably include the service
    // UUID in the advertisement packet.
    final advName = advData.advName;
    final decoded = advName.isNotEmpty ? _decodeLocalName(advName) : null;

    // Not an Anchor device if neither marker is present
    if (!hasAnchorService && decoded == null) return;

    final name = decoded?.name ?? (advName.isNotEmpty ? advName : 'Anchor User');
    final age = decoded?.age;

    Logger.info(
      'FlutterBluePlusBleService: Discovered peer "$name" '
      '(advName: "$advName", hasService: $hasAnchorService, '
      'RSSI: ${result.rssi}, deviceId: $deviceId)',
      'BLE',
    );

    final peer = DiscoveredPeer(
      peerId: deviceId,
      name: name,
      age: age,
      bio: null,
      thumbnailBytes: null,
      rssi: result.rssi,
      timestamp: DateTime.now(),
    );
    _emitPeer(peer);
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
      final device = _connectedDevices.values
          .where((d) => _visiblePeers[peerId] != null)
          .firstOrNull;

      if (device == null) {
        Logger.info(
            'FlutterBluePlusBleService: Peer not connected: $peerId', 'BLE');
        // TODO: Queue message for later delivery
        return false;
      }

      final services = await device.discoverServices();
      final service =
          services.where((s) => s.serviceUuid == _serviceUuid).firstOrNull;
      if (service == null) return false;

      final messageChar = service.characteristics
          .where((c) => c.characteristicUuid == _messagingChar)
          .firstOrNull;
      if (messageChar == null) return false;

      final data = _serializeMessagePayload(payload);
      await messageChar.write(data, withoutResponse: true);

      Logger.info(
          'FlutterBluePlusBleService: Message sent successfully', 'BLE');
      return true;
    } catch (e) {
      Logger.error(
          'FlutterBluePlusBleService: Message send failed', e, null, 'BLE');
      return false;
    }
  }

  @override
  Stream<ReceivedMessage> get messageReceivedStream =>
      _messageReceivedController.stream;

  Uint8List _serializeMessagePayload(MessagePayload payload) {
    final json = {
      'type': 'message',
      'message_type': payload.type.index,
      'message_id': payload.messageId,
      'content': payload.content,
      'timestamp': DateTime.now().toIso8601String(),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  // ==================== Photo Transfer ====================

  @override
  Future<bool> sendPhoto(
      String peerId, Uint8List photoData, String messageId) async {
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
      'FlutterBluePlusBleService: Photo transfer not yet implemented',
      'BLE',
    );

    // TODO: Implement chunked photo transfer
    return false;
  }

  @override
  Stream<PhotoTransferProgress> get photoProgressStream =>
      _photoProgressController.stream;

  @override
  Stream<ReceivedPhoto> get photoReceivedStream =>
      _photoReceivedController.stream;

  @override
  Future<void> cancelPhotoTransfer(String messageId) async {
    Logger.info(
        'FlutterBluePlusBleService: Cancelling photo transfer $messageId',
        'BLE');
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
