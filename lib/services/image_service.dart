import 'dart:io';
import 'dart:typed_data';

import 'package:image_compression_flutter/image_compression_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../core/constants/app_constants.dart';
import '../core/errors/app_error.dart';
import '../core/utils/logger.dart';

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
  static const int _thumbnailMaxSize = 100; // 100x100 px
  static const int _thumbnailMaxBytes = 15 * 1024; // 15KB
  static const int _thumbnailInitialQuality = 70;

  /// Pick an image from gallery
  Future<File?> pickFromGallery() async {
    try {
      final XFile? image = await _picker.pickImage(
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
      final XFile? image = await _picker.pickImage(
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

      if (!await imagesDir.exists()) {
        await imagesDir.create(recursive: true);
      }
      if (!await thumbsDir.exists()) {
        await thumbsDir.create(recursive: true);
      }

      final fileId = _uuid.v4();

      // Compress and save full image
      final compressedBytes = await _compressFullImage(imageFile);
      final photoPath = '${imagesDir.path}/$fileId.jpg';
      await File(photoPath).writeAsBytes(compressedBytes);

      // Generate and save thumbnail
      final thumbnailBytes = await _generateThumbnail(imageFile);
      final thumbnailPath = '${thumbsDir.path}/$fileId_thumb.jpg';
      await File(thumbnailPath).writeAsBytes(thumbnailBytes);

      Logger.info(
        'Processed image: photo=${compressedBytes.length}B, thumb=${thumbnailBytes.length}B',
        'Image',
      );

      return ProcessedImage(
        photoPath: photoPath,
        thumbnailPath: thumbnailPath,
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

    final config = Configuration(
      outputType: ImageOutputType.jpg,
      quality: AppConstants.imageQuality,
    );

    final output = await compressor.compress(ImageFileConfiguration(
      input: input,
      config: config,
    ));

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
      ));

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

    final config = Configuration(
      outputType: ImageOutputType.jpg,
      quality: 10,
    );

    final output = await compressor.compress(ImageFileConfiguration(
      input: input,
      config: config,
    ));

    Logger.warning(
      'Thumbnail still large: ${output.sizeInBytes}B (target: ${_thumbnailMaxBytes}B)',
      'Image',
    );

    return output.rawBytes;
  }

  /// Generate thumbnail bytes from an existing photo path
  Future<Uint8List> generateThumbnailFromPath(String photoPath) async {
    final file = File(photoPath);
    if (!await file.exists()) {
      throw ImageError('Photo file not found: $photoPath');
    }
    return _generateThumbnail(file);
  }

  /// Delete an image and its thumbnail
  Future<void> deleteImage(String photoPath, String thumbnailPath) async {
    try {
      final photoFile = File(photoPath);
      if (await photoFile.exists()) {
        await photoFile.delete();
        Logger.info('Deleted photo: $photoPath', 'Image');
      }

      final thumbFile = File(thumbnailPath);
      if (await thumbFile.exists()) {
        await thumbFile.delete();
        Logger.info('Deleted thumbnail: $thumbnailPath', 'Image');
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
      if (await photoFile.exists()) {
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
      if (await file.exists()) {
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

      if (!await chatImagesDir.exists()) {
        await chatImagesDir.create(recursive: true);
      }

      final file = File(imagePath);
      if (!await file.exists()) {
        throw ImageError('Image file not found: $imagePath');
      }

      final inputBytes = await file.readAsBytes();
      final fileId = _uuid.v4();

      // Target ~150KB with quality 60
      final input = ImageFile(
        filePath: imagePath,
        rawBytes: inputBytes,
      );

      final config = Configuration(
        outputType: ImageOutputType.jpg,
        quality: 60,
      );

      final output = await compressor.compress(ImageFileConfiguration(
        input: input,
        config: config,
      ));

      final outputPath = '${chatImagesDir.path}/$fileId.jpg';
      await File(outputPath).writeAsBytes(output.rawBytes);

      Logger.info(
        'Compressed chat image: ${inputBytes.length}B -> ${output.sizeInBytes}B',
        'Image',
      );

      return outputPath;
    } catch (e) {
      Logger.error('Failed to compress chat image', e, null, 'Image');
      throw ImageError('Failed to compress chat image', e);
    }
  }

  /// Save a received photo from BLE transfer
  Future<String> saveReceivedPhoto(Uint8List photoData) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final receivedDir = Directory('${directory.path}/received_photos');

      if (!await receivedDir.exists()) {
        await receivedDir.create(recursive: true);
      }

      final fileId = _uuid.v4();
      final photoPath = '${receivedDir.path}/$fileId.jpg';
      await File(photoPath).writeAsBytes(photoData);

      Logger.info(
        'Saved received photo: ${photoData.length}B -> $photoPath',
        'Image',
      );

      return photoPath;
    } catch (e) {
      Logger.error('Failed to save received photo', e, null, 'Image');
      throw ImageError('Failed to save received photo', e);
    }
  }

  /// Clean up orphaned images not in the database
  Future<void> cleanupOrphanedImages(List<String> validPaths) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final imagesDir = Directory('${directory.path}/profile_images');
      final thumbsDir = Directory('${directory.path}/thumbnails');

      if (await imagesDir.exists()) {
        await for (final entity in imagesDir.list()) {
          if (entity is File && !validPaths.contains(entity.path)) {
            await entity.delete();
            Logger.info('Cleaned up orphaned image: ${entity.path}', 'Image');
          }
        }
      }

      if (await thumbsDir.exists()) {
        await for (final entity in thumbsDir.list()) {
          if (entity is File && !validPaths.contains(entity.path)) {
            await entity.delete();
            Logger.info('Cleaned up orphaned thumbnail: ${entity.path}', 'Image');
          }
        }
      }
    } catch (e) {
      Logger.error('Failed to cleanup orphaned images', e, null, 'Image');
    }
  }
}
