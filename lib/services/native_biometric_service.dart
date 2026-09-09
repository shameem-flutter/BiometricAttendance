import 'dart:developer';
import 'package:local_auth/local_auth.dart';
import 'package:odoo_mobile/models/face_verification_result.dart';

/// Service managing native iOS biometric authentication (Apple Face ID) via [LocalAuthentication].
///
/// Ensures that:
/// - Only Apple Face ID is used for attendance on iOS (Touch ID is not silently accepted).
/// - No custom camera, ML Kit, or MobileFaceNet embeddings are stored or used on iOS.
/// - Returns typed [FaceVerificationResult] for direct integration with attendance gates.
class NativeBiometricService {
  final LocalAuthentication _auth;

  NativeBiometricService({LocalAuthentication? auth})
      : _auth = auth ?? LocalAuthentication();

  static final NativeBiometricService instance = NativeBiometricService();

  /// Checks whether the device hardware supports local authentication.
  Future<bool> isDeviceSupported() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (e) {
      log('⚠️ [NativeBiometricService] isDeviceSupported error: $e');
      return false;
    }
  }

  /// Checks whether the device is capable of biometric checking.
  Future<bool> canCheckBiometrics() async {
    try {
      return await _auth.canCheckBiometrics;
    } catch (e) {
      log('⚠️ [NativeBiometricService] canCheckBiometrics error: $e');
      return false;
    }
  }

  /// Retrieves the list of enrolled biometrics on the device.
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _auth.getAvailableBiometrics();
    } catch (e) {
      log('⚠️ [NativeBiometricService] getAvailableBiometrics error: $e');
      return const [];
    }
  }

  /// Checks whether Apple Face ID is supported and actively enrolled on this device.
  ///
  /// Strictly requires [BiometricType.face]. Returns false if only Touch ID or no biometric is enrolled.
  Future<bool> isFaceIdAvailable() async {
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) return false;

      final canCheck = await _auth.canCheckBiometrics;
      if (!canCheck) return false;

      final biometrics = await _auth.getAvailableBiometrics();
      return biometrics.contains(BiometricType.face);
    } catch (e) {
      log('⚠️ [NativeBiometricService] isFaceIdAvailable error: $e');
      return false;
    }
  }

  /// Authenticates the user using Apple Face ID.
  ///
  /// Enforces:
  /// - Face ID presence (rejects devices with only Touch ID or no biometrics).
  /// - Biometric-only authentication (`biometricOnly: true` — no passcode/PIN downgrade).
  /// - Mapping to unified [FaceVerificationResult].
  Future<FaceVerificationResult> authenticateWithFaceId({
    String reason = 'Verify your identity to record attendance.',
  }) async {
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) {
        return FaceVerificationResult.failed(
          status: FaceVerificationStatus.error,
          message: 'This device does not support biometric authentication.',
        );
      }

      final canCheck = await _auth.canCheckBiometrics;
      if (!canCheck) {
        return FaceVerificationResult.failed(
          status: FaceVerificationStatus.error,
          message: 'Biometric authentication is not available on this device.',
        );
      }

      final biometrics = await _auth.getAvailableBiometrics();
      if (biometrics.isEmpty) {
        return FaceVerificationResult.failed(
          status: FaceVerificationStatus.noEnrollment,
          message: "Face ID isn't set up on this iPhone. Please configure Face ID in Settings → Face ID & Passcode.",
        );
      }

      // STRICT RULE: Face ID must mean Face ID. Do NOT silently allow Touch ID.
      if (!biometrics.contains(BiometricType.face)) {
        if (biometrics.contains(BiometricType.fingerprint)) {
          return FaceVerificationResult.failed(
            status: FaceVerificationStatus.error,
            message: 'Face ID is required for attendance on iOS. Touch ID is not supported.',
          );
        }
        return FaceVerificationResult.failed(
          status: FaceVerificationStatus.error,
          message: 'Face ID is not available on this device.',
        );
      }

      final bool didAuthenticate = await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );

      if (didAuthenticate) {
        return FaceVerificationResult.success(
          message: 'Face ID verification succeeded.',
        );
      } else {
        return FaceVerificationResult.failed(
          status: FaceVerificationStatus.mismatch,
          message: 'Face ID verification failed. Attendance was not recorded.',
        );
      }
    } on LocalAuthException catch (e) {
      log('⚠️ [NativeBiometricService] LocalAuthException: ${e.code.name} - ${e.description}');
      return mapLocalAuthException(e);
    } catch (e) {
      log('❌ [NativeBiometricService] Unexpected authentication error: $e');
      return FaceVerificationResult.failed(
        status: FaceVerificationStatus.error,
        message: 'Face ID is currently unavailable. Please try again.',
      );
    }
  }

  /// Maps a [LocalAuthException] to an appropriate [FaceVerificationResult].
  FaceVerificationResult mapLocalAuthException(LocalAuthException e) {
    switch (e.code) {
      case LocalAuthExceptionCode.userCanceled:
        return FaceVerificationResult.failed(
          status: FaceVerificationStatus.cancelled,
          message: 'Face ID verification was cancelled. Attendance was not recorded.',
        );
      case LocalAuthExceptionCode.timeout:
        return FaceVerificationResult.failed(
          status: FaceVerificationStatus.timeout,
          message: 'Face ID verification timed out. Please try again.',
        );
      case LocalAuthExceptionCode.noBiometricsEnrolled:
      case LocalAuthExceptionCode.noCredentialsSet:
        return FaceVerificationResult.failed(
          status: FaceVerificationStatus.noEnrollment,
          message: "Face ID isn't set up on this iPhone. Please configure Face ID in Settings → Face ID & Passcode.",
        );
      case LocalAuthExceptionCode.noBiometricHardware:
        return FaceVerificationResult.failed(
          status: FaceVerificationStatus.error,
          message: 'This device does not support Face ID.',
        );
      case LocalAuthExceptionCode.temporaryLockout:
      case LocalAuthExceptionCode.biometricLockout:
        return FaceVerificationResult.failed(
          status: FaceVerificationStatus.error,
          message: 'Face ID is temporarily locked due to failed attempts. Please unlock your device.',
        );
      case LocalAuthExceptionCode.systemCanceled:
        return FaceVerificationResult.failed(
          status: FaceVerificationStatus.cancelled,
          message: 'Face ID verification was interrupted by the system.',
        );
      case LocalAuthExceptionCode.authInProgress:
        return FaceVerificationResult.failed(
          status: FaceVerificationStatus.error,
          message: 'Face ID authentication is already in progress.',
        );
      case LocalAuthExceptionCode.deviceError:
      case LocalAuthExceptionCode.unknownError:
      case LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable:
      case LocalAuthExceptionCode.uiUnavailable:
      case LocalAuthExceptionCode.userRequestedFallback:
        return FaceVerificationResult.failed(
          status: FaceVerificationStatus.error,
          message: 'Face ID is currently unavailable. Please try again.',
        );
    }
  }
}
