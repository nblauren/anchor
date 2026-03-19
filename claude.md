# Anchor - AI Assistant Development Guide

This document is specifically for AI assistants (like Claude, GPT, etc.) working on the Anchor Flutter app. It provides context, patterns, and guidelines to help you contribute effectively.

## Quick Context

**What is Anchor?**
- Offline-first dating/social discovery app for LGBTQ+ cruises and festivals
- Uses Bluetooth Low Energy (BLE) for peer-to-peer communication
- No servers, no internet required, everything local
- Built with Flutter, Drift (SQLite), Bloc pattern, bluetooth_low_energy
- Wi-Fi Direct (flutter_nearby_connections_plus) for high-speed photo transfer with BLE fallback

**Target Environment**: Gay cruises (Atlantis, VACAYA) and festivals where internet is weak/expensive/nonexistent

**Key Challenge**: Reliable communication in metal ships with 50-100+ people in range, intermittent connections, battery constraints

**Photo Transfer**: Wi-Fi Direct (Nearby Connections / Multipeer Connectivity) for high-speed transfer; automatic BLE fallback. Non-blocking FIFO message queue ensures sends never block the UI.

## Project Architecture at a Glance

```
lib/
├── core/           # App-wide utilities (errors, theme, widgets, routing)
├── data/           # Database (Drift) + Repositories
├── services/       # External integrations (BLE, database, images, permissions)
└── features/       # Feature modules (profile, discovery, chat, onboarding, settings, home)
    └── {feature}/
        ├── bloc/       # State management (Bloc pattern)
        ├── screens/    # UI screens
        └── widgets/    # Feature-specific widgets
```

**Core Patterns**:
- **Clean Architecture**: Presentation → Domain → Data
- **Feature-Based**: Self-contained modules
- **Bloc Pattern**: State management with events and states
- **Repository Pattern**: Abstract data access
- **Dependency Injection**: GetIt service locator

## Key Files You Should Know

### Entry Points
- `lib/main.dart` - App initialization, dependency injection setup
- `lib/app.dart` - MaterialApp configuration, theme, bloc providers
- `lib/core/routing/app_shell.dart` - Routing logic (onboarding → permissions → profile setup → home)

### BLE Implementation (Critical)
- `lib/services/ble/ble_facade.dart` - Entry point; thin facade that delegates to sub-modules (connection/, discovery/, gatt/, mesh/, transfer/)
- `lib/services/ble/ble_service_interface.dart` - Abstract BLE contract (also declares `sendHandshakeMessage` and `noiseHandshakeStream`)
- `lib/services/ble/mock_ble_service.dart` - Testing mock
- `lib/services/ble/ble_models.dart` - `DiscoveredPeer` (incl. `publicKeyHex`), `BroadcastPayload` (incl. `publicKeyHex`), `NoiseHandshakeReceived`, etc.
- `lib/services/ble/ble_status_bloc.dart` - BLE adapter state tracking
- `lib/services/ble/ble_connection_bloc.dart` - BLE lifecycle management

### Mesh & Gossip Sync
- `lib/services/mesh/golomb_coded_set.dart` - GCS encode/decode for probabilistic set reconciliation
- `lib/services/mesh/gossip_sync_service.dart` - Periodic GCS-based gossip sync between connected peers
- `lib/services/mesh/bloom_filter.dart` - Bloom filter + rotating variant for message dedup
- `lib/services/mesh/message_router.dart` - Unified router with cross-transport dedup and TTL relay
- `lib/services/mesh/peer_registry.dart` - Canonical peer identity management

### Transport Manager & LAN
- `lib/services/transport/transport_manager.dart` - Unified LAN + Wi-Fi Aware + BLE router; owns E2EE handshake routing; maintains canonical peer ID maps (`_peerIdAlias`, `_bleIdForCanonical`)
- `lib/services/lan/lan_transport_service_impl.dart` - LAN (TCP/UDP) transport; UDP beacon includes `pk` field; handles `noise_hs` TCP frames
- `lib/services/lan/lan_transport_service.dart` - Abstract LAN interface

