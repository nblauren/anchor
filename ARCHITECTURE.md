# Anchor Architecture

## Overview

Anchor is an offline-first, peer-to-peer social discovery app using Bluetooth Low Energy (BLE) for device discovery, messaging, and photo sharing—entirely without internet connectivity.

**Design Philosophy:**
- **Local-First**: All data stored on device, no servers required
- **Privacy by Design**: No accounts, no tracking, user controls all data
- **Resilient Communication**: Store-and-forward messaging for intermittent connectivity
- **Battery Conscious**: Adaptive scanning and connection pooling
- **Feature-Based**: Modular architecture for maintainability

## Architecture Pattern

Anchor follows **Clean Architecture** principles with a **Feature-Based** organization:

```
Presentation Layer (UI + Bloc)
        ↓
Domain Layer (Use Cases + Models)
        ↓
Data Layer (Repositories + Services)
```

### Key Principles

1. **Separation of Concerns**: Each layer has a single responsibility
2. **Dependency Inversion**: High-level modules don't depend on low-level modules
3. **Abstraction**: Services use interfaces for testability and flexibility
4. **Unidirectional Data Flow**: State flows down, events flow up (Bloc pattern)

## Project Structure

```
lib/
├── main.dart                    # App entry point
├── app.dart                     # MaterialApp setup, theme, providers
│
├── core/                        # App-wide utilities and shared code
│   ├── constants/               # App constants (UUIDs, timeouts, etc.)
│   ├── errors/                  # Error types and handling
│   │   └── app_error.dart      # AppError hierarchy (BleError, DatabaseError, etc.)
│   ├── routing/                 # Navigation and routing
│   │   └── app_shell.dart      # Main router (onboarding, permissions, home)
│   ├── screens/                 # Shared screens
│   │   └── splash_screen.dart  # Loading splash
│   ├── theme/                   # App-wide theming
│   │   └── app_theme.dart      # Dark theme, colors, text styles
│   ├── utils/                   # Helper utilities
│   │   └── logger.dart         # Logging utility
│   └── widgets/                 # Reusable UI components
│       ├── empty_state_widget.dart
│       ├── error_state_widget.dart
│       └── loading_widget.dart
│
├── data/                        # Data layer (persistence + repositories)
│   ├── database.dart            # Drift database definition
│   ├── database.g.dart          # Generated Drift code
│   └── repositories/            # Data access layer
│       ├── chat_repository.dart
│       ├── peer_repository.dart
│       └── profile_repository.dart
│
├── services/                    # Service layer (external integrations)
│   ├── database_service.dart   # Database initialization and management
│   ├── image_service.dart      # Photo selection, compression, storage
│   ├── ble/                    # Bluetooth Low Energy service
│   │   ├── ble.dart            # Module exports
│   │   ├── ble_config.dart     # BLE configuration
│   │   ├── ble_service_interface.dart  # Abstract BLE interface
│   │   ├── flutter_blue_plus_ble_service.dart  # Production BLE implementation
│   │   ├── mock_ble_service.dart               # Testing mock
│   │   ├── bridgefy_ble_service.dart           # Legacy (deprecated)
│   │   ├── ble_models.dart     # Data models (DiscoveredPeer, BleMessage)
│   │   ├── ble_status_bloc.dart        # BLE state management
│   │   ├── ble_connection_bloc.dart    # BLE lifecycle management
│   │   └── photo_chunker.dart  # Photo chunking for BLE transfer
│   └── permission_service.dart # Runtime permission requests
│
└── features/                    # Feature modules (self-contained)
    ├── profile/
    │   ├── bloc/                # State management
    │   │   ├── profile_bloc.dart
    │   │   ├── profile_event.dart
    │   │   └── profile_state.dart
    │   └── screens/             # UI screens
    │       ├── profile_setup_screen.dart
    │       └── profile_view_screen.dart
    │
    ├── discovery/
    │   ├── bloc/
    │   │   ├── discovery_bloc.dart
    │   │   ├── discovery_event.dart
    │   │   └── discovery_state.dart
    │   ├── screens/
    │   │   └── discovery_screen.dart
    │   └── widgets/
    │       ├── peer_card.dart
    │       └── peer_detail_screen.dart
    │
    ├── chat/
    │   ├── bloc/
    │   │   ├── chat_bloc.dart
    │   │   ├── chat_event.dart
    │   │   └── chat_state.dart
    │   ├── screens/
    │   │   ├── chat_list_screen.dart
    │   │   └── chat_detail_screen.dart
    │   └── widgets/
    │       ├── conversation_tile.dart
    │       └── message_bubble.dart
    │
    ├── onboarding/
    │   └── screens/
    │       ├── onboarding_screen.dart
    │       └── permissions_screen.dart
    │
    ├── settings/
    │   └── screens/
    │       ├── settings_screen.dart
    │       ├── blocked_users_screen.dart
    │       └── debug_menu_screen.dart
    │
    └── home/
        └── screens/
            └── home_screen.dart  # Bottom navigation shell
```

