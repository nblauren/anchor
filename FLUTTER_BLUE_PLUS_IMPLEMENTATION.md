# Flutter Blue Plus BLE Implementation Guide

## Overview

Anchor now uses **flutter_blue_plus** for direct peer-to-peer Bluetooth Low Energy communication, replacing the previous Bridgefy mesh networking approach.

## What's Implemented ✅

### Core BLE Service (`FlutterBluePlusBleService`)

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

### Service UUIDs

```
Main Service: 0000fff0-0000-1000-8000-00805f9b34fb
Characteristics:
  - Profile Metadata: 0000fff1-0000-1000-8000-00805f9b34fb (READ, NOTIFY)
  - Thumbnail Data:   0000fff2-0000-1000-8000-00805f9b34fb (READ)
  - Messaging:        0000fff3-0000-1000-8000-00805f9b34fb (WRITE, NOTIFY)
```

### Dependencies

```yaml
dependencies:
  flutter_blue_plus: ^1.32.0      # BLE communication
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

### 1. Peripheral Mode (Broadcasting)

**Issue**: `broadcastProfile()` is called but doesn't actually advertise the device.

**Why**: flutter_blue_plus doesn't easily support peripheral/advertising mode on all devices. Most apps are "central" (scanner) only.

**Options**:
- **Option A**: Use platform channels to implement native advertising on iOS/Android
- **Option B**: Accept that discovery is one-way (scanning only)
- **Option C**: Use a different package that supports peripheral mode

**Recommended**: For cruise ship environment, implement Option A with native code.

### 2. Photo Transfer

**Status**: Marked as TODO in code, returns `false` immediately.

**Requirements**:
- Chunk photos into ~500 byte pieces (respect MTU)
- Send chunks sequentially with ACKs
- Reassemble on receiver
- Progress tracking
- Resume on connection loss

**Estimated Effort**: 4-6 hours

### 3. Message Queue (Store-and-Forward)

**Status**: Not implemented.

**Requirements**:
- Database table for pending messages
- Queue messages when peer offline
- Deliver when peer discovered
- Retry logic with exponential backoff
- Message expiration after 24 hours

**Estimated Effort**: 3-4 hours

### 4. Connection Persistence

**Current**: Devices disconnect after 60 seconds of idle time.

**Better Approach**:
- Keep connections to active chat partners
- LRU eviction when pool full
- Priority: active chats > recently viewed > discovery

**Estimated Effort**: 2-3 hours

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

1. **Photos Don't Transfer**: Photo transfer not implemented yet
2. **No Offline Messages**: Messages sent while peer offline are lost
3. **One-Way Discovery**: Devices may not see each other if neither can advertise
4. **iOS Background**: Discovery stops when app backgrounded (iOS limitation)
5. **Connection Limits**: Only 5 concurrent connections (by design, configurable)

## Performance Expectations

- **Discovery Time**: 5-10 seconds typical
- **Message Latency**: 2-3 seconds when connected
- **Connection Setup**: 3-5 seconds
- **Battery Drain**: Needs testing (target <10% per hour)
- **Memory**: Stable with 10+ discovered peers
- **Connection Pool**: Max 5 active, LRU eviction

## Next Implementation Steps

### Priority 1: Photo Transfer
```dart
// In flutter_blue_plus_ble_service.dart
Future<bool> sendPhoto(String peerId, Uint8List photoData, String messageId) async {
  // 1. Negotiate MTU
  // 2. Chunk photo using _photoChunker
  // 3. Send chunks sequentially
  // 4. Wait for ACK per chunk
  // 5. Emit progress updates
  // 6. Handle errors and retries
}
```

### Priority 2: Message Queue
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
  // ... existing code ...

  // Check for pending messages
  _deliverPendingMessages(peer.peerId);
}
```

### Priority 3: Peripheral Mode
```dart
// Platform channel for native advertising
// ios/Runner/BlePeripheralManager.swift
// android/app/src/main/kotlin/.../BlePeripheralService.kt
```

## Code Locations

- **Main Service**: `lib/services/ble/flutter_blue_plus_ble_service.dart`
- **Interface**: `lib/services/ble/ble_service_interface.dart`
- **Dependency Injection**: `lib/injection.dart` (line 36-44)
- **Models**: `lib/services/ble/ble_models.dart`
- **Photo Chunker**: `lib/services/ble/photo_chunker.dart`

## Debugging

Enable verbose logging in debug builds:

```dart
// In flutter_blue_plus_ble_service.dart
Logger.info('FlutterBluePlusBleService: Discovered device ${device.platformName} (RSSI: ${result.rssi})', 'BLE');
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
- ⚠️ Photos (200KB) transfer in under 60 seconds
- ✅ App handles 10+ nearby peers
- ⚠️ Battery drain acceptable (<10% per hour)
- ⚠️ Messages queue when peers offline
- ⚠️ Queued messages deliver when peers return
- ✅ No crashes from BLE errors
- ⚠️ Both iOS and Android working
- ✅ Clear permissions flow

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
