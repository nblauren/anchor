import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import '../../../core/utils/logger.dart';
import '../ble_models.dart';

/// Manages the BLE GATT server (peripheral side): service setup, read
/// request handling, notification pushes, and advertising lifecycle.
///
/// Extracted from the monolithic BLE service (now [BleFacade]) to:
/// - Separate the PeripheralManager lifecycle from scan/connect/messaging
/// - Encapsulate GATT characteristic setup, read serving, and notify pushes
/// - Own all cached profile/thumbnail/photo data for read requests
/// - Handle peripheral state management and advertising retry logic
class GattServer {
  GattServer({
    required PeripheralManager peripheral,
  }) : _peripheral = peripheral;

  final PeripheralManager _peripheral;

  // UUIDs
  static final _serviceUuid =
      UUID.fromString('0000fff0-0000-1000-8000-00805f9b34fb');
  static final _profileCharUuid =
      UUID.fromString('0000fff1-0000-1000-8000-00805f9b34fb');
  static final _thumbnailCharUuid =
      UUID.fromString('0000fff2-0000-1000-8000-00805f9b34fb');
  static final _messagingCharUuid =
      UUID.fromString('0000fff3-0000-1000-8000-00805f9b34fb');
  static final _fullPhotosCharUuid =
      UUID.fromString('0000fff4-0000-1000-8000-00805f9b34fb');

  // GATT characteristics (server side)
  GATTCharacteristic? _profileChar;
  GATTCharacteristic? _thumbnailChar;
  GATTCharacteristic? _messagingChar;
  GATTCharacteristic? _fullPhotosChar;

  // State
  bool _isReady = false;
  bool _peripheralPoweredOn = false;
  bool _settingUp = false;
  bool _startCalled = false;
  bool _isBroadcasting = false;
  Timer? _peripheralRetryTimer;

  // Cached data for GATT server read requests
  Uint8List _profileData = Uint8List(0);
  Uint8List _thumbnailData = Uint8List(0);
  List<int> _ownPhotoSizes = [];
  Uint8List _fullPhotosData = Uint8List(0);
  List<int> _ownFullPhotoSizes = [];
  BroadcastPayload? _pendingPayload;

  // Subscriptions
  StreamSubscription? _stateSubscription;
  StreamSubscription? _charReadSubscription;
  StreamSubscription? _charWriteSubscription;
  StreamSubscription? _charNotifyStateSubscription;

  // ==================== Callbacks ====================

  /// Called when a write arrives on the messaging characteristic (fff3).
  /// Provides the raw data and central UUID for the orchestrator to dispatch.
  void Function(Uint8List data, UUID centralUuid)? onWriteReceived;

  // ==================== Public API ====================

  bool get isReady => _isReady;
  bool get isBroadcasting => _isBroadcasting;
  bool get peripheralPoweredOn => _peripheralPoweredOn;
  BroadcastPayload? get pendingPayload => _pendingPayload;
  String get ownUserId => _pendingPayload?.userId ?? '';

  /// Start listening to peripheral state changes.
  void startListening() {
    _stateSubscription = _peripheral.stateChanged
        .listen((e) => _onPeripheralStateChanged(e.state));
    // Check initial state
    _onPeripheralStateChanged(_peripheral.state);
  }

  /// Mark that start() was called on the BLE service, enabling auto-retry
  /// of GATT setup when the peripheral transitions to poweredOn.
  void markStartCalled() {
    _startCalled = true;
  }

