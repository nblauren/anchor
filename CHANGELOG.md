# Changelog

All notable changes to Anchor are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

### Added
- Store-and-forward for direct messages (queue when peer out of range across sessions)

---

## [1.1.0] — 2026-03-12

### Added
- **Wi-Fi Direct photo transfer**: High-speed photo transfer using `flutter_nearby_connections_plus` (Google Nearby Connections API / Multipeer Connectivity). Photos transfer in < 1 second over Wi-Fi Direct vs. ~3 min over BLE. Automatic fallback to BLE chunking if Wi-Fi Direct is unavailable or times out.
- **Non-blocking message send queue**: Text and photo messages are saved to DB and shown in UI immediately. Actual BLE/Wi-Fi sends happen in the background via a FIFO queue. Users can type multiple messages without waiting for delivery.
- **`RegisterPendingOutgoingPhoto` event**: Background photo send helper registers pending photos through the Bloc event pipeline.
- **`_transferToBleId` mapping**: Resolves Nearby Connections userIds to BLE device IDs in `ChatBloc`, preventing incorrect user creation when receiving photos via Wi-Fi Direct.
- **Drop Anchor ⚓ complete UI**: Full anchor drop UI with history screen, audio feedback, and send/receive notifications.

### Changed
- **Photo consent flow simplified**: Sender no longer sends thumbnail data over BLE — just a lightweight notification. Receiver sees "Photo — Tap to download" and requests the full photo.
- **Send button never blocks**: Removed `ChatStatus.sending` guard from chat input. Send and photo buttons are always active.
- **Keyboard stays open**: After sending a text message, keyboard remains open for rapid follow-up. Uses `onEditingComplete` instead of `onSubmitted` to prevent default unfocus. Tapping the message list dismisses the keyboard.
- **NearbyService reinitializes between transfers**: `_stopNearby()` resets `_initialized` flag so each transfer gets a fresh native init, fixing second-transfer failures.
- **Peripheral state tracking**: Added `_peripheralPoweredOn` flag tracked from stream events instead of relying on potentially stale `_peripheral.state` getter, fixing "Peripheral not ready (unknown)" errors.

### Fixed
- **Wi-Fi Direct ID mismatch**: `_onNearbyPayloadCompleted` now uses BLE device ID (via `_transferToBleId` map) instead of sender's Nearby userId for conversation lookup, preventing ghost user creation.
- **Second Wi-Fi Direct transfer failing**: NearbyService native layer now fully reinitializes between transfer sessions.
- **Sender tearing down too fast**: Added 3-second delay after `transfer_complete` before `_stopNearby()` to let native message channel flush. Added 50ms delay between chunks to prevent channel saturation.
- **BLE peripheral not advertising**: Fixed race condition where `_onPeripheralStateChanged` required `_startCalled` to retry pending payloads — now retries whenever `_pendingPayload` exists.
- **Bloc event queue blocking**: Photo transfer and BLE send no longer block the ChatBloc event queue. All sends use fire-and-forget pattern with status updates dispatched as events.

---

## [1.0.0] — 2026-03

### Added
- **Thumbnail-first photo flow**: Primary profile thumbnail (10–30 KB JPEG) is broadcast with every BLE profile advertisement via characteristic `fff2`. Full photos are fetched separately, on-demand.
- **Photo consent flow**: Full photo transfer now requires explicit receiver acceptance. Sender broadcasts a thumbnail preview (`photoPreview` message type); receiver accepts or declines; full transfer only begins after acceptance.
- **NSFW detection before broadcast**: Primary photo is screened by an on-device classifier (`nsfw_detector_flutter`) before being allowed into the BLE broadcast. Blocked photos are flagged in the profile editor without being transmitted.
- **ID-mapped position and interests**: Position and interests are stored and broadcast as integer IDs mapped to a fixed label set (`profile_constants.dart`). Free-text fields are not broadcast, keeping payload size small and preventing mesh injection of arbitrary text.
- **`fff4` full-photo characteristic**: Serves all profile photo thumbnails on-demand when a central subscribes, supporting full profile view without constantly broadcasting large payloads.
- **TTL-based mesh relay**: Text messages carry a `ttl` field (default 3). Intermediate nodes decrement TTL and forward to all currently-connected peers (excluding sender). No store-and-forward: relay is limited to currently-connected peers only.
- **Deduplication in relay**: Nodes track recently-seen `messageId` values to prevent duplicate relay delivery.
- **High-density adaptive scanning**: When ≥15 peers are visible, scan pause increases and relay probability is throttled to `0.65` to reduce mesh traffic congestion.
- **Battery saver mode**: User-toggled scan profile (2 s scan / 30 s pause) available in Settings.
- **Drop Anchor ⚓ signalling**: BLE event infrastructure for the "quick interest" feature; full UI completion is pending.
- **`AnchorDropRepository`**: Persists sent/received anchor drop history locally.
- **Onboarding iOS background disclosure**: Users are explicitly informed during onboarding that reliable BLE discovery requires the app to be in the foreground on iOS.

### Changed
- **BLE package**: Migrated from `flutter_blue_plus` to `bluetooth_low_energy` (central + peripheral in one package). Both `CentralManager` and `PeripheralManager` run simultaneously on each device, enabling true two-way discovery without platform channels.
- **Profile screen**: Position and interests now rendered from ID-to-label maps rather than raw strings.
- **Discovery grid**: Peers sorted by RSSI (closest first). Grid updates are debounced to prevent excessive redraws when many peers are visible.
- **BleConfig**: Added `meshTtl`, `photoChunkSize`, `highDensityPeerThreshold`, `highDensityScanPause`, `highDensityRelayProbability`, `batterySaverScanPause`, `maxThumbnailSize`, `maxPhotoSize`.

### Fixed
- Peripheral advertising now starts correctly on both iOS and Android using `PeripheralManager` from `bluetooth_low_energy`.
- Peer cards no longer show stale RSSI from previous scan cycles after a peer is lost and rediscovered.

### Architecture / Documentation
- `ARCHITECTURE.md` updated to reflect current mesh logic, photo flow, NSFW gate, ID-mapping rationale, and platform differences.
- `BLE_IMPLEMENTATION.md` (previously `FLUTTER_BLUE_PLUS_IMPLEMENTATION.md`) updated for `bluetooth_low_energy` API and current feature status.
- `README.md` updated with current feature list, accurate limitations, and corrected tech stack.
- `CONTRIBUTING.md` updated with BLE contribution guidelines and constraint reminders.

---

## [0.9.0] — 2025-01

### Added
- Initial BLE discovery and profile broadcast using `flutter_blue_plus`
- 1:1 text messaging over GATT (characteristic `fff3`)
- Local SQLite database via Drift (profile, peers, conversations, messages, blocked users)
- Profile creation: nickname, age, bio, photos (up to 4)
- Discovery grid with RSSI signal indicator
- User blocking (local)
- Onboarding and permissions flow
- Settings screen with debug menu (mock peers, log viewer, data clear)
- Connection pooling (max 5 concurrent, LRU eviction)
- `MockBleService` for unit/widget testing without hardware

---

[Unreleased]: https://github.com/yourusername/anchor/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/yourusername/anchor/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/yourusername/anchor/compare/v0.9.0...v1.0.0
[0.9.0]: https://github.com/yourusername/anchor/releases/tag/v0.9.0