### End-to-End Encryption
- `lib/services/encryption/encryption_service.dart` - Key gen/storage, Noise_XK handshake lifecycle, `hasSession()`, encrypt/decrypt (with traffic padding)
- `lib/services/encryption/noise_handshake.dart` - Pure Noise_XK state machine (`NoiseHandshakeProcessor`)
- `lib/services/encryption/encryption_models.dart` - `NoiseSession`, `EncryptedPayload`, `HandshakeResult`, `HandshakeMessageOut`
- `lib/services/encryption/traffic_padding.dart` - Length-prefixed padding to fixed block sizes (64–4096 bytes) for traffic analysis resistance
- `lib/services/encryption/rate_limiter.dart` - Handshake rate limiting (10/min/peer, 30/min global) to prevent DoS

### Wi-Fi Direct / Nearby Transfer
- `lib/services/nearby/high_speed_transfer_service.dart` - Abstract interface
- `lib/services/nearby/nearby_transfer_service_impl.dart` - Production impl (base64 chunks over Nearby text messages)
- `lib/services/nearby/mock_high_speed_transfer_service.dart` - Test double
- `lib/services/nearby/nearby_models.dart` - NearbyTransferProgress, NearbyPayloadReceived, TransferTransport

### Database
- `lib/data/local_database/database.dart` - Drift database schema v9 (tables: user_profile, discovered_peers, conversations, messages, blocked_users, profile_photos, anchor_drops, message_reactions, peer_public_keys)
- `lib/data/repositories/profile_repository.dart` - Profile CRUD
- `lib/data/repositories/peer_repository.dart` - Peer discovery, blocking
- `lib/data/repositories/chat_repository.dart` - Conversations, messages
- `lib/data/repositories/anchor_drop_repository.dart` - Anchor drop history

### Feature Modules
- `lib/features/profile/` - User profile creation and editing
- `lib/features/discovery/` - BLE peer discovery with grid UI
- `lib/features/chat/` - Conversations and messaging
- `lib/features/onboarding/` - First-time user experience
- `lib/features/settings/` - App settings, blocked users, debug menu

### Configuration
- `pubspec.yaml` - Dependencies (bluetooth_low_energy, drift, bloc, flutter_nearby_connections_plus, etc.)
- `android/app/src/main/AndroidManifest.xml` - Android permissions
- `ios/Runner/Info.plist` - iOS permissions
- `lib/injection.dart` - Dependency injection setup

## BLE Implementation Details

### Service UUIDs (Centralized in `BleUuids` — `lib/services/ble/ble_config.dart`)
```dart
Service:          b4b605d3-7718-42a5-88ec-6fbe8c6c3cb9
Profile (fff1):   02c57431-2cc9-4b9c-9472-37a1efa02bc6  (READ, NOTIFY)
Thumbnail (fff2): e353cf0a-85c2-4d2a-b4b1-8a0fa1bfb1f1  (READ)
Messaging (fff3): 6c4c3e0a-8d29-48b6-83c3-2d19ee02d398  (WRITE, NOTIFY)
Photos (fff4):    79118c43-92a1-48b7-98af-d28a0a9dbc72  (READ, NOTIFY)
Reverse (fff5):   9386c87b-79fb-4b5c-ab38-d0e6a0fffd03  (WRITE, NOTIFY)
```

### How Discovery Works
1. Device A scans for Anchor service UUID (unfiltered scan; matched by service UUID or `A<version>` local name)
2. Device B advertises that UUID (peripheral mode) with compact `A<profileVersion>` local name
3. Device A connects via GATT, reads Profile Metadata (profile char) — includes `pk` (X25519), `spk` (Ed25519) — then reads Thumbnail (thumbnail char)
4. Device A emits `DiscoveredPeer` (with `publicKeyHex`) to stream
5. `TransportManager` stores peer's public key via `encryptionService.storePeerPublicKey(canonicalId, pk)`
6. DiscoveryBloc receives peer, filters blocked users, updates UI
7. Device A disconnects after 60s idle (or keeps for active chat)

### How Messaging Works
0. **E2EE handshake first**: On `OpenConversation`, `ChatBloc` checks `encryptionService.hasSession(peerId)`. If no session, it calls `initiateHandshake()` and shows a "Initiating secure connection…" banner. Input is blocked until the Noise_XK 3-way handshake completes (≤2 BLE RTTs). Messages **cannot** be sent before `isE2eeActive` is true.
1. User sends message → ChatBloc encrypts via `encryptionService.encrypt()` → saves ciphertext to DB → adds to UI immediately → returns (non-blocking)
2. Background FIFO queue (`_sendQueue`) processes sends sequentially:
   - `_sendTextInBackground()` → `TransportManager.sendMessage(peerId, payload)` (routes to best transport)
   - `_sendPhotoInBackground()` → compress + send photo preview