  /// Set up the GATT server: create service with 4 characteristics and
  /// register event listeners. Safe to call multiple times.
  Future<void> setup({bool force = false}) async {
    if (_settingUp && !force) return;

    if (!_peripheralPoweredOn) {
      Logger.warning(
        'GattServer: Skipping setup — peripheral state: ${_peripheral.state}',
        'BLE',
      );
      _schedulePeripheralRetry();
      return;
    }

    _settingUp = true;
    _isReady = false;
    Logger.info('GattServer: Setting up GATT server...', 'BLE');

    try {
      await _peripheral.removeAllServices();

      // Profile characteristic (fff1): centrals read this to get our profile metadata.
      _profileChar = GATTCharacteristic.mutable(
        uuid: _profileCharUuid,
        properties: [GATTCharacteristicProperty.read],
        permissions: [GATTCharacteristicPermission.read],
        descriptors: [],
      );

      // Thumbnail characteristic (fff2): centrals read or subscribe to get
      // our primary profile photo. Notify pushes thumbnail in chunks.
      _thumbnailChar = GATTCharacteristic.mutable(
        uuid: _thumbnailCharUuid,
        properties: [
          GATTCharacteristicProperty.read,
          GATTCharacteristicProperty.notify,
        ],
        permissions: [GATTCharacteristicPermission.read],
        descriptors: [],
      );

      // Messaging characteristic (fff3): centrals write to this to send messages.
      _messagingChar = GATTCharacteristic.mutable(
        uuid: _messagingCharUuid,
        properties: [
          GATTCharacteristicProperty.write,
          GATTCharacteristicProperty.writeWithoutResponse,
        ],
        permissions: [GATTCharacteristicPermission.write],
        descriptors: [],
      );

      // Full-photos characteristic (fff4): serves ALL profile photo thumbnails
      // concatenated, pushed via notify only when a central explicitly subscribes.
      _fullPhotosChar = GATTCharacteristic.mutable(
        uuid: _fullPhotosCharUuid,
        properties: [
          GATTCharacteristicProperty.read,
          GATTCharacteristicProperty.notify,
        ],
        permissions: [GATTCharacteristicPermission.read],
        descriptors: [],
      );

      final service = GATTService(
        uuid: _serviceUuid,
        isPrimary: true,
        includedServices: [],
        characteristics: [
          _profileChar!,
          _thumbnailChar!,
          _messagingChar!,
          _fullPhotosChar!,
        ],
      );

      await _peripheral.addService(service);

      // Handle profile + thumbnail read requests
      await _charReadSubscription?.cancel();
      _charReadSubscription = _peripheral.characteristicReadRequested
          .listen(_onCharacteristicReadRequested);

      // Handle incoming writes on messaging characteristic
      await _charWriteSubscription?.cancel();
      _charWriteSubscription = _peripheral.characteristicWriteRequested
          .listen(_onWriteRequested);

      // Handle thumbnail/full-photos notify subscriptions
      await _charNotifyStateSubscription?.cancel();
      _charNotifyStateSubscription =
          _peripheral.characteristicNotifyStateChanged.listen((args) {
        if (args.characteristic.uuid == _thumbnailCharUuid) {
          _onThumbnailNotifyStateChanged(args);
        } else if (args.characteristic.uuid == _fullPhotosCharUuid) {
          _onFullPhotosNotifyStateChanged(args);
        }
      });

      _isReady = true;
      Logger.info('GattServer: GATT server ready', 'BLE');
    } catch (e) {
      Logger.error('GattServer: GATT server setup failed', e, null, 'BLE');
    } finally {
      _settingUp = false;
    }
  }

  /// Prepare profile data from the payload and start advertising.
  ///
  /// Rejects payloads with an empty name to prevent advertising "A::0"
  /// which other devices decode as the fallback "Anchor User".
  Future<void> broadcastProfile(BroadcastPayload payload) async {
    if (payload.name.trim().isEmpty) {
      Logger.warning(
        'GattServer: Rejecting broadcast with empty name — '
        'profile not loaded yet?',
        'BLE',
      );
      return;
    }
    _pendingPayload = payload;

    // fff2 — PRIMARY thumbnail only (small, fast, sent to every connecting peer).
    _thumbnailData = payload.thumbnailBytes ?? Uint8List(0);
    _ownPhotoSizes = _thumbnailData.isNotEmpty ? [_thumbnailData.length] : [];

    // fff4 — ALL thumbnails concatenated, served on-demand (profile view only).
    if (payload.thumbnailsList != null && payload.thumbnailsList!.isNotEmpty) {
      _ownFullPhotoSizes =
          payload.thumbnailsList!.map((b) => b.length).toList();
      _fullPhotosData = Uint8List.fromList(
        payload.thumbnailsList!.expand((b) => b).toList(),
      );
    } else {
      _ownFullPhotoSizes = _ownPhotoSizes;
      _fullPhotosData = _thumbnailData;
    }

    _profileData = _encodeProfileData(payload);

    Logger.info(
      'GattServer: Broadcasting profile for ${payload.name} '
          '(profileData=${_profileData.length}B, thumbnailData=${_thumbnailData.length}B)',
      'BLE',
    );

    if (!_peripheralPoweredOn) {
      Logger.warning(
        'GattServer: Peripheral not ready (${_peripheral.state}), will retry when ready',
        'BLE',
      );
      _schedulePeripheralRetry();
      return;
    }

    await _startAdvertising(payload);
  }

  /// Retry advertising with the previously stored payload if conditions are met.
  /// Called by the orchestrator when the central adapter powers on.
  Future<void> retryAdvertisingIfNeeded() async {
    if (_pendingPayload != null && !_isBroadcasting && _peripheralPoweredOn) {
      await _startAdvertising(_pendingPayload!);
    }
  }

