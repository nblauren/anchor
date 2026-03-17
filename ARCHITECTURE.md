# Anchor — Architecture

**Last Updated**: March 2026
**Version**: 1.0.0

---

## Overview

Anchor is an offline-first, peer-to-peer proximity chat app for gay cruises, festivals, beaches, and events. It uses Bluetooth Low Energy (BLE) for device discovery, profile broadcasting, messaging, and photo transfer — entirely without internet connectivity.

**Design Philosophy:**

| Principle | Description |
|---|---|
| Local-First | All data stored on-device via SQLite (Drift); no servers, no cloud |
| Privacy by Design | No accounts, no tracking; users control all data |
| Minimal Broadcast | Only essential, ID-mapped profile fields broadcast over BLE |
| Safety Gate | NSFW detection runs locally before any photo is allowed to broadcast |
| Consent-Based Photos | Full photo transfer requires explicit receiver acceptance |
| Battery Conscious | Adaptive scanning intervals, connection pooling, battery saver mode |
| Feature-Based Structure | Self-contained feature modules for maintainability |

---

## Architecture Pattern

Anchor follows **Clean Architecture** with a **Feature-Based** organisation:

```
Presentation Layer  (Flutter Widgets + Bloc)
        ↓ events / ↑ states
Domain / Business Logic Layer  (Bloc handlers, repositories)
        ↓ calls
Data / Service Layer  (Drift DB, BLE service, image service)
```

Key principles:
1. **Separation of concerns** — each layer has a single responsibility
2. **Dependency inversion** — high-level modules depend on abstractions (`BleServiceInterface`), not implementations
3. **Unidirectional data flow** — events flow up to Blocs; states flow back down to widgets
4. **Testability** — `MockBleService` substitutes for real BLE in unit/widget tests

---

## Project Structure

