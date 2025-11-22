import 'package:get_it/get_it.dart';

import 'features/chat/bloc/chat_bloc.dart';
import 'features/discovery/bloc/discovery_bloc.dart';
import 'features/profile/bloc/profile_bloc.dart';
import 'services/ble/ble.dart';
import 'services/database_service.dart';
import 'services/image_service.dart';

/// Global service locator instance
final getIt = GetIt.instance;

/// Initialize all dependencies
Future<void> initializeDependencies() async {
  // Services (singletons)
  getIt.registerLazySingleton<DatabaseService>(() => DatabaseService());
  getIt.registerLazySingleton<ImageService>(() => ImageService());

  // BLE service - using MockBleService for now, will switch to real implementation later
  getIt.registerLazySingleton<BleServiceInterface>(() => MockBleService());

  // Initialize database
  await getIt<DatabaseService>().initialize();

  // Initialize BLE service
  await getIt<BleServiceInterface>().initialize();

  // Blocs (factories - new instance each time)
  getIt.registerFactory<ProfileBloc>(
    () => ProfileBloc(
      databaseService: getIt<DatabaseService>(),
      imageService: getIt<ImageService>(),
    ),
  );

  getIt.registerFactory<DiscoveryBloc>(
    () => DiscoveryBloc(
      peerRepository: getIt<DatabaseService>().peerRepository,
    ),
  );

  // ChatBloc needs the user's own ID, which we get from profile
  getIt.registerFactoryParam<ChatBloc, String, void>(
    (ownUserId, _) => ChatBloc(
      chatRepository: getIt<DatabaseService>().chatRepository,
      imageService: getIt<ImageService>(),
      ownUserId: ownUserId,
    ),
  );

  // BleStatusBloc for tracking BLE status and permissions
  getIt.registerFactory<BleStatusBloc>(
    () => BleStatusBloc(
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