## Core Components

### 1. BLE Service Layer

**Purpose**: Direct peer-to-peer communication via Bluetooth Low Energy

**Interface**: `BleServiceInterface` (lib/services/ble/ble_service_interface.dart:1)

```dart
abstract class BleServiceInterface {
  Stream<DiscoveredPeer> get peerDiscovered;
  Stream<DiscoveredPeer> get peerLost;
  Stream<BleMessage> get messageReceived;
  Stream<BleConnectionStatus> get connectionStatus;

  Future<void> initialize();
  Future<void> startBroadcasting();
  Future<void> startScanning();
  Future<bool> sendMessage(String peerId, String message);
  Future<bool> sendPhoto(String peerId, Uint8List photoData, String messageId);
  Future<void> dispose();
}
```

**Production Implementation**: `FlutterBluePlusBleService` (lib/services/ble/flutter_blue_plus_ble_service.dart:1)

Key features:
- **Adapter State Monitoring**: Real-time Bluetooth on/off/unavailable tracking
- **Runtime Permissions**: Handles Android 12+ and iOS BLE permissions
- **Device Discovery**: Scans for devices advertising Anchor's service UUID
- **GATT Connections**: Direct device-to-device connections for profile reading
- **Connection Pooling**: Max 5 concurrent connections, 30s timeout, 60s idle disconnect
- **Profile Discovery**: Reads peer metadata (name, age, bio, thumbnail)
- **Real-Time Messaging**: Text messages over GATT messaging characteristic
- **Peer Tracking**: Automatic peer timeout and "lost peer" detection (5 min)

**Testing Implementation**: `MockBleService` for unit tests without physical devices

### 2. Data Layer

**Database**: Drift (SQLite) with type-safe queries

**Tables**:
- `user_profile`: User's own profile (single row)
- `profile_photos`: User's photo gallery
- `discovered_peers`: Cached peer profiles from BLE discovery
- `conversations`: Chat conversations with peers
- `messages`: Chat messages (text and photo)
- `blocked_users`: Blocked peer IDs

**Repositories**: Abstract data access, hide implementation details

- **ProfileRepository** (lib/data/repositories/profile_repository.dart:1)
  - CRUD for user profile
  - Photo management
  - Profile validation

- **PeerRepository** (lib/data/repositories/peer_repository.dart:1)
  - Store discovered peers
  - Block/unblock users
  - Query peer details

- **ChatRepository** (lib/data/repositories/chat_repository.dart:1)
  - Create/retrieve conversations
  - Send/receive messages
  - Message status updates
  - Unread counts

### 3. State Management (Bloc Pattern)

**Why Bloc**:
- Separation of business logic from UI
- Predictable state transitions
- Easy testing
- Built-in debugging tools

**Key Blocs**:

