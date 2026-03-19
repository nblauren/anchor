# Anchor — BLE Implementation Guide

**Last Updated**: March 2026

> **Historical note**: This file was previously named `FLUTTER_BLUE_PLUS_IMPLEMENTATION.md`. Anchor no longer uses `flutter_blue_plus`; the production BLE service uses the **`bluetooth_low_energy`** package, which provides both `CentralManager` (scan/connect) and `PeripheralManager` (GATT server/advertise) in a single API.

---

## Overview

Anchor's BLE layer enables fully offline peer-to-peer profile discovery, messaging, and photo sharing. Every device acts simultaneously as a **peripheral** (advertising its profile, serving a GATT server) and a **central** (scanning for and connecting to other Anchor devices).

**Package**: `bluetooth_low_energy: ^6.2.1`

---

## What Is Implemented

### Core BLE Service (`BleFacade`)

Entry point: `lib/services/ble/ble_facade.dart`. Delegates to focused sub-modules (`connection/`, `discovery/`, `gatt/`, `mesh/`, `transfer/`).

| Capability | Status |
|---|---|
| Adapter state monitoring (on/off/unavailable) | ✅ |
| Runtime permission handling (Android 12+, iOS) | ✅ |
| Peripheral (GATT server + advertising) | ✅ |
| Central (scanning + GATT connect) | ✅ |
| Profile metadata read (fff1) | ✅ |
| Primary thumbnail broadcast/read (fff2, ≤30 KB) | ✅ |
| Text messaging over GATT (fff3) | ✅ |
| Full photo characteristic (fff4) | ✅ (served on-demand) |
| Photo consent flow (preview → request → transfer) | ✅ |
| Emoji reactions over BLE | ✅ |
| Read receipts over BLE | ✅ |
| Reply-to message metadata in BLE payload | ✅ |
| NSFW detection before broadcast | ✅ |
| Connection pooling (max 5 concurrent) | ✅ |
| Adaptive scan intervals (normal / battery saver / high density) | ✅ |
| Peer timeout and `peerLost` events | ✅ |
| TTL-based mesh relay (text messages only) | ✅ |
| Drop Anchor signal (fff3 message type) | ✅ |
| Battery saver mode | ✅ |
| GATT write queue (prevents concurrent write errors) | ✅ |
| MAC rotation dedup (stable userId in discovered_peers) | ✅ |

---

## Service and Characteristic UUIDs

All UUIDs are centralized in `BleUuids` (`lib/services/ble/ble_config.dart`). These are proper 128-bit random UUIDs (not the BLE SIG `0000xxxx` range) to avoid collisions with third-party devices.

```
Service:   b4b605d3-7718-42a5-88ec-6fbe8c6c3cb9

Profile (fff1):   02c57431-2cc9-4b9c-9472-37a1efa02bc6   READ, NOTIFY
      Payload: JSON { userId, name, age, positionId, interestIds[], hopCount, pk, spk }

Thumbnail (fff2): e353cf0a-85c2-4d2a-b4b1-8a0fa1bfb1f1   READ, NOTIFY
      Payload: raw JPEG bytes, capped at 30 KB
      Note: NSFW-screened locally before being written here

Messaging (fff3): 6c4c3e0a-8d29-48b6-83c3-2d19ee02d398   WRITE, NOTIFY
      Payload: Binary MeshPacket (signed, encrypted) or JSON (legacy/handshake)
      Message types: text | photo | typing | read | photoPreview | photoRequest | anchorDrop

Photos (fff4):    79118c43-92a1-48b7-98af-d28a0a9dbc72   READ, NOTIFY
      Payload: profile photo thumbnails concatenated; served on-demand

Reverse (fff5):   9386c87b-79fb-4b5c-ab38-d0e6a0fffd03   WRITE, NOTIFY
      Payload: reverse-path writes from peer to server
```

---

## Platform Configuration

### iOS (`ios/Runner/Info.plist`)

