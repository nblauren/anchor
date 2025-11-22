import '../core/utils/logger.dart';
import '../data/local_database/database.dart';
import '../data/repositories/chat_repository.dart';
import '../data/repositories/profile_repository.dart';

/// Service for managing database access
class DatabaseService {
  DatabaseService();

  late final AppDatabase _database;
  late final ProfileRepository _profileRepository;
  late final ChatRepository _chatRepository;

  bool _isInitialized = false;

  /// Whether the service is initialized
  bool get isInitialized => _isInitialized;

  /// Access to profile repository
  ProfileRepository get profileRepository {
    _ensureInitialized();
    return _profileRepository;
  }

  /// Access to chat repository
  ChatRepository get chatRepository {
    _ensureInitialized();
    return _chatRepository;
  }

  /// Access to raw database (for advanced queries)
  AppDatabase get database {
    _ensureInitialized();
    return _database;
  }

  /// Initialize the database service
  Future<void> initialize() async {
    if (_isInitialized) return;

    Logger.info('DatabaseService: Initializing...', 'Database');

    _database = AppDatabase();
    _profileRepository = ProfileRepository(_database);
    _chatRepository = ChatRepository(_database);

    _isInitialized = true;
    Logger.info('DatabaseService: Initialized', 'Database');
  }

  /// Close the database
  Future<void> close() async {
    if (!_isInitialized) return;

    Logger.info('DatabaseService: Closing...', 'Database');
    await _database.close();
    _isInitialized = false;
    Logger.info('DatabaseService: Closed', 'Database');
  }

  void _ensureInitialized() {
    if (!_isInitialized) {
      throw StateError('DatabaseService is not initialized. Call initialize() first.');
    }
  }
}