**ProfileBloc** (lib/features/profile/bloc/profile_bloc.dart:1)
- Manages user's own profile
- Events: LoadProfile, UpdateProfile, AddPhoto, DeletePhoto
- States: ProfileInitial, ProfileLoading, ProfileLoaded, ProfileError

**DiscoveryBloc** (lib/features/discovery/bloc/discovery_bloc.dart:1)
- Manages peer discovery and filtering
- Listens to BLE service's peerDiscovered/peerLost streams
- Filters out blocked users
- Events: StartDiscovery, StopDiscovery, PeerDiscovered, PeerLost
- States: DiscoveryInitial, DiscoveryActive, DiscoveryError

**ChatBloc** (lib/features/chat/bloc/chat_bloc.dart:1)
- Manages conversations and messages
- Listens to BLE service's messageReceived stream
- Handles send/receive/status updates
- Events: LoadConversations, LoadMessages, SendMessage, ReceiveMessage
- States: ChatInitial, ChatLoading, ChatLoaded, ChatError

**BleStatusBloc** (lib/services/ble/ble_status_bloc.dart:1)
- Tracks BLE adapter state (on/off/unavailable)
- Tracks permission status
- Events: CheckBleStatus, RequestPermissions
- States: BleStatusInitial, BleAvailable, BleUnavailable, BlePermissionDenied

**BleConnectionBloc** (lib/services/ble/ble_connection_bloc.dart:1)
- Manages BLE service lifecycle (initialize, start/stop scanning, broadcasting)
- Events: InitializeBleConnection, StartScanning, StopScanning
- States: BleConnectionInitial, BleConnectionInitializing, BleConnectionActive, BleConnectionError

### 4. Feature Modules

Each feature is self-contained with its own bloc, screens, and widgets.

**Profile Feature** (lib/features/profile/):
- Create and edit user profile
- Add/remove photos (up to 6)
- View own profile preview

**Discovery Feature** (lib/features/discovery/):
- Grid view of nearby peers
- Real-time updates as peers discovered/lost
- RSSI signal strength indicator
- Tap to view full peer profile
- Start chat from peer detail screen

**Chat Feature** (lib/features/chat/):
- List of conversations with unread counts
- Real-time chat with text messages
- Photo sharing support
- Message status indicators (sending, sent, delivered)
- "Out of range" warnings

**Onboarding Feature** (lib/features/onboarding/):
- 3-page intro explaining app features
- Permissions explanation screen
- Guides user through first-time setup

**Settings Feature** (lib/features/settings/):
- Edit profile
- View blocked users
- Clear all data
- Debug menu (mock data, logs, BLE status)

**Home Feature** (lib/features/home/):
- Bottom navigation shell
- Switches between Discovery, Chat List, Profile screens

## BLE Communication Protocol

### Service UUIDs

```
Main Service:         0000fff0-0000-1000-8000-00805f9b34fb

Characteristics:
  Profile Metadata:   0000fff1-0000-1000-8000-00805f9b34fb (READ, NOTIFY)
  Thumbnail Data:     0000fff2-0000-1000-8000-00805f9b34fb (READ)
  Messaging:          0000fff3-0000-1000-8000-00805f9b34fb (WRITE, NOTIFY)
```

### Discovery Protocol

1. **Device A starts scanning** for devices advertising `0000fff0-...` service
2. **Device B advertises** the service UUID (peripheral mode)
3. **Device A discovers Device B** and initiates GATT connection
4. **Device A reads** Profile Metadata characteristic:
   ```json
   {
     "user_id": "uuid-here",
     "name": "John",
     "age": 28,
     "bio": "Hey there!"
   }
   ```
5. **Device A reads** Thumbnail Data characteristic (JPEG bytes)
6. **Device A emits** `DiscoveredPeer` to `peerDiscovered` stream
7. **Discovery Bloc** receives peer, filters blocked users, updates UI
8. **Device A disconnects** after 60s of idle time (or keeps open for active chat)

### Messaging Protocol

