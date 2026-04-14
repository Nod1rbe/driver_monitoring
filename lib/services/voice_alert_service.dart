import 'package:flutter_tts/flutter_tts.dart';

class VoiceAlertService {
  VoiceAlertService() : _tts = FlutterTts();

  final FlutterTts _tts;
  DateTime? _lastAlertTime;

  Future<void> init() async {
    await _tts.setLanguage('uz-UZ');
    await _tts.setSpeechRate(0.48);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
  }

  Future<void> speakDangerAlert() async {
    final now = DateTime.now();
    if (_lastAlertTime != null &&
        now.difference(_lastAlertTime!) < const Duration(seconds: 8)) {
      return;
    }

    _lastAlertTime = now;
    await _tts.stop();
    await _tts.speak('Diqqat! Sizda uyqu holati aniqlandi. Xavfsiz joyga toxtang.');
  }

  Future<void> stopSpeaking() async {
    await _tts.stop();
  }

  Future<void> dispose() async {
    await _tts.stop();
  }
}
