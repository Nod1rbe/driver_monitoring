enum DriverRiskLevel {
  safe,
  warning,
  danger,
}

class DriverState {
  const DriverState({
    required this.blinkRate,
    required this.eyeClosurePercent,
    required this.yawnCountPerMinute,
    required this.riskLevel,
    required this.message,
    this.faceDetected = false,
    this.isUsingCamera = false,
  });

  final double blinkRate;
  final double eyeClosurePercent;
  final int yawnCountPerMinute;
  final DriverRiskLevel riskLevel;
  final String message;
  final bool faceDetected;
  final bool isUsingCamera;
}
