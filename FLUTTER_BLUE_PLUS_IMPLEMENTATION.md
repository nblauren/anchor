# Flutter Blue Plus BLE Implementation Guide

> **⚠️ This file is outdated and kept for historical reference only.**
>
> Anchor no longer uses `flutter_blue_plus`. The production BLE implementation uses
> **`bluetooth_low_energy`** (central + peripheral in one API) and has been decomposed
> into focused modules under `lib/services/ble/` with `ble_facade.dart` as the entry point.
>
> **Refer to [BLE_IMPLEMENTATION.md](BLE_IMPLEMENTATION.md) for the current guide.**

## Overview (Historical)

Anchor originally used **flutter_blue_plus** for direct peer-to-peer Bluetooth Low Energy communication. The production BLE service is now `BleFacade` (`lib/services/ble/ble_facade.dart`), decomposed into focused sub-modules.

## What Was Implemented

### Core BLE Service (now `BleFacade`, formerly `FlutterBluePlusBleService`)

- **Adapter State Monitoring**: Real-time tracking of Bluetooth on/off/unavailable states
- **Runtime Permissions**: Handles Android 12+ and iOS BLE permissions with permission_handler
- **Device Discovery**: Scans for devices advertising Anchor's service UUID
- **GATT Connections**: Direct device-to-device connections for profile reading and messaging
- **Connection Management**:
  - Connection pool with max 5 concurrent connections
  - 30-second connection timeout
  - 60-second idle disconnect
  - Auto-cleanup of stale connections
- **Profile Discovery**:
  - Reads profile metadata (name, age, bio, user_id)
  - Reads thumbnail images from characteristics
  - Emits discovered peers with RSSI signal strength
- **Messaging**: Real-time text message exchange over GATT messaging characteristic
- **Peer Tracking**: Automatic peer timeout and "lost peer" detection

### Service UUIDs (OUTDATED — see `BleUuids` in `lib/services/ble/ble_config.dart` for current values)

```
OLD (no longer used):
  Main Service: 0000fff0-0000-1000-8000-00805f9b34fb
  Profile:      0000fff1-0000-1000-8000-00805f9b34fb
  Thumbnail:    0000fff2-0000-1000-8000-00805f9b34fb
  Messaging:    0000fff3-0000-1000-8000-00805f9b34fb

CURRENT: Proper 128-bit random UUIDs — see BleUuids class.
```

### Dependencies (Current)

```yaml
dependencies:
  bluetooth_low_energy: ^6.2.1    # BLE communication (central + peripheral)
  permission_handler: ^11.0.0      # Runtime permissions
```

### Platform Configuration

**iOS** (ios/Runner/Info.plist):
- ✅ NSBluetoothAlwaysUsageDescription
- ✅ NSBluetoothPeripheralUsageDescription
- ✅ NSLocationWhenInUseUsageDescription
- ✅ UIBackgroundModes: bluetooth-central, bluetooth-peripheral

**Android** (AndroidManifest.xml):
- ✅ BLUETOOTH_SCAN, BLUETOOTH_CONNECT, BLUETOOTH_ADVERTISE
- ✅ ACCESS_FINE_LOCATION
- ✅ FOREGROUND_SERVICE, FOREGROUND_SERVICE_CONNECTED_DEVICE
- ✅ android.hardware.bluetooth_le required feature

## What's NOT Yet Implemented ⚠️

### 1. Store-and-Forward Message Queue

**Status**: ✅ **Implemented** — see `lib/services/store_and_forward_service.dart` and schema v7 (`retry_count`, `last_attempt_at` columns on `messages`).

### 2. Concurrent Wi-Fi Direct Transfers

**Status**: One transfer at a time. NearbyService reinitializes between transfers.

**Requirements**:
- Track multiple concurrent transfers
- Multiplex over a single Nearby connection or manage multiple connections

### 3. End-to-End Encryption

**Status**: Not implemented. BLE GATT messages are unencrypted.

**Requirements**:
- RSA/ECDH key pair per device
- Key exchange during BLE discovery
- Encrypt all message content before transmission

## Testing Requirements

### Prerequisites

- **Physical Devices**: BLE doesn't work on simulators/emulators
- **Minimum**: 2 devices running the app
- **Recommended**: 3+ devices for multi-peer testing

### Test Scenarios

#### Basic Discovery
1. Launch app on 2 devices
2. Grant Bluetooth and location permissions
3. **Expected**: Devices discover each other within 10 seconds
4. **Expected**: Names, ages, bios, thumbnails visible
5. **Expected**: RSSI signal strength displayed

#### Messaging
1. Discover peer
2. Open chat screen
3. Send text message
4. **Expected**: Message delivers in 2-3 seconds
5. **Expected**: Delivered status shown in UI
6. **Expected**: Recipient sees message in real-time

#### Connection Loss
1. Establish connection
2. Send message
3. Turn off Bluetooth on one device
4. **Expected**: "Peer lost" event emitted after timeout
5. Turn Bluetooth back on
6. **Expected**: Devices rediscover each other
7. **Current Limitation**: Unsent messages NOT queued (need store-and-forward)

#### Permissions
1. Fresh install
2. Deny Bluetooth permission
3. **Expected**: Clear error message
4. **Expected**: "Open Settings" button works
5. Grant permission
6. **Expected**: App recovers without restart

