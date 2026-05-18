import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../models/driver_state.dart';

/// Haydovchining ko'z holatini real vaqtda tahlil qiluvchi servis.
///
/// Sezgirlikni to'g'irlash uchun quyidagi prinsiplar qo'llanildi:
///
///  * Bir kadrlik (instantaneous) "ko'z yopiq" qiymati XATARNI hisoblashda
///    ishlatilmaydi. Bu eski versiyaning asosiy bug'i edi: ML Kit har bir
///    pillapayotgan kadrda (~15..25 fps) ko'zni yopiq deb topib, har bir
///    pillapayish bir necha hodisa sifatida ro'yxatga olinardi va darhol
///    DANGER chiqarardi.
///  * O'rniga ko'z yopilishi DAVOMIYLIGI hisoblanadi: bir nechta kadr ketma-
///    ket "yopiq" deb belgilanganida, episode boshlanadi; ko'z ochilganda
///    yoki yopiqlik chegarani o'tganida, episode tamomlanadi va ko'rsatkichlar
///    yangilanadi.
///  * Davomiylik chegaralari:
///      - 0..400 ms      => oddiy pillapayish (blink), xato uchun e'tiborga
///                          olinmaydi, faqat blink rate uchun sanaladi;
///      - 400..1500 ms   => mikrouyqu (drowsy episode), ogohlantirish
///                          chiqariladi (WARNING);
///      - >= 1500 ms     => haqiqiy uxlash (DANGER), ovozli signal yoqiladi.
///  * PERCLOS metrikasi: oxirgi 60 soniya davomida ko'z yopiq bo'lgan
///    vaqtning umumiy ulushi (foiz). Bu klassik uyquchanlikni o'lchash
///    standarti hisoblanadi (Wierwille, 1994). Normal: <8%, charchagan:
///    15..25%, xavfli: >30%.
class CameraDrowsinessMonitorService {
  CameraDrowsinessMonitorService()
    : _faceDetector = FaceDetector(
        options: FaceDetectorOptions(
          enableClassification: true,
          performanceMode: FaceDetectorMode.fast,
        ),
      );

  // ---- Sozlamalar (tweak qilinadigan chegaralar) ----------------------------

  /// Ko'z yopiq deb hisoblanish chegarasi (ML Kit `eyeOpenProbability`).
  /// 0..1 oralig'ida: 1 = to'liq ochiq, 0 = to'liq yopiq.
  /// 0.30 chegarasi: nisbatan qattiq — engil siqilish (squint) yopiq emas.
  static const double _closedThreshold = 0.30;

  /// Ochilish chegarasi — hysteresis uchun (yopilishdan biroz yuqori).
  static const double _openThreshold = 0.55;

  /// Oddiy pillapayish chegarasi. Bundan qisqaroq episode — blink, e'tibordan
  /// soqit qilinadi.
  static const int _blinkMaxMs = 400;

  /// Mikrouyqu (drowsy episode) chegarasi. Bundan uzun episode hisoblanadi.
  static const int _drowsyMinMs = 400;

  /// Haqiqiy uxlash chegarasi. Ko'z shu vaqtdan ko'p yopiq bo'lsa, DANGER.
  static const int _sleepMs = 1500;

  /// Risk hisoblash uchun sliding window.
  static const Duration _window = Duration(seconds: 60);

  /// WARNING uchun PERCLOS chegarasi (%).
  static const double _perclosWarn = 15.0;

  /// DANGER uchun PERCLOS chegarasi (%).
  static const double _perclosDanger = 30.0;

  /// Tiklanish vaqti — ko'z shu davomda uzluksiz ochiq bo'lsa, to'plangan
  /// xavfli ko'rsatkichlar (drowsy episodelar) tozalanadi va tizim DANGER
  /// holatidan SAFE/WARNING tomon qaytadi.
  static const int _recoveryMs = 2500;

  // ---- Holat -----------------------------------------------------------------

  final FaceDetector _faceDetector;
  final StreamController<DriverState> _controller =
      StreamController<DriverState>.broadcast();

  // Pillapayishlar (oxirgi 60 s)
  final List<DateTime> _blinkEvents = <DateTime>[];

  // Mikrouyqu / sleep episodelar (oxirgi 60 s)
  final List<_ClosureEpisode> _drowsyEpisodes = <_ClosureEpisode>[];

  // Joriy yopilish episodesi (agar ko'z hozir yopiq bo'lsa)
  DateTime? _closureStartedAt;

  // Ko'z uzluksiz ochiq bo'lgan vaqtning boshlanishi (tiklanishni o'lchash uchun).
  DateTime? _eyesOpenedAt;

  // Hysteresis uchun joriy ko'z holati.
  bool _eyesClosed = false;

  CameraController? _cameraController;
  bool _processing = false;

  Stream<DriverState> get stateStream => _controller.stream;
  CameraController? get cameraController => _cameraController;
  bool get isCameraReady => _cameraController?.value.isInitialized ?? false;

  // ---- Hayot tsikli ----------------------------------------------------------

