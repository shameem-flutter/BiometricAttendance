import 'package:flutter_test/flutter_test.dart';
import 'package:odoo_mobile/models/face_verification_result.dart';
import 'package:odoo_mobile/services/face_verification_service.dart';

void main() {
  group('FaceVerificationResult Tests', () {
    test('FaceVerificationResult.success returns isSuccess true and correct status', () {
      final res = FaceVerificationResult.success(similarity: 0.88);
      expect(res.isSuccess, isTrue);
      expect(res.status, FaceVerificationStatus.success);
      expect(res.similarity, 0.88);
      expect(res.message, contains('succeeded'));
    });

    test('FaceVerificationResult.failed returns isSuccess false and assigned status', () {
      final res = FaceVerificationResult.failed(
        status: FaceVerificationStatus.mismatch,
        message: 'The detected face does not match the logged-in employee.',
        similarity: 0.42,
      );
      expect(res.isSuccess, isFalse);
      expect(res.status, FaceVerificationStatus.mismatch);
      expect(res.similarity, 0.42);
      expect(res.message, 'The detected face does not match the logged-in employee.');
    });

    test('FaceVerificationResult handles all failure statuses', () {
      final statuses = [
        FaceVerificationStatus.mismatch,
        FaceVerificationStatus.livenessFailed,
        FaceVerificationStatus.noFace,
        FaceVerificationStatus.multipleFaces,
        FaceVerificationStatus.cameraDenied,
        FaceVerificationStatus.timeout,
        FaceVerificationStatus.cancelled,
        FaceVerificationStatus.error,
      ];

      for (final s in statuses) {
        final res = FaceVerificationResult.failed(status: s, message: s.name);
        expect(res.isSuccess, isFalse);
        expect(res.status, s);
      }
    });

    test('Verification threshold decision: pass >= 0.75, fail < 0.75', () {
      final enrolled = FaceVerificationService.l2Normalize(List.filled(192, 1.0));
      final liveMatching = FaceVerificationService.l2Normalize(List.filled(192, 1.0));

      final simMatch = FaceVerificationService.computeCosineSimilarity(enrolled, liveMatching);
      expect(simMatch >= FaceVerificationService.defaultSimilarityThreshold, isTrue);

      // Create an orthogonal vector
      final liveDifferent = List.filled(192, 0.0);
      liveDifferent[0] = 1.0;
      final enrolledOther = List.filled(192, 0.0);
      enrolledOther[1] = 1.0;

      final simDiff = FaceVerificationService.computeCosineSimilarity(enrolledOther, liveDifferent);
      expect(simDiff >= FaceVerificationService.defaultSimilarityThreshold, isFalse);
      expect(simDiff, closeTo(0.0, 1e-6));
    });
  });
}
