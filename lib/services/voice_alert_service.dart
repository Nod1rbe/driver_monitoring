import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

/// Xavfli holatda (DANGER) ovoz fayli (assets'dan) chalinadi.
///
/// Fayl 14 s davom etadi, lekin biz faqat dastlabki 3 sekundini chalamiz.
/// Agar haydovchi uyg'onmasa va holat hali ham DANGER bo'lsa, segmentni
/// qaytadan boshlaymiz (loop). SAFE/WARNING ga o'tsa darhol to'xtaydi.
class VoiceAlertService {
  VoiceAlertService();

  // AssetSource pathi `assets/` papkasiga nisbatan beriladi — prefiks qo'shilmasin.
  static const String _assetPath = 'danger-alarm-sound-effect-meme.mp3';
  static const Duration _segmentDuration = Duration(seconds: 3);

  final AudioPlayer _player = AudioPlayer();
  bool _initialized = false;
  bool _isAlarmActive = false;
  Timer? _segmentTimer;

  Future<void> init() async {
    if (_initialized) return;
    await _player.setReleaseMode(ReleaseMode.stop);
    await _player.setVolume(1.0);
    _initialized = true;
  }

  /// DANGER kelganda chaqiriladi. Idempotent — agar signal allaqachon
  /// chalinayotgan bo'lsa, qayta boshlamaydi.
  Future<void> startDangerAlarm() async {
    if (!_initialized) {
      await init();
    }
    if (_isAlarmActive) return;
    _isAlarmActive = true;
    unawaited(HapticFeedback.heavyImpact());
    await _playSegment();
  }

  Future<void> _playSegment() async {
    if (!_isAlarmActive) return;
    try {
      await _player.stop();
      await _player.play(AssetSource(_assetPath), volume: 1.0);
    } catch (_) {
      _isAlarmActive = false;
      return;
    }
    _segmentTimer?.cancel();
    _segmentTimer = Timer(_segmentDuration, () {
      if (!_isAlarmActive) return;
      // 3 sekund o'tdi — agar hali ham DANGER bo'lsa, segmentni qaytarsin.
      _playSegment();
    });
  }

  /// Risk SAFE/WARNING ga tushganda chaqiriladi.
  Future<void> stopAlarm() async {
    if (!_isAlarmActive) return;
    _isAlarmActive = false;
    _segmentTimer?.cancel();
    _segmentTimer = null;
    try {
      await _player.stop();
    } catch (_) {}
  }

  /// Eski API bilan moslik uchun.
  Future<void> speakDangerAlert() => startDangerAlarm();
  Future<void> stopSpeaking() => stopAlarm();

  Future<void> dispose() async {
    await stopAlarm();
    await _player.dispose();
  }
}