3. Transport layer writes to peer (BLE messaging char or LAN TCP frame)
4. Recipient receives message → decrypts if `v=1` → ChatBloc saves to DB → updates UI
5. User can send multiple messages without waiting — each shows a pending indicator until delivered

### How Photo Transfer Works
1. Sender selects photo → saved to DB immediately → lightweight BLE notification sent (no thumbnail)
2. Receiver sees "Photo — Tap to download" → taps to send `photo_request` via BLE
3. Sender receives `photo_request` → fire-and-forget `_sendFullPhoto()`:
   a. If Wi-Fi Direct available: advertise on Nearby → send `wifiTransferReady` BLE signal → stream base64 chunks
   b. If Wi-Fi Direct fails/times out: fallback to BLE chunking via messaging char
4. Receiver gets `wifiTransferReady` BLE signal → browse Nearby → connect → receive chunks → save photo
5. Two ID systems: BLE device IDs ≠ Nearby userIds — `_transferToBleId` map in ChatBloc resolves the mapping

### Connection Management
- **Max Connections**: 5 concurrent (iOS limit ~8-10, Android ~20-50)
- **Connection Timeout**: 30 seconds
- **Idle Timeout**: 60 seconds (disconnect if no activity)
- **Peer Timeout**: 2 minutes (emit `peerLost` if no GATT activity)
- **Eviction**: LRU (Least Recently Used)

### Known Limitations (Important!)
1. **One concurrent Wi-Fi Direct transfer**: NearbyService reinitializes between transfers; no parallel transfers
2. **iOS Background**: Very limited discovery when app backgrounded (Apple restriction)
3. **Wi-Fi Direct platform channel threading**: Native callbacks may arrive on non-platform thread (logged warning, no data loss observed)
4. **E2EE session re-keying**: Sessions are per-connection (in-memory only). If the peer disconnects and reconnects, a new handshake is required. The UI shows "Securing…" again on reconnect.

## Common Tasks and How to Do Them

### Adding a New Feature

1. **Create feature directory**: `lib/features/new_feature/`
2. **Create bloc**: `lib/features/new_feature/bloc/new_feature_bloc.dart`
   - Define events, states, bloc logic
3. **Create screens**: `lib/features/new_feature/screens/new_feature_screen.dart`
4. **Add to DI**: Register bloc in `lib/injection.dart`
5. **Add navigation**: Update `lib/core/routing/app_shell.dart` or relevant screen
6. **Write tests**: `test/features/new_feature/bloc/new_feature_bloc_test.dart`

**Example Bloc Structure**:
```dart
// Events
abstract class NewFeatureEvent extends Equatable {
  const NewFeatureEvent();
}

class LoadData extends NewFeatureEvent {
  @override
  List<Object?> get props => [];
}

// States
abstract class NewFeatureState extends Equatable {
  const NewFeatureState();
}

class NewFeatureInitial extends NewFeatureState {
  @override
  List<Object?> get props => [];
}

// Bloc
class NewFeatureBloc extends Bloc<NewFeatureEvent, NewFeatureState> {
  NewFeatureBloc() : super(NewFeatureInitial()) {
    on<LoadData>(_onLoadData);
  }

  Future<void> _onLoadData(LoadData event, Emitter<NewFeatureState> emit) async {
    // Implementation
  }
}
```

### Modifying the Database Schema

1. **Edit table definitions** in `lib/data/database.dart`
2. **Increment schema version** in `@DriftDatabase` annotation
3. **Add migration** in `onUpgrade` method
4. **Regenerate code**: Run `dart run build_runner build --delete-conflicting-outputs`
5. **Update repositories** to use new schema
6. **Write tests** for migration

**Example Migration**:
```dart
@DriftDatabase(
  tables: [UserProfile, Conversations, Messages, /* ... */],
  daos: [],
  version: 2, // Increment this
)
class AppDatabase extends _$AppDatabase {
  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onUpgrade: (migrator, from, to) async {
        if (from == 1) {
          // Migration from v1 to v2
          await migrator.addColumn(conversations, conversations.lastMessageAt);
        }
      },
    );
  }
}
```

### Adding BLE Functionality

**⚠️ Critical**: BLE only works on physical devices. Testing requires 2+ real phones.

