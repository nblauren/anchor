import 'dart:io';
import 'dart:typed_data';

import 'package:image_compression_flutter/image_compression_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../core/constants/app_constants.dart';
import '../core/errors/app_error.dart';
import '../core/utils/logger.dart';

/// Service for handling image picking, compression, and storage
class ImageService {
  ImageService();

  final ImagePicker _picker = ImagePicker();
  final Uuid _uuid = const Uuid();

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

  /// Compress an image file
  Future<File> compressImage(File imageFile) async {
    try {
      final input = ImageFile(
        filePath: imageFile.path,
        rawBytes: await imageFile.readAsBytes(),
      );

      final config = Configuration(
        outputType: ImageOutputType.webpThenJpg,
        quality: AppConstants.imageQuality,
      );

      final output = await compressor.compress(ImageFileConfiguration(
        input: input,
        config: config,
      ));

      // Save compressed image
      final compressedFile = File(imageFile.path);
      await compressedFile.writeAsBytes(output.rawBytes);

      Logger.info(
        'Compressed image: ${input.sizeInBytes} -> ${output.sizeInBytes} bytes',
        'Image',
      );

      return compressedFile;
    } catch (e) {
      Logger.error('Failed to compress image', e, null, 'Image');
      throw ImageError('Failed to compress image', e);
    }
  }

  /// Save an image to local storage
  Future<String> saveImageToLocal(File imageFile) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final imagesDir = Directory('${directory.path}/profile_images');

      if (!await imagesDir.exists()) {
        await imagesDir.create(recursive: true);
      }

      final fileName = '${_uuid.v4()}.jpg';
      final savedPath = '${imagesDir.path}/$fileName';

      await imageFile.copy(savedPath);
      Logger.info('Saved image to: $savedPath', 'Image');

      return savedPath;
    } catch (e) {
      Logger.error('Failed to save image', e, null, 'Image');
      throw ImageError('Failed to save image', e);
    }
  }

  /// Delete an image from local storage
  Future<void> deleteImage(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        Logger.info('Deleted image: $path', 'Image');
      }
    } catch (e) {
      Logger.error('Failed to delete image', e, null, 'Image');
      throw ImageError('Failed to delete image', e);
    }
  }

  /// Get all saved profile images
  Future<List<String>> getSavedImages() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final imagesDir = Directory('${directory.path}/profile_images');

      if (!await imagesDir.exists()) {
        return [];
      }

      final files = await imagesDir.list().toList();
      return files
          .whereType<File>()
          .map((f) => f.path)
          .toList();
    } catch (e) {
      Logger.error('Failed to get saved images', e, null, 'Image');
      throw ImageError('Failed to get saved images', e);
    }
  }

  /// Create a thumbnail from an image
  Future<Uint8List> createThumbnail(File imageFile) async {
    try {
      final input = ImageFile(
        filePath: imageFile.path,
        rawBytes: await imageFile.readAsBytes(),
      );

      final config = Configuration(
        outputType: ImageOutputType.webpThenJpg,
        quality: 60,
      );

      final output = await compressor.compress(ImageFileConfiguration(
        input: input,
        config: config,
      ));

      return output.rawBytes;
    } catch (e) {
      Logger.error('Failed to create thumbnail', e, null, 'Image');
      throw ImageError('Failed to create thumbnail', e);
    }
  }
}