1. **User sends message** in UI → ChatBloc emits `SendMessage` event
2. **ChatBloc** calls `bleService.sendMessage(peerId, message)`
3. **BLE Service** checks if peer connected:
   - If connected: write to Messaging characteristic immediately
   - If not connected: **queue message for later delivery** (store-and-forward)
4. **Device B subscribes** to Messaging characteristic notifications
5. **Device B receives** message bytes → decodes JSON:
   ```json
   {
     "message_id": "uuid",
     "sender_id": "uuid",
     "timestamp": "2024-01-15T10:30:00Z",
     "type": "text",
     "content": "Hello!"
   }
   ```
6. **Device B emits** `BleMessage` to `messageReceived` stream
7. **ChatBloc** receives message → saves to database → updates UI

### Photo Transfer Protocol

**Status**: ⚠️ Not yet implemented (marked as TODO)

**Planned Implementation**:
1. **Negotiate MTU** with peer device (typically 185 bytes on iOS, 500 bytes on Android)
2. **Compress photo** to ~200KB JPEG (ImageService)
3. **Chunk photo** into MTU-sized pieces using PhotoChunker
4. **Send chunks sequentially** over Messaging characteristic
5. **Wait for ACK** after each chunk
6. **Emit progress** updates via stream
7. **Reassemble** on receiver side
8. **Handle errors**: Retry failed chunks, resume on reconnection

### Connection Management

**Connection Pool**:
- **Max Connections**: 5 concurrent (configurable in BleConfig)
- **Connection Timeout**: 30 seconds
- **Idle Timeout**: 60 seconds of no activity
- **Eviction Policy**: Least Recently Used (LRU)

**Priority System**:
1. **Active chats**: Keep connected if messages being exchanged
2. **Recently viewed**: Keep connected for 60s after viewing profile
3. **Discovery**: Connect only to read profile, then disconnect

**Peer Timeout**:
- If no GATT activity for **5 minutes**, emit `peerLost` event
- UI shows peer as "Out of Range"
- Messages sent after this point are **queued** for later delivery

### Store-and-Forward (Message Queue)

**Status**: ⚠️ Not yet implemented (planned)

**Planned Implementation**:
1. Add `pending_messages` table to Drift schema:
   ```dart
   class PendingMessages extends Table {
     TextColumn get messageId => text()();
     TextColumn get peerId => text()();
     TextColumn get payload => text()();
     DateTimeColumn get createdAt => dateTime()();
     IntColumn get retryCount => integer().withDefault(const Constant(0))();
   }
   ```
2. When `sendMessage()` fails (peer offline):
   - Insert into `pending_messages` table
   - UI shows "Queued" status
3. When peer rediscovered (`peerDiscovered` event):
   - Query `pending_messages` for that peer
   - Attempt delivery for each queued message
   - Delete on success, increment `retryCount` on failure
4. **Retry Strategy**: Exponential backoff (1s, 2s, 4s, 8s)
5. **Expiration**: Delete messages after 3 failed retries OR 24 hours

## Battery Optimization

### Adaptive Scanning Strategy

**Default Mode** (BleConfig):
- Scan for 3 seconds
- Pause for 5 seconds
- Repeat

**Battery Saver Mode** (configurable in Settings):
- Scan for 2 seconds
- Pause for 15 seconds
- Repeat

**Active Chat Mode**:
- Continuous scanning when chat screen open
- Ensures real-time message delivery

### Connection Pooling

- Limit to **5 concurrent connections** (iOS ~8 max, Android ~20-50 max)
- Aggressive LRU eviction to prevent battery drain
- Disconnect idle connections after 60 seconds

### Background Behavior

**iOS**:
- **Very limited** background BLE scanning (Apple restriction)
- App must be in foreground for reliable discovery
- Background notifications not supported for this use case

**Android**:
- **Foreground service** runs to maintain scanning in background
- Shows persistent notification (required by Android)
- Better background support but still drains battery

## Platform Differences

### iOS

**Minimum Version**: iOS 14.0

