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

  // BLE (placeholder for future Bridgefy integration)
  static const Duration bleScanDuration = Duration(seconds: 10);
  static const Duration bleAdvertiseDuration = Duration(seconds: 30);

  // Image
  static const int maxImageWidth = 1080;
  static const int maxImageHeight = 1920;
  static const int imageQuality = 80;
  static const int thumbnailSize = 200;
}
