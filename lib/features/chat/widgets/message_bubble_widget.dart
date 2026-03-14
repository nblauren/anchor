import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/local_database/database.dart';
import '../../../services/image_service.dart';
import '../bloc/chat_state.dart';

/// Groups reactions by emoji and returns a sorted list of (emoji, count, isMine) tuples.
List<({String emoji, int count, bool isMine})> groupReactions(
  List<ReactionEntry> reactions,
  String ownUserId,
) {
  final Map<String, List<ReactionEntry>> byEmoji = {};
  for (final r in reactions) {
    byEmoji.putIfAbsent(r.emoji, () => []).add(r);
  }
  return byEmoji.entries
      .map((e) => (
            emoji: e.key,
            count: e.value.length,
            isMine: e.value.any((r) => r.senderId == ownUserId),
          ))
      .toList()
    ..sort((a, b) => b.count.compareTo(a.count));
}

/// Widget displaying a single chat message bubble.
///
/// Handles three content types:
///   - [MessageContentType.text] — plain text
///   - [MessageContentType.photo] — fully-downloaded image with full-screen viewer
///   - [MessageContentType.photoPreview] — thumbnail + consent overlay; receiver
///     taps to request the full photo via [onRequestFullPhoto].
class MessageBubbleWidget extends StatelessWidget {
  const MessageBubbleWidget({
    super.key,
    required this.message,
    required this.isSentByMe,
    required this.ownUserId,
    this.onRetry,
    this.isRelayedPeer = false,
    this.transferInfo,
    this.onRequestFullPhoto,
    this.onCancelTransfer,
    this.reactions = const [],
    this.onReact,
    this.onLongPress,
  });

  final MessageEntry message;
  final bool isSentByMe;
  final String ownUserId;
  final VoidCallback? onRetry;
  /// When true and message is sent by us, show a relay indicator.
  final bool isRelayedPeer;
  /// Progress info for an active photo transfer keyed to this message.
  final PhotoTransferInfo? transferInfo;
  /// Called when the receiver taps the preview thumbnail to request the full photo.
  /// Receives the [photoId] from the preview metadata.
  final void Function(String photoId)? onRequestFullPhoto;
  /// Called when the user taps the cancel button during an active transfer.
  final VoidCallback? onCancelTransfer;
  /// Reactions for this message.
  final List<ReactionEntry> reactions;
  /// Called when a reaction chip is tapped. Receives the emoji.
  final void Function(String emoji)? onReact;
  /// Called on long-press to open the emoji picker.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final contentType = message.contentType;
    final grouped = groupReactions(reactions, ownUserId);

