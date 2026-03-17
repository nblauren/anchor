/// Application-wide constants
class AppConstants {
  AppConstants._();

  // App Info
  static const String appName = 'Anchor';
  static const String appVersion = '1.0.0';

  // Database
  static const String databaseName = 'anchor_database.db';
  static const int databaseVersion = 1;

  // Profile
  static const int maxPhotos = 6;
  static const int maxBioLength = 500;
  static const int minAge = 18;
  static const int maxAge = 100;

  // Discovery
  static const int discoveryGridColumns = 2;
  static const int maxDiscoveryResults = 50;

  // Chat
  static const int maxMessageLength = 1000;
  static const int messagePageSize = 20;

  // BLE
  static const Duration bleScanDuration = Duration(seconds: 10);
  static const Duration bleAdvertiseDuration = Duration(seconds: 30);

  // Image
  static const int maxImageWidth = 1080;
  static const int maxImageHeight = 1920;
  static const int imageQuality = 80;
  static const int thumbnailSize = 200;

  // Store-and-forward message retry
  static const int messageRetryWindowHours = 24;
  static const int messageMaxCrossSessionRetries = 20;

  // Transport feature flags
  /// Set to false to disable LAN (TCP/UDP) transport entirely and fall back
  /// to BLE-only mode. Useful for debugging or environments where local
  /// network discovery causes issues.
  static const bool enableLanTransport = false;
}
