/// Possible outcomes of a face verification or enrollment attempt.
enum FaceVerificationStatus {
  success,
  mismatch,
  livenessFailed,
  noFace,
  multipleFaces,
  cameraDenied,
  noEnrollment,
  timeout,
  cancelled,
  error,
}

/// Unified result model returned by FaceVerificationScreen and FaceEnrollmentScreen.
class FaceVerificationResult {
  final FaceVerificationStatus status;
  final bool isSuccess;
  final String message;
  final double? similarity;

  const FaceVerificationResult({
    required this.status,
    required this.isSuccess,
    required this.message,
    this.similarity,
  });

  factory FaceVerificationResult.success({double? similarity, String? message}) =>
      FaceVerificationResult(
        status: FaceVerificationStatus.success,
        isSuccess: true,
        message: message ?? 'Face verification succeeded.',
        similarity: similarity,
      );

  factory FaceVerificationResult.failed({
    required FaceVerificationStatus status,
    required String message,
    double? similarity,
  }) =>
      FaceVerificationResult(
        status: status,
        isSuccess: false,
        message: message,
        similarity: similarity,
      );

  @override
  String toString() =>
      'FaceVerificationResult(status: $status, isSuccess: $isSuccess, similarity: $similarity, message: $message)';
}