  /// Stop advertising.
  Future<void> stopAdvertising() async {
    Logger.info('GattServer: Stopped broadcasting', 'BLE');
    try {
      await _peripheral.stopAdvertising();
    } catch (e) {
      Logger.error('GattServer: Stop advertising failed', e, null, 'BLE');
    }
    _isBroadcasting = false;
  }

  /// Remove all services and reset state. Called during stop().
  Future<void> teardown() async {
    _peripheralRetryTimer?.cancel();
    await stopAdvertising();
    try {
      await _peripheral.removeAllServices();
    } catch (e) {
      Logger.error('GattServer: Remove services failed', e, null, 'BLE');
    }
    _isReady = false;
    _settingUp = false;
    _startCalled = false;
  }

  /// Dispose all subscriptions and timers.
  Future<void> dispose() async {
    _peripheralRetryTimer?.cancel();
    await _stateSubscription?.cancel();
    await _charReadSubscription?.cancel();
    await _charWriteSubscription?.cancel();
    await _charNotifyStateSubscription?.cancel();
  }

  // ==================== Internal: State Management ====================

  void _onPeripheralStateChanged(BluetoothLowEnergyState state) {
    Logger.info('GattServer: Peripheral state changed: $state', 'BLE');
    _peripheralPoweredOn = state == BluetoothLowEnergyState.poweredOn;

    if (!_peripheralPoweredOn) return;

    if (_startCalled && !_isReady) {
      // start() was called but GATT setup failed because peripheral wasn't
      // ready. Retry now that it's powered on.
      setup().then((_) {
        if (_pendingPayload != null && !_isBroadcasting) {
          _startAdvertising(_pendingPayload!);
        }
      });
    } else if (_pendingPayload != null && !_isBroadcasting) {
      // Peripheral became ready after broadcastProfile() saved the payload.
      if (!_isReady) {
        setup().then((_) {
          if (_pendingPayload != null && !_isBroadcasting) {
            _startAdvertising(_pendingPayload!);
          }
        });
      } else {
        _startAdvertising(_pendingPayload!);
      }
    }
  }

  /// Schedule a delayed retry for advertising when the peripheral state is
  /// transiently 'unknown' at startup. Retries up to 5 times (every 2s).
  void _schedulePeripheralRetry({int attempt = 1}) {
    if (attempt > 5) {
      Logger.warning(
        'GattServer: Peripheral still not ready after 5 retries — '
            'advertising will start when state changes to poweredOn',
        'BLE',
      );
      return;
    }
    _peripheralRetryTimer?.cancel();
    _peripheralRetryTimer = Timer(const Duration(seconds: 2), () {
      final currentState = _peripheral.state;
      if (currentState == BluetoothLowEnergyState.poweredOn) {
        Logger.info(
          'GattServer: Peripheral now poweredOn (retry $attempt) — '
              'starting advertising',
          'BLE',
        );
        _peripheralPoweredOn = true;
        if (_pendingPayload != null && !_isBroadcasting) {
          if (!_isReady) {
            setup().then((_) {
              if (_pendingPayload != null && !_isBroadcasting) {
                _startAdvertising(_pendingPayload!);
              }
            });
          } else {
            _startAdvertising(_pendingPayload!);
          }
        }
      } else {
        Logger.info(
          'GattServer: Peripheral still $currentState (retry $attempt/5)',
          'BLE',
        );
        _schedulePeripheralRetry(attempt: attempt + 1);
      }
    });
  }

  // ==================== Internal: Advertising ====================

  Future<void> _startAdvertising(BroadcastPayload payload) async {
    try {
      if (_isBroadcasting) {
        await _peripheral.stopAdvertising();
        _isBroadcasting = false;
      }

      final compactName = _encodeLocalName(payload);

      Logger.info(
        'GattServer: Advertising with name="$compactName"',
        'BLE',
      );

      await _peripheral.startAdvertising(Advertisement(
        name: compactName,
        serviceUUIDs: [_serviceUuid],
      ));

      _isBroadcasting = true;
      Logger.info('GattServer: Advertising started', 'BLE');
    } catch (e) {
      Logger.error('GattServer: Advertising failed', e, null, 'BLE');
      _isBroadcasting = false;
    }
  }

  /// Encode local name: "A:<name>:<age>"
  String _encodeLocalName(BroadcastPayload payload) {
    final name =
        payload.name.length > 8 ? payload.name.substring(0, 8) : payload.name;
    final age = payload.age ?? 0;
    return 'A:$name:$age';
  }

