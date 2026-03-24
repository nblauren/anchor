import 'package:anchor/core/constants/profile_constants.dart';
import 'package:anchor/core/theme/app_theme.dart';
import 'package:flutter/material.dart';

/// Single-select dropdown for the user's position preference.
///
/// Stores / emits a compact integer ID (see [ProfileConstants.positionMap]).
/// Provides a "Clear" entry so the user can un-set their position.
class PositionDropdown extends StatelessWidget {
  const PositionDropdown({
    required this.value, required this.onChanged, super.key,
  });

  /// Currently selected position ID, or null if unset.
  final int? value;

  /// Called with the new ID when the user picks an option, or null to clear.
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DropdownButtonFormField<int?>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Position (optional)',
        hintText: 'Select your position',
        prefixIcon: const Icon(Icons.swap_vert_rounded),
        filled: true,
        fillColor: AppTheme.darkCard,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.white12),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppTheme.primaryLight),
        ),
      ),
      dropdownColor: AppTheme.darkCard,
      style: theme.textTheme.bodyLarge?.copyWith(color: AppTheme.textPrimary),
      items: [
        // Explicit "Not set" option
        const DropdownMenuItem<int?>(
          child: Text('— Not set —'),
        ),
        ...ProfileConstants.positionMap.entries.map(
          (e) => DropdownMenuItem<int?>(
            value: e.key,
            child: Text(e.value),
          ),
        ),
      ],
      onChanged: onChanged,
    );
  }
}