- `NSBluetoothAlwaysUsageDescription` ✅
- `NSBluetoothPeripheralUsageDescription` ✅
- `NSLocationWhenInUseUsageDescription` ✅ (required by iOS even though GPS is not used)
- `UIBackgroundModes`: `bluetooth-central`, `bluetooth-peripheral` ✅

### Android (`AndroidManifest.xml`)

- `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE` (Android 12+) ✅
- `ACCESS_FINE_LOCATION` ✅
- `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE` ✅
- `android.hardware.bluetooth_le` (required feature) ✅

---

## Discovery Protocol

```
Device A (Central)                      Device B (Peripheral)
      |                                        |
      |─── scan (match svc UUID or "A<ver>") ─>|
      |<── advertisement (svc UUID + "A3") ────|
      |─── GATT connect ──────────────────────>|
      |─── read profile char ─────────────────>|
      |<── { userId, name, age, positionId,    |
      |      interestIds, hopCount, pk, spk } ─|
      |─── read thumbnail char ───────────────>|
      |<── JPEG bytes (≤30 KB) ────────────────|
      |                                        |
      |  emit DiscoveredPeer                   |
      |  DiscoveryBloc updates grid            |
      |                                        |
      |─── disconnect (idle ≥60 s) ───────────>|
```

---

## Messaging Protocol

Messages are written to the messaging characteristic as binary MeshPackets (signed + encrypted) or JSON (legacy/handshake). The receiver's GATT server notifies subscribed centrals.

```json
{
  "messageId": "uuid",
  "senderId": "uuid",
  "timestamp": "2026-03-09T10:30:00Z",
  "type": "text",
  "content": "Hello!",
  "ttl": 3
}
```

**Mesh relay**: If `ttl > 0`, a receiving node that is not the intended recipient will decrement TTL and forward to all currently-connected peers (excluding the sender). Messages already seen (by `messageId`) are dropped. This is **not** store-and-forward: relay happens only to currently-connected peers.

---

## Photo Consent Flow

```
1. Sender selects photo in UI
   └─> ImageService compresses to target size, generates thumbnail
   └─> ChatBloc emits SendPhotoMessage
   └─> BLE: write photoPreview to messaging char { messageId, thumbnailBytes, type:"photoPreview" }

2. Receiver's GATT server receives photoPreview
   └─> ChatBloc emits PhotoPreviewReceived
   └─> UI shows preview with Accept / Decline

3. Receiver taps Accept
   └─> BLE: write photoRequest to messaging char { messageId, accepted:true, type:"photoRequest" }

4. Sender receives photoRequest { accepted:true }
   └─> Full photo transfer begins over messaging/photos chars in MTU-sized chunks
   └─> Progress reported via photoProgressStream (0.0 → 1.0)

5. Transfer complete
   └─> ChatBloc emits PhotoPreviewUpgraded; UI shows full photo
```

**Wi-Fi Direct High-Speed Transfer (preferred)**:
- Uses `flutter_nearby_connections_plus` (Google Nearby Connections / Multipeer Connectivity)
- Sender = ADVERTISER, Receiver = BROWSER — coordinated via `wifiTransferReady` BLE signal
- Binary data base64-encoded, split into 24 KB chunks over Nearby text messages
- 5 MB photo transfers in < 1 second vs. ~3 min over BLE
- Automatic fallback to BLE chunking if Wi-Fi Direct times out (15 s)
- `_transferToBleId` map in ChatBloc resolves Nearby userIds → BLE device IDs

**Constraints**:
- Full photo transfer is **direct peer-to-peer only** — never relayed through intermediate nodes
- Compressed target: ≤200 KB JPEG
- Photo can be cancelled mid-transfer by either party
- One concurrent Wi-Fi Direct transfer at a time (NearbyService reinitializes between transfers)

---

## Connection Configuration (`BleConfig`)

