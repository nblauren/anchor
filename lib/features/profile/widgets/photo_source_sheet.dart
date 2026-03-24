import 'package:anchor/core/theme/app_theme.dart';
import 'package:flutter/material.dart';

/// Bottom sheet for selecting photo source (camera or gallery)
class PhotoSourceSheet extends StatelessWidget {
  const PhotoSourceSheet({
    required this.onCamera, required this.onGallery, super.key,
  });

  final VoidCallback onCamera;
  final VoidCallback onGallery;

  static Future<void> show(
    BuildContext context, {
    required VoidCallback onCamera,
    required VoidCallback onGallery,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.darkSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => PhotoSourceSheet(
        onCamera: () {
          Navigator.pop(context);
          onCamera();
        },
        onGallery: () {
          Navigator.pop(context);
          onGallery();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.textSecondary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Add Photo',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 20),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.primaryLight.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child:
                    const Icon(Icons.camera_alt, color: AppTheme.primaryLight),
              ),
              title: const Text('Take Photo'),
              subtitle: const Text('Use your camera'),
              onTap: onCamera,
            ),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.primaryLight.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.photo_library,
                    color: AppTheme.primaryLight,),
              ),
              title: const Text('Choose from Gallery'),
              subtitle: const Text('Pick an existing photo'),
              onTap: onGallery,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
