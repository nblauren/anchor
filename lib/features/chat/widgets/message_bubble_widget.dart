import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/local_database/database.dart';

/// Widget displaying a single chat message bubble
class MessageBubbleWidget extends StatelessWidget {
  const MessageBubbleWidget({
    super.key,
    required this.message,
    required this.isSentByMe,
    this.onRetry,
  });

  final MessageEntry message;
  final bool isSentByMe;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final isPhoto = message.contentType == MessageContentType.photo;

    return Align(
      alignment: isSentByMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
          top: 4,
          bottom: 4,
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
            // Content (text or photo)
            if (isPhoto) _buildPhotoContent() else _buildTextContent(),

            // Timestamp and status
            Padding(
              padding: EdgeInsets.only(
                left: 12,
                right: 12,
                bottom: 8,
                top: isPhoto ? 8 : 0,
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

  Widget _buildPhotoContent() {
    final photoPath = message.photoPath;

    if (photoPath == null || photoPath.isEmpty) {
      return _buildPhotoPlaceholder();
    }

    final file = File(photoPath);

    return GestureDetector(
      onTap: () {
        // Could open full-screen viewer
      },
      child: FutureBuilder<bool>(
        future: file.exists(),
        builder: (context, snapshot) {
          if (snapshot.data != true) {
            return _buildPhotoPlaceholder();
          }

          return Stack(
            children: [
              Image.file(
                file,
                fit: BoxFit.cover,
                width: double.infinity,
                height: 200,
                errorBuilder: (context, error, stackTrace) =>
                    _buildPhotoPlaceholder(),
              ),
              // Loading overlay for pending messages
              if (message.status == MessageStatus.pending)
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
          );
        },
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