  Future<void> start() async {
    if (_cameraController != null && _cameraController!.value.isInitialized) {
      if (!(_cameraController!.value.isStreamingImages)) {
        await _cameraController!.startImageStream(_processFrame);
      }
      return;
    }

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw StateError('Kamera topilmadi');
    }

    final frontCamera = cameras.firstWhere(
      (cam) => cam.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      frontCamera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );
    await _cameraController!.initialize();
    await _cameraController!.startImageStream(_processFrame);
  }

  Future<void> stop() async {
    if (_cameraController == null) {
      return;
    }
    if (_cameraController!.value.isStreamingImages) {
      await _cameraController!.stopImageStream();
    }
    await _cameraController!.dispose();
    _cameraController = null;
    _processing = false;
    _resetState();
  }

  void _resetState() {
    _eyesClosed = false;
    _closureStartedAt = null;
    _eyesOpenedAt = null;
    _blinkEvents.clear();
    _drowsyEpisodes.clear();
  }

  // ---- Asosiy ish ------------------------------------------------------------

  Future<void> _processFrame(CameraImage image) async {
    if (_processing) {
      return;
    }
    _processing = true;
    try {
      final controller = _cameraController;
      if (controller == null || !controller.value.isInitialized) {
        return;
      }

      final inputImage = _toInputImage(image, controller.description);
      if (inputImage == null) {
        return;
      }

      final faces = await _faceDetector.processImage(inputImage);
      final state = _buildStateFromFaces(faces);
      _controller.add(state);
    } catch (_) {
      // Bir kadrning xatosi oqimni to'xtatmasin.
    } finally {
      _processing = false;
    }
  }

  DriverState _buildStateFromFaces(List<Face> faces) {
    final now = DateTime.now();
    _pruneOldEvents(now);

    if (faces.isEmpty) {
      // Yuz yo'q — joriy episodeni tashlab yuboramiz (noaniq holat).
      _eyesClosed = false;
      _closureStartedAt = null;
      _eyesOpenedAt = null;
      return DriverState(
        blinkRate: _blinkEvents.length.toDouble(),
        eyeClosurePercent: _computePerclos(now),
        yawnCountPerMinute: _drowsyEpisodes.length,
        riskLevel: DriverRiskLevel.warning,
        message: 'Yuz aniqlanmadi, kameraga to`g`ri qarang',
        faceDetected: false,
        isUsingCamera: true,
      );
    }

    final face = faces.first;
    final leftOpen = face.leftEyeOpenProbability;
    final rightOpen = face.rightEyeOpenProbability;
    final avgOpen = _safeAvg(leftOpen, rightOpen);

    // Hysteresis bilan ko'z holati.
    final bool nowClosed = _eyesClosed
        ? avgOpen <
              _openThreshold // ochilish chegarasi — biroz yuqoriroq
        : avgOpen < _closedThreshold;

    if (nowClosed && !_eyesClosed) {
      // Ko'z hozirgina yopildi.
      _closureStartedAt = now;
      _eyesOpenedAt = null;
    } else if (!nowClosed && _eyesClosed) {
      // Ko'z hozirgina ochildi — episodening davomiyligini baholaymiz.
      final start = _closureStartedAt;
      if (start != null) {
        final durationMs = now.difference(start).inMilliseconds;
        if (durationMs < _blinkMaxMs) {
          // Oddiy pillapayish.
          _blinkEvents.add(now);
        } else {
          // Mikrouyqu yoki uzunroq episode.
          _drowsyEpisodes.add(
            _ClosureEpisode(startedAt: start, durationMs: durationMs),
          );
        }
      }
      _closureStartedAt = null;
      _eyesOpenedAt = now;
    }
    _eyesClosed = nowClosed;

    // Agar ko'z ochiq, lekin "ochilish boshlanishi" hali belgilanmagan bo'lsa
    // (masalan, kuzatish endi boshlandi va yuz darhol topildi), uni hozirdan
    // boshlab hisoblaymiz.
    if (!_eyesClosed && _eyesOpenedAt == null) {
      _eyesOpenedAt = now;
    }

    // ---- Tiklanish (recovery) ------------------------------------------------
    // Eski bug: bir marta DANGER bo'lgandan keyin, ko'z ochilsa ham 60 soniya
    // davomida to'plangan drowsy episodelar va PERCLOS yuqori bo'lib qolardi
    // va ekran "Xavfli holat"da qotib turardi. Endi: ko'z _recoveryMs (~2.5 s)
    // uzluksiz ochiq bo'lsa, to'plangan drowsy episodelarni tozalaymiz —
    // haydovchi "hushyor"ligini tasdiqlangan deb hisoblaymiz.
    if (!_eyesClosed && _eyesOpenedAt != null) {
      final openMs = now.difference(_eyesOpenedAt!).inMilliseconds;
      if (openMs >= _recoveryMs && _drowsyEpisodes.isNotEmpty) {
        _drowsyEpisodes.clear();
      }
    }

    // Joriy episodening hozirgi davomiyligi (agar ko'z hali yopiq bo'lsa).
    final int ongoingClosureMs = (_eyesClosed && _closureStartedAt != null)
        ? now.difference(_closureStartedAt!).inMilliseconds
        : 0;

    final perclos = _computePerclos(now, ongoingClosureMs: ongoingClosureMs);
    final blinkRate = _blinkEvents.length.toDouble();
    final drowsyCount = _drowsyEpisodes.length;

    final riskLevel = _estimateRisk(
      ongoingClosureMs: ongoingClosureMs,
      drowsyCount: drowsyCount,
      perclos: perclos,
      blinkRate: blinkRate,
    );

    return DriverState(
      blinkRate: blinkRate,
      eyeClosurePercent: perclos,
      yawnCountPerMinute: drowsyCount,
      riskLevel: riskLevel,
      message: _messageForRisk(
        riskLevel,
        ongoingClosureMs: ongoingClosureMs,
        drowsyCount: drowsyCount,
      ),
      faceDetected: true,
      isUsingCamera: true,
    );
  }

  // ---- Risk hisoblash --------------------------------------------------------

  DriverRiskLevel _estimateRisk({
    required int ongoingClosureMs,
    required int drowsyCount,
    required double perclos,
    required double blinkRate,
  }) {
    // 1) Haqiqiy uxlash — hozir ko'z >1500 ms uzluksiz yopiq.
    if (ongoingClosureMs >= _sleepMs) {
      return DriverRiskLevel.danger;
    }

    // 2) Bir necha uzun episode + yuqori PERCLOS.
    if (drowsyCount >= 3 && perclos >= _perclosDanger) {
      return DriverRiskLevel.danger;
    }

    // 3) WARNING shartlari (har biri mustaqil belgi).
    final warningSignals =
        (ongoingClosureMs >= _drowsyMinMs ? 1 : 0) +
        (drowsyCount >= 2 ? 1 : 0) +
        (perclos >= _perclosWarn ? 1 : 0) +
        (blinkRate > 0 && blinkRate < 6 ? 1 : 0); // pillapayish kamayishi

    if (warningSignals >= 2) {
      return DriverRiskLevel.warning;
    }
    if (warningSignals == 1 && drowsyCount >= 1) {
      return DriverRiskLevel.warning;
    }
    return DriverRiskLevel.safe;
  }

  String _messageForRisk(
    DriverRiskLevel riskLevel, {
    required int ongoingClosureMs,
    required int drowsyCount,
  }) {
    switch (riskLevel) {
      case DriverRiskLevel.safe:
        return 'Haydovchi hushyor';
      case DriverRiskLevel.warning:
        if (ongoingClosureMs >= _drowsyMinMs) {
          return 'Ko`zlaringizni ochiq tuting!';
        }
        if (drowsyCount >= 2) {
          return 'Charchoq belgilari, tanaffus qiling';
        }
        return 'Diqqat pasaymoqda, hushyor bo`ling';
      case DriverRiskLevel.danger:
        return 'UYQU! Darhol to`xtang yoki to`xtab dam oling';
    }
  }

  // ---- Yordamchilar ----------------------------------------------------------

  /// PERCLOS — oxirgi 60 sekund ichida ko'z yopiq bo'lgan vaqtning ulushi.
  /// Joriy ochilmagan episode (agar mavjud bo'lsa) ham hisobga olinadi.
  double _computePerclos(DateTime now, {int ongoingClosureMs = 0}) {
    int totalClosedMs = 0;
    for (final ep in _drowsyEpisodes) {
      totalClosedMs += ep.durationMs;
    }
    // Pillapayishlar — har biri o'rtacha ~150 ms deb baholanadi.
    totalClosedMs += _blinkEvents.length * 150;
    totalClosedMs += ongoingClosureMs;
    final windowMs = _window.inMilliseconds;
    return (totalClosedMs / windowMs * 100).clamp(0, 100).toDouble();
  }

  void _pruneOldEvents(DateTime now) {
    _blinkEvents.removeWhere((t) => now.difference(t) > _window);
    _drowsyEpisodes.removeWhere((e) => now.difference(e.startedAt) > _window);
  }

  double _safeAvg(double? a, double? b) {
    if (a == null && b == null) {
      // ML Kit ehtimollikni qaytarmagan — neytral qiymat (ko'z ochiq deylik).
      return 0.8;
    }
    if (a == null) return b!;
    if (b == null) return a;
    return (a + b) / 2;
  }

  InputImage? _toInputImage(CameraImage image, CameraDescription description) {
    final rotation = InputImageRotationValue.fromRawValue(
      description.sensorOrientation,
    );
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    final bytes = image.planes.fold<List<int>>(
      <int>[],
      (acc, plane) => acc..addAll(plane.bytes),
    );

    return InputImage.fromBytes(
      bytes: Uint8List.fromList(bytes),
      metadata: InputImageMetadata(
        size: ui.Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  Future<void> dispose() async {
    await stop();
    await _cameraController?.dispose();
    await _faceDetector.close();
    await _controller.close();
  }
}

class _ClosureEpisode {
  const _ClosureEpisode({required this.startedAt, required this.durationMs});
  final DateTime startedAt;
  final int durationMs;
}
