import '../core/utils/logger.dart';

/// Service for handling local notifications
///
/// This is a stub implementation that logs notifications.
/// To enable actual notifications, implement with flutter_local_notifications:
/// 1. Add flutter_local_notifications to pubspec.yaml
/// 2. Configure iOS/Android notification channels
/// 3. Implement the actual notification display
class NotificationService {
  NotificationService();

  bool _isInitialized = false;

  /// Initialize the notification service
  Future<void> initialize() async {
    if (_isInitialized) return;

    // TODO: Initialize flutter_local_notifications
    // await _initializeNotifications();

    _isInitialized = true;
    Logger.info('NotificationService: Initialized (stub)', 'Notifications');
  }

  /// Request notification permissions
  Future<bool> requestPermissions() async {
    // TODO: Request actual permissions
    Logger.info('NotificationService: Permission requested (stub)', 'Notifications');
    return true;
  }

  /// Show a notification for a new message
  Future<void> showMessageNotification({
    required String fromPeerId,
    required String fromName,
    required String messagePreview,
    String? photoPath,
  }) async {
    // TODO: Show actual notification using flutter_local_notifications
    Logger.info(
      'NotificationService: Message notification - $fromName: $messagePreview',
      'Notifications',
    );
  }

  /// Show a notification for a new peer discovered
  Future<void> showPeerDiscoveredNotification({
    required String peerId,
    required String peerName,
  }) async {
    // TODO: Show actual notification
    Logger.info(
      'NotificationService: Peer discovered - $peerName',
      'Notifications',
    );
  }

  /// Cancel all notifications
  Future<void> cancelAll() async {
    // TODO: Cancel actual notifications
    Logger.info('NotificationService: Cancelled all notifications', 'Notifications');
  }

  /// Cancel notification by ID
  Future<void> cancel(int id) async {
    // TODO: Cancel specific notification
    Logger.info('NotificationService: Cancelled notification $id', 'Notifications');
  }

  /// Set badge count (iOS)
  Future<void> setBadgeCount(int count) async {
    // TODO: Set actual badge count
    Logger.info('NotificationService: Badge count set to $count', 'Notifications');
  }

  /// Clear badge (iOS)
  Future<void> clearBadge() async {
    await setBadgeCount(0);
  }
}

/// Notification IDs
class NotificationIds {
  NotificationIds._();

  static const int messageBase = 1000;
  static const int peerDiscoveredBase = 2000;

  static int forMessage(String messageId) {
    return messageBase + messageId.hashCode.abs() % 1000;
  }

  static int forPeer(String peerId) {
    return peerDiscoveredBase + peerId.hashCode.abs() % 1000;
  }
}