    return Align(
      alignment: isSentByMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment:
            isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onLongPress: onLongPress,
            child: Container(
              margin: EdgeInsets.only(
                top: 4,
                bottom: grouped.isEmpty ? 4 : 2,
                left: isSentByMe ? 48 : 0,
                right: isSentByMe ? 0 : 48,
              ),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              decoration: BoxDecoration(
                color: isSentByMe ? AppTheme.primaryColor : AppTheme.darkCard,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: isSentByMe
                      ? const Radius.circular(16)
                      : const Radius.circular(4),
                  bottomRight: isSentByMe
                      ? const Radius.circular(4)
                      : const Radius.circular(16),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (contentType == MessageContentType.photo)
                    _buildPhotoContent(context)
                  else if (contentType == MessageContentType.photoPreview)
                    _buildPhotoPreviewContent(context)
                  else
                    _buildTextContent(),

                  // Timestamp and status row
                  Padding(
                    padding: EdgeInsets.only(
                      left: 12,
                      right: 12,
                      bottom: 8,
                      top: contentType != MessageContentType.text ? 8 : 0,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _formatTime(message.createdAt),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 11,
                          ),
                        ),
                        if (isSentByMe && isRelayedPeer) ...[
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.hub_outlined,
                            size: 11,
                            color: Colors.white38,
                          ),
                        ],
                        if (isSentByMe) ...[
                          const SizedBox(width: 4),
                          _buildStatusIcon(),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Reaction chips
          if (grouped.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(
                left: isSentByMe ? 48 : 4,
                right: isSentByMe ? 4 : 48,
                bottom: 4,
              ),
              child: Wrap(
                spacing: 4,
                children: grouped.map((g) {
                  return GestureDetector(
                    onTap: () => onReact?.call(g.emoji),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: g.isMine
                            ? AppTheme.primaryColor.withValues(alpha: 0.35)
                            : AppTheme.darkCard,
                        borderRadius: BorderRadius.circular(12),
                        border: g.isMine
                            ? Border.all(
                                color: AppTheme.primaryColor.withValues(
                                    alpha: 0.7),
                                width: 1,
                              )
                            : null,
                      ),
                      child: Text(
                        g.count > 1 ? '${g.emoji} ${g.count}' : g.emoji,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTextContent() {
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 12, top: 10),
      child: Text(
        message.textContent ?? '',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 15,
          height: 1.3,
        ),
      ),
    );
  }

  Widget _buildPhotoContent(BuildContext context) {
    final photoPath = message.photoPath;
    if (photoPath == null || photoPath.isEmpty) {
      return _buildPhotoPlaceholder();
    }

    return _PhotoContent(
      photoPath: photoPath,
      status: message.status,
      transferInfo: transferInfo,
      isSentByMe: isSentByMe,
      onTap: (file) => _showFullScreen(context, file),
      onCancel: onCancelTransfer,
    );
  }

  Widget _buildPhotoPreviewContent(BuildContext context) {
    // Parse metadata stored in textContent.
    String photoId = '';
    int originalSize = 0;
    try {
      final meta =
          jsonDecode(message.textContent ?? '{}') as Map<String, dynamic>;
      photoId = meta['photo_id'] as String? ?? '';
      originalSize = meta['original_size'] as int? ?? 0;
    } catch (_) {}

    return _PhotoPreviewContent(
      thumbnailPath: message.photoPath,
      status: message.status,
      photoId: photoId,
      originalSize: originalSize,
      transferInfo: transferInfo,
      isSentByMe: isSentByMe,
      onRequestFullPhoto: onRequestFullPhoto,
      onCancel: onCancelTransfer,
    );
  }

  void _showFullScreen(BuildContext context, File file) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => Dialog(
        insetPadding: EdgeInsets.zero,
        backgroundColor: Colors.transparent,
        child: Stack(
          fit: StackFit.expand,
          children: [
            PhotoView(
              imageProvider: FileImage(file),
              minScale: PhotoViewComputedScale.contained * 0.8,
              maxScale: PhotoViewComputedScale.covered * 4.0,
              initialScale: PhotoViewComputedScale.contained,
              backgroundDecoration: const BoxDecoration(color: Colors.black),
              loadingBuilder: (context, event) => const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
              errorBuilder: (context, error, stackTrace) => const Center(
                child: Icon(Icons.broken_image, color: Colors.white54, size: 64),
              ),
            ),
            Positioned(
              top: 40,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 36),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPhotoPlaceholder() {
    return Container(
      width: double.infinity,
      height: 150,
      color: AppTheme.darkCard,
      child: const Center(
        child: Icon(
          Icons.image,
          color: AppTheme.textHint,
          size: 48,
        ),
      ),
    );
  }

  Widget _buildStatusIcon() {
    switch (message.status) {
      case MessageStatus.pending:
        return SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: Colors.white.withValues(alpha: 0.6),
          ),
        );
      case MessageStatus.sent:
        return Icon(
          Icons.done,
          size: 14,
          color: Colors.white.withValues(alpha: 0.6),
        );
      case MessageStatus.delivered:
        return const Icon(
          Icons.done_all,
          size: 14,
          color: Colors.lightBlueAccent,
        );
      case MessageStatus.read:
        return const Icon(
          Icons.done_all,
          size: 14,
          color: Colors.lightBlueAccent,
        );
      case MessageStatus.failed:
        return GestureDetector(
          onTap: onRetry,
          child: const Icon(
            Icons.error_outline,
            size: 14,
            color: Colors.redAccent,
          ),
        );
    }
  }

  String _formatTime(DateTime dateTime) {
    return '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
  }
}

// ---------------------------------------------------------------------------
// Photo preview with tap-to-download consent overlay
// ---------------------------------------------------------------------------

class _PhotoPreviewContent extends StatefulWidget {
  const _PhotoPreviewContent({
    required this.thumbnailPath,
    required this.status,
    required this.photoId,
    required this.originalSize,
    required this.isSentByMe,
    this.transferInfo,
    this.onRequestFullPhoto,
    this.onCancel,
  });

  final String? thumbnailPath;
  final MessageStatus status;
  final String photoId;
  final int originalSize;
  final bool isSentByMe;
  final PhotoTransferInfo? transferInfo;
  final void Function(String photoId)? onRequestFullPhoto;
  final VoidCallback? onCancel;

  @override
  State<_PhotoPreviewContent> createState() => _PhotoPreviewContentState();
}

class _PhotoPreviewContentState extends State<_PhotoPreviewContent> {
  late Future<String?> _resolvedPathFuture;

  @override
  void initState() {
    super.initState();
    _resolvedPathFuture = resolvePhotoPath(widget.thumbnailPath ?? '');
  }

  @override
  void didUpdateWidget(_PhotoPreviewContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.thumbnailPath != widget.thumbnailPath) {
      _resolvedPathFuture = resolvePhotoPath(widget.thumbnailPath ?? '');
    }
  }

  String get _formattedSize {
    final bytes = widget.originalSize;
    if (bytes <= 0) return '';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  bool get _isDownloading => widget.transferInfo != null;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _resolvedPathFuture,
      builder: (context, snapshot) {
        final resolvedPath = snapshot.data;
        final file =
            resolvedPath != null ? File(resolvedPath) : null;

        return Stack(
          children: [
            // Blurred thumbnail background
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: file != null
                  ? Image.file(
                      file,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: 200,
                      errorBuilder: (_, __, ___) => _buildPlaceholder(),
                    )
                  : _buildPlaceholder(),
            ),

            // Dark scrim
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: Colors.black.withValues(alpha: 0.45),
                ),
              ),
            ),

            // Consent overlay or progress overlay
            Positioned.fill(
              child: _isDownloading
                  ? _buildProgressOverlay()
                  : widget.isSentByMe
                      ? _buildSentOverlay()
                      : _buildConsentOverlay(context),
            ),
          ],
        );
      },
    );
  }