```
lib/
├── main.dart                        # App entry point; sets up GetIt, runs app
├── app.dart                         # MaterialApp, theme, top-level BlocProviders
├── injection.dart                   # GetIt dependency wiring
│
├── core/                            # App-wide shared code
│   ├── constants/
│   │   ├── app_constants.dart       # Timeouts, limits, string keys
│   │   └── profile_constants.dart   # Position IDs, interest IDs and labels
│   ├── errors/
│   │   └── app_error.dart           # AppError hierarchy (BleError, DatabaseError, …)
│   ├── routing/
│   │   └── app_shell.dart           # Top-level router: onboarding → permissions → home
│   ├── screens/
│   │   └── splash_screen.dart
│   ├── theme/
│   │   └── app_theme.dart           # Dark theme, colours, text styles
│   ├── utils/
│   │   └── logger.dart              # Structured logging utility
│   └── widgets/                     # Reusable UI primitives
│       ├── empty_state_widget.dart
│       ├── error_state_widget.dart
│       └── loading_widget.dart
│
├── data/                            # Data layer
│   ├── local_database/
│   │   ├── database.dart            # Drift database + table definitions
│   │   └── database.g.dart          # Generated Drift code (do not edit)
│   ├── models/                      # Pure Dart model classes
│   │   ├── chat_message.dart
│   │   ├── conversation.dart
│   │   ├── discovered_user.dart
│   │   └── user_profile.dart
│   └── repositories/
│       ├── profile_repository.dart
│       ├── peer_repository.dart
│       ├── chat_repository.dart
│       └── anchor_drop_repository.dart
│
├── services/
│   ├── database_service.dart        # Drift DB init and lifecycle
│   ├── image_service.dart           # Photo pick, compress, store, thumbnail gen
│   ├── nsfw_detection_service.dart  # On-device NSFW classifier
│   ├── notification_service.dart    # Local push notifications
│   ├── audio_service.dart           # Ambient audio feedback (messages, drops, photos)
│   ├── store_and_forward_service.dart # Cross-session message retry queue
│   ├── encryption/
│   │   ├── encryption_service.dart  # Key gen/storage, Noise_XK handshake lifecycle, encrypt/decrypt
│   │   ├── encryption_models.dart   # NoiseSession, EncryptedPayload, HandshakeResult, etc.
│   │   ├── noise_handshake.dart     # Pure Noise_XK state machine (NoiseHandshakeProcessor)
│   │   └── encryption.dart          # Barrel export
│   ├── ble/
│   │   ├── ble_facade.dart                    # Thin facade exposing BleServiceInterface
│   │   ├── ble_service_interface.dart         # Abstract BLE contract
│   │   ├── mock_ble_service.dart              # Test double
│   │   ├── ble_models.dart                    # BLE-layer data types
│   │   ├── ble_config.dart                    # Runtime configuration
│   │   ├── ble_status_bloc.dart               # BLE adapter state tracking
│   │   ├── ble_connection_bloc.dart           # BLE service lifecycle management
│   │   ├── photo_chunker.dart                 # Photo chunk/reassemble helpers
│   │   ├── connection/                        # ConnectionManager, PeerConnection
│   │   ├── discovery/                         # BleScanner, ProfileReader
│   │   ├── gatt/                              # GattServer, GattWriteQueue
│   │   ├── mesh/                              # MeshRelayService
│   │   └── transfer/                          # PhotoTransferHandler
│   ├── nearby/
│   │   ├── high_speed_transfer_service.dart    # Abstract Wi-Fi Direct interface
│   │   ├── nearby_transfer_service_impl.dart   # Production impl (flutter_nearby_connections_plus)
│   │   ├── mock_high_speed_transfer_service.dart # Test double
│   │   ├── nearby_models.dart                  # NearbyTransferProgress, NearbyPayloadReceived
│   │   └── nearby.dart                         # Barrel export
│   ├── transport/
│   │   ├── transport_manager.dart              # Unified LAN + Wi-Fi Aware + BLE router
│   │   └── transport_enums.dart                # TransportType, etc.
│   ├── lan/
│   │   ├── lan_transport_service.dart          # Abstract LAN interface
│   │   ├── lan_transport_service_impl.dart     # Production impl
│   │   └── mock_lan_transport_service.dart     # Test double
│   └── wifi_aware/
│       ├── wifi_aware_transport_service.dart   # Abstract Wi-Fi Aware interface
│       ├── wifi_aware_transport_service_impl.dart # Production impl (wifi_aware_p2p)
│       └── mock_wifi_aware_transport_service.dart # Test double
│
└── features/
    ├── profile/                     # Own profile management
    │   ├── bloc/
    │   ├── screens/
    │   └── widgets/
    ├── discovery/                   # Peer grid, filtering, anchor drops
    │   ├── bloc/
    │   ├── screens/
    │   └── widgets/
    ├── chat/                        # 1:1 messaging, photo consent flow
    │   ├── bloc/
    │   ├── screens/
    │   └── widgets/
    ├── onboarding/                  # First-run intro + permissions explainer
    ├── settings/                    # User settings, blocked users, debug menu
    └── home/                        # Bottom navigation shell
```

> **Note**: `flutter_blue_plus_ble_service.dart` is named for historical reasons but actually uses the `bluetooth_low_energy` package, which provides both Central and Peripheral managers in a single API.

---

## BLE Communication Protocol

### Package

Anchor uses **`bluetooth_low_energy`** (not `flutter_blue_plus`). This package provides:
- `CentralManager` — scanning and connecting to peripherals
- `PeripheralManager` — GATT server and advertising

Both roles run simultaneously on the same device, enabling true peer-to-peer discovery.

### Service and Characteristic UUIDs

```
Main Service:           0000fff0-0000-1000-8000-00805f9b34fb

Characteristics:
  fff1  Profile metadata    READ, NOTIFY   name, age, position ID, interest IDs, userId, pk (X25519 public key hex)
  fff2  Primary thumbnail   READ, NOTIFY   JPEG bytes, 10–30 KB
  fff3  Messaging           WRITE, NOTIFY  JSON-encoded messages (text, photo events, anchor drop)
  fff4  Full photo set      READ           On-demand; serves all profile thumbnails concatenated
```

### Discovery Protocol

```
Device A (Central)                         Device B (Peripheral)
      |                                           |
      |-- scan for fff0 service UUID ------------>|
      |<-- advertisement (fff0 + local name) -----|
      |                                           |
      |-- GATT connect -------------------------->|
      |-- read fff1 (profile metadata) ---------->|
      |<-- { userId, name, age, positionId,       |
      |       interestIds, hopCount, pk } --------|
      |-- read fff2 (primary thumbnail) --------->|
      |<-- JPEG bytes (≤30 KB) ------------------|
      |                                           |
      |  emit DiscoveredPeer to stream            |
      |  (DiscoveryBloc updates grid)             |
      |                                           |
      |-- disconnect (idle after 60 s) ---------->|
```