#### Multiple Peers
1. Launch app on 5+ devices in same room
2. **Expected**: All devices discover each other
3. **Expected**: No crashes or performance issues
4. **Expected**: Connection pool limits respected (max 5)

### Known Issues

1. **Store-and-forward**: ✅ Implemented — messages are persisted and retried on peer rediscovery
2. **One concurrent Wi-Fi Direct transfer**: Second transfer requires NearbyService reinit
3. **iOS Background**: Discovery stops when app backgrounded (iOS limitation)
4. **Connection Limits**: Only 5 concurrent connections (by design, configurable)
5. **Wi-Fi Direct threading warning**: Native callbacks may arrive on non-platform thread (no data loss observed)

## Performance Expectations

- **Discovery Time**: 5-10 seconds typical
- **Message Latency**: 2-3 seconds when connected
- **Connection Setup**: 3-5 seconds
- **Battery Drain**: Needs testing (target <10% per hour)
- **Memory**: Stable with 10+ discovered peers
- **Connection Pool**: Max 5 active, LRU eviction

## Next Implementation Steps

### Priority 1: Store-and-Forward Message Queue
```dart
// Add to Drift schema
class PendingMessages extends Table {
  TextColumn get messageId => text()();
  TextColumn get peerId => text()();
  TextColumn get payload => text()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get retryCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {messageId};
}

// In BLE service
void _onPeerDiscovered(DiscoveredPeer peer) {
  // Check for pending messages queued from previous sessions
  _deliverPendingMessages(peer.peerId);
}
```

### Priority 2: End-to-End Encryption
**Status**: ✅ **Implemented** — Noise_XK/XX handshake + XChaCha20-Poly1305 session encryption. See `lib/services/encryption/`.

### Priority 3: Concurrent Wi-Fi Direct Transfers
- Track multiple simultaneous transfers in NearbyService
- Multiplex or manage multiple Nearby connections

## Code Locations (CURRENT)

- **BLE Facade (entry point)**: `lib/services/ble/ble_facade.dart`
- **Interface**: `lib/services/ble/ble_service_interface.dart`
- **Sub-modules**: `lib/services/ble/connection/`, `discovery/`, `gatt/`, `mesh/`, `transfer/`
- **UUID constants**: `BleUuids` in `lib/services/ble/ble_config.dart`
- **Dependency Injection**: `lib/injection.dart`
- **Models**: `lib/services/ble/ble_models.dart`
- **Photo Chunker**: `lib/services/ble/photo_chunker.dart`

## Debugging

Enable verbose logging in debug builds:

```dart
// In ble_facade.dart (or relevant sub-module)
Logger.info('BleFacade: Discovered device ... (RSSI: ...)', 'BLE');
```

Watch these logs:
- "Discovered device" - Successful scan results
- "Connected to" - GATT connection established
- "Discovered peer" - Profile read successfully
- "Message sent successfully" - Messaging working
- "Lost peer" - Timeout triggered

## Platform-Specific Notes

### iOS
- **Background Discovery**: Very limited, app must be in foreground
- **Connection Limit**: ~8-10 devices max
- **MTU**: Typically 185 bytes
- **Location Permission**: Required even though not actually using GPS

### Android
- **Background Support**: Better with foreground service
- **Connection Limit**: 20-50 depending on device
- **MTU**: Often negotiable up to 512 bytes
- **Android 12+**: New permission model (BLUETOOTH_SCAN, BLUETOOTH_CONNECT)

## Success Criteria

The implementation will be fully complete when:

- ✅ Two devices discover each other reliably
- ✅ Text messages deliver in 2-3 seconds
- ✅ Photos transfer via Wi-Fi Direct (< 1 s) with BLE fallback (~60 s)
- ✅ App handles 10+ nearby peers
- ⚠️ Battery drain acceptable (<10% per hour) — needs profiling
- ✅ Messages queue across sessions when peers offline (store-and-forward)
- ✅ No crashes from BLE errors
- ✅ Both iOS and Android working
- ✅ Clear permissions flow
- ✅ Non-blocking message send queue (FIFO)

Legend:
- ✅ Implemented and working
- ⚠️ Not yet implemented or needs testing

## Cruise Ship Environment Considerations

1. **Metal Interference**: Bluetooth signal may be degraded by ship's metal structure
2. **Peer Density**: Could have 50-100+ passengers in range
3. **Movement**: People moving around ship, connections frequently lost/regained
4. **Battery Life**: Critical - passengers won't charge phones every few hours

**Recommendations**:
- Aggressive connection pooling (keep only active chats connected)
- Efficient scanning (scan 3s, pause 5s, repeat)
- Battery saver mode option (scan 2s, pause 15s)
- Store-and-forward is ESSENTIAL (don't lose messages)
- UI feedback for "out of range" vs "offline permanently"

## Getting Help

Common issues and solutions:

**"Bluetooth is not available"**
- Device doesn't support BLE (very rare)
- Check physical Bluetooth hardware

**"Permission denied"**
- User denied permission
- Guide to Settings > App > Permissions

**"Connection timeout"**
- Peer device locked/asleep
- Bluetooth interference
- Too far away (>10-30 meters typical range)

**"No peers discovered"**
- Both devices may be scanning only (peripheral mode issue)
- Bluetooth off on one device
- App backgrounded on iOS
- Check logs for scan results

**"Message not delivered"**
- Peer disconnected before send completed
- Need message queue implementation
- Check connection status before sending

## License

This implementation is part of the Anchor app project.
