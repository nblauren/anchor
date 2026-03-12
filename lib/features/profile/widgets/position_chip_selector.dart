import 'package:flutter/material.dart';

import '../../../core/constants/profile_constants.dart';
import '../../../core/theme/app_theme.dart';

/// Single-select chip grid for position preference.
///
/// Displays all positions from [ProfileConstants.positionMap] as [ChoiceChip]s.
/// Tapping an already-selected chip deselects it (sets value to null).
/// Emits [int?] via [onChanged].
class PositionChipSelector extends StatelessWidget {
  const PositionChipSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  /// Currently selected position ID, or null if unset.
  final int? value;

  /// Called with the new ID, or null when deselected.
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: ProfileConstants.positionMap.entries.map((e) {
        final selected = value == e.key;

        return ChoiceChip(
          label: Text(e.value),
          selected: selected,
          onSelected: (_) => onChanged(selected ? null : e.key),
          selectedColor: AppTheme.primaryLight.withAlpha(51),
          backgroundColor: AppTheme.darkCard,
          labelStyle: TextStyle(
            color: selected ? AppTheme.primaryLight : AppTheme.textSecondary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
          side: BorderSide(
            color: selected ? AppTheme.primaryLight : Colors.white12,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        );
      }).toList(),
    );
  }
}
