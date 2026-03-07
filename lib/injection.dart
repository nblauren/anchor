import 'package:get_it/get_it.dart';

import 'core/utils/logger.dart';
import 'features/chat/bloc/chat_bloc.dart';
import 'features/discovery/bloc/discovery_bloc.dart';
import 'features/profile/bloc/profile_bloc.dart';
import 'services/ble/ble.dart';
import 'services/database_service.dart';
import 'services/image_service.dart';
import 'services/notification_service.dart';

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
  getIt.registerLazySingleton<NotificationService>(() => NotificationService());

  // BLE service - select based on config
  getIt.registerLazySingleton<BleServiceInterface>(() {
    if (config.useMockService) {
      Logger.info('Using MockBleService for testing', 'DI');
      return MockBleService();
    } else {
      Logger.info('Using FlutterBluePlusBleService for production', 'DI');
      return FlutterBluePlusBleService(config: config);
    }
  });

  // Initialize database
  await getIt<DatabaseService>().initialize();

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

  // Blocs (factories - new instance each time)
  getIt.registerFactory<ProfileBloc>(
    () => ProfileBloc(
      databaseService: getIt<DatabaseService>(),
      imageService: getIt<ImageService>(),
      bleService: getIt<BleServiceInterface>(),
    ),
  );

  getIt.registerFactory<DiscoveryBloc>(
    () => DiscoveryBloc(
      peerRepository: getIt<DatabaseService>().peerRepository,
      bleService: getIt<BleServiceInterface>(),
      notificationService: getIt<NotificationService>(),
    ),
  );

  // ChatBloc needs the user's own ID, which we get from profile
  getIt.registerFactoryParam<ChatBloc, String, void>(
    (ownUserId, _) => ChatBloc(
      chatRepository: getIt<DatabaseService>().chatRepository,
      imageService: getIt<ImageService>(),
      bleService: getIt<BleServiceInterface>(),
      notificationService: getIt<NotificationService>(),
      ownUserId: ownUserId,
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
    ),
  );
}

/// Dispose all dependencies
Future<void> disposeDependencies() async {
  await getIt<DatabaseService>().close();
  await getIt<BleServiceInterface>().dispose();
  await getIt.reset();
}
