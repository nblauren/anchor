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

  /// Store-and-forward TTL in days (cruise duration).
  /// Messages older than this are expired and marked as failed.
  static const int storeForwardTtlDays = 7;

  // In-session transport retry queue
  static const int maxInSessionRetries = 5;
  static const int retryQueueExpiryMinutes = 10;
  static const int maxRetryQueueSize = 100;

  // Battery-aware transport policy
  static const int batteryCriticalThreshold = 10;
  static const int batteryLowThreshold = 20;

  // Mesh protocol
  /// Default TTL for direct messages (max relay hops).
  static const int meshDefaultTtl = 3;
  /// Maximum TTL allowed.
  static const int meshMaxTtl = 5;
  /// TTL for anchor drop signals (short range).
  static const int meshAnchorDropTtl = 2;
  /// TTL for peer announcements (broader discovery).
  static const int meshAnnounceTtl = 5;
  /// Expected unique messages for Bloom filter sizing.
  static const int meshDedupCapacity = 10000;
  /// E2EE session timeout in hours.
  static const int e2eeSessionTimeoutHours = 24;

  // Transport feature flags
  /// Set to false to disable LAN (TCP/UDP) transport entirely and fall back
  /// to BLE-only mode. Useful for debugging or environments where local
  /// network discovery causes issues.
  static const bool enableLanTransport = false;
}
