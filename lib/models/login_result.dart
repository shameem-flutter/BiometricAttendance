class LoginResult {
  final bool isSuccess;
  final String? sessionId;
  final String? accessToken;
  final int? employeeId;
  final String? employeeName;
  final bool isRouteManagementInstalled;
  final bool? requireFaceRecognition;
  final bool? faceRegistered;
  final String? faceEmbeddingData;
  final String? errorMessage;

  const LoginResult({
    required this.isSuccess,
    this.sessionId,
    this.accessToken,
    this.employeeId,
    this.employeeName,
    this.isRouteManagementInstalled = false,
    this.requireFaceRecognition,
    this.faceRegistered,
    this.faceEmbeddingData,
    this.errorMessage,
  });

  factory LoginResult.failed({String? message}) => LoginResult(
        isSuccess: false,
        errorMessage: message,
      );
}
