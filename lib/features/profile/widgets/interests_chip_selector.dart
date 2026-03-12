import 'package:flutter/material.dart';

import '../../../core/constants/profile_constants.dart';
import '../../../core/theme/app_theme.dart';

/// Multi-select chip grid for interest tags.
///
/// - Displays all fixed interest options from [ProfileConstants.interestMap].
/// - No custom free-text input — only the predefined labels may be selected.
/// - Enforces a maximum of [ProfileConstants.maxInterestSelections] chips.
/// - Emits the full updated [List<int>] of selected IDs via [onChanged].
class InterestsChipSelector extends StatelessWidget {
  const InterestsChipSelector({
    super.key,
    required this.selectedIds,
    required this.onChanged,
  });

  /// Currently selected interest IDs.
  final List<int> selectedIds;

  /// Called with the complete updated list whenever selection changes.
  final ValueChanged<List<int>> onChanged;

  void _toggle(int id) {
    final updated = List<int>.from(selectedIds);
    if (updated.contains(id)) {
      updated.remove(id);
    } else if (updated.length < ProfileConstants.maxInterestSelections) {
      updated.add(id);
    }
    onChanged(updated);
  }

  @override
  Widget build(BuildContext context) {
    final atMax = selectedIds.length >= ProfileConstants.maxInterestSelections;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: ProfileConstants.interestMap.entries.map((e) {
            final selected = selectedIds.contains(e.key);
            final disabled = !selected && atMax;

            return FilterChip(
              label: Text(e.value),
              selected: selected,
              onSelected: disabled ? null : (_) => _toggle(e.key),
              selectedColor: AppTheme.primaryLight.withAlpha(51),
              checkmarkColor: AppTheme.primaryLight,
              backgroundColor: AppTheme.darkCard,
              disabledColor: AppTheme.darkCard.withAlpha(128),
              labelStyle: TextStyle(
                color: disabled
                    ? AppTheme.textHint
                    : selected
                        ? AppTheme.primaryLight
                        : AppTheme.textSecondary,
                fontWeight:
                    selected ? FontWeight.w600 : FontWeight.normal,
              ),
              side: BorderSide(
                color: selected
                    ? AppTheme.primaryLight
                    : Colors.white12,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            );
          }).toList(),
        ),
        if (atMax) ...[
          const SizedBox(height: 6),
          Text(
            'Max ${ProfileConstants.maxInterestSelections} interests selected',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.warning,
                ),
          ),
        ] else ...[
          const SizedBox(height: 6),
          Text(
            '${selectedIds.length} / ${ProfileConstants.maxInterestSelections} selected',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.textHint,
                ),
          ),
        ],
      ],
    );
  }
}
