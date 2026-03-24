import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/data/repositories/anchor_drop_repository_interface.dart';
import 'package:anchor/data/repositories/chat_repository_interface.dart';
import 'package:anchor/data/repositories/encryption_repository_interface.dart';
import 'package:anchor/data/repositories/peer_repository_interface.dart';
import 'package:anchor/data/repositories/profile_repository_interface.dart';
import 'package:anchor/features/chat/bloc/chat_bloc.dart';
import 'package:anchor/features/chat/bloc/chat_e2ee_bloc.dart';
import 'package:anchor/features/chat/bloc/conversation_list_bloc.dart';
import 'package:anchor/features/chat/bloc/photo_transfer_bloc.dart';
import 'package:anchor/features/chat/bloc/reaction_bloc.dart';
import 'package:anchor/features/discovery/bloc/anchor_drop_bloc.dart';
import 'package:anchor/features/discovery/bloc/discovery_bloc.dart';
import 'package:anchor/features/profile/bloc/profile_bloc.dart';
import 'package:anchor/features/transport/bloc/transport_bloc.dart';
import 'package:anchor/services/audio_service.dart';
import 'package:anchor/services/ble/ble.dart';
import 'package:anchor/services/chat_event_bus.dart';
import 'package:anchor/services/database_service.dart';
import 'package:anchor/services/encryption/encryption.dart';
import 'package:anchor/services/image_service.dart';
import 'package:anchor/services/incoming_message_service.dart';
import 'package:anchor/services/lan/lan.dart';
import 'package:anchor/services/mesh/mesh.dart';
import 'package:anchor/services/message_send_service.dart';
import 'package:anchor/services/nearby/nearby.dart';
import 'package:anchor/services/notification_service.dart';
import 'package:anchor/services/nsfw_detection_service.dart';
import 'package:anchor/services/panic_service.dart';
import 'package:anchor/services/profile_broadcast_service.dart';
import 'package:anchor/services/store_and_forward_service.dart';
import 'package:anchor/services/transport/transport.dart';
import 'package:anchor/services/wifi_aware/wifi_aware.dart';
import 'package:get_it/get_it.dart';

/// Global service locator instance
final getIt = GetIt.instance;

