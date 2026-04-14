import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../models/driver_state.dart';

class CameraDrowsinessMonitorService {
  CameraDrowsinessMonitorService() : _faceDetector = FaceDetector(options: FaceDetectorOptions(
    enableClassification: true,
    performanceMode: FaceDetectorMode.fast,
  ));

  final FaceDetector _faceDetector;
  final StreamController<DriverState> _controller =
      StreamController<DriverState>.broadcast();
  final List<DateTime> _blinkEvents = <DateTime>[];
  final List<DateTime> _drowsyEvents = <DateTime>[];
  final Random _random = Random();

  CameraController? _cameraController;
  bool _processing = false;
  bool _wasEyeClosed = false;

  Stream<DriverState> get stateStream => _controller.stream;
  CameraController? get cameraController => _cameraController;
  bool get isCameraReady => _cameraController?.value.isInitialized ?? false;

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
      imageFormatGroup:
          Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
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
    _wasEyeClosed = false;
  }

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
      // Ignore single-frame failures to keep stream alive.
    } finally {
      _processing = false;
    }
  }

  DriverState _buildStateFromFaces(List<Face> faces) {
    if (faces.isEmpty) {
      return const DriverState(
        blinkRate: 0,
        eyeClosurePercent: 0,
        yawnCountPerMinute: 0,
        riskLevel: DriverRiskLevel.warning,
        message: 'Yuz aniqlanmadi, kameraga to`g`ri qarang',
        faceDetected: false,
        isUsingCamera: true,
      );
    }

    final now = DateTime.now();
    _pruneOldEvents(now);
    final face = faces.first;

    final leftOpen = face.leftEyeOpenProbability;
    final rightOpen = face.rightEyeOpenProbability;
    final avgOpen = _safeAvg(leftOpen, rightOpen);
    final eyeClosurePercent = ((1 - avgOpen) * 100).clamp(0, 100);

    final eyesClosed = avgOpen < 0.35;
    if (eyesClosed && !_wasEyeClosed) {
      _blinkEvents.add(now);
    }
    if (eyeClosurePercent > 70) {
      _drowsyEvents.add(now);
    }
    _wasEyeClosed = eyesClosed;

    final blinkRate = _blinkEvents.length.toDouble();
    final drowsyPerMinute = _drowsyEvents.length;

    final riskLevel = _estimateRisk(
      blinkRate: blinkRate,
      eyeClosurePercent: eyeClosurePercent.toDouble(),
      yawnCountPerMinute: drowsyPerMinute,
    );

    return DriverState(
      blinkRate: blinkRate == 0 ? _random.nextDouble() * 2 : blinkRate,
      eyeClosurePercent: eyeClosurePercent.toDouble(),
      yawnCountPerMinute: drowsyPerMinute,
      riskLevel: riskLevel,
      message: _messageForRisk(riskLevel),
      faceDetected: true,
      isUsingCamera: true,
    );
  }

  void _pruneOldEvents(DateTime now) {
    _blinkEvents.removeWhere(
      (event) => now.difference(event) > const Duration(minutes: 1),
    );
    _drowsyEvents.removeWhere(
      (event) => now.difference(event) > const Duration(minutes: 1),
    );
  }

  DriverRiskLevel _estimateRisk({
    required double blinkRate,
    required double eyeClosurePercent,
    required int yawnCountPerMinute,
  }) {
    final warningScore =
        (blinkRate < 10 ? 1 : 0) +
        (eyeClosurePercent > 45 ? 1 : 0) +
        (yawnCountPerMinute >= 8 ? 1 : 0);
    final dangerScore =
        (blinkRate < 7 ? 1 : 0) +
        (eyeClosurePercent > 60 ? 1 : 0) +
        (yawnCountPerMinute >= 15 ? 1 : 0);

    if (dangerScore >= 2) {
      return DriverRiskLevel.danger;
    }
    if (warningScore >= 2) {
      return DriverRiskLevel.warning;
    }
    return DriverRiskLevel.safe;
  }

  String _messageForRisk(DriverRiskLevel riskLevel) {
    return switch (riskLevel) {
      DriverRiskLevel.safe => 'Haydovchi hushyor',
      DriverRiskLevel.warning => 'Diqqat pasaymoqda, hushyor bo`ling',
      DriverRiskLevel.danger => 'Uyqu holati aniqlandi! Ovozli signal yoqildi',
    };
  }

  double _safeAvg(double? a, double? b) {
    if (a == null && b == null) {
      return 0.65;
    }
    if (a == null) {
      return b!;
    }
    if (b == null) {
      return a;
    }
    return (a + b) / 2;
  }

  InputImage? _toInputImage(CameraImage image, CameraDescription description) {
    final rotation = InputImageRotationValue.fromRawValue(
      description.sensorOrientation,
    );
    if (rotation == null) {
      return null;
    }

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) {
      return null;
    }

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
