# Anchor ⚓

An offline-first proximity chat app for gay cruises, festivals, beaches, and events — no internet required.

## Overview

Anchor solves the connectivity problem at gay cruises and LGBTQ+ festivals where internet is expensive, unreliable, or simply unavailable. Using Bluetooth Low Energy (BLE), users can discover nearby profiles, chat one-to-one, and share photos — entirely without servers, accounts, or an internet connection.

Designed with privacy first: no registration, no cloud sync, all data stays on your device.

## Features

### Implemented

- **Offline Profile Discovery** — BLE mesh scanning surfaces nearby users sorted by RSSI signal strength
- **Discovery Grid** — proximity-sorted grid view; users closest to you appear first
- **1:1 Chat** — real-time text messaging directly between devices over BLE GATT
- **Thumbnail-First Photo Flow** — primary thumbnail (10–30 KB) broadcast with every profile; full photos fetched on-demand with explicit receiver consent
- **Photo Consent Flow** — sender offers a preview; receiver accepts before the full photo is transferred
- **NSFW Detection** — primary photo is screened before being broadcast over BLE; blocked photos are flagged in-app without transmitting
- **Profile: Position & Interests (ID-mapped)** — position and interests stored as integer IDs, not free text, keeping broadcast payload small and consistent
- **Drop Anchor ⚓** — quick interest signal sent to a nearby peer (planned; infrastructure in place)
- **BLE Mesh Relay** — TTL-based message flooding through connected peers for extended reach; no store-and-forward for relayed messages (direct peers only)
- **Block Users Locally** — full control over who can reach you; blocking is stored on-device only
- **Privacy-First** — no servers, no accounts, no analytics; delete the app to erase all data

### Planned

- End-to-end encryption (public key exchange during discovery)
- Group chat / broadcast rooms
- Voice messages
- Photo albums (multiple photos per message)
- Event codes for organizers to scope discovery to attendees

## Technology Stack

| Layer | Technology |
|---|---|
| Framework | Flutter (Dart) |
| BLE | `bluetooth_low_energy` (central + peripheral) |
| Local Database | Drift (SQLite, type-safe) |
| State Management | Bloc / Cubit |
| Dependency Injection | GetIt |
| Image Handling | `image_picker`, `image_compression_flutter` |
| NSFW Detection | `nsfw_detector_flutter` |
| Notifications | `flutter_local_notifications` |

## Getting Started

### Prerequisites

- Flutter SDK 3.10.0 or higher (see `.fvmrc` for pinned FVM version)
- Xcode 14+ (iOS development)
- Android Studio (Android development)
- **Physical devices required** — BLE does not function in simulators or emulators
- **Minimum 2 devices** to test discovery and messaging

### Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/anchor.git
cd anchor

# Install dependencies
flutter pub get

# iOS: install CocoaPods dependencies
cd ios && pod install && cd ..

# Regenerate Drift database code (only needed after schema changes)
dart run build_runner build --delete-conflicting-outputs

# Run on a physical device
flutter run
```

### Platform Setup

**iOS Requirements**
- Minimum OS version: iOS 14.0
- Required `Info.plist` keys (already configured):
  - `NSBluetoothAlwaysUsageDescription`
  - `NSBluetoothPeripheralUsageDescription`
  - `NSLocationWhenInUseUsageDescription`
- Background modes: `bluetooth-central`, `bluetooth-peripheral`
- **Important**: On iOS, BLE discovery requires the app to be in the foreground. Inform users of this limitation during onboarding.

**Android Requirements**
- Minimum SDK: API 26 (Android 8.0)
- Permissions configured in `AndroidManifest.xml`:
  - `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE` (Android 12+)
  - `ACCESS_FINE_LOCATION` (required for BLE scan)
  - `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`
- A persistent foreground service maintains BLE scanning in the background.

## How It Works

### First-Time Setup

1. Launch the app and complete onboarding
2. Create your profile: nickname, age, position (from a fixed list), interests (from a fixed list), and primary photo
3. Primary photo is screened for NSFW content before being allowed to broadcast
4. Grant Bluetooth and Location permissions when prompted
5. Your profile begins advertising automatically via BLE

### Discovering Nearby Users

1. Open the Discovery screen
2. Nearby users appear in a proximity-sorted grid (closest RSSI first)
3. Tap any profile to view details and start a chat

### Messaging

1. Messages are sent directly over BLE GATT — no relay, no server
2. Text messages deliver in 2–3 seconds when both devices are in range
3. If a peer goes out of range, messages are not queued (no store-and-forward for direct messages in v1)
4. Photos require explicit receiver consent before transfer begins

### Privacy Controls

- Block any user from their profile screen; blocked peers are invisible to you and cannot message you
- All data is stored locally — nothing is sent to any server
- Delete the app to permanently remove all data

## Architecture

```
lib/
├── core/              # App-wide utilities, theme, routing, constants
├── data/              # Drift database schema, repositories
├── services/
│   ├── ble/           # BLE service (central + peripheral via bluetooth_low_energy)
│   ├── image_service.dart
│   ├── nsfw_detection_service.dart
│   └── notification_service.dart
└── features/
    ├── profile/       # Profile creation, editing, photo management
    ├── discovery/     # BLE peer grid, filtering, anchor drops
    ├── chat/          # 1:1 messaging, photo consent flow
    ├── onboarding/
    ├── settings/
    └── home/
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed technical documentation.