| Parameter | Default | Notes |
|---|---|---|
| `useMockService` | `false` | Set `true` for UI-only / unit tests |
| `enableMeshRelay` | `true` | TTL-based relay of text messages |
| `meshTtl` | 3 | Max relay hops |
| `photoChunkSize` | 4096 B | Adjusted per negotiated MTU |
| `messageTimeout` | 30 s | GATT write timeout |
| `peerLostTimeout` | 2 min | Emit peerLost after this idle time |
| `maxThumbnailSize` | 30 KB | Thumbnail char cap |
| `maxPhotoSize` | 500 KB | Full photo cap before compression |
| `highDensityPeerThreshold` | 15 | Peers visible before high-density mode |
| `highDensityScanPause` | 12 s | Scan pause in high-density mode |
| `normalScanPause` | 15 s | Scan pause in normal mode |
| `highDensityRelayProbability` | 0.65 | Relay probability in high-density |
| `batterySaverScanPause` | 30 s | Scan pause in battery saver mode |

---

## Testing Requirements

### Prerequisites

- Physical devices only (BLE is unavailable in simulators/emulators)
- Minimum: 2 devices
- Recommended: 3+ devices for mesh relay testing

### Test Scenarios

#### Basic Discovery
1. Launch app on 2 devices; grant all permissions
2. **Expected**: Both devices appear in each other's discovery grid within 10 seconds
3. **Expected**: Nickname, age, position, interests, thumbnail all visible
4. **Expected**: RSSI signal strength displayed; grid sorted by proximity

#### Text Messaging
1. Discover peer → open chat
2. Send a text message
3. **Expected**: Delivered in ≤3 seconds
4. **Expected**: Message status transitions: sending → delivered

#### Photo Consent Flow
1. In chat, tap the photo button and select a photo
2. **Expected**: Receiver sees thumbnail preview with Accept / Decline
3. Accept
4. **Expected**: Transfer progress shown; full photo appears on completion

#### NSFW Detection
1. Set a photo with explicit content as the primary profile photo
2. **Expected**: Photo is blocked before being broadcast; UI warns user to choose a different photo

#### Mesh Relay (requires 3 devices)
1. Device A and Device C cannot directly reach each other; Device B is in range of both
2. Device A sends a message to Device C
3. **Expected**: Message relayed through Device B (TTL decremented); Device C receives it

#### Connection Loss
1. Connect and send a message; then turn off Bluetooth on one device
2. **Expected**: `peerLost` event emitted after 2-minute timeout; peer removed from grid
3. Turn Bluetooth back on
4. **Expected**: Devices rediscover each other within one scan cycle

#### Battery Saver Mode
1. Enable battery saver in Settings
2. Check debug logs
3. **Expected**: Scan duration 2 s, pause 30 s confirmed in logs

#### Permissions Denied
1. Fresh install; deny Bluetooth permission when prompted
2. **Expected**: Clear error message shown
3. **Expected**: "Open Settings" deep-link functions correctly
4. Grant permission in device Settings
5. **Expected**: App recovers without requiring restart

#### Multiple Peers (5+)
1. Launch app on 5+ devices in the same room
2. **Expected**: All discover each other; no crashes; connection pool limit (5) respected; LRU eviction observed in logs

---

## Known Limitations

| Limitation | Detail |
|---|---|
| Photo relay | Full photos are direct only; not relayed through mesh |
| iOS background | Discovery stops when app is backgrounded (Apple restriction); disclosed in onboarding |
| iOS connection limit | ~8–10 concurrent BLE connections |
| iOS MTU | Typically 185 bytes (affects chunk size and throughput) |
| Android MTU | Negotiable up to 512 bytes |
| One concurrent Wi-Fi Direct transfer | NearbyService reinitialises between sessions; parallel transfers not yet supported |

---

## Performance Expectations

| Metric | Target |
|---|---|
| Discovery time | ≤10 seconds from scan start |
| Text message latency | ≤3 seconds when in range |
| GATT connection setup | 3–5 seconds |
| Photo transfer (200 KB) | 30–60 seconds |
| Battery drain | <10% per hour of active use (target; needs real-device profiling) |
| Memory (10+ peers) | Stable; no observable leak over 1 hour session |

