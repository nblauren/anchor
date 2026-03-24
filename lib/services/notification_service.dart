import 'dart:async';

import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/services/audio_service.dart';
import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Service for handling local notifications
class NotificationService {
  NotificationService({AudioService? audioService})
      : _audioService = audioService;

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  final AudioService? _audioService;

  bool _isInitialized = false;

  static const _androidChannelIdMessages = 'messages_channel';
  static const _androidChannelIdPeers = 'peers_channel';
  static const _androidChannelIdAnchorDrops = 'anchor_drops_channel';
  static const _androidChannelIdReactions = 'reactions_channel';

  /// Initialize the notification service
  Future<void> initialize() async {
    if (_isInitialized) return;

    // Android initialization settings
    const initializationSettingsAndroid =
        AndroidInitializationSettings(
            '@mipmap/ic_launcher',); // or your own icon

    // iOS & macOS initialization settings
    const initializationSettingsDarwin =
        DarwinInitializationSettings(
      
    );

    // Combined settings
    const initializationSettings =
        InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsDarwin,
      macOS: initializationSettingsDarwin,
    );

    // Initialize plugin
    final initialized = await _notificationsPlugin.initialize(
      settings: initializationSettings,
    );

    if (initialized != true) {
      Logger.warning(
          'NotificationService: Initialization failed', 'Notifications',);
      return;
    }

    // Create Android notification channels (required since Android 8.0)
    await _createNotificationChannels();

    _isInitialized = true;
    Logger.info(
        'NotificationService: Initialized successfully', 'Notifications',);
  }

  Future<void> _createNotificationChannels() async {
    const messagesChannel =
        AndroidNotificationChannel(
      _androidChannelIdMessages, // id
      'New Messages', // name
      description: 'Notifications for incoming messages',
      importance: Importance.max,
    );

    const peersChannel = AndroidNotificationChannel(
      _androidChannelIdPeers,
      'Peer Discovery',
      description: 'Notifications when new peers are found',
      importance: Importance.high,
    );

    await _notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(messagesChannel);

    await _notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(peersChannel);

    const anchorDropsChannel =
        AndroidNotificationChannel(
      _androidChannelIdAnchorDrops,
      'Anchor Drops',
      description: 'When someone drops anchor on you',
      importance: Importance.high,
    );

    await _notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(anchorDropsChannel);

    const reactionsChannel =
        AndroidNotificationChannel(
      _androidChannelIdReactions,
      'Reactions',
      description: 'When someone reacts to your message',
    );

    await _notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(reactionsChannel);
  }

  /// Request notification permissions (mainly useful on iOS)
  Future<bool> requestPermissions() async {
    final androidImpl =
        _notificationsPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    final androidGranted =
        await androidImpl?.requestNotificationsPermission();

    final iosGranted = await _notificationsPlugin
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
        'Notifications',);
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

    final id = NotificationIds.forMessage(fromPeerId);

    const androidDetails =
        AndroidNotificationDetails(
      _androidChannelIdMessages,
      'New Messages',
      channelDescription: 'Notifications for incoming messages',
      importance: Importance.max,
      priority: Priority.high,
      // largeIcon: photoPath != null ? FilePathAndroidBitmap(photoPath) : null,
      // styleInformation: photoPath != null ? BigPictureStyleInformation(...) : null,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
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

    unawaited(_audioService?.playPop());

    Logger.info(
        'Notification shown - $fromName: $messagePreview', 'Notifications',);
  }

  /// Show a notification when someone drops anchor on us
  Future<void> showAnchorDropNotification({
    required String fromPeerId,
    required String fromName,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    final id = NotificationIds.forAnchorDrop(fromPeerId);

    const androidDetails =
        AndroidNotificationDetails(
      _androidChannelIdAnchorDrops,
      'Anchor Drops',
      channelDescription: 'When someone drops anchor on you',
      importance: Importance.high,
      priority: Priority.high,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      macOS: iosDetails,
    );

    await _notificationsPlugin.show(
      id: id,
      title: '$fromName dropped anchor on you! \u2693',
      body: 'Tap to view their profile',
      notificationDetails: details,
      payload: 'anchor_drop:$fromPeerId',
    );

    unawaited(_audioService?.playPop());

    Logger.info('Anchor drop notification shown - $fromName', 'Notifications');
  }

  /// Show a notification for a new peer discovered
  Future<void> showPeerDiscoveredNotification({
    required String peerId,
    required String peerName,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    final id = NotificationIds.forPeer(peerId);

    const androidDetails =
        AndroidNotificationDetails(
      _androidChannelIdPeers,
      'Peer Discovery',
      channelDescription: 'New nearby/offline peers found',
      importance: Importance.high,
      priority: Priority.high,
    );

    const details =
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

  /// Show a notification when someone reacts to your message.
  Future<void> showReactionNotification({
    required String fromPeerId,
    required String fromName,
    required String emoji,
    required String messagePreview,
  }) async {
    if (!_isInitialized) await initialize();

    const androidDetails =
        AndroidNotificationDetails(
      _androidChannelIdReactions,
      'Reactions',
      channelDescription: 'When someone reacts to your message',
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: false, // sound played separately via AudioService
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      macOS: iosDetails,
    );

    await _notificationsPlugin.show(
      id: NotificationIds.forReaction(fromPeerId),
      title: '$fromName reacted $emoji',
      body: messagePreview,
      notificationDetails: details,
      payload: 'reaction:$fromPeerId',
    );

    unawaited(_audioService?.playReaction());

    Logger.info(
        'Reaction notification shown - $fromName $emoji', 'Notifications',);
  }

  /// Cancel all notifications
  Future<void> cancelAll() async {
    await _notificationsPlugin.cancelAll();
    Logger.info(
        'NotificationService: Cancelled all notifications', 'Notifications',);
  }

  /// Cancel notification by ID
  Future<void> cancel(int id) async {
    await _notificationsPlugin.cancel(id: id);
    Logger.info(
        'NotificationService: Cancelled notification $id', 'Notifications',);
  }

  /// Set badge count (iOS mainly)
  Future<void> setBadgeCount(int count) async {
    try {
      await AppBadgePlus.updateBadge(count);
      Logger.info(
          'NotificationService: Badge count set to $count', 'Notifications',);
    } on Exception catch (e) {
      Logger.debug(
          'NotificationService: Badge update not supported on this launcher: $e',
          'Notifications',);
    }
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

  static const int anchorDropBase = 3000;

  static int forAnchorDrop(String peerId) {
    return anchorDropBase + peerId.hashCode.abs() % 1000;
  }

  static const int reactionBase = 4000;

  static int forReaction(String peerId) {
    return reactionBase + peerId.hashCode.abs() % 1000;
  }
}
