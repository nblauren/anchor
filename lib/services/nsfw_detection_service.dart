import '../core/utils/logger.dart';

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
abstract class NsfwDetectionService {
  /// Analyse the image at [absolutePath] and return a [NsfwCheckResult].
  ///
  /// Runs on the calling isolate.  If your model is CPU-heavy, wrap in
  /// `compute()` to keep the UI responsive.
  Future<NsfwCheckResult> analyzeImage(String absolutePath);
}

/// Stub that always reports safe.
///
/// Replace the body of [analyzeImage] with real inference before shipping
/// to production.  Two ready-to-use integration patterns are documented
/// in comments below.
class StubNsfwDetectionService implements NsfwDetectionService {
  const StubNsfwDetectionService();

  @override
  Future<NsfwCheckResult> analyzeImage(String absolutePath) async {
    // ── tflite_flutter integration ─────────────────────────────────────────
    //
    // 1. Add to pubspec.yaml:
    //      tflite_flutter: ^0.10.4
    //      flutter:
    //        assets:
    //          - assets/models/nsfw_model.tflite
    //
    // 2. Replace this method body with:
    //
    //    import 'dart:io';
    //    import 'package:tflite_flutter/tflite_flutter.dart';
    //    import 'package:image/image.dart' as img;
    //
    //    final interpreter =
    //        await Interpreter.fromAsset('assets/models/nsfw_model.tflite');
    //    final rawBytes = await File(absolutePath).readAsBytes();
    //    final image = img.decodeImage(rawBytes)!;
    //    final resized = img.copyResize(image, width: 224, height: 224);
    //
    //    // Normalise to [-1, 1] float32 (adjust per your model's input spec)
    //    final input = List.generate(
    //      1,
    //      (_) => List.generate(224, (y) => List.generate(224, (x) {
    //        final pixel = resized.getPixel(x, y);
    //        return [
    //          (img.getRed(pixel) / 127.5) - 1.0,
    //          (img.getGreen(pixel) / 127.5) - 1.0,
    //          (img.getBlue(pixel) / 127.5) - 1.0,
    //        ];
    //      })),
    //    );
    //    // Output shape [1, N_classes].  Adjust indices for your label order.
    //    // Example: class 1 = "sexy/nude", class 3 = "porn"
    //    final output = List.filled(5, 0.0).reshape([1, 5]);
    //    interpreter.run(input, output);
    //
    //    final nsfwScore = (output[0][1] as double) + (output[0][3] as double);
    //    return NsfwCheckResult(
    //      isSafe: nsfwScore < 0.5,
    //      confidence: 1.0 - nsfwScore,
    //    );
    //
    // ── nsfw_detector_flutter integration ─────────────────────────────────
    //
    // 1. Add to pubspec.yaml:
    //      nsfw_detector_flutter: ^latest
    //
    // 2. Replace this method body with:
    //
    //    import 'package:nsfw_detector_flutter/nsfw_detector_flutter.dart';
    //
    //    final result = await NsfwDetector.detectFromPath(absolutePath);
    //    return NsfwCheckResult(
    //      isSafe: result.classification != NsfwClass.nsfw,
    //      confidence: result.confidence ?? 1.0,
    //    );
    //
    // ──────────────────────────────────────────────────────────────────────

    // Stub: always safe.
    Logger.info(
      'NsfwDetection: stub check — always safe '
      '(replace StubNsfwDetectionService with real model)',
      'NSFW',
    );
    return const NsfwCheckResult(isSafe: true, confidence: 1.0);
  }
}