  /// Encode profile metadata as compact JSON for the profile characteristic.
  ///
  /// fff2 (thumbnail char) serves only the PRIMARY photo, so the JSON
  /// only carries its size via `thumbnail_size`.
  ///
  /// When the peer has multiple photos they are available via fff4. The JSON
  /// advertises this via `photo_count` + `full_photo_sizes` so the central
  /// knows whether to request fff4 and how to split the data.
  Uint8List _encodeProfileData(BroadcastPayload payload) {
    final json = <String, dynamic>{
      'userId': payload.userId,
      'name': payload.name,
      'age': payload.age,
      'bio': payload.bio,
      if (payload.position != null) 'pos': payload.position,
      if (payload.interests != null && payload.interests!.isNotEmpty)
        'int': payload.interests,
      if (_thumbnailData.isNotEmpty) 'thumbnail_size': _thumbnailData.length,
      if (_ownFullPhotoSizes.length > 1) ...{
        'photo_count': _ownFullPhotoSizes.length,
        'full_photo_sizes': _ownFullPhotoSizes,
      },
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  // ==================== Internal: Read Requests ====================

  /// Handles read requests for ALL readable characteristics.
  /// Dispatches by UUID so profile (fff1), thumbnail (fff2), and
  /// full-photos (fff4) are served from the correct data buffer.
  ///
  /// iOS issues Read Blob Requests with increasing offsets for data > ATT MTU.
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
      } else if (charUuid == _fullPhotosCharUuid) {
        sourceData = _fullPhotosData;
        charName = 'full_photos';
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
        'GattServer: Read request [$charName] offset=$offset '
            'total=${sourceData.length}B responding=${slice.length}B',
        'BLE',
      );

      await _peripheral.respondReadRequestWithValue(
        args.request,
        value: slice,
      );
    } catch (e) {
      Logger.error(
          'GattServer: Characteristic read response failed', e, null, 'BLE');
    }
  }

  // ==================== Internal: Write Requests ====================

  /// Receives writes on the messaging characteristic (fff3), responds to the
  /// GATT write request, then delegates raw data to the orchestrator callback.
  void _onWriteRequested(
      GATTCharacteristicWriteRequestedEventArgs args) async {
    try {
      await _peripheral.respondWriteRequest(args.request);

      final data = args.request.value;
      if (data.isEmpty) return;

      onWriteReceived?.call(data, args.central.uuid);
    } catch (e) {
      Logger.error('GattServer: Write receive failed', e, null, 'BLE');
    }
  }

  // ==================== Internal: Notify Push ====================

  /// Push the primary thumbnail in MTU-sized chunks when a central subscribes
  /// to the thumbnail characteristic (fff2).
  void _onThumbnailNotifyStateChanged(
      GATTCharacteristicNotifyStateChangedEventArgs args) async {
    if (args.characteristic.uuid != _thumbnailCharUuid) return;
    if (!args.state) return;

    final data = _thumbnailData;
    if (data.isEmpty) return;

    final central = args.central;
    int maxChunk;
    try {
      maxChunk = await _peripheral.getMaximumNotifyLength(central);
    } catch (_) {
      maxChunk = 500;
    }

    Logger.info(
      'GattServer: Central subscribed to thumbnail — pushing '
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
          _thumbnailChar!,
          value: chunk,
        );
        offset = end;
      } catch (e) {
        Logger.warning(
          'GattServer: Thumbnail chunk failed at offset $offset: $e',
          'BLE',
        );
        break;
      }
    }
    Logger.info(
      'GattServer: Thumbnail push complete (${data.length}B sent)',
      'BLE',
    );
  }

  /// Push ALL photo thumbnails concatenated when a central subscribes
  /// to the full-photos characteristic (fff4).
  void _onFullPhotosNotifyStateChanged(
      GATTCharacteristicNotifyStateChangedEventArgs args) async {
    if (args.characteristic.uuid != _fullPhotosCharUuid) return;
    if (!args.state) return;

    final data = _fullPhotosData;
    if (data.isEmpty) return;

    final central = args.central;
    int maxChunk;
    try {
      maxChunk = await _peripheral.getMaximumNotifyLength(central);
    } catch (_) {
      maxChunk = 500;
    }

    Logger.info(
      'GattServer: Central subscribed to full-photos — pushing '
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
          _fullPhotosChar!,
          value: chunk,
        );
        offset = end;
      } catch (e) {
        Logger.warning(
          'GattServer: Full-photos chunk failed at offset $offset: $e',
          'BLE',
        );
        break;
      }
    }
    Logger.info(
      'GattServer: Full-photos push complete (${data.length}B sent)',
      'BLE',
    );
  }
}
