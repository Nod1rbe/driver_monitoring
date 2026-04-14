import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../models/driver_state.dart';
import '../services/camera_drowsiness_monitor_service.dart';
import '../services/drowsiness_monitor_service.dart';
import '../services/voice_alert_service.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late final CameraDrowsinessMonitorService _cameraMonitorService;
  late final DrowsinessMonitorService _monitorService;
  late final VoiceAlertService _voiceAlertService;
  StreamSubscription<DriverState>? _subscription;
  bool _cameraMode = true;
  bool _isMonitoring = false;

  DriverState _currentState = const DriverState(
    blinkRate: 12,
    eyeClosurePercent: 20,
    yawnCountPerMinute: 0,
    riskLevel: DriverRiskLevel.safe,
    message: 'Tizim ishga tushmoqda...',
  );

  @override
  void initState() {
    super.initState();
    _cameraMonitorService = CameraDrowsinessMonitorService();
    _monitorService = DrowsinessMonitorService();
    _voiceAlertService = VoiceAlertService();
    _initServices();
  }

  Future<void> _initServices() async {
    await _voiceAlertService.init();
    await _startMonitoring();
  }

  Future<void> _startMonitoring() async {
    await _subscription?.cancel();
    Stream<DriverState> stream;
    try {
      await _cameraMonitorService.start();
      stream = _cameraMonitorService.stateStream;
      _cameraMode = true;
    } catch (_) {
      _monitorService.start();
      stream = _monitorService.stateStream;
      _cameraMode = false;
    }
    _isMonitoring = true;
    _subscription = stream.listen((state) async {
      if (!mounted) {
        return;
      }
      setState(() {
        _currentState = state;
      });
      if (state.riskLevel == DriverRiskLevel.danger) {
        await _voiceAlertService.speakDangerAlert();
      }
    });
  }

  Future<void> _stopMonitoring() async {
    await _subscription?.cancel();
    _subscription = null;
    _monitorService.stop();
    await _cameraMonitorService.stop();
    await _voiceAlertService.stopSpeaking();
    if (!mounted) {
      return;
    }
    setState(() {
      _isMonitoring = false;
      _currentState = const DriverState(
        blinkRate: 0,
        eyeClosurePercent: 0,
        yawnCountPerMinute: 0,
        riskLevel: DriverRiskLevel.safe,
        message: 'Monitoring to`xtatildi',
        faceDetected: false,
        isUsingCamera: false,
      );
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _monitorService.dispose();
    _cameraMonitorService.dispose();
    _voiceAlertService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = _paletteForRisk(_currentState.riskLevel);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [colors.backgroundTop, colors.backgroundBottom],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.directions_car_filled_rounded,
                      color: Colors.white.withValues(alpha: 0.95),
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Driver Monitoring',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'Real-time',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Expanded(
                  flex: 6,
                  child: _CameraPreviewCard(
                    cameraController: _cameraMonitorService.cameraController,
                    showFallback: !_cameraMode,
                  ),
                ),
                const SizedBox(height: 12),
                _RiskBanner(
                  title: _titleForRisk(_currentState.riskLevel),
                  message:
                      '${_currentState.message} ${_currentState.faceDetected ? "" : "| Yuz topilmadi"}',
                  backgroundColor: colors.banner,
                ),
                const SizedBox(height: 14),
                Expanded(
                  flex: 3,
                  child: GridView.count(
                    crossAxisCount: 2,
                    mainAxisSpacing: 5,
                    crossAxisSpacing: 5,
                    childAspectRatio: 2.35,
                    children: [
                      _MetricCard(
                        label: 'Blink rate',
                        value: '${_currentState.blinkRate.toStringAsFixed(1)}/min',
                        icon: Icons.remove_red_eye_outlined,
                      ),
                      _MetricCard(
                        label: 'Ko`z yopilishi',
                        value:
                            '${_currentState.eyeClosurePercent.toStringAsFixed(1)}%',
                        icon: Icons.visibility_off_outlined,
                      ),
                      _MetricCard(
                        label: 'Yawning',
                        value: '${_currentState.yawnCountPerMinute}/min',
                        icon: Icons.sentiment_dissatisfied_outlined,
                      ),
                      _MetricCard(
                        label: 'Risk darajasi',
                        value: _titleForRisk(_currentState.riskLevel),
                        icon: Icons.warning_amber_rounded,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      if (_isMonitoring) {
                        await _stopMonitoring();
                        return;
                      }
                      await _startMonitoring();
                      if (!mounted) {
                        return;
                      }
                      setState(() {});
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor:
                          _isMonitoring ? const Color(0xFFB91C1C) : colors.button,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: Icon(
                      _isMonitoring
                          ? Icons.pause_circle_filled_rounded
                          : Icons.play_circle_fill_rounded,
                    ),
                    label: Text(
                      _isMonitoring
                          ? 'Monitoringni to`xtatish'
                          : 'Monitoringni boshlash',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.white70, size: 16),
          const Spacer(),
          Text(
            value,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Colors.white70,
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraPreviewCard extends StatelessWidget {
  const _CameraPreviewCard({
    required this.cameraController,
    required this.showFallback,
  });

  final CameraController? cameraController;
  final bool showFallback;

  @override
  Widget build(BuildContext context) {
    final isReady =
        !showFallback &&
        cameraController != null &&
        cameraController!.value.isInitialized;

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          border: Border.all(color: Colors.white24),
        ),
        child: !isReady
            ? const Center(
                child: Text(
                  'Kamera mavjud emas.\nDemo monitoring rejimi ishlayapti.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70),
                ),
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  final aspectRatio = cameraController!.value.aspectRatio;

                  return SizedBox.expand(
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: constraints.maxWidth,
                        height: constraints.maxWidth / aspectRatio,
                        child: CameraPreview(cameraController!),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _RiskBanner extends StatelessWidget {
  const _RiskBanner({
    required this.title,
    required this.message,
    required this.backgroundColor,
  });

  final String title;
  final String message;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          const Icon(
            Icons.shield_moon_rounded,
            color: Colors.white,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$title: $message',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.95),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RiskPalette {
  const _RiskPalette({
    required this.backgroundTop,
    required this.backgroundBottom,
    required this.banner,
    required this.button,
  });

  final Color backgroundTop;
  final Color backgroundBottom;
  final Color banner;
  final Color button;
}

_RiskPalette _paletteForRisk(DriverRiskLevel riskLevel) {
  return switch (riskLevel) {
    DriverRiskLevel.safe => const _RiskPalette(
      backgroundTop: Color(0xFF0F172A),
      backgroundBottom: Color(0xFF1D4ED8),
      banner: Color(0xFF059669),
      button: Color(0xFF2563EB),
    ),
    DriverRiskLevel.warning => const _RiskPalette(
      backgroundTop: Color(0xFF1E1B4B),
      backgroundBottom: Color(0xFF7C2D12),
      banner: Color(0xFFD97706),
      button: Color(0xFFB45309),
    ),
    DriverRiskLevel.danger => const _RiskPalette(
      backgroundTop: Color(0xFF3F0B14),
      backgroundBottom: Color(0xFF991B1B),
      banner: Color(0xFFDC2626),
      button: Color(0xFFB91C1C),
    ),
  };
}

String _titleForRisk(DriverRiskLevel riskLevel) {
  return switch (riskLevel) {
    DriverRiskLevel.safe => 'Xavfsiz',
    DriverRiskLevel.warning => 'Ogohlantirish',
    DriverRiskLevel.danger => 'Xavfli holat',
  };
}
