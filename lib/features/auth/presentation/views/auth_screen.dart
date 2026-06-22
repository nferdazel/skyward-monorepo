// ignore_for_file: curly_braces_in_flow_control_structures
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_button.dart';
import '../../../../presentation/widgets/app_snackbar.dart';
import '../../../../presentation/widgets/skyward_logo.dart';
import '../cubit/auth_cubit.dart';
import '../cubit/auth_state.dart';

class AuthModeCubit extends Cubit<bool> {
  AuthModeCubit() : super(true);
  void toggle() => emit(!state);
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  late final GlobalKey<FormState> _formKey;

  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _companyController;
  late final TextEditingController _ceoController;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _formKey = GlobalKey<FormState>();
    _usernameController = TextEditingController();
    _passwordController = TextEditingController();
    _companyController = TextEditingController();
    _ceoController = TextEditingController();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _companyController.dispose();
    _ceoController.dispose();
    super.dispose();
  }

  void _submitForm(BuildContext context, bool isLoginMode) {
    if (_formKey.currentState?.validate() ?? false) {
      final cubit = context.read<AuthCubit>();
      if (isLoginMode) {
        cubit.login(
          username: _usernameController.text,
          password: _passwordController.text,
        );
      } else {
        cubit.register(
          username: _usernameController.text,
          password: _passwordController.text,
          companyName: _companyController.text,
          ceoName: _ceoController.text,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider<AuthModeCubit>(
      create: (context) => AuthModeCubit(),
      child: Scaffold(
        body: BlocConsumer<AuthCubit, AuthState>(
          listener: (context, state) {
          if (state is AuthError) {
              AppSnackBar.showError(context, state.message);
            }
          },
          builder: (context, state) {
            final isLoading = state is AuthLoading;

            return Container(
              color: AppTheme.background,
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  child: BlocBuilder<AuthModeCubit, bool>(
                    builder: (context, isLoginMode) => ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: _buildFormCard(
                        context,
                        isLoading,
                        isLoginMode,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildFormCard(
    BuildContext context,
    bool isLoading,
    bool isLoginMode,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Logo
        SkywardLogo(size: 64, showBackground: true),
        const SizedBox(height: AppSpacing.lg),
        // Wordmark
        Text(
          AppStrings.skyward,
          style: AppTypography.screenTitleLarge.copyWith(
            fontSize: 20,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.12,
            color: AppTheme.primary,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        // Subtitle
        Text(
          'AIRLINE OPERATIONS SIMULATOR',
          style: AppTypography.microLabel.copyWith(
            color: AppTheme.textSecondary,
          ),
        ),
        const SizedBox(height: AppSpacing.xxxl),
        // Tab switcher
        BlocBuilder<AuthModeCubit, bool>(
          builder: (context, isLoginMode) {
            return Container(
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: AppTheme.border),
              ),
              padding: const EdgeInsets.all(AppSpacing.xs),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () {
                        if (!isLoginMode) {
                          context.read<AuthCubit>().clearError();
                          context.read<AuthModeCubit>().toggle();
                          _formKey.currentState?.reset();
                        }
                      },
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.sm,
                        ),
                        decoration: BoxDecoration(
                          color: isLoginMode
                              ? AppTheme.accentSubtle
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Center(
                          child: Text(
                            'LOGIN',
                            style: AppTypography.microLabel.copyWith(
                              color: isLoginMode
                                  ? AppTheme.primary
                                  : AppTheme.textSecondary,
                              fontWeight: isLoginMode
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: () {
                        if (isLoginMode) {
                          context.read<AuthCubit>().clearError();
                          context.read<AuthModeCubit>().toggle();
                          _formKey.currentState?.reset();
                        }
                      },
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.sm,
                        ),
                        decoration: BoxDecoration(
                          color: !isLoginMode
                              ? AppTheme.accentSubtle
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Center(
                          child: Text(
                            'REGISTER',
                            style: AppTypography.microLabel.copyWith(
                              color: !isLoginMode
                                  ? AppTheme.primary
                                  : AppTheme.textSecondary,
                              fontWeight: !isLoginMode
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: AppSpacing.xl),
        // Form
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Username
              TextFormField(
                controller: _usernameController,
                keyboardType: TextInputType.name,
                enabled: !isLoading,
                decoration: const InputDecoration(
                  labelText: 'USERNAME',
                  prefixIcon: Icon(Icons.person_outline, size: 20),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty)
                    return AppStrings.enterValidUsername;
                  if (value.trim().length < 4)
                    return AppStrings.usernameMinLength;
                  return null;
                },
              ),
              const SizedBox(height: AppSpacing.md),
              // Password
              TextFormField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                enabled: !isLoading,
                decoration: InputDecoration(
                  labelText: 'PASSWORD',
                  prefixIcon: const Icon(Icons.lock_outline, size: 20),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                      color: AppTheme.textMuted,
                      size: 18,
                    ),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty)
                    return AppStrings.enterValidPassword;
                  if (value.length < 6)
                    return AppStrings.passwordMinLength;
                  return null;
                },
              ),
              if (!isLoginMode) ...[
                const SizedBox(height: AppSpacing.md),
                // Company Name
                TextFormField(
                  controller: _companyController,
                  enabled: !isLoading,
                  decoration: const InputDecoration(
                    labelText: 'COMPANY NAME',
                    prefixIcon: Icon(Icons.business_outlined, size: 20),
                    hintText: AppStrings.companyNameAuthHint,
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty)
                      return AppStrings.enterCompanyName;
                    return null;
                  },
                ),
                const SizedBox(height: AppSpacing.md),
                // CEO Name
                TextFormField(
                  controller: _ceoController,
                  enabled: !isLoading,
                  decoration: const InputDecoration(
                    labelText: 'CEO NAME',
                    prefixIcon: Icon(Icons.badge_outlined, size: 20),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty)
                      return AppStrings.enterCeoName;
                    return null;
                  },
                ),
              ],
              const SizedBox(height: AppSpacing.xxl),
              // Submit Button
              AppButton(
                text: isLoginMode
                    ? 'EXECUTE OPERATIONS'
                    : 'INCORPORATE COMPANY',
                onPressed: isLoading
                    ? null
                    : () => _submitForm(context, isLoginMode),
                isLoading: isLoading,
                width: double.infinity,
                height: 48,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