---

## Code Locations

| Component | File |
|---|---|
| BLE facade (entry point) | `lib/services/ble/ble_facade.dart` |
| BLE interface | `lib/services/ble/ble_service_interface.dart` |
| BLE data models | `lib/services/ble/ble_models.dart` |
| Configuration | `lib/services/ble/ble_config.dart` |
| Connection management | `lib/services/ble/connection/connection_manager.dart` |
| Scanning | `lib/services/ble/discovery/ble_scanner.dart` |
| Profile reading | `lib/services/ble/discovery/profile_reader.dart` |
| GATT server | `lib/services/ble/gatt/gatt_server.dart` |
| GATT write queue | `lib/services/ble/gatt/gatt_write_queue.dart` |
| Mesh relay | `lib/services/ble/mesh/mesh_relay_service.dart` |
| Photo transfer | `lib/services/ble/transfer/photo_transfer_handler.dart` |
| Photo chunker | `lib/services/ble/photo_chunker.dart` |
| Adapter state bloc | `lib/services/ble/ble_status_bloc.dart` |
| Service lifecycle bloc | `lib/services/ble/ble_connection_bloc.dart` |
| Mock BLE service | `lib/services/ble/mock_ble_service.dart` |
| Wi-Fi Direct interface | `lib/services/nearby/high_speed_transfer_service.dart` |
| Wi-Fi Direct impl | `lib/services/nearby/nearby_transfer_service_impl.dart` |
| Wi-Fi Direct models | `lib/services/nearby/nearby_models.dart` |
| Mock Wi-Fi Direct | `lib/services/nearby/mock_high_speed_transfer_service.dart` |
| Transport manager | `lib/services/transport/transport_manager.dart` |
| Store-and-forward | `lib/services/store_and_forward_service.dart` |
| Dependency wiring | `lib/injection.dart` |

---

## Debugging

Enable verbose logging in debug builds by checking `Logger` output tagged `'BLE'`. Key log messages:

| Log message | Meaning |
|---|---|
| `Discovered device …` | Scan result received |
| `Connected to …` | GATT connection established |
| `Discovered peer …` | Profile + thumbnail read successfully |
| `Message sent successfully` | fff3 write acknowledged |
| `Relaying message TTL=…` | Mesh relay hop in progress |
| `Lost peer …` | Timeout; `peerLost` emitted |
| `NSFW blocked …` | Photo failed NSFW check; not broadcast |
| `Photo preview sent` | Consent flow step 1 complete |
| `Photo request accepted` | Consent flow step 2 complete; transfer starting |

**Debug Menu**: Settings → Debug Menu shows live BLE status, peer list, log viewer, and mock peer injection.

---

## Cruise Ship Environment Considerations

| Challenge | Mitigation |
|---|---|
| Metal bulkheads degrade BLE signal | Shorter retry intervals; educate users about range limits |
| 50–100+ passengers in BLE range | Adaptive scanning; high-density relay throttling |
| Frequent movement / connection churn | Short peer-lost timeout (2 min) for fast re-discovery |
| Battery life critical (no charging mid-cruise) | Battery saver mode; aggressive connection pooling |

---

## Common Troubleshooting

| Symptom | Check |
|---|---|
| "Bluetooth is not available" | Device doesn't support BLE (very rare) or hardware fault |
| "Permission denied" | User denied permission; guide to Settings → App → Permissions |
| "Connection timeout" | Peer locked/asleep, too far away, or RF interference |
| "No peers discovered" | Both devices scanning only with no peripheral — check advertising is running; check iOS foreground requirement |
| "Message not delivered" | Peer disconnected before write completed; no store-and-forward in v1 |
| Photo transfer hangs | Check consent was accepted; verify connection is still active; cancel and retry |
