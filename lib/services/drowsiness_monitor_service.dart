import 'dart:async';
import 'dart:math';

import '../models/driver_state.dart';

class DrowsinessMonitorService {
  DrowsinessMonitorService() : _random = Random();

  final Random _random;

  Timer? _timer;
  final StreamController<DriverState> _controller =
      StreamController<DriverState>.broadcast();

  Stream<DriverState> get stateStream => _controller.stream;

  DriverState _lastState = const DriverState(
    blinkRate: 12,
    eyeClosurePercent: 20,
    yawnCountPerMinute: 0,
    riskLevel: DriverRiskLevel.safe,
    message: 'Holat barqaror',
    faceDetected: false,
    isUsingCamera: false,
  );

  DriverState get lastState => _lastState;

  void start() {
    _emitNewState();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      _emitNewState();
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _emitNewState() {
    final blinkRate = 8 + _random.nextDouble() * 18;
    final eyeClosurePercent = 10 + _random.nextDouble() * 65;
    final yawnCount = _random.nextInt(6);

    final riskLevel = _estimateRisk(
      blinkRate: blinkRate,
      eyeClosurePercent: eyeClosurePercent,
      yawnCountPerMinute: yawnCount,
    );

    _lastState = DriverState(
      blinkRate: blinkRate,
      eyeClosurePercent: eyeClosurePercent,
      yawnCountPerMinute: yawnCount,
      riskLevel: riskLevel,
      message: _messageForRisk(riskLevel),
      faceDetected: true,
      isUsingCamera: false,
    );
    _controller.add(_lastState);
  }

  DriverRiskLevel _estimateRisk({
    required double blinkRate,
    required double eyeClosurePercent,
    required int yawnCountPerMinute,
  }) {
    final warningScore =
        (blinkRate < 11 ? 1 : 0) +
        (eyeClosurePercent > 40 ? 1 : 0) +
        (yawnCountPerMinute >= 2 ? 1 : 0);
    final dangerScore =
        (blinkRate < 9 ? 1 : 0) +
        (eyeClosurePercent > 55 ? 1 : 0) +
        (yawnCountPerMinute >= 4 ? 1 : 0);

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
      DriverRiskLevel.warning => 'Diqqat kamaymoqda, tanaffus tavsiya etiladi',
      DriverRiskLevel.danger => 'Uyqu holati aniqlandi! Darhol to`xtang',
    };
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
