import 'package:anchor/core/utils/logger.dart';
import 'package:audioplayers/audioplayers.dart';

/// Lightweight service for playing in-app sound effects.
///
/// All sounds use [AVAudioSessionCategory.ambient] (iOS) and
/// [AndroidUsageType.notificationRingtone] mapped through the notification
/// stream (Android), so they are silenced automatically when the device is
/// on silent / Do Not Disturb.
class AudioService {
  AudioService();

  final AudioPlayer _player = AudioPlayer();

  static const _popSound = 'audio/mixkit-long-pop-2358.wav';

  // Audio context that respects the iOS silent switch and Android DND.
  static final _silentRespectingContext = AudioContext(
    iOS: AudioContextIOS(
      // Ambient: plays through the speaker but stops when the silent switch
      // is engaged or the screen locks with silent mode on.
      category: AVAudioSessionCategory.ambient,
    ),
    android: const AudioContextAndroid(
      contentType: AndroidContentType.sonification,
      // STREAM_NOTIFICATION — respects Do Not Disturb and volume settings.
      usageType: AndroidUsageType.notificationRingtone,
      audioFocus: AndroidAudioFocus.none,
    ),
  );

  /// Play the pop sound for incoming messages and anchor drops.
  Future<void> playPop() async {
    try {
      await _player.setAudioContext(_silentRespectingContext);
      await _player.play(AssetSource(_popSound));
    } catch (e) {
      Logger.warning('AudioService: Failed to play sound: $e', 'Audio');
    }
  }

  /// Play a short sound when someone reacts to your message.
  /// Respects the device silent switch / Do Not Disturb.
  Future<void> playReaction() async {
    try {
      await _player.setAudioContext(_silentRespectingContext);
      await _player.play(AssetSource(_popSound));
    } catch (e) {
      Logger.warning('AudioService: Failed to play reaction sound: $e', 'Audio');
    }
  }

  Future<void> dispose() async {
    await _player.dispose();
  }
}
