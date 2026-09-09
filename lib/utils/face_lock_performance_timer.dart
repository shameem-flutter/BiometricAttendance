import 'package:flutter/foundation.dart';

/// Debug-only performance measurement utility for Face Lock operations.
///
/// Records fine-grained latencies for each pipeline stage:
/// - Camera initialization
/// - ML Kit per-frame inference
/// - Active liveness challenge completion
/// - Frame conversion (NV21/BGRA -> RGB)
/// - MobileFaceNet TFLite inference
/// - Template matching / cosine similarity
class FaceLockPerformanceTimer {
  final Stopwatch _totalWatch = Stopwatch();
  final Stopwatch _stepWatch = Stopwatch();

  int cameraInitMs = 0;
  int livenessMs = 0;
  int frameConversionMs = 0;
  int mobileFaceNetMs = 0;
  int similarityMs = 0;

  final List<int> _mlKitLatencies = [];

  void startTotal() {
    _totalWatch.reset();
    _totalWatch.start();
  }

  void startStep() {
    _stepWatch.reset();
    _stepWatch.start();
  }

  int stopStep() {
    _stepWatch.stop();
    return _stepWatch.elapsedMilliseconds;
  }

  void recordMlKitLatency(int latencyMs) {
    _mlKitLatencies.add(latencyMs);
  }

  int get mlKitAvgLatencyMs {
    if (_mlKitLatencies.isEmpty) return 0;
    return (_mlKitLatencies.reduce((a, b) => a + b) / _mlKitLatencies.length).round();
  }

  int get totalMs => _totalWatch.elapsedMilliseconds;

  void logResults({String operation = 'Verification'}) {
    if (!kDebugMode) return;
    debugPrint('────────────────── [FaceLock Perf: $operation] ──────────────────');
    debugPrint('[FaceLock Perf] Camera init: $cameraInitMs ms');
    debugPrint('[FaceLock Perf] ML Kit avg latency: $mlKitAvgLatencyMs ms');
    debugPrint('[FaceLock Perf] Liveness: $livenessMs ms');
    debugPrint('[FaceLock Perf] Frame conversion: $frameConversionMs ms');
    debugPrint('[FaceLock Perf] MobileFaceNet: $mobileFaceNetMs ms');
    debugPrint('[FaceLock Perf] Similarity: $similarityMs ms');
    debugPrint('[FaceLock Perf] TOTAL: $totalMs ms');
    debugPrint('────────────────────────────────────────────────────────────────');
  }
}
