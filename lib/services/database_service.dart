import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/data/local_database/database.dart';
import 'package:anchor/data/repositories/anchor_drop_repository.dart';
import 'package:anchor/data/repositories/anchor_drop_repository_interface.dart';
import 'package:anchor/data/repositories/chat_repository.dart';
import 'package:anchor/data/repositories/chat_repository_interface.dart';
import 'package:anchor/data/repositories/encryption_repository.dart';
import 'package:anchor/data/repositories/encryption_repository_interface.dart';
import 'package:anchor/data/repositories/peer_repository.dart';
import 'package:anchor/data/repositories/peer_repository_interface.dart';
import 'package:anchor/data/repositories/profile_repository.dart';
import 'package:anchor/data/repositories/profile_repository_interface.dart';

/// Service for managing database access and repositories
class DatabaseService {
  DatabaseService();

  late final AppDatabase _database;
  late final ProfileRepository _profileRepository;
  late final PeerRepository _peerRepository;
  late final ChatRepository _chatRepository;
  late final AnchorDropRepository _anchorDropRepository;
  late final EncryptionRepository _encryptionRepository;

  bool _isInitialized = false;

  /// Whether the service is initialized
  bool get isInitialized => _isInitialized;

  /// Access to profile repository (local user profile and photos)
  ProfileRepositoryInterface get profileRepository {
    _ensureInitialized();
    return _profileRepository;
  }

  /// Access to peer repository (discovered peers and blocking)
  PeerRepositoryInterface get peerRepository {
    _ensureInitialized();
    return _peerRepository;
  }

  /// Access to chat repository (conversations and messages)
  ChatRepositoryInterface get chatRepository {
    _ensureInitialized();
    return _chatRepository;
  }

  /// Access to anchor drop repository (sent and received drops)
  AnchorDropRepositoryInterface get anchorDropRepository {
    _ensureInitialized();
    return _anchorDropRepository;
  }

  /// Access to encryption repository (E2EE peer keys and sessions)
  EncryptionRepositoryInterface get encryptionRepository {
    _ensureInitialized();
    return _encryptionRepository;
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
    _anchorDropRepository = AnchorDropRepository(_database);
    _encryptionRepository = EncryptionRepository(_database);

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
      await _database.delete(_database.messageReactions).go();
      await _database.delete(_database.messages).go();
      await _database.delete(_database.conversations).go();
      await _database.delete(_database.blockedUsers).go();
      await _database.delete(_database.discoveredPeers).go();
      await _database.delete(_database.userPhotos).go();
      await _database.delete(_database.userProfiles).go();
    });

    Logger.info('DatabaseService: All data cleared', 'Database');
  }
}