1. **Modify interface**: Update `lib/services/ble/ble_service_interface.dart`
2. **Implement in BleFacade**: `lib/services/ble/ble_facade.dart` (delegates to sub-modules in `connection/`, `discovery/`, `gatt/`, `mesh/`, `transfer/`)
3. **Implement in MockBleService**: `lib/services/ble/mock_ble_service.dart` (for testing)
4. **Update models**: Add to `lib/services/ble/ble_models.dart` if needed
5. **Test with mock**: Write unit tests
6. **Test on devices**: Manually test on 2+ physical devices

**Example: Adding a new BLE event**:
```dart
// 1. Add stream to interface
abstract class BleServiceInterface {
  // ... existing streams ...
  Stream<NewEvent> get newEvent; // Add this
}

// 2. Implement in BleFacade (or relevant sub-module)
class BleFacade implements BleServiceInterface {
  final _newEventController = StreamController<NewEvent>.broadcast();

  @override
  Stream<NewEvent> get newEvent => _newEventController.stream;

  // Emit events when appropriate
  void _handleSomething() {
    _newEventController.add(NewEvent(/* ... */));
  }

  @override
  Future<void> dispose() async {
    await _newEventController.close(); // Don't forget!
    // ... other cleanup ...
  }
}

// 3. Listen in bloc
class SomeBloc extends Bloc<SomeEvent, SomeState> {
  SomeBloc(BleServiceInterface bleService) : super(SomeInitial()) {
    _bleSubscription = bleService.newEvent.listen((event) {
      add(HandleNewEvent(event));
    });
  }

  @override
  Future<void> close() {
    _bleSubscription.cancel();
    return super.close();
  }
}
```

### Adding UI Components

1. **Reusable widgets**: Place in `lib/core/widgets/`
2. **Feature-specific widgets**: Place in `lib/features/{feature}/widgets/`
3. **Use const constructors**: Improve performance
4. **Extract complex widgets**: Keep build methods <50 lines
5. **Support dark theme**: Use `Theme.of(context).colorScheme`

**Example: Reusable Widget**:
```dart
// lib/core/widgets/custom_button.dart
class CustomButton extends StatelessWidget {
  const CustomButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.isLoading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: isLoading ? null : onPressed,
      child: isLoading
          ? const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon),
                  const SizedBox(width: 8),
                ],
                Text(label),
              ],
            ),
    );
  }
}
```

## Important Patterns and Conventions

### Error Handling

**Always use AppError hierarchy**:
```dart
try {
  await someOperation();
} catch (e) {
  throw BleError('Failed to connect', e, BleErrorType.connectionFailed);
}
```

**In blocs, emit error states**:
```dart
try {
  final data = await repository.getData();
  emit(DataLoaded(data));
} catch (e) {
  if (e is AppError) {
    emit(DataError(e));
  } else {
    emit(DataError(AppError('Unexpected error', e)));
  }
}
```

**In UI, handle errors gracefully**:
```dart
BlocBuilder<DataBloc, DataState>(
  builder: (context, state) {
    if (state is DataError) {
      return ErrorStateWidget.fromError(
        state.error,
        onRetry: () => context.read<DataBloc>().add(const LoadData()),
      );
    }
    // ... other states ...
  },
)
```

### Logging

**Use Logger utility** for all logging:
```dart
Logger.info('User profile loaded', 'Profile');
Logger.warning('Peer connection timeout', 'BLE');
Logger.error('Failed to save message', 'Chat', error);
Logger.debug('Raw BLE data: $data', 'BLE');
```

**Don't use print()** - it's not visible in production logs.

### Async Operations in Blocs

**Always use async/await** with proper error handling:
```dart
on<SomeEvent>((event, emit) async {
  try {
    emit(SomeLoading());
    final result = await repository.getData();
    emit(SomeLoaded(result));
  } catch (e) {
    emit(SomeError(e));
  }
});
```

**Cancel subscriptions** in `close()`:
```dart
@override
Future<void> close() {
  _subscription?.cancel();
  return super.close();
}
```

### State Management Best Practices

1. **Immutable states**: Use `@immutable` or `const`
2. **Equatable**: Extend Equatable for easy comparison
3. **Single responsibility**: One bloc per feature
4. **Don't share blocs**: Each screen creates its own instance (via GetIt.registerFactory)
5. **Dispose properly**: Cancel streams, close controllers