## Current Limitations

### Platform

| Limitation | Detail |
|---|---|
| iOS background discovery | Apple restricts BLE scanning when the app is backgrounded; users must keep the app in the foreground |
| Android background | Works via foreground service, but shows a persistent notification |
| BLE range | 10–30 metres line-of-sight; metal bulkheads (cruise ships) and crowded RF environments reduce range |
| iOS connection limit | ~8–10 concurrent BLE connections |
| Android connection limit | 20–50 concurrent BLE connections (device-dependent) |

### Messaging

| Limitation | Detail |
|---|---|
| No store-and-forward | If a peer goes out of range before a message is delivered, the message is not queued or retried |
| Photo relay | Full photos are only transferred direct peer-to-peer; multi-hop relay for photos is not supported |
| Photo transfer speed | ~30–60 seconds for a 200 KB photo over BLE |

### Environment

- Metal cruise ship hulls can reduce BLE signal range significantly
- High BLE device density (50–100+ users) may cause scan competition; the app uses adaptive scanning to compensate
- Devices must be within range simultaneously for message delivery

## Privacy & Security

- **Local-only**: All data stored in SQLite on-device via Drift; no network calls
- **No accounts**: No registration, email, or authentication required
- **Minimal broadcast**: Only nickname, age, position ID, interest IDs, and a ≤30 KB thumbnail are broadcast
- **NSFW gate**: Primary photos are screened locally before being allowed to broadcast
- **Consent-based photos**: Full photo transfer requires explicit receiver acceptance
- **User blocking**: Enforced locally; blocked users cannot discover or message you
- **No encryption** (v1): BLE GATT messages are unencrypted; E2E encryption is planned for a future release

## Testing

> **BLE testing requires physical devices.** Simulators and emulators cannot use Bluetooth hardware.

### Basic Test Scenarios

| Scenario | Expected Result |
|---|---|
| Discovery — 2 devices | Both appear in each other's grid within 10 seconds |
| Text message | Delivers in 2–3 seconds when in range |
| Photo consent flow | Sender offers preview; receiver accepts; full photo transfers |
| NSFW photo | Blocked before broadcast; flagged in profile editor |
| Permissions denied | Clear error with Settings deep-link |
| Multiple peers (5+) | All discover each other; no crashes; connection pool respected |

See [BLE_IMPLEMENTATION.md](BLE_IMPLEMENTATION.md) for detailed BLE testing guidance.

## Development Status

### Completed

- Profile creation and management (nickname, age, position, interests, photos)
- BLE central + peripheral via `bluetooth_low_energy`
- Discovery grid with RSSI-based proximity sorting
- 1:1 text messaging over GATT
- Thumbnail-first photo broadcast (10–30 KB primary thumbnail)
- Full photo fetch on-demand with consent flow
- NSFW detection before broadcasting primary photo
- Drop Anchor ⚓ signal (infrastructure and BLE events ready)
- Mesh relay with TTL-based flooding (no store-and-forward for relayed messages)
- Local user blocking
- Battery saver mode (adaptive scan intervals)
- Connection pooling (max 5 concurrent)
- Onboarding with iOS background limitation disclosure
- Settings screen with debug menu

### In Progress / Planned

- Drop Anchor UI completion
- End-to-end encryption
- Group chat
- Voice messages
- Photo albums
- Event codes for organizers

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for:
- Development setup
- Coding standards
- Testing requirements
- Pull request process

## License

[License TBD]

## Acknowledgments

- Built for the LGBTQ+ community by people who use it
- Inspired by real connectivity challenges on gay cruises and festivals

---

**Made for the community, by the community** 🏳️‍🌈⚓
