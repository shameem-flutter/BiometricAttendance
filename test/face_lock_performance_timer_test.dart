import 'package:flutter_test/flutter_test.dart';
import 'package:odoo_mobile/utils/face_lock_performance_timer.dart';

void main() {
  group('FaceLockPerformanceTimer Tests', () {
    test('Timer tracks step latency and ML Kit average accurately', () async {
      final timer = FaceLockPerformanceTimer();
      timer.startTotal();

      timer.startStep();
      await Future.delayed(const Duration(milliseconds: 30));
      timer.cameraInitMs = timer.stopStep();

      expect(timer.cameraInitMs, greaterThanOrEqualTo(25));

      timer.recordMlKitLatency(20);
      timer.recordMlKitLatency(30);
      timer.recordMlKitLatency(40);

      expect(timer.mlKitAvgLatencyMs, 30);

      expect(timer.totalMs, greaterThanOrEqualTo(25));
    });

    test('Empty ML Kit latencies return 0 average', () {
      final timer = FaceLockPerformanceTimer();
      expect(timer.mlKitAvgLatencyMs, 0);
    });
  });
}