## Testing Guidelines

### Unit Tests (Required for PRs)

**Test all blocs**:
```dart
void main() {
  group('ProfileBloc', () {
    late ProfileRepository mockRepository;
    late ProfileBloc bloc;

    setUp(() {
      mockRepository = MockProfileRepository();
      bloc = ProfileBloc(mockRepository);
    });

    tearDown(() {
      bloc.close();
    });

    blocTest<ProfileBloc, ProfileState>(
      'emits [ProfileLoading, ProfileLoaded] when LoadProfile succeeds',
      build: () {
        when(() => mockRepository.getProfile()).thenAnswer((_) async => mockProfile);
        return bloc;
      },
      act: (bloc) => bloc.add(const LoadProfile()),
      expect: () => [
        ProfileLoading(),
        ProfileLoaded(mockProfile),
      ],
    );
  });
}
```

**Test repositories with in-memory database**:
```dart
void main() {
  group('ChatRepository', () {
    late AppDatabase database;
    late ChatRepository repository;

    setUp(() {
      database = AppDatabase.memory(); // In-memory for tests
      repository = ChatRepository(database);
    });

    tearDown(() async {
      await database.close();
    });

    test('getConversationByPeerId returns conversation if exists', () async {
      // Insert test data
      await database.into(database.conversations).insert(
        ConversationsCompanion.insert(
          conversationId: 'conv-1',
          peerId: 'peer-1',
          peerName: 'John',
        ),
      );

      // Test
      final result = await repository.getConversationByPeerId('peer-1');
      expect(result, isNotNull);
      expect(result!.peerId, 'peer-1');
    });
  });
}
```

### Device Testing (Manual)

**⚠️ BLE requires physical devices. Simulators will NOT work.**

**Minimum test setup**:
1. 2 physical devices (iOS or Android)
2. Anchor installed on both
3. Bluetooth enabled
4. Within 10-30 meters

**Test checklist**:
- [ ] Discovery: Devices see each other within 10 seconds
- [ ] Profile: Name, age, bio, thumbnail visible
- [ ] Messaging: Text message delivers in 2-3 seconds
- [ ] Out of range: "Lost peer" event when Bluetooth off
- [ ] Permissions: Deny/grant flow works
- [ ] Multiple peers: 3+ devices all discover each other

## Common Pitfalls and Solutions

### Pitfall 1: Forgetting to Close Streams

**Problem**: Memory leaks from unclosed StreamControllers

**Solution**: Always close in `dispose()`:
```dart
@override
Future<void> dispose() async {
  await _peerDiscoveredController.close();
  await _messageReceivedController.close();
  // ... close all controllers ...
  await super.dispose();
}
```

### Pitfall 2: Modifying State Directly

**Problem**: Mutating bloc state instead of emitting new state

**Solution**: Emit new state, don't modify existing:
```dart
// ❌ Wrong
state.peers.add(newPeer);
emit(state);

// ✅ Correct
emit(state.copyWith(peers: [...state.peers, newPeer]));
```

### Pitfall 3: Blocking UI Thread

**Problem**: Heavy computation on main thread causes jank

**Solution**: Use `compute()` for expensive operations:
```dart
final compressed = await compute(compressImage, imageBytes);
```

### Pitfall 4: Not Handling Bluetooth Off

**Problem**: App crashes or hangs when Bluetooth disabled

**Solution**: Check adapter state first:
```dart
final adapterState = await FlutterBluePlus.adapterState.first;
if (adapterState != BluetoothAdapterState.on) {
  throw BleError('Bluetooth is off', null, BleErrorType.disabled);
}
```

### Pitfall 5: Testing BLE on Simulators

**Problem**: BLE code doesn't work, no errors

**Solution**: **Use physical devices**. BLE is not supported on simulators/emulators.

## Working with Existing Code

### Before Making Changes

1. **Read ARCHITECTURE.md** - Understand the system design
2. **Check related files** - See how similar features are implemented
3. **Run tests** - Ensure existing tests pass: `flutter test`
4. **Analyze code** - Check for lint issues: `flutter analyze`

### When Refactoring

1. **Make small changes** - One refactor at a time
2. **Don't break tests** - Update tests as you refactor
3. **Keep same behavior** - Refactoring shouldn't change functionality
4. **Extract before modifying** - Extract complex code into methods first

