import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/database/supabase_client.dart';
import '../../core/theme/app_theme.dart';
import '../../features/auth/presentation/cubit/auth_cubit.dart';
import '../../features/auth/presentation/cubit/auth_state.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';
import 'app_button.dart';

// ── Persistence key ──
const _kOnboardingCompleteKey = 'onboarding_complete';

// ── Animation durations ──
const _kStepTransitionDuration = Duration(milliseconds: 250);
const _kDotAnimationDuration = Duration(milliseconds: 200);

/// Returns `true` if the onboarding has already been completed.
Future<bool> isOnboardingComplete() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_kOnboardingCompleteKey) ?? false;
}

/// Marks onboarding as done so it never shows again.
Future<void> markOnboardingComplete() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_kOnboardingCompleteKey, true);
}

/// Persists onboarding_completed = true to the database for the given user.
Future<void> _persistOnboardingToDatabase(String userId) async {
  try {
    await SupabaseManager.client
        .from('users')
        .update({'onboarding_completed': true}).eq(
          'auth_user_id',
          SupabaseManager.client.auth.currentUser?.id ?? '',
        );
  } catch (e) {
    // Non-fatal: local cache is the primary gate; DB sync is best-effort.
    SupabaseManager.logError('persist_onboarding_completed', e);
  }
}

// ── Step model ──

class OnboardingStep {
  final String title;
  final String description;
  final IconData icon;
  final String? actionLabel;

  const OnboardingStep({
    required this.title,
    required this.description,
    required this.icon,
    this.actionLabel,
  });
}

// ── Overlay widget ──

class OnboardingOverlay extends StatefulWidget {
  const OnboardingOverlay({super.key, required this.onComplete});

  final VoidCallback onComplete;

  @override
  State<OnboardingOverlay> createState() => _OnboardingOverlayState();
}

class _OnboardingOverlayState extends State<OnboardingOverlay> {
  int _currentStep = 0;
  bool _dismissed = false;

  static const _steps = [
    OnboardingStep(
      title: 'Welcome to Skyward',
      description:
          'Build your airline from the ground up. Acquire aircraft, '
          'establish routes, and compete against AI rivals to become the '
          "world's top airline.",
      icon: Icons.flight_takeoff,
    ),
    OnboardingStep(
      title: 'Step 1: Acquire Aircraft',
      description:
          'Navigate to the Fleet tab and acquire your first aircraft. '
          'You can buy or lease — leasing requires less upfront capital.',
      icon: Icons.airplanemode_active,
      actionLabel: 'Go to Fleet',
    ),
    OnboardingStep(
      title: 'Step 2: Create a Route',
      description:
          'Navigate to the Routes tab and use the Blueprint Planner to '
          'create your first flight connection between two airports.',
      icon: Icons.map_outlined,
      actionLabel: 'Go to Routes',
    ),
    OnboardingStep(
      title: 'Step 3: Assign & Fly',
      description:
          'Assign your aircraft to the route. Once assigned, the '
          'simulation will automatically process flights and generate revenue.',
      icon: Icons.play_circle_outline,
    ),
    OnboardingStep(
      title: "You're Ready!",
      description:
          'Monitor your finances, expand your fleet, and climb the '
          'leaderboard. The simulation ticks every minute — your airline '
          'is always running.',
      icon: Icons.emoji_events_outlined,
      actionLabel: 'Start Playing',
    ),
  ];

  bool get _isLast => _currentStep == _steps.length - 1;

  void _next() {
    if (_isLast) {
      _complete();
    } else {
      setState(() => _currentStep++);
    }
  }

  void _back() {
    if (_currentStep > 0) {
      setState(() => _currentStep--);
    }
  }

  void _skip() {
    _complete();
  }

  void _complete() {
    if (_dismissed) return;
    _dismissed = true;
    markOnboardingComplete();
    // Also persist to the database so onboarding never shows on another device.
    final authState = context.read<AuthCubit>().state;
    if (authState is AuthAuthenticated) {
      _persistOnboardingToDatabase(authState.user.id);
    }
    widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    final step = _steps[_currentStep];

    return AnimatedSwitcher(
      duration: _kStepTransitionDuration,
      child: Material(
        key: ValueKey(_currentStep),
        color: Colors.black.withValues(alpha: 0.85),
        child: SafeArea(
          child: Stack(
            children: [
              // ── Centered card ──
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Container(
                    margin: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xxl,
                    ),
                    padding: const EdgeInsets.all(AppSpacing.xxxl),
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(
                        AppSpacing.radiusRound,
                      ),
                      border: Border.all(color: AppTheme.border),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Step indicator dots
                        _buildStepIndicator(),
                        const SizedBox(height: AppSpacing.xxxl),

                        // Icon
                        Icon(step.icon, size: 48, color: AppTheme.primary),
                        const SizedBox(height: AppSpacing.xl),

                        // Title
                        Text(
                          step.title,
                          style: AppTypography.screenTitleLarge,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: AppSpacing.md),

                        // Description
                        Text(
                          step.description,
                          style: AppTypography.bodyLarge.copyWith(
                            color: AppTheme.textSecondary,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: AppSpacing.xxxl),

                        // Navigation buttons
                        _buildActions(),
                      ],
                    ),
                  ),
                ),
              ),

              // ── Skip button (top-right) ──
              Positioned(
                top: AppSpacing.lg,
                right: AppSpacing.lg,
                child: AppButton(
                  text: 'SKIP',
                  onPressed: _skip,
                  type: AppButtonType.secondary,
                  height: 40,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStepIndicator() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_steps.length, (i) {
        final active = i == _currentStep;
        return AnimatedContainer(
          duration: _kDotAnimationDuration,
          width: active ? AppSpacing.xxl : AppSpacing.sm,
          height: AppSpacing.sm,
          margin: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          decoration: BoxDecoration(
            color: active ? AppTheme.primary : AppTheme.border,
            borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
          ),
        );
      }),
    );
  }

  Widget _buildActions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Back button — invisible on first step
        if (_currentStep > 0)
          AppButton(
            text: 'BACK',
            onPressed: _back,
            type: AppButtonType.secondary,
            height: 40,
          )
        else
          const SizedBox(width: 80),

        // Next / Start button
        AppButton(
          text: _isLast ? 'START PLAYING' : 'NEXT',
          onPressed: _next,
          height: 40,
        ),
      ],
    );
  }
}
