import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:odoo_mobile/models/face_verification_result.dart';
import 'package:odoo_mobile/services/native_biometric_service.dart';


class FakeLocalAuth extends Fake implements LocalAuthentication {
  bool isSupported;
  bool canCheck;
  List<BiometricType> biometrics;
  bool authResult;
  Exception? exceptionToThrow;

  FakeLocalAuth({
    this.isSupported = true,
    this.canCheck = true,
    this.biometrics = const [BiometricType.face],
    this.authResult = true,
    this.exceptionToThrow,
  });

  @override
  Future<bool> isDeviceSupported() async => isSupported;

  @override
  Future<bool> get canCheckBiometrics async => canCheck;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async => biometrics;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<dynamic> authMessages = const [],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return authResult;
  }

}

void main() {
  group('NativeBiometricService Unit Tests', () {
    test('isFaceIdAvailable returns true when Face ID is enrolled', () async {
      final fakeAuth = FakeLocalAuth(biometrics: [BiometricType.face]);
      final service = NativeBiometricService(auth: fakeAuth);

      final available = await service.isFaceIdAvailable();
      expect(available, isTrue);
    });

    test('isFaceIdAvailable returns false when only Touch ID is enrolled', () async {
      final fakeAuth = FakeLocalAuth(biometrics: [BiometricType.fingerprint]);
      final service = NativeBiometricService(auth: fakeAuth);

      final available = await service.isFaceIdAvailable();
      expect(available, isFalse);
    });

    test('isFaceIdAvailable returns false when device does not support biometrics', () async {
      final fakeAuth = FakeLocalAuth(isSupported: false);
      final service = NativeBiometricService(auth: fakeAuth);

      final available = await service.isFaceIdAvailable();
      expect(available, isFalse);
    });

    test('authenticateWithFaceId succeeds when auth returns true with Face ID', () async {
      final fakeAuth = FakeLocalAuth(
        biometrics: [BiometricType.face],
        authResult: true,
      );
      final service = NativeBiometricService(auth: fakeAuth);

      final result = await service.authenticateWithFaceId();
      expect(result.isSuccess, isTrue);
      expect(result.status, FaceVerificationStatus.success);
    });

    test('authenticateWithFaceId fails with mismatch when auth returns false', () async {
      final fakeAuth = FakeLocalAuth(
        biometrics: [BiometricType.face],
        authResult: false,
      );
      final service = NativeBiometricService(auth: fakeAuth);

      final result = await service.authenticateWithFaceId();
      expect(result.isSuccess, isFalse);
      expect(result.status, FaceVerificationStatus.mismatch);
    });

    test('authenticateWithFaceId rejects Touch ID with clear error', () async {
      final fakeAuth = FakeLocalAuth(
        biometrics: [BiometricType.fingerprint],
      );
      final service = NativeBiometricService(auth: fakeAuth);

      final result = await service.authenticateWithFaceId();
      expect(result.isSuccess, isFalse);
      expect(result.status, FaceVerificationStatus.error);
      expect(result.message, contains('Touch ID is not supported'));
    });

    test('authenticateWithFaceId returns noEnrollment when biometrics list is empty', () async {
      final fakeAuth = FakeLocalAuth(
        biometrics: const [],
      );
      final service = NativeBiometricService(auth: fakeAuth);

      final result = await service.authenticateWithFaceId();
      expect(result.isSuccess, isFalse);
      expect(result.status, FaceVerificationStatus.noEnrollment);
      expect(result.message, contains('Settings → Face ID & Passcode'));
    });

    test('maps LocalAuthException userCanceled to cancelled status', () {
      final service = NativeBiometricService();
      const exception = LocalAuthException(code: LocalAuthExceptionCode.userCanceled);
      final result = service.mapLocalAuthException(exception);

      expect(result.isSuccess, isFalse);
      expect(result.status, FaceVerificationStatus.cancelled);
    });

    test('maps LocalAuthException timeout to timeout status', () {
      final service = NativeBiometricService();
      const exception = LocalAuthException(code: LocalAuthExceptionCode.timeout);
      final result = service.mapLocalAuthException(exception);

      expect(result.isSuccess, isFalse);
      expect(result.status, FaceVerificationStatus.timeout);
    });

    test('maps LocalAuthException noBiometricsEnrolled to noEnrollment status', () {
      final service = NativeBiometricService();
      const exception = LocalAuthException(code: LocalAuthExceptionCode.noBiometricsEnrolled);
      final result = service.mapLocalAuthException(exception);

      expect(result.isSuccess, isFalse);
      expect(result.status, FaceVerificationStatus.noEnrollment);
    });

    test('maps LocalAuthException temporaryLockout to error status', () {
      final service = NativeBiometricService();
      const exception = LocalAuthException(code: LocalAuthExceptionCode.temporaryLockout);
      final result = service.mapLocalAuthException(exception);

      expect(result.isSuccess, isFalse);
      expect(result.status, FaceVerificationStatus.error);
      expect(result.message, contains('temporarily locked'));
    });

    test('maps LocalAuthException systemCanceled to cancelled status', () {
      final service = NativeBiometricService();
      const exception = LocalAuthException(code: LocalAuthExceptionCode.systemCanceled);
      final result = service.mapLocalAuthException(exception);

      expect(result.isSuccess, isFalse);
      expect(result.status, FaceVerificationStatus.cancelled);
    });

    test('authenticateWithFaceId handles thrown LocalAuthException correctly', () async {
      final fakeAuth = FakeLocalAuth(
        biometrics: [BiometricType.face],
        exceptionToThrow: const LocalAuthException(code: LocalAuthExceptionCode.userCanceled),
      );
      final service = NativeBiometricService(auth: fakeAuth);

      final result = await service.authenticateWithFaceId();
      expect(result.isSuccess, isFalse);
      expect(result.status, FaceVerificationStatus.cancelled);
      expect(result.message, contains('cancelled'));
    });

    test('authenticateWithFaceId handles unexpected generic exception gracefully', () async {
      final fakeAuth = FakeLocalAuth(
        biometrics: [BiometricType.face],
        exceptionToThrow: Exception('Platform channel breakdown'),
      );
      final service = NativeBiometricService(auth: fakeAuth);

      final result = await service.authenticateWithFaceId();
      expect(result.isSuccess, isFalse);
      expect(result.status, FaceVerificationStatus.error);
      expect(result.message, contains('Face ID is currently unavailable'));
    });
  });
}