**Permissions** (Info.plist):
- NSBluetoothAlwaysUsageDescription
- NSBluetoothPeripheralUsageDescription
- NSLocationWhenInUseUsageDescription (required even though GPS not used)

**Background Modes**:
- bluetooth-central
- bluetooth-peripheral

**Limitations**:
- **Connection Limit**: ~8-10 devices max
- **MTU**: Typically 185 bytes
- **Background Discovery**: Severely limited, app must be in foreground
- **Peripheral Mode**: Advertising stops when app backgrounded

### Android

**Minimum Version**: API 26 (Android 8.0)

**Permissions** (AndroidManifest.xml):
- BLUETOOTH_SCAN (Android 12+)
- BLUETOOTH_CONNECT (Android 12+)
- BLUETOOTH_ADVERTISE (Android 12+)
- ACCESS_FINE_LOCATION (required for BLE scanning)
- FOREGROUND_SERVICE
- FOREGROUND_SERVICE_CONNECTED_DEVICE

**Features**:
- android.hardware.bluetooth_le (required)

**Limitations**:
- **Connection Limit**: 20-50 depending on device
- **MTU**: Often negotiable up to 512 bytes
- **Foreground Service**: Required for background scanning, shows notification

## Security & Privacy

### Data Storage

- **All data local**: SQLite database on device
- **No cloud sync**: Nothing leaves the device via internet
- **No accounts**: No authentication, registration, or servers
- **Ephemeral**: Delete app = delete all data permanently

### BLE Privacy

- **Minimal broadcast**: Only name, age, bio, and thumbnail shared over BLE
- **No location tracking**: BLE doesn't reveal GPS coordinates
- **User control**: User decides what profile info to share
- **Block functionality**: Blocked users can't see you or message you

### Message Security

**Current** (v1.0):
- Messages sent **unencrypted** over BLE
- Anyone in range with Anchor could theoretically intercept

**Future** (v2.0 - planned):
- **End-to-end encryption** using public key cryptography
- Each device generates RSA key pair on first launch
- Public keys exchanged during discovery
- Messages encrypted with recipient's public key

### Platform Security

**iOS**:
- App Sandbox prevents access to other apps' data
- Keychain for secure credential storage (if needed in future)

**Android**:
- App-private storage protected by Android permissions
- Encrypted storage available for sensitive data (if needed)

## Testing Strategy

### Unit Tests

**Repositories**:
- Test CRUD operations with in-memory Drift database
- Verify constraints and foreign keys
- Test edge cases (null values, duplicates, etc.)

**Blocs**:
- Test state transitions for all events
- Mock repositories and services
- Verify stream emissions
- Test error handling

**Services**:
- Use MockBleService to test without physical devices
- Test permission request flows
- Test error scenarios (Bluetooth off, permissions denied)

### Integration Tests

**BLE Discovery Flow**:
1. Initialize BLE service
2. Start scanning
3. Mock peer discovered event
4. Verify DiscoveryBloc receives peer
5. Verify peer saved to database
6. Verify UI updates

**Messaging Flow**:
1. Discover peer
2. Open chat
3. Send message
4. Verify message saved to database
5. Mock message received event
6. Verify UI updates

### Device Testing

**⚠️ Required**: BLE doesn't work on simulators/emulators

**Minimum Setup**:
- 2 physical devices (iOS or Android)
- Anchor app installed on both
- Bluetooth enabled on both
- Devices within 10-30 meters

**Test Scenarios**:
1. **Basic Discovery**: Devices discover each other within 10 seconds
2. **Messaging**: Text message delivers in 2-3 seconds when in range
3. **Photo Transfer**: 100KB photo completes in <60 seconds (when implemented)
4. **Out of Range**: Message queues when peer offline, delivers on reconnect (when implemented)
5. **Permissions**: Clear flow when permissions denied, app recovers when granted
6. **Multiple Peers**: 5+ devices discover each other without crashes
7. **Connection Limits**: Only 5 concurrent connections, LRU eviction works
8. **Battery Drain**: <10% per hour of active use (target)