/// Initialize all dependencies
///
/// [bleConfig] controls whether to use mock or real BLE service.
/// Defaults to [BleConfig.fromEnvironment()] which reads from
/// environment variables (USE_MOCK_BLE).
Future<void> initializeDependencies({
  BleConfig? bleConfig,
}) async {
  // Determine BLE config
  final config = bleConfig ?? BleConfig.fromEnvironment();
  Logger.info('Initializing with BLE config: $config', 'DI');

  // Register BLE config
  getIt
    ..registerSingleton<BleConfig>(config)

    // Services (singletons)
    ..registerLazySingleton<DatabaseService>(DatabaseService.new)
    ..registerLazySingleton<ImageService>(ImageService.new)
    ..registerLazySingleton<AudioService>(AudioService.new)
    ..registerLazySingleton<NotificationService>(
      () => NotificationService(audioService: getIt<AudioService>()),
    );

  // Initialize database
  await getIt<DatabaseService>().initialize();

  // Register repository interfaces (backed by DatabaseService instances)
  final dbService = getIt<DatabaseService>();
  getIt
    ..registerLazySingleton<ChatRepositoryInterface>(
      () => dbService.chatRepository,
    )
    ..registerLazySingleton<PeerRepositoryInterface>(
      () => dbService.peerRepository,
    )
    ..registerLazySingleton<ProfileRepositoryInterface>(
      () => dbService.profileRepository,
    )
    ..registerLazySingleton<AnchorDropRepositoryInterface>(
      () => dbService.anchorDropRepository,
    )
    ..registerLazySingleton<EncryptionRepositoryInterface>(
      () => dbService.encryptionRepository,
    )

    // Encryption service — registered after database is ready.
    // Must be initialized before BLE so it can supply the local public key
    // for embedding in BroadcastPayload (fff1 characteristic).
    ..registerLazySingleton<EncryptionService>(
    () => EncryptionService(
      encryptionRepository: getIt<EncryptionRepositoryInterface>(),
    ),
  );
  await getIt<EncryptionService>().initialize();

  // PeerRegistry — single source of truth for all peer identity resolution
  getIt.registerLazySingleton<PeerRegistry>(PeerRegistry.new);

  // Hydrate PeerRegistry from persisted aliases so transport ID resolution
  // works immediately on startup (before any BLE/LAN discovery events).
  final aliases = await getIt<DatabaseService>().peerRepository.getAllAliases();
  getIt<PeerRegistry>().hydrateFromAliases(aliases);

  // GossipSyncService — GCS-based gossip sync for mesh message reconciliation
  getIt
    ..registerLazySingleton<GossipSyncService>(GossipSyncService.new)

    // MessageRouter — unified cross-transport dedup and gossip relay
    ..registerLazySingleton<MessageRouter>(() => MessageRouter(
      peerRegistry: getIt<PeerRegistry>(),
      encryptionService: getIt<EncryptionService>(),
      gossipSyncService: getIt<GossipSyncService>(),
    ),)

    // BLE service - select based on config
    ..registerLazySingleton<BleServiceInterface>(() {
      if (config.useMockService) {
        Logger.info('Using MockBleService for testing', 'DI');
        return MockBleService();
      } else {
        Logger.info('Using BleFacade for production', 'DI');
        return BleFacade(
          config: config,
          encryptionService: getIt<EncryptionService>(),
          gossipSyncService: getIt<GossipSyncService>(),
        );
      }
    });

  // Initialize BLE service
  try {
    await getIt<BleServiceInterface>().initialize();
  } on Exception catch (e) {
    // BLE initialization may fail if permissions not granted or BLE unavailable
    // Log the error but don't crash - user will see permissions screen
    Logger.warning('BLE initialization failed: $e', 'DI');
  }

  // Initialize notification service
  await getIt<NotificationService>().initialize();

  // NSFW detection service — on-device TFLite model via nsfw_detector_flutter
  getIt
    ..registerLazySingleton<NsfwDetectionService>(NsfwDetectorFlutterService.new)

    // High-speed transfer (Wi-Fi Direct via Nearby Connections / Multipeer)
    // Android: Nearby Connections (Wi-Fi Direct)
    // iOS: Multipeer Connectivity (via flutter_nearby_connections_plus)
    ..registerLazySingleton<HighSpeedTransferService>(() {
      if (config.useMockService) {
        Logger.info('Using MockHighSpeedTransferService for testing', 'DI');
        return MockHighSpeedTransferService();
      } else {
        Logger.info('Using NearbyTransferServiceImpl for production', 'DI');
        return NearbyTransferServiceImpl();
      }
    })

    // LAN transport service
    ..registerLazySingleton<LanTransportService>(() {
      if (config.useMockService) {
        Logger.info('Using MockLanTransportService for testing', 'DI');
        return MockLanTransportService();
      } else {
        Logger.info('Using LanTransportServiceImpl for production', 'DI');
        return LanTransportServiceImpl();
      }
    })

    // Wi-Fi Aware transport service
    ..registerLazySingleton<WifiAwareTransportService>(() {
      if (config.useMockService) {
        Logger.info('Using MockWifiAwareTransportService for testing', 'DI');
        return MockWifiAwareTransportService();
      } else {
        Logger.info('Using WifiAwareTransportServiceImpl for production', 'DI');
        return WifiAwareTransportServiceImpl();
      }
    })

    // Transport health tracker (per-peer, per-transport metrics)
    ..registerLazySingleton<TransportHealthTracker>(
      TransportHealthTracker.new,
    )

    // Unified transport manager (LAN primary, Wi-Fi Aware secondary, BLE fallback)
    ..registerLazySingleton<TransportManager>(() => TransportManager(
      lanService: getIt<LanTransportService>(),
      wifiAwareService: getIt<WifiAwareTransportService>(),
      bleService: getIt<BleServiceInterface>(),
      peerRegistry: getIt<PeerRegistry>(),
      messageRouter: getIt<MessageRouter>(),
      encryptionService: getIt<EncryptionService>(),
      healthTracker: getIt<TransportHealthTracker>(),
      highSpeedTransferService: getIt<HighSpeedTransferService>(),
      gossipSyncService: getIt<GossipSyncService>(),
    ),)

    // Panic service — emergency identity wipe
    ..registerLazySingleton<PanicService>(() => PanicService(
      transportManager: getIt<TransportManager>(),
      encryptionService: getIt<EncryptionService>(),
      databaseService: getIt<DatabaseService>(),
    ),)

    // In-session transport retry queue
    ..registerLazySingleton<TransportRetryQueue>(
      () => TransportRetryQueue(transportManager: getIt<TransportManager>()),
    )

    // Store-and-forward service (singleton — retries pending messages on peer rediscovery)
    ..registerLazySingleton<StoreAndForwardService>(
      () => StoreAndForwardService(
        chatRepository: getIt<ChatRepositoryInterface>(),
        peerRepository: getIt<PeerRepositoryInterface>(),
        profileRepository: getIt<ProfileRepositoryInterface>(),
        transportManager: getIt<TransportManager>(),
      ),
    );

  // Initialize store-and-forward (no-op if no profile yet — safe to call early)
  await getIt<StoreAndForwardService>().initialize();

  // Chat event bus (singleton — shared across chat-related blocs)
  getIt
    ..registerLazySingleton<ChatEventBus>(ChatEventBus.new)

    // Message send service (singleton — owns the FIFO send queue)
    ..registerLazySingleton<MessageSendService>(() => MessageSendService(
      transportManager: getIt<TransportManager>(),
      imageService: getIt<ImageService>(),
      chatRepository: getIt<ChatRepositoryInterface>(),
      retryQueue: getIt<TransportRetryQueue>(),
    ),)

    // Incoming message service (singleton — persists messages even when chat is closed)
    ..registerLazySingleton<IncomingMessageService>(
        () => IncomingMessageService(
              transportManager: getIt<TransportManager>(),
              chatRepository: getIt<ChatRepositoryInterface>(),
              peerRepository: getIt<PeerRepositoryInterface>(),
              notificationService: getIt<NotificationService>(),
              chatEventBus: getIt<ChatEventBus>(),
            )..start(),)

    // Profile broadcast service (extracted from ProfileBloc)
    ..registerLazySingleton<ProfileBroadcastService>(
      () => ProfileBroadcastService(
        transportManager: getIt<TransportManager>(),
      ),
    )

    // Blocs (factories - new instance each time)
    ..registerFactory<ProfileBloc>(
      () => ProfileBloc(
        databaseService: getIt<DatabaseService>(),
        imageService: getIt<ImageService>(),
        nsfwDetectionService: getIt<NsfwDetectionService>(),
        profileBroadcastService: getIt<ProfileBroadcastService>(),
      ),
    )

    ..registerFactory<DiscoveryBloc>(
      () => DiscoveryBloc(
        peerRepository: getIt<PeerRepositoryInterface>(),
        transportManager: getIt<TransportManager>(),
        notificationService: getIt<NotificationService>(),
      ),
    )

    // AnchorDropBloc for ⚓ drop anchor feature
    ..registerFactory<AnchorDropBloc>(
      () => AnchorDropBloc(
        anchorDropRepository: getIt<AnchorDropRepositoryInterface>(),
        peerRepository: getIt<PeerRepositoryInterface>(),
        transportManager: getIt<TransportManager>(),
        notificationService: getIt<NotificationService>(),
      ),
    )

    // ChatBloc needs the user's own ID, which we get from profile
    ..registerFactoryParam<ChatBloc, String, void>(
      (ownUserId, _) => ChatBloc(
        chatRepository: getIt<ChatRepositoryInterface>(),
        peerRepository: getIt<PeerRepositoryInterface>(),
        transportManager: getIt<TransportManager>(),
        notificationService: getIt<NotificationService>(),
        ownUserId: ownUserId,
        messageSendService: getIt<MessageSendService>(),
        chatEventBus: getIt<ChatEventBus>(),
        storeAndForwardService: getIt<StoreAndForwardService>(),
        encryptionService: getIt<EncryptionService>(),
      ),
    )

    // PhotoTransferBloc for photo transfer progress and state
    ..registerFactoryParam<PhotoTransferBloc, String, void>(
      (ownUserId, _) => PhotoTransferBloc(
        chatRepository: getIt<ChatRepositoryInterface>(),
        peerRepository: getIt<PeerRepositoryInterface>(),
        imageService: getIt<ImageService>(),
        transportManager: getIt<TransportManager>(),
        notificationService: getIt<NotificationService>(),
        chatEventBus: getIt<ChatEventBus>(),
        messageSendService: getIt<MessageSendService>(),
        ownUserId: ownUserId,
        highSpeedTransferService: getIt<HighSpeedTransferService>(),
      ),
    )

    // ConversationListBloc for conversation list management
    ..registerFactoryParam<ConversationListBloc, String, void>(
      (ownUserId, _) => ConversationListBloc(
        chatRepository: getIt<ChatRepositoryInterface>(),
        notificationService: getIt<NotificationService>(),
        chatEventBus: getIt<ChatEventBus>(),
        messageSendService: getIt<MessageSendService>(),
        storeAndForwardService: getIt<StoreAndForwardService>(),
        retryQueue: getIt<TransportRetryQueue>(),
      ),
    )

    // ChatE2eeBloc for E2EE handshake state per conversation
    ..registerFactory<ChatE2eeBloc>(
      () => ChatE2eeBloc(
        encryptionService: getIt<EncryptionService>(),
      ),
    )

    // ReactionBloc for emoji reactions per conversation
    ..registerFactoryParam<ReactionBloc, String, void>(
      (ownUserId, _) => ReactionBloc(
        chatRepository: getIt<ChatRepositoryInterface>(),
        peerRepository: getIt<PeerRepositoryInterface>(),
        transportManager: getIt<TransportManager>(),
        notificationService: getIt<NotificationService>(),
        ownUserId: ownUserId,
      ),
    )

    // TransportBloc for UI transport indicators
    ..registerLazySingleton<TransportBloc>(
      () => TransportBloc(
        transportManager: getIt<TransportManager>(),
        healthTracker: getIt<TransportHealthTracker>(),
      ),
    );

  // Eagerly start the incoming message service so messages are persisted
  // even when no chat screen is open.
  getIt<IncomingMessageService>();

  // BleStatusBloc for tracking BLE status and permissions
  getIt
    ..registerFactory<BleStatusBloc>(
      () => BleStatusBloc(
        bleService: getIt<BleServiceInterface>(),
      ),
    )

    // BleConnectionBloc for managing BLE lifecycle
    ..registerFactory<BleConnectionBloc>(
      () => BleConnectionBloc(
        bleService: getIt<BleServiceInterface>(),
        transportManager: getIt<TransportManager>(),
      ),
    );
}

/// Dispose all dependencies
Future<void> disposeDependencies() async {
  getIt<IncomingMessageService>().dispose();
  getIt<MessageSendService>().dispose();
  getIt<ChatEventBus>().dispose();
  await getIt<EncryptionService>().dispose();
  await getIt<StoreAndForwardService>().dispose();
  await getIt<TransportRetryQueue>().dispose();
  await getIt<TransportHealthTracker>().dispose();
  await getIt<TransportManager>().dispose();
  await getIt<MessageRouter>().dispose();
  await getIt<PeerRegistry>().dispose();
  await getIt<LanTransportService>().dispose();
  await getIt<HighSpeedTransferService>().dispose();
  await getIt<DatabaseService>().close();
  await getIt.reset();
}
