import 'dart:io';
import 'dart:typed_data';

import 'package:anchor/core/constants/app_constants.dart';
import 'package:anchor/core/errors/app_error.dart';
import 'package:anchor/core/utils/logger.dart';
import 'package:image_compression_flutter/image_compression_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Resolve a photo path stored in the database to a valid absolute path.
///
/// Paths are stored relative to the app documents directory (e.g.
/// "chat_images/abc.jpg") so they survive app reinstalls where the iOS
/// sandbox UUID changes. Absolute paths from older versions are also handled
/// by stripping the sandbox-specific prefix.
Future<String?> resolvePhotoPath(String? storedPath) async {
  if (storedPath == null || storedPath.isEmpty) return null;

  // Try as-is first (handles current-session absolute paths)
  if (storedPath.startsWith('/') && File(storedPath).existsSync()) {
    return storedPath;
  }

  final docsDir = await getApplicationDocumentsDirectory();

  // Relative path (new format) — resolve against current docs dir
  if (!storedPath.startsWith('/')) {
    final resolved = '${docsDir.path}/$storedPath';
    return File(resolved).existsSync() ? resolved : null;
  }

  // Old absolute path whose sandbox UUID may have changed — re-root it
  const marker = '/Documents/';
  final idx = storedPath.indexOf(marker);
  if (idx != -1) {
    final relative = storedPath.substring(idx + marker.length);
    final resolved = '${docsDir.path}/$relative';
    return File(resolved).existsSync() ? resolved : null;
  }

  return null;
}

/// Result of processing an image with both full and thumbnail versions
class ProcessedImage {
  const ProcessedImage({
    required this.photoPath,
    required this.thumbnailPath,
    required this.thumbnailBytes,
  });

  final String photoPath;
  final String thumbnailPath;
  final Uint8List thumbnailBytes;
}

/// Service for handling image picking, compression, and storage
class ImageService {
  ImageService();

  final ImagePicker _picker = ImagePicker();
  final Uuid _uuid = const Uuid();

  // Thumbnail constraints for BLE broadcast
  static const int _thumbnailMaxBytes = 15 * 1024; // 15KB
  static const int _thumbnailInitialQuality = 70;

  // BLE transfer compression target (~50KB keeps transfer under 30s)
  static const int _bleTransferMaxBytes = 50 * 1024; // 50KB