### Debugging

**Enable verbose logging** in debug builds:

```dart
// In flutter_blue_plus_ble_service.dart
Logger.info('FlutterBluePlusBleService: Discovered device ${device.platformName}', 'BLE');
```

**Watch for key log messages**:
- "Discovered device" - Successful scan results
- "Connected to" - GATT connection established
- "Discovered peer" - Profile read successfully
- "Message sent successfully" - Messaging working
- "Lost peer" - Timeout triggered

**Debug Menu** (lib/features/settings/screens/debug_menu_screen.dart:1):
- BLE status display
- Add mock peers/messages
- View logs
- Database stats
- Clear data

## Performance Considerations

### Discovery Performance

- **Discovery Time**: 5-10 seconds typical
- **RSSI Range**: -30 (very close) to -90 (far away)
- **Scan Efficiency**: 3s scan, 5s pause = 37.5% duty cycle
- **Peer Limit**: Designed for 10-50 nearby peers

### Messaging Performance

- **Message Latency**: 2-3 seconds when connected
- **Connection Setup**: 3-5 seconds first time
- **Throughput**: ~500 bytes/second (varies by MTU)
- **Queue Depth**: Unlimited (stored in SQLite)

### Memory Usage

- **Peer Profiles**: ~10KB per peer (with thumbnail)
- **Messages**: ~500 bytes per text message
- **Photos**: ~200KB compressed per photo
- **Database Size**: ~1MB per 100 messages with photos

### Battery Usage

**Target**: <10% per hour of active use

**Factors**:
- Scanning duty cycle (37.5% default)
- Number of active connections (max 5)
- Screen on time
- Photo transfers

### Cruise Ship Environment

**Challenges**:
1. **Metal Interference**: Ship's steel structure degrades BLE signal
2. **Peer Density**: 50-100+ passengers in range
3. **Movement**: Frequent connection loss/regain as people move
4. **Battery Life**: Critical - passengers won't charge every few hours

