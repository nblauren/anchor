import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../bloc/profile_state.dart';

/// Preview widget showing how the profile will appear to others
class ProfilePreviewWidget extends StatelessWidget {
  const ProfilePreviewWidget({
    super.key,
    required this.name,
    this.age,
    this.bio,
    required this.photos,
  });

  final String? name;
  final int? age;
  final String? bio;
  final List<ProfilePhoto> photos;

  @override
  Widget build(BuildContext context) {
    final primaryPhoto = photos.isNotEmpty
        ? photos.firstWhere((p) => p.isPrimary, orElse: () => photos.first)
        : null;

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.darkCard,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Icon(Icons.visibility, color: AppTheme.textSecondary, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Profile Preview',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                ),
              ],
            ),
          ),
          // Preview card (mimics discovery grid card)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: AspectRatio(
              aspectRatio: 0.75,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Photo or placeholder
                      if (primaryPhoto != null)
                        Image.file(
                          File(primaryPhoto.photoPath),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _buildPlaceholder(),
                        )
                      else
                        _buildPlaceholder(),

                      // Gradient overlay
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withOpacity(0.8),
                            ],
                            stops: const [0.5, 1.0],
                          ),
                        ),
                      ),

                      // User info
                      Positioned(
                        left: 12,
                        right: 12,
                        bottom: 12,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _formatNameAge(),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (bio != null && bio!.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                bio!,
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.8),
                                  fontSize: 12,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),

                      // Photo count indicator
                      if (photos.length > 1)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.6),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.photo_library,
                                  color: Colors.white,
                                  size: 14,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '${photos.length}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: AppTheme.darkSurface,
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.person, size: 48, color: AppTheme.textSecondary),
            SizedBox(height: 8),
            Text(
              'Add a photo',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  String _formatNameAge() {
    final displayName = name?.isNotEmpty == true ? name : 'Your Name';
    if (age != null) {
      return '$displayName, $age';
    }
    return displayName!;
  }
}
