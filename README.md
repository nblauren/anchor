# Anchor

A fully offline dating and social discovery app for gay cruises and festivals using Bluetooth Low Energy.

## Overview

Anchor solves the connectivity problem at gay cruises and festivals where internet is weak, expensive, or nonexistent. Using Bluetooth Low Energy, users can discover nearby profiles, chat, and share photos—all without any internet connection.

## Features

- **Offline Profile Discovery** via Bluetooth (10-30 meter range)
- **Direct Peer-to-Peer Messaging** - no servers required
- **Photo Sharing** without internet (chunked transfer over BLE)
- **Privacy-Focused** - no servers, no accounts, everything stays local
- **Store-and-Forward** - messages queue and deliver when users reconnect
- **Block Users Locally** - full control over who can contact you
- **Built for LGBTQ+ Cruises** - designed for Atlantis, VACAYA, and festivals

## Technology Stack

- **Flutter** - Cross-platform mobile framework
- **Bluetooth Low Energy** via flutter_blue_plus
- **Drift** - Local SQLite database
- **Bloc** - State management pattern
- **Feature-Based Architecture** with Clean Architecture principles

## Getting Started

### Prerequisites

- Flutter SDK 3.10.0 or higher
- Xcode 14+ (for iOS development)
- Android Studio (for Android development)
- **Physical devices required** - BLE doesn't work in simulators/emulators
- **Minimum 2 devices** for testing discovery and messaging

### Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/anchor.git
cd anchor

# Get dependencies
flutter pub get

# iOS setup
cd ios && pod install && cd ..

# Run on physical device
flutter run
```

### Platform Setup

**iOS Requirements:**
- Minimum version: iOS 14.0
- Required Info.plist permissions already configured:
  - NSBluetoothAlwaysUsageDescription
  - NSBluetoothPeripheralUsageDescription
  - NSLocationWhenInUseUsageDescription
- **Important**: App must remain in foreground for reliable BLE discovery

**Android Requirements:**
- Minimum version: API 26 (Android 8.0)
- Required permissions already configured in AndroidManifest.xml:
  - BLUETOOTH, BLUETOOTH_SCAN, BLUETOOTH_CONNECT, BLUETOOTH_ADVERTISE
  - ACCESS_FINE_LOCATION
  - FOREGROUND_SERVICE
- Foreground service runs to maintain BLE scanning in background

## How to Use

### First Time Setup

1. Launch the app
2. Complete onboarding screens
3. Create your profile (name, age, bio, photos)
4. Grant Bluetooth and Location permissions when prompted
5. Your profile broadcasts automatically via Bluetooth

### Discovering Users

1. Open the Discovery screen (grid view)
2. Nearby users appear automatically within 10-30 meters
3. Tap a profile to view full details
4. Start a chat from their profile screen

### Messaging

1. Messages send instantly when users are in range (2-3 seconds)
2. If recipient is out of range, messages queue locally
3. Messages auto-deliver when you reconnect
4. Photo sharing: select photo, compresses automatically, sends in chunks

### Privacy Controls

1. Block users from their profile screen
2. Blocked users won't see you or message you
3. All data stays on your device—nothing syncs to servers
4. Delete the app to remove all your data permanently

## Architecture

### High-Level Structure

```
lib/
├── core/              # App-wide utilities, theme, constants
├── data/              # Database models and repositories
├── services/          # BLE, image, permissions, database
├── features/          # Feature modules (profile, discovery, chat)
│   ├── profile/
│   ├── discovery/
│   ├── chat/
│   ├── onboarding/
│   ├── settings/
│   └── home/
└── main.dart
```

### Key Components

- **BLE Service**: Direct peer-to-peer communication via flutter_blue_plus
- **Drift Database**: Local SQLite storage for profiles, messages, peers
- **Bloc Pattern**: State management for all features
- **Repository Layer**: Data access abstraction
- **Store-and-Forward**: Message queue for offline delivery

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed technical documentation.

## Known Limitations

### Platform Limitations

- **iOS**: Must stay in foreground for reliable discovery (Apple restriction)
- **Android**: Better background support but shows notification
- **Range**: 10-30 meters depending on obstacles (walls, crowds, metal)
- **Connection Limit**: iOS ~8-10 connections, Android 20-50

### BLE Limitations

- **Photo Transfer**: ~30-60 seconds for 200KB compressed photo
- **No Cloud Sync**: Everything is local—switch devices = start fresh
- **Discovery**: May take 5-10 seconds to discover nearby users

### Environment Considerations

- Metal bulkheads (cruise ships) can reduce range
- Crowded areas may have BLE interference
- Works best in clustered social spaces (pool decks, bars, dining areas)

## Privacy & Security

- **Local-Only**: All data stored on device, nothing sent to servers
- **No Accounts**: No registration, login, or authentication required
- **Minimal Broadcast**: Only name, age, bio, and thumbnail shared via BLE
- **Direct P2P**: Messages go directly between devices
- **User Control**: You decide what profile info to share
- **Block Functionality**: Block users locally at any time

## Contributing

We welcome contributions! See [CONTRIBUTING.md](CONTRIBUTING.md) for:
- How to report bugs
- How to suggest features
- How to submit pull requests
- Coding standards and best practices

## Testing

**⚠️ Important**: Must test on physical devices (BLE doesn't work on simulators)

### Basic Test Scenarios

1. **Profile Discovery**: 2 devices discover each other within 10 seconds
2. **Messaging**: Text message delivers in 2-3 seconds when in range
3. **Photo Transfer**: 100KB photo completes in under 60 seconds
4. **Out of Range**: Message queues when peer offline, delivers on reconnect
5. **Permissions**: Clear flow when permissions denied

See [FLUTTER_BLUE_PLUS_IMPLEMENTATION.md](FLUTTER_BLUE_PLUS_IMPLEMENTATION.md) for detailed testing guide.

## Development Status

### ✅ Completed

- Profile creation and management
- BLE discovery with flutter_blue_plus
- Direct peer-to-peer messaging
- Connection management and pooling
- Message status tracking
- Settings and debug screens
- Onboarding flow

### ⚠️ In Progress

- Photo transfer (chunking implementation needed)
- Message queue for store-and-forward
- Peripheral mode advertising (platform channel needed)
- Battery optimization tuning

### 📋 Future Enhancements

- End-to-end encryption
- Group chat
- Voice messages
- Photo albums
- Event codes for organizers

## License

[Choose appropriate license - MIT, GPL, etc.]

## Acknowledgments

- Built with love for the LGBTQ+ community
- Inspired by real connectivity challenges on gay cruises
- Special thanks to testers and early adopters

## Contact

- **Issues**: [GitHub Issues](https://github.com/yourusername/anchor/issues)
- **Discussions**: [GitHub Discussions](https://github.com/yourusername/anchor/discussions)
- **Email**: your.email@example.com

---

**Made for the community, by the community** 🏳️‍🌈⚓
