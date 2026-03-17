import 'package:get_it/get_it.dart';

import 'core/utils/logger.dart';
import 'features/chat/bloc/chat_bloc.dart';
import 'features/discovery/bloc/discovery_bloc.dart';
import 'features/profile/bloc/profile_bloc.dart';
import 'features/transport/bloc/transport_bloc.dart';
import 'services/ble/ble.dart';
import 'services/database_service.dart';
import 'services/encryption/encryption.dart';
import 'services/image_service.dart';
import 'services/audio_service.dart';
import 'services/lan/lan.dart';
import 'services/nearby/nearby.dart';
import 'services/notification_service.dart';
import 'services/nsfw_detection_service.dart';
import 'services/store_and_forward_service.dart';
import 'services/transport/transport.dart';
import 'services/wifi_aware/wifi_aware.dart';

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
  getIt.registerSingleton<BleConfig>(config);

  // Services (singletons)
  getIt.registerLazySingleton<DatabaseService>(() => DatabaseService());
  getIt.registerLazySingleton<ImageService>(() => ImageService());
  getIt.registerLazySingleton<AudioService>(() => AudioService());
  getIt.registerLazySingleton<NotificationService>(
    () => NotificationService(audioService: getIt<AudioService>()),
  );

  // BLE service - select based on config
  getIt.registerLazySingleton<BleServiceInterface>(() {
    if (config.useMockService) {
      Logger.info('Using MockBleService for testing', 'DI');
      return MockBleService();
    } else {
      Logger.info('Using BleFacade for production', 'DI');
      return BleFacade(
        config: config,
        encryptionService: getIt<EncryptionService>(),
      );
    }
  });

  // Initialize database
  await getIt<DatabaseService>().initialize();

  // Encryption service — registered after database is ready.
  // Must be initialized before BLE so it can supply the local public key
  // for embedding in BroadcastPayload (fff1 characteristic).
  getIt.registerLazySingleton<EncryptionService>(
    () => EncryptionService(database: getIt<DatabaseService>().database),
  );
  await getIt<EncryptionService>().initialize();

  // Initialize BLE service
  try {
    await getIt<BleServiceInterface>().initialize();
  } catch (e) {
    // BLE initialization may fail if permissions not granted or BLE unavailable
    // Log the error but don't crash - user will see permissions screen
    Logger.warning('BLE initialization failed: $e', 'DI');
  }

  // Initialize notification service
  await getIt<NotificationService>().initialize();

  // NSFW detection service — on-device TFLite model via nsfw_detector_flutter
  getIt.registerLazySingleton<NsfwDetectionService>(() => NsfwDetectorFlutterService());

  // High-speed transfer (Wi-Fi Direct via Nearby Connections / Multipeer)
  // Android: Nearby Connections (Wi-Fi Direct)
  // iOS: Multipeer Connectivity (via flutter_nearby_connections_plus)
  getIt.registerLazySingleton<HighSpeedTransferService>(() {
    if (config.useMockService) {
      Logger.info('Using MockHighSpeedTransferService for testing', 'DI');
      return MockHighSpeedTransferService();
    } else {
      Logger.info('Using NearbyTransferServiceImpl for production', 'DI');
      return NearbyTransferServiceImpl();
    }
  });

  // LAN transport service
  getIt.registerLazySingleton<LanTransportService>(() {
    if (config.useMockService) {
      Logger.info('Using MockLanTransportService for testing', 'DI');
      return MockLanTransportService();
    } else {
      Logger.info('Using LanTransportServiceImpl for production', 'DI');
      return LanTransportServiceImpl();
    }
  });

  // Wi-Fi Aware transport service
  getIt.registerLazySingleton<WifiAwareTransportService>(() {
    if (config.useMockService) {
      Logger.info('Using MockWifiAwareTransportService for testing', 'DI');
      return MockWifiAwareTransportService();
    } else {
      Logger.info('Using WifiAwareTransportServiceImpl for production', 'DI');
      return WifiAwareTransportServiceImpl();
    }
  });

  // Transport health tracker (per-peer, per-transport metrics)
  getIt.registerLazySingleton<TransportHealthTracker>(
    () => TransportHealthTracker(),
  );

  // Unified transport manager (LAN primary, Wi-Fi Aware secondary, BLE fallback)
  getIt.registerLazySingleton<TransportManager>(() => TransportManager(
    lanService: getIt<LanTransportService>(),
    wifiAwareService: getIt<WifiAwareTransportService>(),
    bleService: getIt<BleServiceInterface>(),
    encryptionService: getIt<EncryptionService>(),
    healthTracker: getIt<TransportHealthTracker>(),
    highSpeedTransferService: getIt<HighSpeedTransferService>(),
  ));

  // In-session transport retry queue
  getIt.registerLazySingleton<TransportRetryQueue>(
    () => TransportRetryQueue(transportManager: getIt<TransportManager>()),
  );

  // Store-and-forward service (singleton — retries pending messages on peer rediscovery)
  getIt.registerLazySingleton<StoreAndForwardService>(
    () => StoreAndForwardService(
      chatRepository: getIt<DatabaseService>().chatRepository,
      peerRepository: getIt<DatabaseService>().peerRepository,
      profileRepository: getIt<DatabaseService>().profileRepository,
      transportManager: getIt<TransportManager>(),
    ),
  );

  // Initialize store-and-forward (no-op if no profile yet — safe to call early)
  await getIt<StoreAndForwardService>().initialize();

  // Blocs (factories - new instance each time)
  getIt.registerFactory<ProfileBloc>(
    () => ProfileBloc(
      databaseService: getIt<DatabaseService>(),
      imageService: getIt<ImageService>(),
      bleService: getIt<BleServiceInterface>(),
      nsfwDetectionService: getIt<NsfwDetectionService>(),
      transportManager: getIt<TransportManager>(),
    ),
  );

  getIt.registerFactory<DiscoveryBloc>(
    () => DiscoveryBloc(
      peerRepository: getIt<DatabaseService>().peerRepository,
      transportManager: getIt<TransportManager>(),
      anchorDropRepository: getIt<DatabaseService>().anchorDropRepository,
      notificationService: getIt<NotificationService>(),
    ),
  );

  // ChatBloc needs the user's own ID, which we get from profile
  getIt.registerFactoryParam<ChatBloc, String, void>(
    (ownUserId, _) => ChatBloc(
      chatRepository: getIt<DatabaseService>().chatRepository,
      peerRepository: getIt<DatabaseService>().peerRepository,
      imageService: getIt<ImageService>(),
      transportManager: getIt<TransportManager>(),
      notificationService: getIt<NotificationService>(),
      ownUserId: ownUserId,
      highSpeedTransferService: getIt<HighSpeedTransferService>(),
      storeAndForwardService: getIt<StoreAndForwardService>(),
      encryptionService: getIt<EncryptionService>(),
      retryQueue: getIt<TransportRetryQueue>(),
    ),
  );

  // TransportBloc for UI transport indicators
  getIt.registerLazySingleton<TransportBloc>(
    () => TransportBloc(
      transportManager: getIt<TransportManager>(),
      healthTracker: getIt<TransportHealthTracker>(),
    ),
  );

  // BleStatusBloc for tracking BLE status and permissions
  getIt.registerFactory<BleStatusBloc>(
    () => BleStatusBloc(
      bleService: getIt<BleServiceInterface>(),
    ),
  );

  // BleConnectionBloc for managing BLE lifecycle
  getIt.registerFactory<BleConnectionBloc>(
    () => BleConnectionBloc(
      bleService: getIt<BleServiceInterface>(),
      transportManager: getIt<TransportManager>(),
    ),
  );
}

/// Dispose all dependencies
Future<void> disposeDependencies() async {
  await getIt<EncryptionService>().dispose();
  await getIt<StoreAndForwardService>().dispose();
  await getIt<TransportRetryQueue>().dispose();
  await getIt<TransportHealthTracker>().dispose();
  await getIt<TransportManager>().dispose();
  await getIt<LanTransportService>().dispose();
  await getIt<HighSpeedTransferService>().dispose();
  await getIt<DatabaseService>().close();
  await getIt.reset();
}
