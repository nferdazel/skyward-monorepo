import 'package:flutter/foundation.dart';

/// Sound service for UI feedback.
/// Currently logs sound events for future audio implementation.
/// When audio package is added, replace debugPrint with actual playback.
class SoundService {
  static bool _enabled = true;

  static void setEnabled(bool enabled) {
    _enabled = enabled;
  }

  /// Play a UI click/tap sound
  static void playTap() {
    if (!_enabled) return;
    // TODO: Play tap sound when audio package is added
    debugPrint('[SOUND] tap');
  }

  /// Play a success sound
  static void playSuccess() {
    if (!_enabled) return;
    debugPrint('[SOUND] success');
  }

  /// Play an error/alert sound
  static void playError() {
    if (!_enabled) return;
    debugPrint('[SOUND] error');
  }

  /// Play a notification sound
  static void playNotification() {
    if (!_enabled) return;
    debugPrint('[SOUND] notification');
  }

  /// Play a milestone achievement sound
  static void playAchievement() {
    if (!_enabled) return;
    debugPrint('[SOUND] achievement');
  }

  /// Play a cash register / revenue sound
  static void playCashRegister() {
    if (!_enabled) return;
    debugPrint('[SOUND] cash_register');
  }
}