  /// Pick an image from gallery
  Future<File?> pickFromGallery() async {
    try {
      final image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: AppConstants.maxImageWidth.toDouble(),
        maxHeight: AppConstants.maxImageHeight.toDouble(),
        imageQuality: AppConstants.imageQuality,
      );

      if (image == null) return null;
      return File(image.path);
    } catch (e) {
      Logger.error('Failed to pick image from gallery', e, null, 'Image');
      throw ImageError('Failed to pick image from gallery', e);
    }
  }

  /// Pick an image from camera
  Future<File?> pickFromCamera() async {
    try {
      final image = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: AppConstants.maxImageWidth.toDouble(),
        maxHeight: AppConstants.maxImageHeight.toDouble(),
        imageQuality: AppConstants.imageQuality,
        preferredCameraDevice: CameraDevice.front,
      );

      if (image == null) return null;
      return File(image.path);
    } catch (e) {
      Logger.error('Failed to pick image from camera', e, null, 'Image');
      throw ImageError('Failed to pick image from camera', e);
    }
  }

  /// Process an image: compress full version and generate thumbnail
  /// Returns paths and thumbnail bytes for BLE broadcast
  Future<ProcessedImage> processImage(File imageFile) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final imagesDir = Directory('${directory.path}/profile_images');
      final thumbsDir = Directory('${directory.path}/thumbnails');

      if (!imagesDir.existsSync()) {
        await imagesDir.create(recursive: true);
      }
      if (!thumbsDir.existsSync()) {
        await thumbsDir.create(recursive: true);
      }

      final fileId = _uuid.v4();

      // Compress and save full image
      final compressedBytes = await _compressFullImage(imageFile);
      final photoPath = '${imagesDir.path}/$fileId.jpg';
      await File(photoPath).writeAsBytes(compressedBytes);

      // Generate and save thumbnail
      final thumbnailBytes = await _generateThumbnail(imageFile);
      final thumbnailPath = '${thumbsDir.path}/${fileId}_thumb.jpg';
      await File(thumbnailPath).writeAsBytes(thumbnailBytes);

      Logger.info(
        'Processed image: photo=${compressedBytes.length}B, thumb=${thumbnailBytes.length}B',
        'Image',
      );

      // Return relative paths so they survive iOS sandbox UUID changes on reinstall
      return ProcessedImage(
        photoPath: 'profile_images/$fileId.jpg',
        thumbnailPath: 'thumbnails/${fileId}_thumb.jpg',
        thumbnailBytes: thumbnailBytes,
      );
    } catch (e) {
      Logger.error('Failed to process image', e, null, 'Image');
      throw ImageError('Failed to process image', e);
    }
  }

  /// Compress full-size image for local storage
  Future<Uint8List> _compressFullImage(File imageFile) async {
    final input = ImageFile(
      filePath: imageFile.path,
      rawBytes: await imageFile.readAsBytes(),
    );

    const config = Configuration(
      outputType: ImageOutputType.jpg,
    );

    final output = await compressor.compress(ImageFileConfiguration(
      input: input,
      config: config,
    ),);

    return output.rawBytes;
  }

  /// Generate a small thumbnail for BLE broadcast (max 15KB, ~100x100px)
  Future<Uint8List> _generateThumbnail(File imageFile) async {
    final inputBytes = await imageFile.readAsBytes();
    var quality = _thumbnailInitialQuality;

    // Try progressively lower quality until under size limit
    while (quality >= 10) {
      final input = ImageFile(
        filePath: imageFile.path,
        rawBytes: inputBytes,
      );

      final config = Configuration(
        outputType: ImageOutputType.jpg,
        quality: quality,
      );

      final output = await compressor.compress(ImageFileConfiguration(
        input: input,
        config: config,
      ),);

      if (output.sizeInBytes <= _thumbnailMaxBytes) {
        Logger.info(
          'Generated thumbnail: ${output.sizeInBytes}B at quality $quality',
          'Image',
        );
        return output.rawBytes;
      }

      quality -= 10;
    }

    // If still too large, return lowest quality version
    final input = ImageFile(
      filePath: imageFile.path,
      rawBytes: inputBytes,
    );

    const config = Configuration(
      outputType: ImageOutputType.jpg,
      quality: 10,
    );

    final output = await compressor.compress(ImageFileConfiguration(
      input: input,
      config: config,
    ),);

    Logger.warning(
      'Thumbnail still large: ${output.sizeInBytes}B (target: ${_thumbnailMaxBytes}B)',
      'Image',
    );

    return output.rawBytes;
  }

  /// Generate thumbnail bytes from an existing photo path
  Future<Uint8List> generateThumbnailFromPath(String photoPath) async {
    final file = File(photoPath);
    if (!file.existsSync()) {
      throw ImageError('Photo file not found: $photoPath');
    }
    return _generateThumbnail(file);
  }

  /// Delete an image and its thumbnail (paths may be relative or absolute)
  Future<void> deleteImage(String photoPath, String thumbnailPath) async {
    try {
      final resolvedPhoto = await resolvePhotoPath(photoPath);
      if (resolvedPhoto != null) {
        await File(resolvedPhoto).delete();
        Logger.info('Deleted photo: $resolvedPhoto', 'Image');
      }

      final resolvedThumb = await resolvePhotoPath(thumbnailPath);
      if (resolvedThumb != null) {
        await File(resolvedThumb).delete();
        Logger.info('Deleted thumbnail: $resolvedThumb', 'Image');
      }
    } catch (e) {
      Logger.error('Failed to delete image', e, null, 'Image');
      throw ImageError('Failed to delete image', e);
    }
  }

  /// Delete image by photo path only (derives thumbnail path)
  Future<void> deleteImageByPath(String photoPath) async {
    try {
      final photoFile = File(photoPath);
      if (photoFile.existsSync()) {
        await photoFile.delete();
        Logger.info('Deleted photo: $photoPath', 'Image');
      }
    } catch (e) {
      Logger.error('Failed to delete image', e, null, 'Image');
      throw ImageError('Failed to delete image', e);
    }
  }

  /// Get the primary thumbnail bytes for BLE broadcast
  Future<Uint8List?> getPrimaryThumbnailBytes(String? thumbnailPath) async {
    if (thumbnailPath == null) return null;

    try {
      final file = File(thumbnailPath);
      if (file.existsSync()) {
        return await file.readAsBytes();
      }
      return null;
    } catch (e) {
      Logger.error('Failed to read thumbnail', e, null, 'Image');
      return null;
    }
  }

  /// Compress a photo for chat messages (target ~100-200KB)
  Future<String> compressForChat(String imagePath) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final chatImagesDir = Directory('${directory.path}/chat_images');

      if (!chatImagesDir.existsSync()) {
        await chatImagesDir.create(recursive: true);
      }

      final file = File(imagePath);
      if (!file.existsSync()) {
        throw ImageError('Image file not found: $imagePath');
      }

      final inputBytes = await file.readAsBytes();
      final fileId = _uuid.v4();

      // Target ~150KB with quality 60
      final input = ImageFile(
        filePath: imagePath,
        rawBytes: inputBytes,
      );

      const config = Configuration(
        outputType: ImageOutputType.jpg,
        quality: 60,
      );

      final output = await compressor.compress(ImageFileConfiguration(
        input: input,
        config: config,
      ),);

      final outputPath = '${chatImagesDir.path}/$fileId.jpg';
      await File(outputPath).writeAsBytes(output.rawBytes);

      Logger.info(
        'Compressed chat image: ${inputBytes.length}B -> ${output.sizeInBytes}B',
        'Image',
      );

      // Return relative path so it survives sandbox UUID changes on reinstall
      return 'chat_images/$fileId.jpg';
    } catch (e) {
      Logger.error('Failed to compress chat image', e, null, 'Image');
      throw ImageError('Failed to compress chat image', e);
    }
  }

  /// Compress a photo aggressively for BLE transfer (target ~30-50KB)
  ///
  /// BLE has very limited bandwidth — each chunk is only a few hundred bytes
  /// and transfers take seconds per chunk. This reduces the image to the
  /// smallest reasonable size while maintaining recognisable quality.
  Future<Uint8List> compressForBleTransfer(String imagePath) async {
    try {
      final file = File(imagePath);
      if (!file.existsSync()) {
        throw ImageError('Image file not found: $imagePath');
      }

      final inputBytes = await file.readAsBytes();

      // Already small enough — skip re-compression
      if (inputBytes.length <= _bleTransferMaxBytes) {
        Logger.info(
          'BLE photo already small enough: ${inputBytes.length}B',
          'Image',
        );
        return inputBytes;
      }

      // Try progressively lower quality until under target
      var quality = 50;
      while (quality >= 10) {
        final input = ImageFile(
          filePath: imagePath,
          rawBytes: inputBytes,
        );

        final config = Configuration(
          outputType: ImageOutputType.jpg,
          quality: quality,
        );

        final output = await compressor.compress(ImageFileConfiguration(
          input: input,
          config: config,
        ),);

        if (output.sizeInBytes <= _bleTransferMaxBytes) {
          Logger.info(
            'BLE photo compressed: ${inputBytes.length}B -> ${output.sizeInBytes}B '
            '(quality $quality)',
            'Image',
          );
          return output.rawBytes;
        }

        quality -= 10;
      }

      // Last resort: lowest quality
      final input = ImageFile(
        filePath: imagePath,
        rawBytes: inputBytes,
      );

      const config = Configuration(
        outputType: ImageOutputType.jpg,
        quality: 10,
      );

      final output = await compressor.compress(ImageFileConfiguration(
        input: input,
        config: config,
      ),);

      Logger.warning(
        'BLE photo still large after max compression: ${output.sizeInBytes}B '
        '(target: ${_bleTransferMaxBytes}B)',
        'Image',
      );

      return output.rawBytes;
    } catch (e) {
      Logger.error('Failed to compress photo for BLE', e, null, 'Image');
      // Fallback: return original bytes
      return File(imagePath).readAsBytes();
    }
  }

  /// Save a received photo from BLE transfer
  Future<String> saveReceivedPhoto(Uint8List photoData) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final receivedDir = Directory('${directory.path}/received_photos');

      if (!receivedDir.existsSync()) {
        await receivedDir.create(recursive: true);
      }

      final fileId = _uuid.v4();
      final photoPath = '${receivedDir.path}/$fileId.jpg';
      await File(photoPath).writeAsBytes(photoData);

      Logger.info(
        'Saved received photo: ${photoData.length}B -> $photoPath',
        'Image',
      );

      // Return relative path so it survives sandbox UUID changes on reinstall
      return 'received_photos/$fileId.jpg';
    } catch (e) {
      Logger.error('Failed to save received photo', e, null, 'Image');
      throw ImageError('Failed to save received photo', e);
    }
  }

  /// Save thumbnail bytes received via BLE preview to a persistent file.
  ///
  /// Returns a relative path (e.g. "chat_thumbnails/uuid.jpg") that survives
  /// iOS sandbox UUID changes across reinstalls.
  Future<String> saveChatThumbnail(Uint8List thumbnailBytes) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final thumbDir = Directory('${directory.path}/chat_thumbnails');

      if (!thumbDir.existsSync()) {
        await thumbDir.create(recursive: true);
      }

      final fileId = _uuid.v4();
      final thumbPath = '${thumbDir.path}/$fileId.jpg';
      await File(thumbPath).writeAsBytes(thumbnailBytes);

      Logger.info(
        'Saved chat thumbnail: ${thumbnailBytes.length}B -> $thumbPath',
        'Image',
      );

      return 'chat_thumbnails/$fileId.jpg';
    } catch (e) {
      Logger.error('Failed to save chat thumbnail', e, null, 'Image');
      throw ImageError('Failed to save chat thumbnail', e);
    }
  }

  /// Generate a compact preview thumbnail for chat photo consent flow.
  ///
  /// Targets ≤15 KB so it can be transmitted over BLE in a few seconds.
  /// Reuses the existing [generateThumbnailFromPath] logic.
  Future<Uint8List> generatePreviewThumbnail(String absolutePhotoPath) async {
    return generateThumbnailFromPath(absolutePhotoPath);
  }

  /// Clean up orphaned images not in the database
  Future<void> cleanupOrphanedImages(List<String> validPaths) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final imagesDir = Directory('${directory.path}/profile_images');
      final thumbsDir = Directory('${directory.path}/thumbnails');

      if (imagesDir.existsSync()) {
        await for (final entity in imagesDir.list()) {
          if (entity is File && !validPaths.contains(entity.path)) {
            await entity.delete();
            Logger.info('Cleaned up orphaned image: ${entity.path}', 'Image');
          }
        }
      }

      if (thumbsDir.existsSync()) {
        await for (final entity in thumbsDir.list()) {
          if (entity is File && !validPaths.contains(entity.path)) {
            await entity.delete();
            Logger.info(
                'Cleaned up orphaned thumbnail: ${entity.path}', 'Image',);
          }
        }
      }
    } catch (e) {
      Logger.error('Failed to cleanup orphaned images', e, null, 'Image');
    }
  }
}
