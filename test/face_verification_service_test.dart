import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:odoo_mobile/services/face_verification_service.dart';

void main() {
  group('FaceVerificationService Unit Tests', () {
    test('l2Normalize creates unit vector with length 1.0', () {
      final input = [3.0, 4.0];
      final normalized = FaceVerificationService.l2Normalize(input);

      expect(normalized.length, 2);
      expect(normalized[0], closeTo(0.6, 1e-6));
      expect(normalized[1], closeTo(0.8, 1e-6));

      double norm = math.sqrt(normalized[0] * normalized[0] + normalized[1] * normalized[1]);
      expect(norm, closeTo(1.0, 1e-6));
    });

    test('computeCosineSimilarity identical vectors equals 1.0', () {
      final v1 = FaceVerificationService.l2Normalize(List.generate(192, (i) => i.toDouble() + 1.0));
      final similarity = FaceVerificationService.computeCosineSimilarity(v1, v1);

      expect(similarity, closeTo(1.0, 1e-6));
    });

    test('computeCosineSimilarity orthogonal vectors equals 0.0', () {
      final v1 = [1.0, 0.0, 0.0];
      final v2 = [0.0, 1.0, 0.0];
      final similarity = FaceVerificationService.computeCosineSimilarity(v1, v2);

      expect(similarity, closeTo(0.0, 1e-6));
    });

    test('computeCosineSimilarity opposite vectors equals -1.0', () {
      final v1 = [1.0, 0.0];
      final v2 = [-1.0, 0.0];
      final similarity = FaceVerificationService.computeCosineSimilarity(v1, v2);

      expect(similarity, closeTo(-1.0, 1e-6));
    });

    test('computeCompositeTemplate averages and normalizes multiple frames correctly', () {
      final f1 = FaceVerificationService.l2Normalize([1.0, 0.0, 0.0]);
      final f2 = FaceVerificationService.l2Normalize([0.0, 1.0, 0.0]);
      final composite = FaceVerificationService.computeCompositeTemplate([f1, f2]);

      // Average is [0.5, 0.5, 0], normalized is [1/sqrt(2), 1/sqrt(2), 0]
      final expected = 1.0 / math.sqrt(2.0);
      expect(composite[0], closeTo(expected, 1e-6));
      expect(composite[1], closeTo(expected, 1e-6));
      expect(composite[2], closeTo(0.0, 1e-6));
    });
  });
}
