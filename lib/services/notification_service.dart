import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../core/utils/logger.dart';

/// Service for handling local notifications
class NotificationService {
  NotificationService();

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  bool _isInitialized = false;

  static const _androidChannelIdMessages = 'messages_channel';
  static const _androidChannelIdPeers = 'peers_channel';

  /// Initialize the notification service
  Future<void> initialize() async {
    if (_isInitialized) return;

    // Android initialization settings
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings(
            '@mipmap/ic_launcher'); // or your own icon

    // iOS & macOS initialization settings
    const DarwinInitializationSettings initializationSettingsDarwin =
        DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    // Combined settings
    const InitializationSettings initializationSettings =
        InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsDarwin,
      macOS: initializationSettingsDarwin,
    );

    // Initialize plugin
    final bool? initialized = await _notificationsPlugin.initialize(
      settings: initializationSettings,
    );

    if (initialized != true) {
      Logger.warning(
          'NotificationService: Initialization failed', 'Notifications');
      return;
    }

    // Create Android notification channels (required since Android 8.0)
    await _createNotificationChannels();

    _isInitialized = true;
    Logger.info(
        'NotificationService: Initialized successfully', 'Notifications');
  }

  Future<void> _createNotificationChannels() async {
    const AndroidNotificationChannel messagesChannel =
        AndroidNotificationChannel(
      _androidChannelIdMessages, // id
      'New Messages', // name
      description: 'Notifications for incoming messages',
      importance: Importance.max,
      playSound: true,
    );

    const AndroidNotificationChannel peersChannel = AndroidNotificationChannel(
      _androidChannelIdPeers,
      'Peer Discovery',
      description: 'Notifications when new peers are found',
      importance: Importance.high,
      playSound: true,
    );

    await _notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(messagesChannel);

    await _notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(peersChannel);
  }

  /// Request notification permissions (mainly useful on iOS)
  Future<bool> requestPermissions() async {
    final AndroidFlutterLocalNotificationsPlugin? androidImpl =
        _notificationsPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    final bool? androidGranted =
        await androidImpl?.requestNotificationsPermission();

    final bool? iosGranted = await _notificationsPlugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );

    final granted = (androidGranted ?? true) && (iosGranted ?? true);
    Logger.info(
        'NotificationService: Permissions ${granted ? "granted" : "denied/partially"}',
        'Notifications');
    return granted;
  }

  /// Show a notification for a new message
  Future<void> showMessageNotification({
    required String fromPeerId,
    required String fromName,
    required String messagePreview,
    String? photoPath, // can be used for largeIcon / bigPicture later
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    final int id = NotificationIds.forMessage(fromPeerId);

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      _androidChannelIdMessages,
      'New Messages',
      channelDescription: 'Notifications for incoming messages',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: true,
      // largeIcon: photoPath != null ? FilePathAndroidBitmap(photoPath) : null,
      // styleInformation: photoPath != null ? BigPictureStyleInformation(...) : null,
    );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      macOS: iosDetails,
    );

    await _notificationsPlugin.show(
      id: id,
      title: fromName,
      body: messagePreview,
      notificationDetails: details,
      payload: 'message:$fromPeerId',
    );

    Logger.info(
        'Notification shown - $fromName: $messagePreview', 'Notifications');
  }

  /// Show a notification for a new peer discovered
  Future<void> showPeerDiscoveredNotification({
    required String peerId,
    required String peerName,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    final int id = NotificationIds.forPeer(peerId);

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      _androidChannelIdPeers,
      'Peer Discovery',
      channelDescription: 'New nearby/offline peers found',
      importance: Importance.high,
      priority: Priority.high,
    );

    const NotificationDetails details =
        NotificationDetails(android: androidDetails);

    await _notificationsPlugin.show(
      id: id,
      title: 'New Peer Found',
      body: peerName,
      notificationDetails: details,
      payload: 'peer:$peerId',
    );

    Logger.info('Peer discovered notification - $peerName', 'Notifications');
  }

  /// Cancel all notifications
  Future<void> cancelAll() async {
    await _notificationsPlugin.cancelAll();
    Logger.info(
        'NotificationService: Cancelled all notifications', 'Notifications');
  }

  /// Cancel notification by ID
  Future<void> cancel(int id) async {
    await _notificationsPlugin.cancel(id: id);
    Logger.info(
        'NotificationService: Cancelled notification $id', 'Notifications');
  }

  /// Set badge count (iOS mainly)
  Future<void> setBadgeCount(int count) async {
    AppBadgePlus.updateBadge(count);
    Logger.info(
        'NotificationService: Badge count set to $count', 'Notifications');
  }

  /// Clear badge (iOS/macOS)
  Future<void> clearBadge() async {
    await setBadgeCount(0);
  }
}

/// Notification IDs (your original logic is fine)
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
