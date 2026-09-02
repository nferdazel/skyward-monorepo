import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_motion.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

class CommandItem {
  final String id;
  final String title;
  final String category;
  final IconData icon;
  final String? shortcut;
  final VoidCallback onSelected;

  const CommandItem({
    required this.id,
    required this.title,
    required this.category,
    required this.icon,
    this.shortcut,
    required this.onSelected,
  });
}

/// A Linear/Raycast-inspired Command Palette (Cmd + K / Ctrl + K) for rapid keyboard navigation.
class CommandPalette extends StatefulWidget {
  final List<CommandItem> commands;

  const CommandPalette({
    super.key,
    required this.commands,
  });

  static Future<void> show({
    required BuildContext context,
    required List<CommandItem> commands,
  }) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'CommandPaletteDismiss',
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: AppMotion.micro,
      pageBuilder: (ctx, anim1, anim2) {
        return Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 100.0),
            child: CommandPalette(commands: commands),
          ),
        );
      },
      transitionBuilder: (ctx, anim, secondaryAnim, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: AppMotion.springSnappy,
        );
        return ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
          child: FadeTransition(
            opacity: anim,
            child: child,
          ),
        );
      },
    );
  }

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _selectedIndex = 0;
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  List<CommandItem> get _filteredCommands {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return widget.commands;
    return widget.commands.where((cmd) {
      return cmd.title.toLowerCase().contains(query) ||
          cmd.category.toLowerCase().contains(query);
    }).toList();
  }

  void _handleKey(KeyEvent event) {
    if (event is KeyDownEvent) {
      final items = _filteredCommands;
      if (items.isEmpty) return;

      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        setState(() {
          _selectedIndex = (_selectedIndex + 1) % items.length;
        });
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        setState(() {
          _selectedIndex = (_selectedIndex - 1 + items.length) % items.length;
        });
      } else if (event.logicalKey == LogicalKeyboardKey.enter) {
        if (_selectedIndex >= 0 && _selectedIndex < items.length) {
          final selected = items[_selectedIndex];
          Navigator.of(context).pop();
          selected.onSelected();
        }
      } else if (event.logicalKey == LogicalKeyboardKey.escape) {
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredCommands;

    return KeyboardListener(
      focusNode: _focusNode,
      onKeyEvent: _handleKey,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 580.0,
          constraints: const BoxConstraints(maxHeight: 420.0),
          decoration: BoxDecoration(
            color: AppTheme.surfaceElevated,
            borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
            border: Border.all(
              color: AppTheme.borderHighlight,
              width: 1.0,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Search Header
              Container(
                height: 48.0,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceRaised,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(AppSpacing.radiusDefault - 1),
                  ),
                  border: Border(
                    bottom: BorderSide(
                      color: AppTheme.borderSubtle,
                      width: 1.0,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.search,
                      size: 18,
                      color: AppTheme.primary,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        style: AppTypography.bodyMedium.copyWith(
                          color: AppTheme.textPrimary,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Type a command, route, or fleet search...',
                          hintStyle: AppTypography.captionLight,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                          filled: false,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.surface,
                        borderRadius: BorderRadius.circular(2),
                        border: Border.all(
                          color: AppTheme.borderSubtle,
                          width: 1,
                        ),
                      ),
                      child: Text(
                        'ESC',
                        style: AppTypography.nanoLabel.copyWith(
                          color: AppTheme.textMuted,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Results List
              Flexible(
                child: filtered.isEmpty
                    ? Container(
                        padding: const EdgeInsets.all(AppSpacing.xxl),
                        alignment: Alignment.center,
                        child: Text(
                          'No matching commands found',
                          style: AppTypography.captionLight,
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: filtered.length,
                        padding: const EdgeInsets.all(AppSpacing.xs),
                        itemBuilder: (context, index) {
                          final item = filtered[index];
                          final isSelected = index == _selectedIndex;

                          return InkWell(
                            onTap: () {
                              Navigator.of(context).pop();
                              item.onSelected();
                            },
                            borderRadius: BorderRadius.circular(
                              AppSpacing.radiusTight,
                            ),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.md,
                                vertical: AppSpacing.sm,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? AppTheme.surfaceActive
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(
                                  AppSpacing.radiusTight,
                                ),
                                border: isSelected
                                    ? Border.all(
                                        color: AppTheme.borderHighlight,
                                        width: 1.0,
                                      )
                                    : null,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    item.icon,
                                    size: 16,
                                    color: isSelected
                                        ? AppTheme.primary
                                        : AppTheme.textSecondary,
                                  ),
                                  const SizedBox(width: AppSpacing.md),
                                  Expanded(
                                    child: Text(
                                      item.title,
                                      style: AppTypography.bodyMedium.copyWith(
                                        color: isSelected
                                            ? AppTheme.textPrimary
                                            : AppTheme.textSecondary,
                                        fontWeight: isSelected
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppTheme.surface,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                    child: Text(
                                      item.category.toUpperCase(),
                                      style: AppTypography.nanoLabel.copyWith(
                                        color: AppTheme.textMuted,
                                        fontSize: 9,
                                      ),
                                    ),
                                  ),
                                  if (item.shortcut != null) ...[
                                    const SizedBox(width: AppSpacing.sm),
                                    Text(
                                      item.shortcut!,
                                      style: AppTypography.nanoLabel.copyWith(
                                        color: AppTheme.primary,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
