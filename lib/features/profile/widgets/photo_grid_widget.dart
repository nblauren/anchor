import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../services/image_service.dart' show resolvePhotoPath;
import '../bloc/profile_state.dart';

/// Grid widget for displaying and managing profile photos with drag and drop reordering
class PhotoGridWidget extends StatelessWidget {
  const PhotoGridWidget({
    super.key,
    required this.photos,
    required this.onAddPhoto,
    required this.onRemovePhoto,
    required this.onReorder,
    required this.onSetPrimary,
    this.isLoading = false,
    this.maxPhotos = 5,
  });

  final List<ProfilePhoto> photos;
  final VoidCallback onAddPhoto;
  final Function(String photoId) onRemovePhoto;
  final Function(List<String> photoIds) onReorder;
  final Function(String photoId) onSetPrimary;
  final bool isLoading;
  final int maxPhotos;

  @override
  Widget build(BuildContext context) {
    final canAddMore = photos.length < maxPhotos;
    final itemCount = canAddMore ? photos.length + 1 : photos.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Photos',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            Text(
              '${photos.length}/$maxPhotos',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'First photo is shown in discovery. Long press to set as primary.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppTheme.textHint,
              ),
        ),
        const SizedBox(height: 12),
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: itemCount,
          onReorder: (oldIndex, newIndex) {
            if (oldIndex >= photos.length || newIndex > photos.length) return;
            if (newIndex > oldIndex) newIndex--;

            final reordered = List<ProfilePhoto>.from(photos);
            final item = reordered.removeAt(oldIndex);
            reordered.insert(newIndex, item);

            onReorder(reordered.map((p) => p.id).toList());
          },
          itemBuilder: (context, index) {
            // Add photo button
            if (index == photos.length && canAddMore) {
              return _AddPhotoButton(
                key: const ValueKey('add_photo'),
                onTap: onAddPhoto,
                isLoading: isLoading,
              );
            }

            final photo = photos[index];
            return _PhotoItem(
              key: ValueKey(photo.id),
              photo: photo,
              index: index,
              onRemove: () => onRemovePhoto(photo.id),
              onSetPrimary: () => onSetPrimary(photo.id),
            );
          },
        ),
      ],
    );
  }
}

class _PhotoItem extends StatefulWidget {
  const _PhotoItem({
    super.key,
    required this.photo,
    required this.index,
    required this.onRemove,
    required this.onSetPrimary,
  });

  final ProfilePhoto photo;
  final int index;
  final VoidCallback onRemove;
  final VoidCallback onSetPrimary;

  @override
  State<_PhotoItem> createState() => _PhotoItemState();
}

class _PhotoItemState extends State<_PhotoItem> {
  late Future<String?> _resolvedPath;

  @override
  void initState() {
    super.initState();
    _resolvedPath = resolvePhotoPath(widget.photo.photoPath);
  }

  @override
  void didUpdateWidget(_PhotoItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photo.photoPath != widget.photo.photoPath) {
      _resolvedPath = resolvePhotoPath(widget.photo.photoPath);
    }
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photo;
    final index = widget.index;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ReorderableDragStartListener(
        index: index,
        child: GestureDetector(
          onLongPress: photo.isPrimary ? null : widget.onSetPrimary,
          child: Container(
            height: 100,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: photo.isPrimary
                  ? Border.all(color: AppTheme.primaryColor, width: 2)
                  : null,
            ),
            child: Row(
              children: [
                // Photo
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 100,
                    height: 100,
                    child: FutureBuilder<String?>(
                      future: _resolvedPath,
                      builder: (context, snapshot) {
                        final path = snapshot.data;
                        if (path == null) {
                          return Container(
                            color: AppTheme.darkCard,
                            child: const Icon(Icons.broken_image,
                                color: AppTheme.textSecondary),
                          );
                        }
                        return Image.file(
                          File(path),
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          errorBuilder: (_, __, ___) => Container(
                            color: AppTheme.darkCard,
                            child: const Icon(Icons.broken_image,
                                color: AppTheme.textSecondary),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Info
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (photo.isPrimary)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryColor,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'PRIMARY',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        )
                      else
                        Text(
                          'Photo ${index + 1}',
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 14,
                          ),
                        ),
                      const SizedBox(height: 4),
                      Text(
                        'Drag to reorder',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppTheme.textHint,
                            ),
                      ),
                    ],
                  ),
                ),
                // Actions
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: AppTheme.error),
                  onPressed: widget.onRemove,
                ),
                const Icon(Icons.drag_handle, color: AppTheme.textSecondary),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AddPhotoButton extends StatelessWidget {
  const _AddPhotoButton({
    super.key,
    required this.onTap,
    required this.isLoading,
  });

  final VoidCallback onTap;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: isLoading ? null : onTap,
        child: Container(
          height: 100,
          decoration: BoxDecoration(
            color: AppTheme.darkCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: AppTheme.primaryColor.withValues(alpha: 0.5),
              width: 2,
              strokeAlign: BorderSide.strokeAlignInside,
            ),
          ),
          child: Center(
            child: isLoading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppTheme.primaryColor,
                    ),
                  )
                : const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.add_photo_alternate,
                        color: AppTheme.primaryColor,
                        size: 32,
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Add Photo',
                        style: TextStyle(
                          color: AppTheme.primaryColor,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
