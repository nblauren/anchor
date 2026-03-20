import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/local_database/database.dart';

/// Floating emoji picker shown as an overlay above a message bubble.
/// Animates in with a scale+fade on the container and staggered pop per emoji.
class FloatingEmojiPicker extends StatefulWidget {
  const FloatingEmojiPicker({
    super.key,
    required this.emojis,
    required this.onEmojiTap,
    this.currentReactions = const [],
    required this.ownUserId,
  });

  final List<String> emojis;
  final void Function(String emoji) onEmojiTap;
  final List<ReactionEntry> currentReactions;
  final String ownUserId;

  @override
  State<FloatingEmojiPicker> createState() => _FloatingEmojiPickerState();
}

class _FloatingEmojiPickerState extends State<FloatingEmojiPicker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _containerScale;
  late final Animation<double> _containerOpacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _containerScale = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutBack,
    );
    _containerOpacity = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Returns a staggered animation interval for emoji at [index].
  Animation<double> _emojiAnimation(int index) {
    final count = widget.emojis.length;
    final start = 0.15 + (index / count) * 0.5; // stagger start 0.15–0.65
    final end = (start + 0.35).clamp(0.0, 1.0);
    return CurvedAnimation(
      parent: _controller,
      curve: Interval(start, end, curve: Curves.easeOutBack),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: FadeTransition(
        opacity: _containerOpacity,
        child: ScaleTransition(
          scale: _containerScale,
          alignment: Alignment.bottomLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: AppTheme.darkCard,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(widget.emojis.length, (i) {
                final emoji = widget.emojis[i];
                final alreadyReacted = widget.currentReactions.any(
                    (r) => r.senderId == widget.ownUserId && r.emoji == emoji);
                return ScaleTransition(
                  scale: _emojiAnimation(i),
                  child: GestureDetector(
                    onTap: () => widget.onEmojiTap(emoji),
                    child: Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: alreadyReacted
                          ? BoxDecoration(
                              color:
                                  AppTheme.primaryColor.withValues(alpha: 0.25),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: AppTheme.primaryColor
                                    .withValues(alpha: 0.5),
                              ),
                            )
                          : null,
                      child: Text(emoji, style: const TextStyle(fontSize: 24)),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}
