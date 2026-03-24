import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:anchor/core/constants/message_keys.dart';
import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/services/ble/ble_config.dart';
import 'package:anchor/services/ble/ble_models.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

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

  // UUIDs — centralized in BleUuids
  static final _serviceUuid = BleUuids.service;
  static final _profileCharUuid = BleUuids.profileChar;
  static final _thumbnailCharUuid = BleUuids.thumbnailChar;
  static final _messagingCharUuid = BleUuids.messagingChar;
  static final _fullPhotosCharUuid = BleUuids.fullPhotosChar;
  static final _reversePathCharUuid = BleUuids.reversePathChar;

  // GATT characteristics (server side)
  late GATTCharacteristic _profileChar;
  late GATTCharacteristic _thumbnailChar;
  GATTCharacteristic? _messagingChar;
  late GATTCharacteristic _fullPhotosChar;
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
  StreamSubscription<BluetoothLowEnergyStateChangedEventArgs>? _stateSubscription;
  StreamSubscription<GATTCharacteristicReadRequestedEventArgs>? _charReadSubscription;
  StreamSubscription<GATTCharacteristicWriteRequestedEventArgs>? _charWriteSubscription;
  StreamSubscription<GATTCharacteristicNotifyStateChangedEventArgs>? _charNotifyStateSubscription;

  /// Periodic timer that restarts advertising to prevent stale BLE caches.
  /// Both iOS and Android cache advertisement data aggressively — restarting
  /// every 90 seconds ensures fresh discovery in long sessions.
  Timer? _reAnnounceTimer;

  /// Re-announce interval. 90 seconds balances freshness vs. battery cost.
  static const _reAnnounceInterval = Duration(seconds: 90);

  // ── Anti-enumeration rate limiting ─────────────────────────────────────
  /// Sliding window of unique central UUIDs that read our profile (fff1).
  /// If >20 unique centrals read within 60s, new centrals get empty data.
  final Queue<_ProfileReadRecord> _profileReadWindow = Queue();
  static const _maxProfileReadsPerMinute = 20;
  static const _profileReadWindowDuration = Duration(seconds: 60);

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
          _profileChar,
          _thumbnailChar,
          _messagingChar!,
          _fullPhotosChar,
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
    } on Exception catch (e) {
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
    _reAnnounceTimer?.cancel();
    _reAnnounceTimer = null;
    Logger.info('GattServer: Stopped broadcasting', 'BLE');
    try {
      await _peripheral.stopAdvertising();
    } on Exception catch (e) {
      Logger.error('GattServer: Stop advertising failed', e, null, 'BLE');
    }
    _isBroadcasting = false;
  }

  /// Remove all services and reset state. Called during stop().
  Future<void> teardown() async {
    await _peripheralReadySub?.cancel();
    _peripheralReadySub = null;
    await stopAdvertising();
    try {
      await _peripheral.removeAllServices();
    } on Exception catch (e) {
      Logger.error('GattServer: Remove services failed', e, null, 'BLE');
    }
    _isReady = false;
    _settingUp = false;
    _startCalled = false;
  }

  /// Dispose all subscriptions and timers.
  Future<void> dispose() async {
    _reAnnounceTimer?.cancel();
    _reAnnounceTimer = null;
    await _peripheralReadySub?.cancel();
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
  StreamSubscription<BluetoothLowEnergyStateChangedEventArgs>? _peripheralReadySub;

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

      // On Android 13+ (API 33), BluetoothAdapter.setName() is deprecated
      // and causes startAdvertising() to hang indefinitely when a name is
      // passed. Skip the local name on Android entirely — the service UUID
      // alone is sufficient for discovery (iOS uses filtered scan), and the
      // profile version comes from the GATT fff1 read.
      //
      // On iOS, include the compact local name "A<profileVersion>" so the
      // scanner can skip redundant GATT profile reads when the version
      // hasn't changed. Budget: Flags(3) + UUID(18) + Name(2+N) ≈ 26B.
      final Advertisement ad;
      if (Platform.isAndroid) {
        Logger.info(
          'GattServer: Advertising with service UUID only (Android — '
          'name skipped to avoid setName hang)',
          'BLE',
        );
        ad = Advertisement(serviceUUIDs: [_serviceUuid]);
      } else {
        final compactName = _encodeLocalName(payload);
        Logger.info(
          'GattServer: Advertising with name="$compactName" '
          '(${compactName.length} chars, est ${23 + 2 + compactName.length} bytes)',
          'BLE',
        );
        ad = Advertisement(
          name: compactName,
          serviceUUIDs: [_serviceUuid],
        );
      }

      await _peripheral.startAdvertising(ad);

      _isBroadcasting = true;
      _scheduleReAnnounce(payload);
      Logger.info('GattServer: Advertising started successfully', 'BLE');
    } on Exception catch (e) {
      Logger.error('GattServer: Advertising failed', e, null, 'BLE');
      _isBroadcasting = false;
      _reAnnounceTimer?.cancel();

      // Retry once after a short delay — Android occasionally rejects the
      // first advertising attempt after GATT server setup completes, but
      // succeeds on a second try once the adapter stabilises.
      Future.delayed(const Duration(seconds: 2), () async {
        if (_isBroadcasting || !_isReady) return;
        Logger.info(
          'GattServer: Retrying advertising after initial failure',
          'BLE',
        );
        try {
          await _peripheral.startAdvertising(Advertisement(
            serviceUUIDs: [_serviceUuid],
          ),);
          _isBroadcasting = true;
          _scheduleReAnnounce(payload);
          Logger.info(
            'GattServer: Advertising started successfully (retry)',
            'BLE',
          );
        } on Exception catch (retryErr) {
          Logger.error(
            'GattServer: Advertising retry also failed — device will not be '
            'discoverable until next broadcast update',
            retryErr,
            null,
            'BLE',
          );
        }
      });
    }
  }

  /// Schedule periodic re-advertising to defeat platform advertisement caching.
  void _scheduleReAnnounce(BroadcastPayload payload) {
    _reAnnounceTimer?.cancel();
    _reAnnounceTimer = Timer.periodic(_reAnnounceInterval, (_) async {
      if (!_isBroadcasting || !_isReady) return;
      Logger.debug('GattServer: Re-announcing advertisement for freshness', 'BLE');
      try {
        await _peripheral.stopAdvertising();
        final compactName = _encodeLocalName(payload);
        try {
          await _peripheral.startAdvertising(Advertisement(
            name: compactName,
            serviceUUIDs: [_serviceUuid],
          ),);
        } on Exception catch (_) {
          await _peripheral.startAdvertising(Advertisement(
            serviceUUIDs: [_serviceUuid],
          ),);
        }
      } on Exception catch (e) {
        Logger.warning('GattServer: Re-announce failed: $e', 'BLE');
      }
    });
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
      MessageKeys.userId: payload.userId,
      MessageKeys.name: payload.name,
      MessageKeys.age: payload.age,
      MessageKeys.bio: payload.bio,
      if (payload.position != null) MessageKeys.position: payload.position,
      if (payload.interests != null && payload.interests!.isNotEmpty)
        MessageKeys.interests: payload.interests,
      if (_thumbnailData.isNotEmpty) MessageKeys.thumbnailSize: _thumbnailData.length,
      if (_ownFullPhotoSizes.length > 1) ...{
        MessageKeys.photoCount: _ownFullPhotoSizes.length,
        MessageKeys.fullPhotoSizes: _ownFullPhotoSizes,
      },
      // E2EE: include our X25519 public key so the peer can initiate Noise_XK.
      if (payload.publicKeyHex != null) MessageKeys.publicKey: payload.publicKeyHex,
      // Ed25519 signing public key for mesh packet signature verification.
      if (payload.signingPublicKeyHex != null) MessageKeys.signingPublicKey: payload.signingPublicKeyHex,
      // Profile version for change detection — scanners skip re-reads when unchanged.
      MessageKeys.profileVersion: _profileVersion,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  // ==================== Internal: Read Requests ====================

  /// Handles read requests for ALL readable characteristics.
  /// Dispatches by UUID so profile (fff1), thumbnail (fff2), and
  /// full-photos (fff4) are served from the correct data buffer.
  ///
  /// iOS issues Read Blob Requests with increasing offsets for data > ATT MTU.
  Future<void> _onCharacteristicReadRequested(
      GATTCharacteristicReadRequestedEventArgs args,) async {
    try {
      final charUuid = args.characteristic.uuid;
      final offset = args.request.offset;

      // Anti-enumeration: rate-limit profile reads from unique centrals
      if (charUuid == _profileCharUuid && offset == 0) {
        final centralId = args.central.uuid.toString();
        if (_isProfileReadRateLimited(centralId)) {
          Logger.warning(
            'GattServer: Rate-limited profile read from $centralId',
            'BLE',
          );
          await _peripheral.respondReadRequestWithValue(
            args.request,
            value: Uint8List(0),
          );
          return;
        }
      }

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
    } on Exception catch (e) {
      Logger.error(
          'GattServer: Characteristic read response failed', e, null, 'BLE',);
    }
  }

  // ==================== Internal: Write Requests ====================

  /// Receives writes on the messaging characteristic (fff3), responds to the
  /// GATT write request, then delegates raw data to the orchestrator callback.
  Future<void> _onWriteRequested(
      GATTCharacteristicWriteRequestedEventArgs args,) async {
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
    } on Exception catch (e) {
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
    } on Exception catch (e) {
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
    } on Exception catch (e) {
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
  Future<void> _onThumbnailNotifyStateChanged(
      GATTCharacteristicNotifyStateChangedEventArgs args,) async {
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
    } on Exception catch (_) {
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
          _thumbnailChar,
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
      } on Exception catch (e) {
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
  Future<void> _onFullPhotosNotifyStateChanged(
      GATTCharacteristicNotifyStateChangedEventArgs args,) async {
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
    } on Exception catch (_) {
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
          _fullPhotosChar,
          value: chunk,
        );
        offset = end;
        chunkIdx++;

        // Inter-chunk delay — same rationale as thumbnail push.
        if (offset < data.length) {
          await Future<void>.delayed(_interChunkDelay);
        }
      } on Exception catch (e) {
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

  /// Check if a profile read should be rate-limited.
  /// Returns true if too many unique centrals have read our profile recently.
  bool _isProfileReadRateLimited(String centralId) {
    final now = DateTime.now();
    final cutoff = now.subtract(_profileReadWindowDuration);

    // Purge expired entries
    while (_profileReadWindow.isNotEmpty &&
        _profileReadWindow.first.timestamp.isBefore(cutoff)) {
      _profileReadWindow.removeFirst();
    }

    // Allow re-reads from known centrals (they already have our profile)
    final isKnown = _profileReadWindow.any((r) => r.centralId == centralId);
    if (isKnown) return false;

    // Check if we've hit the unique-central limit
    final uniqueCentrals = <String>{};
    for (final r in _profileReadWindow) {
      uniqueCentrals.add(r.centralId);
    }
    if (uniqueCentrals.length >= _maxProfileReadsPerMinute) {
      return true;
    }

    // Record this read
    _profileReadWindow.add(_ProfileReadRecord(centralId, now));
    return false;
  }
}

/// Record of a profile (fff1) read for anti-enumeration tracking.
class _ProfileReadRecord {
  _ProfileReadRecord(this.centralId, this.timestamp);
  final String centralId;
  final DateTime timestamp;
}
