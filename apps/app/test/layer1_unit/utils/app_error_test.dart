import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/core/utils/app_error.dart';

void main() {
  group('AppError.extractMessage', () {
    test('SocketException returns network message', () {
      final error = Exception('SocketException: Connection refused');
      final result = AppError.extractMessage(error, 'fallback');
      expect(result, 'Network connection failed. Please check your connection.');
    });

    test('TimeoutException returns timeout message', () {
      final error = Exception('TimeoutException: Request timed out after 30s');
      final result = AppError.extractMessage(error, 'fallback');
      expect(result, 'Request timed out. Please try again.');
    });

    test('generic exception returns fallback', () {
      final error = Exception('Something weird happened');
      final result = AppError.extractMessage(error, 'Default error message');
      expect(result, 'Default error message');
    });

    test('empty fallback string is returned for unmatched errors', () {
      final error = StateError('bad state');
      final result = AppError.extractMessage(error, '');
      expect(result, '');
    });

    test('string containing SocketException is matched', () {
      final result = AppError.extractMessage(
        'SocketException: Failed host lookup',
        'fallback',
      );
      expect(result, 'Network connection failed. Please check your connection.');
    });

    test('string containing TimeoutException is matched', () {
      final result = AppError.extractMessage(
        'TimeoutException after 0:00:30.000000',
        'fallback',
      );
      expect(result, 'Request timed out. Please try again.');
    });
  });
}
