import 'package:audioplayers/audioplayers.dart';

import '../core/utils/logger.dart';

/// Lightweight service for playing in-app sound effects.
class AudioService {
  AudioService();

  final AudioPlayer _player = AudioPlayer();

  static const _popSound = 'audio/mixkit-long-pop-2358.wav';

  /// Play the pop sound for incoming messages and anchor drops.
  Future<void> playPop() async {
    try {
      await _player.play(AssetSource(_popSound));
    } catch (e) {
      Logger.warning('AudioService: Failed to play sound: $e', 'Audio');
    }
  }

  Future<void> dispose() async {
    await _player.dispose();
  }
}
