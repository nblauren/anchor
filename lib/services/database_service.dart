import '../core/utils/logger.dart';
import '../data/local_database/database.dart';
import '../data/repositories/chat_repository.dart';
import '../data/repositories/peer_repository.dart';
import '../data/repositories/profile_repository.dart';

/// Service for managing database access and repositories
class DatabaseService {
  DatabaseService();

  late final AppDatabase _database;
  late final ProfileRepository _profileRepository;
  late final PeerRepository _peerRepository;
  late final ChatRepository _chatRepository;

  bool _isInitialized = false;

  /// Whether the service is initialized
  bool get isInitialized => _isInitialized;

  /// Access to profile repository (local user profile and photos)
  ProfileRepository get profileRepository {
    _ensureInitialized();
    return _profileRepository;
  }

  /// Access to peer repository (discovered peers and blocking)
  PeerRepository get peerRepository {
    _ensureInitialized();
    return _peerRepository;
  }

  /// Access to chat repository (conversations and messages)
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
    _peerRepository = PeerRepository(_database);
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

  /// Clear all data from the database
  Future<void> clearAllData() async {
    _ensureInitialized();
    Logger.info('DatabaseService: Clearing all data...', 'Database');

    await _database.transaction(() async {
      // Delete in order to respect foreign key constraints
      await _database.delete(_database.messages).go();
      await _database.delete(_database.conversations).go();
      await _database.delete(_database.blockedUsers).go();
      await _database.delete(_database.discoveredPeers).go();
      await _database.delete(_database.profilePhotos).go();
      await _database.delete(_database.userProfile).go();
    });

    Logger.info('DatabaseService: All data cleared', 'Database');
  }
}