**Optimizations**:
- Aggressive connection pooling (keep only active chats)
- Battery saver mode option (scan 2s, pause 15s)
- Store-and-forward is ESSENTIAL (don't lose messages)
- UI feedback for "out of range" vs "offline permanently"

## Future Enhancements

### Phase 2 Features

1. **Photo Transfer** (~4-6 hours)
   - Chunking and reassembly
   - Progress tracking
   - Resume on reconnection

2. **Message Queue** (~3-4 hours)
   - PendingMessages table
   - Store-and-forward logic
   - Retry with exponential backoff

3. **Peripheral Mode** (timing TBD)
   - Platform channels for native advertising
   - iOS: BlePeripheralManager.swift
   - Android: BlePeripheralService.kt

### Phase 3 Features

4. **End-to-End Encryption**
   - RSA key pair generation
   - Public key exchange during discovery
   - Message encryption/decryption

5. **Group Chat**
   - Broadcast messages to multiple peers
   - Group discovery via QR codes

6. **Voice Messages**
   - Record audio clips
   - Compress and chunk for BLE transfer

7. **Photo Albums**
   - Share multiple photos in one message
   - Photo gallery view in chat

8. **Event Codes**
   - Organizers generate event code
   - Users enter code to filter peers to event attendees only

## Dependency Injection

**GetIt** for service locator pattern (lib/injection.dart:1)

```dart
final getIt = GetIt.instance;

void setupDependencies(BleConfig config) {
  // Services
  getIt.registerLazySingleton<DatabaseService>(() => DatabaseService());
  getIt.registerLazySingleton<ImageService>(() => ImageService());

  // BLE Service (with config for mock vs production)
  getIt.registerLazySingleton<BleServiceInterface>(() {
    if (config.useMockService) {
      return MockBleService();
    } else {
      return FlutterBluePlusBleService(config: config);
    }
  });

  // Repositories
  getIt.registerFactory<ProfileRepository>(() => ProfileRepository(getIt<DatabaseService>().database));
  getIt.registerFactory<PeerRepository>(() => PeerRepository(getIt<DatabaseService>().database));
  getIt.registerFactory<ChatRepository>(() => ChatRepository(getIt<DatabaseService>().database));

  // Blocs
  getIt.registerFactory<ProfileBloc>(() => ProfileBloc(/* ... */));
  getIt.registerFactory<DiscoveryBloc>(() => DiscoveryBloc(/* ... */));
  getIt.registerFactoryParam<ChatBloc, String, void>((userId, _) => ChatBloc(/* ... */));
  getIt.registerFactory<BleStatusBloc>(() => BleStatusBloc(/* ... */));
  getIt.registerFactory<BleConnectionBloc>(() => BleConnectionBloc(/* ... */));
}
```

**Benefits**:
- Easy swapping of implementations (mock vs production)
- Centralized dependency management
- Testability (inject mocks)
- Lazy initialization

## Error Handling

**AppError Hierarchy** (lib/core/errors/app_error.dart:1)

```dart
abstract class AppError implements Exception {
  String get userMessage;  // User-friendly message
  String get code;         // Error code for logging
  bool get isRecoverable;  // Can user retry?
}

// Specific error types
class BleError extends AppError { /* ... */ }
class DatabaseError extends AppError { /* ... */ }
class PermissionError extends AppError { /* ... */ }
class ImageError extends AppError { /* ... */ }
class ProfileError extends AppError { /* ... */ }
class ChatError extends AppError { /* ... */ }
class DiscoveryError extends AppError { /* ... */ }
```

**Error UI Components**:
- ErrorStateWidget: Full-screen error with retry button
- ErrorBanner: Inline error banner
- ErrorSnackBar: Toast-style error notification

**Error Recovery**:
- Recoverable errors show "Retry" button
- Non-recoverable errors show "OK" button
- Errors logged with error codes for debugging

## Logging

**Logger Utility** (lib/core/utils/logger.dart:1)

```dart
class Logger {
  static void info(String message, [String? tag]) { /* ... */ }
  static void warning(String message, [String? tag]) { /* ... */ }
  static void error(String message, [String? tag, Object? error]) { /* ... */ }
  static void debug(String message, [String? tag]) { /* ... */ }
}
```

**Usage**:
```dart
Logger.info('Discovered device: $deviceName', 'BLE');
Logger.error('Failed to connect', 'BLE', error);
```

**Log Viewing**: Debug menu shows recent logs with copy-to-clipboard functionality

## Configuration

**BleConfig** (lib/services/ble/ble_config.dart:1)

```dart
class BleConfig {
  final bool useMockService;           // Use MockBleService for testing
  final int maxConnections;            // Max concurrent BLE connections (default 5)
  final Duration connectionTimeout;    // GATT connection timeout (default 30s)
  final Duration idleTimeout;          // Disconnect after idle (default 60s)
  final Duration peerTimeout;          // Emit peerLost after (default 5min)
  final Duration scanDuration;         // Scan for (default 3s)
  final Duration scanPause;            // Pause between scans (default 5s)
}
```

**Build Flavors** (planned):
- `development`: Mock BLE, debug logging, no obfuscation
- `staging`: Real BLE, debug logging, no obfuscation
- `production`: Real BLE, minimal logging, obfuscation enabled

## References

- [Flutter Blue Plus Documentation](https://pub.dev/packages/flutter_blue_plus)
- [Drift Documentation](https://drift.simonbinder.eu/docs/)
- [Flutter Bloc Documentation](https://bloclibrary.dev/)
- [BLE GATT Specification](https://www.bluetooth.com/specifications/gatt/)
- [iOS Core Bluetooth Guide](https://developer.apple.com/documentation/corebluetooth)
- [Android BLE Guide](https://developer.android.com/guide/topics/connectivity/bluetooth/ble-overview)

---

**Last Updated**: January 2025
**Version**: 1.0.0
**Author**: Anchor Development Team