### When Fixing Bugs

1. **Reproduce first** - Understand the bug thoroughly
2. **Write failing test** - Capture the bug in a test
3. **Fix minimally** - Don't refactor while fixing
4. **Verify test passes** - Ensure your fix works
5. **Test on devices** - If BLE-related, test on physical devices

## Specific Guidance for Common Requests

### "Add photo transfer" — ✅ IMPLEMENTED

Photo transfer is fully implemented with Wi-Fi Direct (primary) and BLE chunking (fallback).

**Key files**:
- `lib/services/nearby/nearby_transfer_service_impl.dart` — Wi-Fi Direct transfer (base64 chunks over Nearby text messages)
- `lib/features/chat/bloc/chat_bloc.dart` — `_sendFullPhoto()`, `_onWifiTransferReady()`, `_onNearbyPayloadCompleted()`
- `lib/services/ble/flutter_blue_plus_ble_service.dart` — BLE photo chunking fallback

**Key patterns**:
- Fire-and-forget: `_sendFullPhoto()` is not awaited in the bloc handler to avoid blocking the event queue
- ID mapping: `_transferToBleId` maps Nearby transferId → BLE device ID (these are different!)
- NearbyService reinitializes between transfers (`_stopNearby()` resets `_initialized`)
- 3-second delay after `transfer_complete` before disconnecting to let native channel flush

### "Add store-and-forward message queue"

**What needs to be done** (not yet implemented):
1. Add `PendingMessages` table to `lib/data/local_database/database.dart`
2. Create `PendingMessageRepository` in `lib/data/repositories/`
3. Queue messages when peer offline; deliver when peer rediscovered
4. Retry with exponential backoff; expire after 24 hours

**Note**: In-session message queuing IS implemented — the FIFO `_sendQueue` in ChatBloc ensures messages send sequentially in the background. What's NOT implemented is cross-session persistence (messages lost if peer goes out of range).

### "Improve battery life"

**Already implemented**:
- Adaptive scanning (normal / battery saver / high-density / zero-peers modes)
- Dynamic RSSI floor (-90 dBm normal, -78 dBm high-density) drops weak peers
- Continuous scan (no pause) when 0 peers visible
- Battery saver mode toggle in Settings
- Connection pooling (max 5 concurrent, LRU eviction)
- Wi-Fi Direct only activates during active photo transfers (not always-on)

**Further optimization ideas**:
- Reduce max connections from 5 to 3
- Only scan when Discovery screen is open
- Stop scanning when app backgrounded (Android)

## Key Documentation References

- **README.md** - User-facing documentation, getting started
- **ARCHITECTURE.md** - Technical architecture, design decisions
- **CONTRIBUTING.md** - Contribution guidelines, PR process
- **FLUTTER_BLUE_PLUS_IMPLEMENTATION.md** - BLE implementation details, testing guide
- **Flutter Blue Plus Docs**: https://pub.dev/packages/flutter_blue_plus
- **Drift Docs**: https://drift.simonbinder.eu/docs/
- **Bloc Docs**: https://bloclibrary.dev/

## Quick Commands

```bash
# Get dependencies
flutter pub get

# Generate code (after database changes)
dart run build_runner build --delete-conflicting-outputs

# Format code
flutter format .

# Analyze code
flutter analyze

# Run tests
flutter test

# Run on device
flutter run -d <device-id>

# Clean build
flutter clean && flutter pub get

# iOS pod install
cd ios && pod install && cd ..
```

## Final Tips

1. **Read existing code first** - Understand patterns before adding new code
2. **Follow established patterns** - Don't introduce new patterns without discussion
3. **Test on devices** - For BLE features, always test on physical devices
4. **Small PRs** - Keep changes focused and reviewable
5. **Ask questions** - If unclear, ask in PR comments or issues
6. **Document as you go** - Update docs when changing behavior
7. **Think about battery** - BLE is battery-intensive, optimize where possible
8. **Consider the environment** - Metal ships, crowds, intermittent connections
9. **Privacy matters** - No data should leave the device without explicit user action
10. **Community first** - Built for LGBTQ+ cruises, keep that mission in mind

---

**Remember**: Anchor is built for the LGBTQ+ community to connect on cruises where internet is unreliable. Every feature should serve that mission. Privacy, reliability, and battery life are paramount.

**Happy coding!** 🏳️‍🌈⚓
