import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../presentation/theme/app_typography.dart';

/// Baris pengatur jumlah kursi. Dipakai dialog konfigurasi kursi (pesawat yang
/// sudah dimiliki) dan dialog pembelian kursi, jadi ia ikut pindah bersama
/// keduanya alih-alih disalin.
class SeatAdjustmentRow extends StatelessWidget {
  const SeatAdjustmentRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.maxPossible,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  final int maxPossible;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: AppTypography.badgeText.copyWith(
                color: AppTheme.textPrimary,
              ),
            ),
            Text(
              '$value Seats',
              style: AppTypography.badgeText.copyWith(color: AppTheme.primary),
            ),
          ],
        ),
        Row(
          children: [
            IconButton(
              icon: Icon(Icons.remove, size: 16, color: AppTheme.textSecondary),
              onPressed: value > 0 ? () => onChanged(value - 1) : null,
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2.0,
                  activeTrackColor: AppTheme.primary,
                  inactiveTrackColor: AppTheme.border,
                  thumbColor: AppTheme.primary,
                  overlayColor: AppTheme.primary.withValues(alpha: 0.1),
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                ),
                child: Slider(
                  value: value.toDouble(),
                  min: 0,
                  max: maxPossible.toDouble(),
                  onChanged: (v) => onChanged(v.toInt()),
                ),
              ),
            ),
            IconButton(
              icon: Icon(Icons.add, size: 16, color: AppTheme.textSecondary),
              onPressed: value < maxPossible
                  ? () => onChanged(value + 1)
                  : null,
            ),
          ],
        ),
      ],
    );
  }
}
