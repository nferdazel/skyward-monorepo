# Contributing to Skyward

Thank you for your interest in contributing to Skyward!

## Getting Started

1. Fork the repository
2. Clone your fork
3. Create a feature branch: `git checkout -b feature/your-feature`
4. Make your changes
5. Run tests: `flutter test`
6. Run analysis: `flutter analyze`
7. Commit with conventional messages: `git commit -m "feat: your feature"`
8. Push and create a Pull Request

## Development Setup

```bash
flutter pub get
cp .env.example .env  # Add your Supabase credentials
dart run build_runner build
flutter run
```

## Code Style

- Follow the [MAINTAINER_STANDARD.md](MAINTAINER_STANDARD.md)
- Cubit-only state management
- Feature-first architecture with gateway pattern for data access
- Desktop web only (no mobile responsive)
- Use the design system tokens (AppTheme, AppSpacing, AppTypography)

## Commit Convention

Use conventional commits:
- `feat:` — New features
- `fix:` — Bug fixes
- `refactor:` — Code refactoring
- `docs:` — Documentation
- `test:` — Tests
- `chore:` — Maintenance

## Pull Request Guidelines

- Keep PRs focused on a single change
- Include tests for new features
- Update documentation if needed
- Ensure `flutter analyze` and `flutter test` pass

## Test Structure

Tests are organized into layers:

- `test/layer1_unit/` — Unit tests (cubits, models, business logic)
- `test/layer2_widget/` — Widget smoke tests
- `test/layer3_integration/` — Integration tests (auth flows, realtime)
- `test/layer4_database/` — SQL audit and RPC/trigger tests

Run a specific layer: `flutter test test/layer1_unit/`
