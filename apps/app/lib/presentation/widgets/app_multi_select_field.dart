import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';
import 'app_button.dart';
import 'app_dialog_shell.dart';

/// A multi-select field that opens a checkbox picker dialog.
class AppMultiSelectField extends StatelessWidget {
  final String label;
  final List<String> options;
  final List<String> selectedValues;
  final ValueChanged<List<String>> onChanged;

  const AppMultiSelectField({
    super.key,
    required this.label,
    required this.options,
    required this.selectedValues,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final summary = selectedValues.isEmpty
        ? 'ALL'
        : selectedValues.length == 1
        ? selectedValues.first.toUpperCase()
        : '${selectedValues.length} SELECTED';

    return Semantics(
      button: true,
      label: 'Select $label',
      child: InkWell(
        onTap: () => _showPicker(context),
        borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: AppTheme.background,
        borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
            border: Border.all(color: AppTheme.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: AppTypography.captionRegular.copyWith(
                        color: AppTypography.textSecondary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      summary,
                      style: AppTypography.badgeText.copyWith(
                        color: AppTypography.textPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Icon(Icons.expand_more, color: AppTheme.primary, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showPicker(BuildContext context) async {
    final working = List<String>.from(selectedValues);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AppDialogShell(
              title: label,
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 300),
                      child: SingleChildScrollView(
                        child: Column(
                          children: options.map((option) {
                            final selected = working.contains(option);
                            return CheckboxListTile(
                              value: selected,
                              dense: true,
                              visualDensity: const VisualDensity(
                                horizontal: -4,
                                vertical: -4,
                              ),
                              contentPadding: EdgeInsets.zero,
                              activeColor: AppTheme.primary,
                              controlAffinity: ListTileControlAffinity.leading,
                              title: Text(
                                option.toUpperCase(),
                                style: AppTypography.captionRegular.copyWith(
                                  color: AppTypography.textPrimary,
                                ),
                              ),
                              onChanged: (_) {
                                setState(() {
                                  if (selected) {
                                    working.remove(option);
                                  } else {
                                    working.add(option);
                                  }
                                });
                              },
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      children: [
                        AppButton(
                          text: 'CLEAR',
                          onPressed: () {
                            onChanged(const []);
                            Navigator.of(dialogContext).pop();
                          },
                          type: AppButtonType.secondary,
                          height: 40,
                        ),
                        const Spacer(),
                        AppButton(
                          text: 'CANCEL',
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          type: AppButtonType.secondary,
                          height: 40,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        AppButton(
                          text: 'APPLY',
                          onPressed: () {
                            onChanged(working);
                            Navigator.of(dialogContext).pop();
                          },
                          height: 40,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
