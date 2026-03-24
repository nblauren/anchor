import 'dart:io';

import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/services/database_service.dart';
import 'package:anchor/services/encryption/encryption_service.dart';
import 'package:anchor/services/transport/transport_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Emergency identity wipe — destroys all user data, encryption keys,
/// cached images, and preferences in a single operation.
///
/// Designed for safety-critical scenarios where a user needs to instantly
/// erase all traces of the app's activity (e.g., entering an environment
/// where being identified as LGBTQ+ could be dangerous).
///
/// ## What gets destroyed
///
/// 1. **Transport** — BLE/LAN/Wi-Fi stopped, no more broadcasts
/// 2. **Encryption keys** — X25519 + Ed25519 keys zeroed from memory and
///    deleted from secure storage; all E2EE sessions cleared
/// 3. **Database** — All tables wiped (profiles, messages, conversations,
///    peers, reactions, anchor drops, photos, public keys)
/// 4. **SharedPreferences** — All app preferences cleared
/// 5. **Cached images** — Application cache directory wiped
///
/// ## What survives
///
/// - The app binary itself (can't self-delete)
/// - OS-level Bluetooth pairing data (managed by the OS)
class PanicService {
  PanicService({
    required TransportManager transportManager,
    required EncryptionService encryptionService,
    required DatabaseService databaseService,
  })  : _transport = transportManager,
        _encryption = encryptionService,
        _database = databaseService;

  final TransportManager _transport;
  final EncryptionService _encryption;
  final DatabaseService _database;

  /// Execute emergency wipe. Returns true if all steps completed.
  ///
  /// This operation is irreversible. The app must be restarted after
  /// completion (the caller should navigate to a "data wiped" screen
  /// and then exit or restart the onboarding flow).
  Future<bool> executeEmergencyWipe() async {
    Logger.info('PanicService: EMERGENCY WIPE INITIATED', 'Panic');

    var allSuccess = true;

    // Step 1: Stop all transports immediately
    try {
      await _transport.stop();
      Logger.info('PanicService: Transports stopped', 'Panic');
    } on Exception catch (e) {
      // Best-effort cleanup during emergency wipe
      Logger.error('PanicService: Transport stop failed', e, null, 'Panic');
      allSuccess = false;
    }

    // Step 2: Destroy all encryption keys
    try {
      await _encryption.destroyAllKeys();
      Logger.info('PanicService: Encryption keys destroyed', 'Panic');
    } on Exception catch (e) {
      // Best-effort cleanup during emergency wipe
      Logger.error('PanicService: Key destruction failed', e, null, 'Panic');
      allSuccess = false;
    }

    // Step 3: Clear database
    try {
      await _database.clearAllData();
      Logger.info('PanicService: Database cleared', 'Panic');
    } on Exception catch (e) {
      // Best-effort cleanup during emergency wipe
      Logger.error('PanicService: Database clear failed', e, null, 'Panic');
      allSuccess = false;
    }

    // Step 4: Clear SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      Logger.info('PanicService: SharedPreferences cleared', 'Panic');
    } on Exception catch (e) {
      // Best-effort cleanup during emergency wipe
      Logger.error('PanicService: SharedPreferences clear failed', e, null, 'Panic');
      allSuccess = false;
    }

    // Step 5: Wipe cached images
    try {
      await _wipeCacheDirectory();
      Logger.info('PanicService: Cache directory wiped', 'Panic');
    } on Exception catch (e) {
      // Best-effort cleanup during emergency wipe
      Logger.error('PanicService: Cache wipe failed', e, null, 'Panic');
      allSuccess = false;
    }

    Logger.info(
      'PanicService: Emergency wipe ${allSuccess ? "COMPLETE" : "PARTIAL (some steps failed)"}',
      'Panic',
    );

    return allSuccess;
  }

  /// Delete all files in the app's cache and temporary directories.
  Future<void> _wipeCacheDirectory() async {
    final dirs = <Directory>[];

    try {
      dirs.add(await getTemporaryDirectory());
    } on Exception catch (_) {
      // Best-effort cleanup during emergency wipe
    }

    try {
      dirs.add(await getApplicationCacheDirectory());
    } on Exception catch (_) {
      // Best-effort cleanup during emergency wipe
    }

    // Also wipe app support directory (may contain cached images)
    if (!kIsWeb) {
      try {
        dirs.add(await getApplicationSupportDirectory());
      } on Exception catch (_) {
        // Best-effort cleanup during emergency wipe
      }
    }

    for (final dir in dirs) {
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
        await dir.create(); // Recreate empty directory
      }
    }
  }
}
