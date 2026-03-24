import 'dart:io';

import 'package:anchor/core/utils/logger.dart';
import 'package:nsfw_detector_flutter/nsfw_detector_flutter.dart';

/// Result of an on-device sensitive-content analysis.
class NsfwCheckResult {
  const NsfwCheckResult({
    required this.isSafe,
    this.confidence = 1.0,
  });

  /// Whether the image is considered safe to broadcast publicly.
  final bool isSafe;

  /// Confidence score: 1.0 = definitely safe, 0.0 = definitely unsafe.
  final double confidence;

  @override
  String toString() =>
      'NsfwCheckResult(isSafe=$isSafe, confidence=${confidence.toStringAsFixed(2)})';
}

/// Contract for on-device sensitive-content detection.
///
/// Plug in your ML model by providing a concrete subclass:
///   - [StubNsfwDetectionService] (default) — always safe, compiles without
///     any ML dependency.  Use this until your model is ready.
///   - See in-code examples for `tflite_flutter` and `nsfw_detector_flutter`.
// This is a legitimate interface pattern for dependency injection.
// ignore: one_member_abstracts
abstract class NsfwDetectionService {
  /// Analyse the image at [absolutePath] and return a [NsfwCheckResult].
  ///
  /// Runs on the calling isolate.  If your model is CPU-heavy, wrap in
  /// `compute()` to keep the UI responsive.
  Future<NsfwCheckResult> analyzeImage(String absolutePath);
}

/// Production implementation backed by the `nsfw_detector_flutter` package
/// (Yahoo open_nsfw TFLite model, runs fully on-device).
///
/// The [NsfwDetector] is loaded lazily on the first call and reused
/// thereafter — loading is ~100–300 ms the first time.
///
/// **Platform requirements**
/// - Android: `minSdkVersion 26` in `android/app/build.gradle`
/// - iOS: Disable "Strip Linked Product" in Xcode Build Settings
///        (target → Build Settings → search "strip linked product" → set to No)
class NsfwDetectorFlutterService implements NsfwDetectionService {
  NsfwDetectorFlutterService({this.threshold = 0.7});

  /// Probability threshold above which an image is considered NSFW.
  /// The default (0.7) matches the package default.
  final double threshold;

  NsfwDetector? _detector;

  Future<NsfwDetector> _getDetector() async {
    _detector ??= await NsfwDetector.load();
    return _detector!;
  }

  @override
  Future<NsfwCheckResult> analyzeImage(String absolutePath) async {
    final detector = await _getDetector();
    final result = await detector.detectNSFWFromFile(File(absolutePath));
    Logger.info(
      'NsfwDetection: score=${result?.score.toStringAsFixed(3)} '
          'isNsfw=${result?.isNsfw} path=$absolutePath',
      'NSFW',
    );

    if (result == null) {
      Logger.error('NSFW detection failed for $absolutePath', 'NSFW');
      return const NsfwCheckResult(isSafe: true);
    }

    return NsfwCheckResult(
      isSafe: !result.isNsfw,
      confidence: result.score,
    );
  }
}
