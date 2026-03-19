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
  static final _reversePathCharUuid =
      UUID.fromString('0000fff5-0000-1000-8000-00805f9b34fb');

  // GATT characteristics (server side)
  GATTCharacteristic? _profileChar;
  GATTCharacteristic? _thumbnailChar;
  GATTCharacteristic? _messagingChar;
  GATTCharacteristic? _fullPhotosChar;
  GATTCharacteristic? _reversePathChar;

  // Connected Centrals — tracked so we can send GATT notifications back
  // to a Central that wrote to us (reverse-path for cross-platform handshakes
  // where the responder can't discover the initiator's Peripheral).
  final Map<String, Central> _connectedCentrals = {};

  // Centrals subscribed to fff3 notifications (bidirectional messaging).
  // When a Central subscribes to fff3, we can push messages back to it
  // without needing a separate reverse GATT connection.
  final Map<String, Central> _fff3SubscribedCentrals = {};

  // State
  bool _isReady = false;
  bool _peripheralPoweredOn = false;
  bool _settingUp = false;
  bool _startCalled = false;
  bool _isBroadcasting = false;

  /// Monotonically increasing profile version. Incremented each time
  /// [broadcastProfile] is called with a changed payload. Advertised in the
  /// BLE local name so scanners can skip GATT reads for unchanged profiles.
  int _profileVersion = 0;

  /// Snapshot of the last payload identity used to detect real changes.
  /// We compare the fields that are included in the GATT profile (fff1) and
  /// thumbnail size — if they haven't changed, the version stays the same.
  String? _lastPayloadFingerprint;

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
  int get profileVersion => _profileVersion;

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
  ///
  /// Does NOT pre-check [_peripheralPoweredOn] — instead it attempts the
  /// native call and infers readiness from the result. This breaks the
  /// chicken-and-egg where the peripheral state event never fires because
  /// nothing has poked the native PeripheralManager yet (mirroring how
  /// CentralManager is implicitly initialised by startDiscovery()).
  Future<void> setup({bool force = false}) async {
    if (_settingUp && !force) return;

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

      // Messaging characteristic (fff3): bidirectional messaging.
      // - WRITE / WRITE_WITHOUT_RESPONSE: Centrals write to send messages.
      // - NOTIFY: Peripheral can push messages back to subscribed Centrals,
      //   enabling bidirectional messaging over a single GATT connection.
      //   This eliminates the need for a reverse connection in most cases
      //   (the Central doesn't have to also discover the Peripheral's
      //   advertisement and connect in the other direction).
      // - fff5 is kept as a fallback for legacy clients and edge cases.
      _messagingChar = GATTCharacteristic.mutable(
        uuid: _messagingCharUuid,
        properties: [
          GATTCharacteristicProperty.write,
          GATTCharacteristicProperty.writeWithoutResponse,
          GATTCharacteristicProperty.notify,
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

      // Reverse-path characteristic (fff5): Peripheral → Central notifications
      // for cross-platform E2EE handshake responses. Separate from fff3 because
      // combining write + notify on one characteristic breaks Android GATT.
      _reversePathChar = GATTCharacteristic.mutable(
        uuid: _reversePathCharUuid,
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
          _reversePathChar!,
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

      // Handle notify subscription events for all characteristics.
      await _charNotifyStateSubscription?.cancel();
      _charNotifyStateSubscription =
          _peripheral.characteristicNotifyStateChanged.listen((args) {
        final centralId = args.central.uuid.toString();
        if (args.characteristic.uuid == _thumbnailCharUuid) {
          _onThumbnailNotifyStateChanged(args);
        } else if (args.characteristic.uuid == _fullPhotosCharUuid) {
          _onFullPhotosNotifyStateChanged(args);
        } else if (args.characteristic.uuid == _messagingCharUuid) {
          // Track Centrals subscribing to fff3 notifications (bidirectional messaging).
          if (args.state) {
            _fff3SubscribedCentrals[centralId] = args.central;
            Logger.info(
              'GattServer: Central ${centralId.substring(0, min(8, centralId.length))} '
              'subscribed to fff3 notify (bidirectional messaging)',
              'BLE',
            );
          } else {
            _fff3SubscribedCentrals.remove(centralId);
            Logger.debug(
              'GattServer: Central ${centralId.substring(0, min(8, centralId.length))} '
              'unsubscribed from fff3 notify',
              'BLE',
            );
          }
        } else if (args.characteristic.uuid == _reversePathCharUuid) {
          // Track Central when it subscribes to fff5 (reverse-path) notifications
          _connectedCentrals[centralId] = args.central;
          Logger.debug(
            'GattServer: Central ${centralId.substring(0, min(8, centralId.length))} '
            '${args.state ? "subscribed to" : "unsubscribed from"} fff5 notify',
            'BLE',
          );
        }
      });

      // Reaching here means the native calls succeeded — peripheral is ready.
      _peripheralPoweredOn = true;
      _isReady = true;
      Logger.info('GattServer: GATT server ready', 'BLE');
    } catch (e) {
      Logger.error('GattServer: GATT server setup failed', e, null, 'BLE');
      // Native call failed — peripheral not ready yet. Subscribe to state
      // changes so we retry as soon as it becomes ready.
      _waitForPeripheralReady();
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

    // Increment profile version only when the payload actually changes.
    final thumbLen = payload.thumbnailBytes?.length ?? 0;
    final fingerprint =
        '${payload.userId}|${payload.name}|${payload.age}|${payload.bio}'
        '|${payload.position}|${payload.interests}|$thumbLen'
        '|${payload.publicKeyHex}';
    if (fingerprint != _lastPayloadFingerprint) {
      _profileVersion++;
      _lastPayloadFingerprint = fingerprint;
      Logger.info(
        'GattServer: Profile version bumped to $_profileVersion',
        'BLE',
      );
    }

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

    if (!_isReady) {
      // GATT server not set up yet — attempt setup now. setup() will schedule
      // its own retry if the peripheral is still not ready.
      await setup();
      if (!_isReady) return;
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
    _peripheralReadySub?.cancel();
    _peripheralReadySub = null;
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
    _peripheralReadySub?.cancel();
    _peripheralReadySub = null;
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

    // Cancel any in-flight peripheral-ready subscription — state change is authoritative.
    _peripheralReadySub?.cancel();
    _peripheralReadySub = null;

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

  /// Subscribe to peripheral state changes and wait for poweredOn.
  ///
  /// Replaces the old polling approach (5 retries × 2s) with an event-driven
  /// listener that reacts immediately when the peripheral becomes ready,
  /// regardless of how long it takes.
  StreamSubscription? _peripheralReadySub;

  void _waitForPeripheralReady() {
    // Already ready — handle immediately.
    if (_peripheral.state == BluetoothLowEnergyState.poweredOn) {
      _onPeripheralBecameReady();
      return;
    }

    Logger.info(
      'GattServer: Peripheral not ready (${_peripheral.state}) — '
          'subscribing to state changes',
      'BLE',
    );

    _peripheralReadySub?.cancel();
    _peripheralReadySub = _peripheral.stateChanged.listen((e) {
      if (e.state == BluetoothLowEnergyState.poweredOn) {
        _peripheralReadySub?.cancel();
        _peripheralReadySub = null;
        _onPeripheralBecameReady();
      }
    });
  }

  void _onPeripheralBecameReady() {
    Logger.info(
      'GattServer: Peripheral now poweredOn — starting advertising',
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
  }

  // ==================== Internal: Advertising ====================

  Future<void> _startAdvertising(BroadcastPayload payload) async {
    try {
      if (_isBroadcasting) {
        await _peripheral.stopAdvertising();
        _isBroadcasting = false;
      }

      // Keep the advertisement UNDER 31 bytes so the service UUID stays in
      // the primary AD packet (not the scan response). This is critical for
      // cross-platform discovery — Android scanners filtering by UUID only
      // check the primary packet, and iOS strips overflow data in background.
      //
      // Budget breakdown:
      //   Flags:                3 bytes
      //   128-bit Service UUID: 18 bytes  (2 header + 16 UUID)
      //   Short local name:     2 + N bytes (header + "A<version>")
      //   Total:                23 + N → must keep N ≤ 8 to stay under 31
      //
      // We use a minimal name "A<profileVersion>" (e.g. "A3") instead of the
      // old "A:Nicholas:28:3" which pushed the UUID to the scan response.
      // Full profile data is available via GATT fff1 read after connection.
      final compactName = _encodeLocalName(payload);

      Logger.info(
        'GattServer: Advertising with name="$compactName" '
        '(${compactName.length} chars, est ${23 + 2 + compactName.length} bytes)',
        'BLE',
      );

      try {
        await _peripheral.startAdvertising(Advertisement(
          name: compactName,
          serviceUUIDs: [_serviceUuid],
        ));
      } catch (e) {
        // On Android 13+ (API 33), BluetoothAdapter.setName() is deprecated
        // and may fail — causing the entire startAdvertising call to throw.
        // Fall back to advertising WITHOUT the local name.
        Logger.warning(
          'GattServer: Advertising with name failed ($e) — '
              'retrying without name (service UUID only)',
          'BLE',
        );
        await _peripheral.startAdvertising(Advertisement(
          serviceUUIDs: [_serviceUuid],
        ));
      }

      _isBroadcasting = true;
      Logger.info('GattServer: Advertising started successfully', 'BLE');
    } catch (e) {
      Logger.error('GattServer: Advertising failed', e, null, 'BLE');
      _isBroadcasting = false;
    }
  }

  /// Encode local name: "A<profileVersion>" (e.g. "A3", "A17").
  ///
  /// Minimal format to keep the advertisement under 31 bytes while still
  /// allowing scanners to skip GATT reads for unchanged profiles. The full
  /// profile (name, age, bio) is served via fff1 GATT read after connection.
  ///
  /// Old format was "A:<name>:<age>:<version>" which exceeded 31 bytes and
  /// pushed the service UUID to the scan response, breaking UUID-filtered
  /// discovery on Android and in iOS background mode.
  String _encodeLocalName(BroadcastPayload payload) {
    return 'A$_profileVersion';
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
      // E2EE: include our X25519 public key so the peer can initiate Noise_XK.
      if (payload.publicKeyHex != null) 'pk': payload.publicKeyHex,
      // Profile version for change detection — scanners skip re-reads when unchanged.
      'pv': _profileVersion,
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

      // Track this Central so we can send GATT notifications back to it
      // (reverse-path for handshake responses).
      final centralUuid = args.central.uuid.toString();
      _connectedCentrals[centralUuid] = args.central;

      Logger.debug(
        'GattServer: [WRITE] ${data.length}B from '
        'central=${centralUuid.substring(0, min(8, centralUuid.length))} '
        '(marker=0x${data[0].toRadixString(16).padLeft(2, '0')}, '
        'fff3sub=${_fff3SubscribedCentrals.containsKey(centralUuid)})',
        'BLE',
      );

      onWriteReceived?.call(data, args.central.uuid);
    } catch (e) {
      Logger.error('GattServer: Write receive failed', e, null, 'BLE');
    }
  }

  /// Send data to a specific connected Central via fff5 GATT notification.
  ///
  /// Used for reverse-path handshake responses when we (Peripheral) can't
  /// discover the Central's Peripheral (common Android↔iOS scenario).
  /// Returns true if the notification was sent successfully.
  Future<bool> sendToCentral(String centralUuidStr, Uint8List data) async {
    final central = _connectedCentrals[centralUuidStr];
    if (central == null || _reversePathChar == null) {
      Logger.debug(
        'GattServer: sendToCentral — central $centralUuidStr not tracked '
        'or reverse-path char not ready',
        'BLE',
      );
      return false;
    }
    try {
      await _peripheral.notifyCharacteristic(
        central,
        _reversePathChar!,
        value: data,
      );
      Logger.info(
        'GattServer: Sent ${data.length}B via fff5 notify to central '
        '${centralUuidStr.substring(0, min(8, centralUuidStr.length))}',
        'BLE',
      );
      return true;
    } catch (e) {
      Logger.warning(
        'GattServer: fff5 notify to $centralUuidStr failed: $e',
        'BLE',
      );
      return false;
    }
  }

  /// Send data to a specific connected Central via fff3 GATT notification.
  ///
  /// Used for bidirectional messaging: the Peripheral pushes messages back
  /// to a Central over the same connection the Central uses to write to us.
  /// Falls back to fff5 if the Central isn't subscribed to fff3 notify.
  /// Returns true if the notification was sent successfully.
  Future<bool> sendToCentralViaFff3(String centralUuidStr, Uint8List data) async {
    final central = _fff3SubscribedCentrals[centralUuidStr];
    if (central == null || _messagingChar == null) {
      Logger.debug(
        'GattServer: sendToCentralViaFff3 — central $centralUuidStr not '
        'subscribed to fff3 notify, falling back to fff5',
        'BLE',
      );
      // Fall back to fff5 reverse-path
      return sendToCentral(centralUuidStr, data);
    }
    try {
      await _peripheral.notifyCharacteristic(
        central,
        _messagingChar!,
        value: data,
      );
      Logger.info(
        'GattServer: Sent ${data.length}B via fff3 notify to central '
        '${centralUuidStr.substring(0, min(8, centralUuidStr.length))}',
        'BLE',
      );
      return true;
    } catch (e) {
      Logger.warning(
        'GattServer: fff3 notify to $centralUuidStr failed: $e — '
        'falling back to fff5',
        'BLE',
      );
      // Fall back to fff5 reverse-path
      return sendToCentral(centralUuidStr, data);
    }
  }

  /// Whether a Central is subscribed to fff3 notifications.
  bool isCentralSubscribedToFff3(String centralUuidStr) =>
      _fff3SubscribedCentrals.containsKey(centralUuidStr);

  // ==================== Internal: Notify Push ====================

  /// Delay between consecutive GATT notification chunks pushed to a Central.
  /// Prevents Android BLE buffer overflow (which silently drops notifications)
  /// and iOS prepare queue saturation (CBATTError code 9).
  static const _interChunkDelay = Duration(milliseconds: 10);

  /// Push the primary thumbnail in MTU-sized chunks when a central subscribes
  /// to the thumbnail characteristic (fff2).
  void _onThumbnailNotifyStateChanged(
      GATTCharacteristicNotifyStateChangedEventArgs args) async {
    if (args.characteristic.uuid != _thumbnailCharUuid) return;
    if (!args.state) {
      Logger.debug(
        'GattServer: Central unsubscribed from thumbnail (fff2)',
        'BLE',
      );
      return;
    }

    final data = _thumbnailData;
    if (data.isEmpty) return;

    final central = args.central;
    int maxChunk;
    try {
      maxChunk = await _peripheral.getMaximumNotifyLength(central);
    } catch (_) {
      maxChunk = 500;
    }

    final totalChunks = (data.length + maxChunk - 1) ~/ maxChunk;
    Logger.info(
      'GattServer: Central subscribed to thumbnail — pushing '
          '${data.length}B in $totalChunks chunks (≤${maxChunk}B each)',
      'BLE',
    );

    var offset = 0;
    var chunkIdx = 0;
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
        chunkIdx++;

        // Inter-chunk delay to let the receiver's BLE stack process the
        // notification before the next one arrives. Without this, Android
        // receivers silently drop chunks when their internal buffer fills.
        if (offset < data.length) {
          await Future<void>.delayed(_interChunkDelay);
        }
      } catch (e) {
        Logger.warning(
          'GattServer: Thumbnail chunk $chunkIdx/$totalChunks failed '
          'at offset $offset: $e',
          'BLE',
        );
        break;
      }
    }
    Logger.info(
      'GattServer: Thumbnail push complete '
      '($chunkIdx/$totalChunks chunks, ${data.length}B sent)',
      'BLE',
    );
  }

  /// Push ALL photo thumbnails concatenated when a central subscribes
  /// to the full-photos characteristic (fff4).
  void _onFullPhotosNotifyStateChanged(
      GATTCharacteristicNotifyStateChangedEventArgs args) async {
    if (args.characteristic.uuid != _fullPhotosCharUuid) return;
    if (!args.state) {
      Logger.debug(
        'GattServer: Central unsubscribed from full-photos (fff4)',
        'BLE',
      );
      return;
    }

    final data = _fullPhotosData;
    if (data.isEmpty) return;

    final central = args.central;
    int maxChunk;
    try {
      maxChunk = await _peripheral.getMaximumNotifyLength(central);
    } catch (_) {
      maxChunk = 500;
    }

    final totalChunks = (data.length + maxChunk - 1) ~/ maxChunk;
    Logger.info(
      'GattServer: Central subscribed to full-photos — pushing '
          '${data.length}B in $totalChunks chunks (≤${maxChunk}B each)',
      'BLE',
    );

    var offset = 0;
    var chunkIdx = 0;
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
        chunkIdx++;

        // Inter-chunk delay — same rationale as thumbnail push.
        if (offset < data.length) {
          await Future<void>.delayed(_interChunkDelay);
        }
      } catch (e) {
        Logger.warning(
          'GattServer: Full-photos chunk $chunkIdx/$totalChunks failed '
          'at offset $offset: $e',
          'BLE',
        );
        break;
      }
    }
    Logger.info(
      'GattServer: Full-photos push complete '
      '($chunkIdx/$totalChunks chunks, ${data.length}B sent)',
      'BLE',
    );
  }
}