**Peer timeout**: If no GATT activity is observed for the configured `peerLostTimeout` (default 2 minutes), a `peerLost` event is emitted and the peer is marked out-of-range in the UI.

### Messaging Protocol

```
Sender (Central)                           Receiver (Peripheral / GATT server)
      |                                           |
      |-- connect (if not already) ------------->|
      |-- subscribe to fff3 NOTIFY ------------->|
      |-- write to fff3 (JSON payload) --------->|
      |                                           |
      |   { messageId, senderId, timestamp,       |
      |     type, content, ttl? }                 |
      |                                           |
      |                         messageReceived stream emits
      |                         ChatBloc saves to DB, updates UI
```

Message types (`MessageType` enum): `text`, `photo`, `typing`, `read`, `photoPreview`, `photoRequest`, `wifiTransferReady`

**Noise handshake messages** are routed separately (not via `MessageType`) as top-level JSON with `"type": "noise_hs"`. See [End-to-End Encryption](#end-to-end-encryption) section.

**Store-and-forward for direct messages**: Undelivered messages (status `pending` or `failed`) are persisted in the `messages` table. `StoreAndForwardService` monitors peer discovery events and retries queued messages when a peer is rediscovered, incrementing `retry_count` and updating `last_attempt_at` on each attempt.

### Photo Transfer Protocol

Photo sharing uses a consent-first flow with Wi-Fi Direct high-speed transfer:

```
Step 1 — Preview notification (Sender → Receiver via BLE fff3)
  { type: "photoPreview", messageId, photoId, originalSize }
  Note: No thumbnail data is sent — the receiver sees "Photo — Tap to download"

Step 2 — Consent request (Receiver → Sender via BLE fff3)
  { type: "photoRequest", photoId, accepted: true }

Step 3 — Full photo transfer (Wi-Fi Direct preferred, BLE fallback)
  a. Sender starts Nearby Connections advertising
  b. Sender sends wifiTransferReady BLE signal with sender's Nearby ID
  c. Receiver starts browsing → discovers → invites → connects
  d. Sender streams base64-encoded chunks over Wi-Fi Direct text channel
  e. If Wi-Fi Direct times out (15 s), sender falls back to BLE chunking via fff3

Step 4 — Transfer complete
  Receiver saves photo, upgrades preview bubble to full photo in UI
```

**Wi-Fi Direct Transfer (`HighSpeedTransferService`):**
- Uses `flutter_nearby_connections_plus` (Google Nearby Connections API / Multipeer Connectivity)
- Sender = ADVERTISER, Receiver = BROWSER (coordinated via BLE signal)
- Binary data base64-encoded and split into 24 KB chunks (~32 KB base64)
- 5 MB photo transfers in < 1 second over Wi-Fi Direct vs. ~3 min over BLE
- One concurrent transfer at a time; NearbyService reinitializes between transfers

**Constraints:**
- Full photo transfer is **direct peer-to-peer only** — multi-hop relay for photos is not supported
- Compressed target size: ≤200 KB JPEG
- Progress updates emitted via `photoProgressStream` (BLE) or `transferProgressStream` (Wi-Fi Direct)
- Transfer can be cancelled by either party
- Two separate ID systems: BLE device IDs vs app userIds — mapped via `_transferToBleId` in ChatBloc

### Mesh Relay Protocol

For text messages, Anchor implements a **TTL-based flooding** relay:

```
Original sender sets TTL (default 3).
Each relay node:
  1. Checks message deduplication cache (messageId already seen → drop).
  2. Decrements TTL; if TTL == 0 → drop.
  3. Forwards to all currently connected peers (excluding the sender).
```

**Important constraints:**
- Relay is **not** store-and-forward — a node only relays to peers that are currently connected
- Photos are **never** relayed; only text-type messages are eligible for mesh relay
- Relay is toggled via `BleConnectionBloc` → `SetMeshRelay` event
- In high-density environments, relay probability is throttled (`highDensityRelayProbability = 0.65`)

### Connection Management

| Parameter | Default | Notes |
|---|---|---|
| Max concurrent connections | 5 | Configurable in `BleConfig` |
| Connection timeout | 30 s | GATT connect attempt timeout |
| Idle disconnect | 60 s | Drop connections with no recent activity |
| Peer lost timeout | 2 min | Emit `peerLost` if no GATT activity |
| Normal scan duration | 5 s | Active scan window |
| Normal scan pause | 15 s | Pause between scans |
| Battery saver scan duration | 2 s | |
| Battery saver scan pause | 30 s | |

**Adaptive scanning**: In high-density mode (≥15 visible peers), scan pause increases (`highDensityScanPause`) and relay probability is reduced to limit mesh traffic.

---

## Profile Data Model

### Broadcast Payload (over BLE)

| Field | Type | Detail |
|---|---|---|
| `userId` | UUID string | Stable per-install identifier |
| `name` | string | Nickname, user-set |
| `age` | int | User-set |
| `positionId` | int | Maps to a fixed list of position labels |
| `interestIds` | List\<int\> | Maps to a fixed interest label set; no free-text interests |
| `hopCount` | int | 0 = direct; >0 = relayed |
| `pk` | hex string | X25519 public key for Noise_XK E2EE handshake |
| Primary thumbnail | JPEG bytes | ≤30 KB; screened for NSFW before broadcast |

Position IDs and interest IDs are defined in `lib/core/constants/profile_constants.dart`. Using integer IDs keeps the broadcast payload compact and prevents injection of arbitrary text into the mesh.

### Local-Only Profile Fields

The following are stored locally and never broadcast over BLE:
- Bio / extended description
- Additional photos (up to 4 total)
- Block list

### NSFW Detection Flow

```
User selects photo (gallery or camera)
        ↓
ImageService compresses to thumbnail (≤30 KB)
        ↓
NsfwDetectionService.classify(thumbnailBytes)
        ↓
  NSFW score too high?
  ├── Yes → ProfileBloc emits nsfwBlockedPhotoId
  │         Photo stored locally but not broadcast
  │         UI prompts user to choose a different photo
  └── No  → Photo approved; set as primary thumbnail
             broadcastProfile() includes thumbnail bytes
```

---

## State Management (Bloc Pattern)

### Why Bloc

- Clean separation of business logic and UI
- Predictable, testable state transitions
- Strong event/state typing with Equatable
- Bloc DevTools integration for debugging

### Key Blocs

**`ProfileBloc`** (`lib/features/profile/bloc/profile_bloc.dart`)
- Manages the user's own profile
- Key events: `LoadProfile`, `CreateProfile`, `UpdateProfile`, `AddPhoto`, `RemovePhoto`, `SetPrimaryPhoto`, `BroadcastProfile`, `DismissNsfwWarning`
- Handles NSFW detection result routing and photo ordering

**`DiscoveryBloc`** (`lib/features/discovery/bloc/discovery_bloc.dart`)
- Listens to BLE `peerDiscovered` / `peerLost` streams
- Filters blocked users
- Applies position and interest filters (local, zero-network)
- Manages anchor drop send/receive events
- Key events: `StartDiscovery`, `StopDiscovery`, `PeerDiscovered`, `PeerLost`, `BlockPeer`, `SetPositionFilter`, `ToggleInterestFilter`, `DropAnchorOnPeer`

**`ChatBloc`** (`lib/features/chat/bloc/chat_bloc.dart`)
- Manages conversations and messages
- Listens to `messageReceived` stream from BLE service
- Handles photo consent flow: `PhotoPreviewReceived` → `RequestFullPhoto` → `PhotoTransferProgressUpdated`
- **Non-blocking send queue**: `SendTextMessage` and `SendPhotoMessage` save to DB and update UI immediately, then send via BLE in the background using a FIFO queue (`_sendQueue`). Input is never blocked.
- **Emoji reactions**: `SendReaction` / `ReactionReceived` events; cannot react to own message
- **Reply-to**: `SendTextMessage` and `SendPhotoMessage` accept optional `replyToMessageId`
- **Read receipts**: `MarkMessagesRead` emits BLE read-receipt; `ReadReceiptReceived` updates message status to `read`
- Wi-Fi Direct integration: `WifiTransferReadyReceived` triggers Nearby browsing; `NearbyPayloadCompleted` handles received photos; `_transferToBleId` map resolves Nearby userIds to BLE device IDs
- **E2EE handshake gate**: Chat input is blocked while `isE2eeHandshaking` is true; a "Initiating secure connection…" banner is shown. Messages cannot be sent without an active session (`isE2eeActive`)
- Key events: `SendTextMessage`, `SendPhotoMessage`, `BleMessageReceived`, `PhotoPreviewReceived`, `RequestFullPhoto`, `PhotoRequestReceived`, `CancelPhotoTransfer`, `WifiTransferReadyReceived`, `NearbyPayloadCompleted`, `RegisterPendingOutgoingPhoto`, `SendReaction`, `ReactionReceived`, `MarkMessagesRead`, `ReadReceiptReceived`, `E2eeSessionEstablished`, `E2eePeerKeyArrived`

**`BleStatusBloc`** (`lib/services/ble/ble_status_bloc.dart`)
- Tracks Bluetooth adapter state (enabled / disabled / unavailable)
- Tracks runtime permission status
- Triggers permission requests

**`BleConnectionBloc`** (`lib/services/ble/ble_connection_bloc.dart`)
- Manages BLE service lifecycle (initialize, start/stop scanning, start/stop broadcasting)
- Handles app foreground/background transitions
- Exposes `SetBatterySaver` and `SetMeshRelay` toggle events

---

## Data Layer

### Drift Database Schema

| Table | Purpose |
|---|---|
| `user_profiles` | The device owner's profile (single row) |
| `user_photos` | Photos attached to the user's profile (up to 4) |
| `discovered_peers` | Cached peer profiles read from BLE (includes `userId` for MAC rotation dedup) |
| `conversations` | 1:1 chat conversations |
| `messages` | Chat messages; includes `retry_count`, `last_attempt_at` (store-and-forward) and `reply_to_message_id` (reply-to) |
| `blocked_users` | Locally blocked peer IDs |
| `anchor_drops` | History of sent/received anchor drop signals |
| `message_reactions` | Emoji reactions on messages (sender, emoji, timestamp) |
| `peer_public_keys` | Cached X25519 public keys for peers (used for E2EE Noise_XK handshake) |

**Schema version**: 9

| Migration | Change |
|---|---|
| v1 → v2 | Full schema recreate (dropped old tables) |
| v2 → v3 | Add `anchor_drops` table |
| v3 → v4 | Add `position` and `interests` columns to `user_profiles` and `discovered_peers` |
| v4 → v5 | Add `user_id` to `discovered_peers` (stable ID for BLE MAC rotation dedup) |
| v5 → v6 | Add `message_reactions` table |
| v6 → v7 | Add `retry_count` and `last_attempt_at` to `messages` (store-and-forward) |
| v7 → v8 | Add `reply_to_message_id` to `messages` (reply-to) |
| v8 → v9 | Add `peer_public_keys` table (E2EE key storage) |

All writes go through repositories; Blocs never access the database directly.

### Repositories

| Repository | Responsibility |
|---|---|
| `ProfileRepository` | CRUD for own profile and photos |
| `PeerRepository` | Store/update/query discovered peers; block management |
| `ChatRepository` | Conversations, messages, unread counts, status updates, reactions |
| `AnchorDropRepository` | Persist and query anchor drop history |

---

## Feature Modules

### Profile (`lib/features/profile/`)

- Create and edit profile: nickname, age, position (ID), interests (IDs), up to 4 photos
- Primary photo selection with NSFW gate
- Profile preview widget (shows exactly what others see)
- Photo management: add, remove, reorder, set primary

### Discovery (`lib/features/discovery/`)

- Real-time peer grid, sorted by RSSI (closest first)
- Filter by position ID and/or interest IDs (local filtering, no network)
- Peer detail screen: view profile, initiate chat, send anchor drop
- Radar-style alternate view (`RadarView` widget)
- Peer card shows: name, age, position label, interest chips, signal strength, hop count

### Chat (`lib/features/chat/`)

- Conversation list with unread counts and last-message preview
- Real-time 1:1 text messaging with non-blocking FIFO send queue
- Photo consent flow:
  1. Sender selects photo → lightweight BLE notification sent (no thumbnail)
  2. Receiver sees "Photo — Tap to download", taps to accept
  3. Full photo transfers via Wi-Fi Direct (< 1 s) with automatic BLE fallback
- Message status: pending → sent → delivered → read
- Emoji reactions (tap-to-react emoji picker; reactions sync over BLE)
- Reply-to messages with quoted preview bubble
- Store-and-forward: undelivered messages are retried when peer is rediscovered
- Keyboard stays open after sending for rapid follow-up messages
- Out-of-range indicator when peer not currently visible

### Onboarding (`lib/features/onboarding/`)

- Multi-page intro explaining app concept
- Explicit explanation of iOS background limitation (must stay in foreground)
- Permissions rationale screen (Bluetooth, Location)

### Settings (`lib/features/settings/`)

- Edit own profile
- Blocked users management
- Battery saver mode toggle
- Mesh relay toggle
- Debug menu: BLE status, mock peers/messages, log viewer, database stats, data clear

---

## Platform Differences

### iOS

| Item | Detail |
|---|---|
| Minimum version | iOS 14.0 |
| Background BLE | Severely limited; discovery stops when app is backgrounded (Apple restriction) |
| Background modes | `bluetooth-central`, `bluetooth-peripheral` declared but OS throttles aggressively |
| Connection limit | ~8–10 concurrent |
| GATT MTU | Typically 185 bytes |
| Onboarding note | Users are informed about the foreground requirement during onboarding |

### Android

| Item | Detail |
|---|---|
| Minimum SDK | API 26 (Android 8.0) |
| Background BLE | Supported via `FOREGROUND_SERVICE`; displays a persistent notification |
| Connection limit | 20–50 concurrent (device-dependent) |
| GATT MTU | Negotiable up to 512 bytes |
| Android 12+ | Requires `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE` permissions |

---

## Battery Optimization

### Adaptive Scanning

| Mode | Scan Duration | Pause | Notes |
|---|---|---|---|
| Normal | 5 s | 15 s | Default |
| Battery Saver | 2 s | 30 s | User-toggled in Settings |
| High Density (auto) | 5 s | 12 s | Auto-engaged when ≥15 peers visible; relay probability reduced to 0.65 |

### Connection Pooling

- Maximum 5 concurrent connections (LRU eviction)
- Active chat connections are prioritised over idle discovery connections
- Idle connections are dropped after 60 seconds of no activity

### Photo Thumbnail Budget

Primary thumbnails are capped at 30 KB and compressed by `ImageService` before being written to the `fff2` characteristic. This limits both broadcast size and battery cost of serving thumbnails to scanning peers.

---

## Privacy & Safety

### Data Residency

- 100% local: SQLite on-device via Drift
- No network calls, no analytics, no telemetry
- Uninstalling the app permanently deletes all data

### BLE Broadcast Minimisation

- Only integer IDs (not free text) for position and interests — prevents arbitrary text injection into the mesh and keeps payload size small
- Primary photo screened by on-device NSFW classifier before broadcast is permitted
- No GPS coordinates broadcast or stored; BLE RSSI gives approximate proximity only

### Message Security

All chat messages are **end-to-end encrypted** using the Noise_XK protocol. See the [End-to-End Encryption](#end-to-end-encryption) section for full details.

### User Controls

- Block any peer locally at any time
- Blocked peers: cannot discover you, cannot message you, are hidden from your grid
- Visibility can be toggled (stop broadcasting)

---

## Error Handling

**`AppError` hierarchy** (`lib/core/errors/app_error.dart`):

```dart
abstract class AppError implements Exception {
  String get userMessage;  // shown to user
  String get code;         // for logging/debugging
  bool get isRecoverable;  // controls Retry vs OK button
}

// Concrete types:
class BleError extends AppError { … }
class DatabaseError extends AppError { … }
class PermissionError extends AppError { … }
class ImageError extends AppError { … }
class ProfileError extends AppError { … }
class ChatError extends AppError { … }
class DiscoveryError extends AppError { … }
```

Error UI components: `ErrorStateWidget` (full-screen), inline banners, SnackBar toasts.

---

## Logging

`Logger` utility (`lib/core/utils/logger.dart`):

```dart
Logger.info('Discovered peer: $name', 'BLE');
Logger.warning('Relay TTL exhausted', 'BLE');
Logger.error('Connection failed', 'BLE', error);
Logger.debug('Thumbnail bytes: ${bytes.length}', 'BLE');
```

Logs are viewable in real time via **Settings → Debug Menu → View Logs**.

---

## Dependency Injection

**GetIt** service locator (`lib/injection.dart`):

```dart
void setupDependencies(BleConfig config) {
  getIt.registerLazySingleton<DatabaseService>(() => DatabaseService());
  getIt.registerLazySingleton<ImageService>(() => ImageService());
  getIt.registerLazySingleton<NsfwDetectionService>(() => NsfwDetectionService());

  getIt.registerLazySingleton<BleServiceInterface>(() =>
    config.useMockService ? MockBleService() : FlutterBluePlusBleService(config: config));

  getIt.registerFactory<ProfileRepository>(
      () => ProfileRepository(getIt<DatabaseService>().database));
  getIt.registerFactory<PeerRepository>(
      () => PeerRepository(getIt<DatabaseService>().database));
  getIt.registerFactory<ChatRepository>(
      () => ChatRepository(getIt<DatabaseService>().database));
  getIt.registerFactory<AnchorDropRepository>(
      () => AnchorDropRepository(getIt<DatabaseService>().database));

  // Blocs registered as factories (new instance per screen/widget)
  getIt.registerFactory<ProfileBloc>(() => ProfileBloc(…));
  getIt.registerFactory<DiscoveryBloc>(() => DiscoveryBloc(…));
  getIt.registerFactory<ChatBloc>(() => ChatBloc(…));
  getIt.registerFactory<BleStatusBloc>(() => BleStatusBloc(…));
  getIt.registerFactory<BleConnectionBloc>(() => BleConnectionBloc(…));
}
```

---

## Testing Strategy

### Unit Tests

- **Repositories**: In-memory Drift database; test CRUD, constraints, edge cases
- **Blocs**: Mock repositories and services; assert state transitions and stream emissions
- **Services**: `MockBleService` for BLE-dependent logic without hardware

### Integration Tests

- Discovery flow: init service → start scan → emit mock `DiscoveredPeer` → verify `DiscoveryBloc` state → verify DB write → verify UI
- Messaging flow: discover peer → open chat → send message → verify DB → mock `messageReceived` → verify UI
- Photo consent flow: emit `photoPreview` → user accepts → emit `photoRequest` → emit progress → verify completion

### Device Tests

> BLE requires physical hardware. Minimum: 2 devices.

| Scenario | Pass Criteria |
|---|---|
| Discovery | Both devices appear in each other's grid within 10 s |
| Text message | Delivers in ≤3 s when in range |
| Photo consent | Preview shown; accept triggers transfer; progress displayed |
| NSFW photo | Blocked before broadcast; UI shows warning |
| Permissions denied | Error shown; Settings link works; app recovers on grant |
| 5+ peers | All discover each other; connection pool respected; no crashes |
| Battery saver | Reduced scan frequency confirmed in debug logs |
| Mesh relay | Message reaches peer via intermediate node (requires 3 devices) |

---

## End-to-End Encryption

### Protocol

Anchor uses **Noise_XK** — a 3-message handshake that gives mutual authentication (receiver's static key is known ahead of time from BLE/LAN profile exchange) plus forward secrecy via ephemeral X25519 key pairs.

```
Initiator (I)                   Responder (R)
     |                                  |
     |-- msg1: e, es ------------------>|   (I's ephemeral key + encrypt with R's static key)
     |<-- msg2: e, ee, se --------------|   (R's ephemeral key + two shared secrets)
     |-- msg3: s, se ------------------>|   (I's static key, authenticated)
     |                                  |
     |  Both derive identical session keys (send_k, recv_k)
     |  All subsequent messages use XChaCha20-Poly1305
```

- **Session keys**: ephemeral, in-memory only — forward secrecy per BLE/LAN connection
- **Nonces**: 24-byte random (XChaCha20 keyspace: collision probability negligible)
- **AEAD**: Poly1305 authenticates every message; tampered packets are silently dropped

### Key Files

| File | Purpose |
|---|---|
| `lib/services/encryption/encryption_service.dart` | Key gen/storage, session management, handshake lifecycle |
| `lib/services/encryption/noise_handshake.dart` | Pure Noise_XK state machine (`NoiseHandshakeProcessor`) |
| `lib/services/encryption/encryption_models.dart` | `NoiseSession`, `EncryptedPayload`, `HandshakeResult`, `HandshakeMessageOut` |
| `lib/services/transport/transport_manager.dart` | Routes inbound and outbound handshake messages across BLE and LAN transports |

### Key Exchange

**BLE**: The device's X25519 public key is serialized as `pk` in the `fff1` GATT characteristic (JSON field alongside `userId`, `name`, etc.). It is read during every GATT profile read and passed through `DiscoveredPeer.publicKeyHex`.

**LAN**: The public key is included as `pk` in the `anchor_hello` UDP beacon. `TransportManager.broadcastProfile()` injects the key from `EncryptionService` into `BroadcastPayload` before forwarding to LAN and Wi-Fi Aware transports.

**Storage**: `TransportManager` calls `encryptionService.storePeerPublicKey(canonicalId, pk)` whenever a peer's key arrives (from either transport). Keys are persisted in the `peer_public_keys` DB table (schema v9).

### Canonical Peer IDs

E2EE sessions are keyed by **canonical peer ID** — the conversation's `peerId` field:
- LAN-primary peers: their LAN UUID (from UDP beacon)
- BLE-only peers: their BLE device ID

`TransportManager` maintains `_peerIdAlias[bleId] = lanId` and `_bleIdForCanonical[lanId] = bleId` maps so handshake messages can be translated and routed to the correct transport regardless of which ID the peer was discovered under.

### Handshake Routing (TransportManager)

`TransportManager._subscribeToHandshakeRouting()` wires up the full handshake pipeline:

```
BLE noiseHandshakeStream  ──┐
                             ├──► _processIncomingHandshake()
LAN noiseHandshakeStream  ──┘       │
                                    ▼
                        encryptionService.processHandshakeMessage(canonicalId, step, payload)
                                    │
                             (on step 3 complete)
                                    ▼
                        E2eeSessionEstablished event → ChatBloc

outboundHandshakeStream  ──────► _routeOutboundHandshake()
                                    │
                         ┌──────────┴──────────┐
                     LAN transport?         BLE transport?
                         │                       │
              lanService.sendHandshakeMessage  bleService.sendHandshakeMessage(bleId)
```

### Wire Formats

**Handshake message** (BLE fff3 / LAN TCP frame):
```json
{"type": "noise_hs", "step": 1, "payload": "<base64>", "sender_id": "..."}
```

**Encrypted chat message** (v=1 signals ciphertext):
```json
{"type": "message", "sender_id": "...", "message_type": 0, "message_id": "...",
 "timestamp": "...", "v": 1, "n": "<24-byte nonce base64>", "c": "<ciphertext+tag base64>"}
```
Inner plaintext (encrypted, JSON):
```json
{"content": "hello", "reply_to_id": null}
```

Messages without `v` or with `v=0` are treated as plaintext (backward compatibility).

### UI Indicators

- Chat header: green "🔒 End-to-end encrypted" when `ChatState.isE2eeActive`
- Chat header: spinner + "Securing…" while `ChatState.isE2eeHandshaking` (input disabled)
- Message bubble: green 🔒 icon when `ReceivedMessage.isEncrypted = true`
- Users **cannot send messages** before a session is established (enforced in ChatBloc)

### Security Properties

| Property | Detail |
|---|---|
| Private key storage | `flutter_secure_storage` (iOS Keychain / Android Keystore); never in DB or logs |
| Session key storage | In-memory only; cleared on `dispose()` |
| Forward secrecy | Ephemeral DH per session; session compromise doesn't reveal past messages |
| Authentication | Poly1305 AEAD tag on every message; tampered messages dropped silently |
| Nonce | 24-byte random (XChaCha20); collision probability negligible |

---

## Future Enhancements (Planned)

| Feature | Notes |
|---|---|
| Group chat | Broadcast messages to multiple peers; group formation via QR/event code |
| Voice messages | Record, compress, chunk, transfer over BLE or Wi-Fi Direct |
| Photo albums | Multiple photos per message; gallery view |
| Event codes | Organiser-generated code to scope discovery to event attendees |
| Concurrent Wi-Fi Direct transfers | Support multiple simultaneous photo transfers |

---

## References

- [bluetooth_low_energy pub.dev](https://pub.dev/packages/bluetooth_low_energy)
- [Drift (SQLite) Documentation](https://drift.simonbinder.eu/)
- [Flutter Bloc Documentation](https://bloclibrary.dev/)
- [BLE GATT Specification](https://www.bluetooth.com/specifications/gatt/)
- [iOS Core Bluetooth Guide](https://developer.apple.com/documentation/corebluetooth)
- [Android BLE Guide](https://developer.android.com/guide/topics/connectivity/bluetooth/ble-overview)
