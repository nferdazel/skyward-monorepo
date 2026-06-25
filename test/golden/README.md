# Golden Tests

Golden tests for visual regression testing.

## Running

```bash
flutter test --update-goldens test/golden/
```

## Adding New Golden Tests

1. Create a test file in this directory
2. Use `matchesGoldenFile()` matcher
3. Run with `--update-goldens` to create baseline screenshots