  /// Overlay shown on the SENDER's side: "Waiting for recipient to download"
  Widget _buildSentOverlay() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.photo_camera_outlined, color: Colors.white70, size: 32),
        const SizedBox(height: 8),
        Text(
          'Preview sent',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.85),
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
        if (_formattedSize.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            _formattedSize,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 12,
            ),
          ),
        ],
        const SizedBox(height: 4),
        Text(
          'Waiting for tap to download',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  /// Overlay shown on the RECEIVER's side: tap to download
  Widget _buildConsentOverlay(BuildContext context) {
    return GestureDetector(
      onTap: () => widget.onRequestFullPhoto?.call(widget.photoId),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.download_rounded,
              color: Colors.white,
              size: 32,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _formattedSize.isNotEmpty
                ? 'Photo ($_formattedSize)'
                : 'Photo',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Tap to download full photo',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  /// Progress overlay shown while the full photo is being transferred.
  Widget _buildProgressOverlay() {
    final info = widget.transferInfo!;
    final percent = info.progressPercent;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 48,
          height: 48,
          child: CircularProgressIndicator(
            value: info.progress > 0 ? info.progress : null,
            color: Colors.white,
            strokeWidth: 3,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          info.progress > 0 ? 'Downloading $percent%' : 'Starting...',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.9),
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: widget.onCancel,
          icon: const Icon(Icons.cancel_outlined, size: 16, color: Colors.white70),
          label: Text(
            'Cancel',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 12,
            ),
          ),
          style: TextButton.styleFrom(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            minimumSize: Size.zero,
          ),
        ),
      ],
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      width: double.infinity,
      height: 200,
      color: AppTheme.darkSurface,
      child: const Center(
        child: Icon(Icons.image, color: AppTheme.textHint, size: 48),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Full photo content (existing, enhanced with cancel support)
// ---------------------------------------------------------------------------

class _PhotoContent extends StatefulWidget {
  const _PhotoContent({
    required this.photoPath,
    required this.status,
    required this.isSentByMe,
    required this.onTap,
    this.transferInfo,
    this.onCancel,
  });

  final String photoPath;
  final MessageStatus status;
  final bool isSentByMe;
  final void Function(File file) onTap;
  final PhotoTransferInfo? transferInfo;
  final VoidCallback? onCancel;

  @override
  State<_PhotoContent> createState() => _PhotoContentState();
}

class _PhotoContentState extends State<_PhotoContent> {
  late Future<String?> _resolvedPathFuture;

  @override
  void initState() {
    super.initState();
    _resolvedPathFuture = resolvePhotoPath(widget.photoPath);
  }

  @override
  void didUpdateWidget(_PhotoContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photoPath != widget.photoPath) {
      _resolvedPathFuture = resolvePhotoPath(widget.photoPath);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _resolvedPathFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _buildPlaceholder();
        }

        final resolvedPath = snapshot.data;
        if (resolvedPath == null) return _buildPlaceholder();

        final file = File(resolvedPath);

        return GestureDetector(
          onTap: () => widget.onTap(file),
          child: Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  file,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: 200,
                  errorBuilder: (context, error, stackTrace) =>
                      _buildPlaceholder(),
                ),
              ),
              // Upload progress overlay (sender side)
              if (widget.transferInfo != null)
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: Colors.black.withValues(alpha: 0.45),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 40,
                          height: 40,
                          child: CircularProgressIndicator(
                            value: widget.transferInfo!.progress > 0
                                ? widget.transferInfo!.progress
                                : null,
                            color: Colors.white,
                            strokeWidth: 3,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          widget.transferInfo!.progress > 0
                              ? '${widget.transferInfo!.progressPercent}%'
                              : 'Sending…',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        TextButton.icon(
                          onPressed: widget.onCancel,
                          icon: const Icon(Icons.cancel_outlined,
                              size: 14, color: Colors.white70),
                          label: const Text(
                            'Cancel',
                            style:
                                TextStyle(color: Colors.white70, fontSize: 11),
                          ),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 2),
                            minimumSize: Size.zero,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else if (widget.status == MessageStatus.pending)
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.4),
                    child: const Center(
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      width: double.infinity,
      height: 150,
      color: AppTheme.darkCard,
      child: const Center(
        child: Icon(Icons.image, color: AppTheme.textHint, size: 48),
      ),
    );
  }
}
