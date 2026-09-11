import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:geolocator/geolocator.dart';
import 'package:odoo_mobile/constants/color_constants.dart';
import 'package:odoo_mobile/services/account_manager.dart';
import 'package:odoo_mobile/services/api_services/attendance_service.dart';
import 'package:odoo_mobile/services/gps_tracking_service.dart';
import 'package:odoo_mobile/models/account_model.dart';
import 'package:odoo_mobile/models/face_verification_result.dart';
import 'package:odoo_mobile/screens/face_enrollment_screen.dart';
import 'package:odoo_mobile/screens/face_verification_screen.dart';
import 'package:odoo_mobile/services/face_verification_service.dart';
import 'package:odoo_mobile/services/native_biometric_service.dart';
import 'package:odoo_mobile/widgets/gps_tracking_card.dart';
import 'package:odoo_mobile/widgets/account_switcher_sheet.dart';

class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  final AttendanceService _attendanceService = AttendanceService();

  late Stream<DateTime> _timeStream;
  List<Map<String, dynamic>> _customers = [];
  Map<String, dynamic>? _selectedCustomer;

  bool _isLoading = false;
  bool _showAllRecords = false;
  String _checkInTime = "--:--";
  String _checkOutTime = "--:--";
  String _hoursWorked = "0h 0m";
  List<Map<String, dynamic>> _recentRecords = [];

  @override
  void initState() {
    super.initState();
    _timeStream = Stream<DateTime>.periodic(
      const Duration(seconds: 1),
      (_) => DateTime.now(),
    ).asBroadcastStream();

    // OPT-4: Prewarm MobileFaceNet model in background on Android only
    if (Platform.isAndroid) {
      unawaited(
        FaceVerificationService.instance.initialize().catchError((e) {
          log('⚠️ [AttendanceScreen] FaceVerificationService prewarm error: $e');
        }),
      );
    }

    _loadCustomers();
    _loadAttendanceHistory();
    _syncFaceStatusFromBackend();
  }

  /// Synchronizes authoritative face registration status and template from Odoo backend
  Future<void> _syncFaceStatusFromBackend() async {
    // On iOS, face template synchronization and embedding storage are not required
    if (Platform.isIOS) return;

    final activeAccount = AccountManager.instance.activeAccount;
    if (activeAccount == null) return;

    try {
      final indexResp = await _attendanceService.getFaceIndex();
      if (indexResp != null && indexResp.isSuccess) {
        final requireFace = indexResp.requireFaceRecognition ?? activeAccount.requireFaceRecognition;
        final faceRegistered = indexResp.faceRegistered ?? activeAccount.faceRegistered ?? false;

        // If face is registered on backend and embedding data returned, cache/persist it locally
        if (faceRegistered && indexResp.faceEmbeddingData != null) {
          final embedding = indexResp.parsedEmbedding;
          if (embedding != null && embedding.isNotEmpty) {
            await FaceVerificationService.instance.saveEnrolledEmbedding(activeAccount.id, embedding);
          }
        }

        await AccountManager.instance.updateFaceRegistrationStatus(
          activeAccount.id,
          faceRegistered: faceRegistered,
          requireFaceRecognition: requireFace,
          faceEmbeddingData: indexResp.faceEmbeddingData,
        );
        log("👤 [AttendanceScreen] Face status synchronized: requireFace=$requireFace, registered=$faceRegistered");
      }
    } catch (e) {
      log('⚠️ [AttendanceScreen] Failed to sync face status from backend: $e');
    }
  }



  Future<void> _loadCustomers() async {
    final isRouteInstalled = AccountManager.instance.activeAccount?.isRouteManagementInstalled ?? false;
    if (!isRouteInstalled) return;

    final response = await _attendanceService.fetchCustomers();
    if (response != null && response['status'] == 'success') {
      if (!mounted) return;
      final rawList = List<Map<String, dynamic>>.from(response['data'] ?? []);

      final seenIds = <dynamic>{};
      final uniqueCustomers = <Map<String, dynamic>>[];
      for (final customer in rawList) {
        final id = customer['id'];
        if (id != null && seenIds.add(id)) {
          uniqueCustomers.add(customer);
        }
      }

      setState(() {
        _customers = uniqueCustomers;
        if (_selectedCustomer != null) {
          _selectedCustomer = _customers
              .where((c) => c['id'] == _selectedCustomer!['id'])
              .firstOrNull;
        }
      });
    }
  }

  String _parseTimeString(dynamic value) {
    if (value == null || value == false) return "--:--";
    final str = value.toString().trim();
    if (str.isEmpty || str.toLowerCase() == "false" || str.toLowerCase() == "null" || str == "-") {
      return "--:--";
    }
    return str;
  }

  Future<void> _loadAttendanceHistory() async {
    final response = await _attendanceService.fetchAttendanceHistory();
    if (response != null && response['status'] == 'success') {
      final summary = response['today_summary'] as Map<String, dynamic>?;
      final recent = response['recent_records'] as List<dynamic>?;

      if (!mounted) return;
      setState(() {
        if (summary != null) {
          _checkInTime = _parseTimeString(summary['check_in']);
          _checkOutTime = _parseTimeString(summary['check_out']);
          _hoursWorked = summary['hours']?.toString() ?? "0h 0m";
        }
        if (recent != null) {
          _recentRecords =
              recent.map((e) => Map<String, dynamic>.from(e)).toList();
        }
      });

      bool isCheckedIn;
      if (summary != null && summary['is_checked_in'] is bool) {
        isCheckedIn = summary['is_checked_in'] as bool;
      } else {
        isCheckedIn = _checkInTime != "--:--" && _checkOutTime == "--:--";
      }

      GpsTrackingService.instance.updateCheckInStatus(isCheckedIn);
    }
  }

  Future<Position?> _getCurrentLocation() async {
    final messenger = ScaffoldMessenger.of(context);
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (!mounted) return null;
      messenger.showSnackBar(
        const SnackBar(content: Text("Location services are disabled on your device.")),
      );
      return null;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (!mounted) return null;
        messenger.showSnackBar(
          const SnackBar(content: Text("Location permissions are denied.")),
        );
        return null;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      if (!mounted) return null;
      messenger.showSnackBar(
        const SnackBar(
            content: Text("Location permissions are permanently denied. Please enable in Settings.")),
      );
      return null;
    }

    // 1. Try last known position first for quick response
    try {
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null) {
        log("📍 [Location] Got last known position: ${lastKnown.latitude}, ${lastKnown.longitude}");
        return lastKnown;
      }
    } catch (e) {
      log("⚠️ [Location] getLastKnownPosition failed: $e");
    }

    // 2. Try current position with medium accuracy & 10s timeout
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 10),
        ),
      );
      log("📍 [Location] Got current position: ${pos.latitude}, ${pos.longitude}");
      return pos;
    } catch (e) {
      log("⚠️ [Location] Medium accuracy position failed: $e");
    }

    // 3. Fallback to low accuracy position
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 5),
        ),
      );
      log("📍 [Location] Got low accuracy position: ${pos.latitude}, ${pos.longitude}");
      return pos;
    } catch (e) {
      log("⚠️ [Location] Low accuracy position failed: $e");
    }

    // 4. Fallback to GpsTrackingService cached location
    final service = GpsTrackingService.instance;
    if (service.currentLatitude != null && service.currentLongitude != null) {
      log("📍 [Location] Using GpsTrackingService cached location: ${service.currentLatitude}, ${service.currentLongitude}");
      return Position(
        longitude: service.currentLongitude!,
        latitude: service.currentLatitude!,
        timestamp: DateTime.now(),
        accuracy: service.accuracy ?? 0,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );
    }

    return null;
  }

  Future<void> _handleAttendance(String action) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _isLoading = true);

    try {
      final activeAccount = AccountManager.instance.activeAccount;
      if (activeAccount == null) {
        if (!mounted) return;
        messenger.showSnackBar(
          SnackBar(
            content: const Text("No active account found. Please log in again."),
            backgroundColor: redColor,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
        return;
      }

      // DECISION LOGIC FOR FACE RECOGNITION (Odoo 19 Cases 1, 2, 3)
      final bool requireFaceRecognition = activeAccount.requireFaceRecognition ?? true;

      bool authPassed = false;
      double? similarityScore;

      if (Platform.isIOS) {
        // On iOS: server face registration and face_embedding_data are not required.
        // Attendance authentication uses native Apple Face ID without similarity scores.
        authPassed = await _verifyIosFaceId(activeAccount, action);
        similarityScore = null;
        if (!authPassed) {
          return; // MANDATORY: Return immediately without requesting GPS or calling attendance API
        }
      } else {
        // On Android: check requireFaceRecognition and custom Face Lock
        if (!requireFaceRecognition) {
          // CASE 1: Face recognition not required -> Skip face verification entirely
          log("ℹ️ [Attendance] Face recognition not required for account ${activeAccount.id}. Proceeding directly to GPS...");
          authPassed = true;
        } else {
          // CASES 2 & 3: Face recognition required
          final (passed, score) = await _verifyAndroidFaceLock(activeAccount, action);
          authPassed = passed;
          similarityScore = score;
          if (!authPassed) {
            return; // MANDATORY: Return immediately without requesting GPS or calling attendance API
          }
        }
      }

      log("✅ [Attendance] Auth check passed (platform: ${Platform.isIOS ? 'ios' : 'android'}, requireFace: $requireFaceRecognition). Proceeding to GPS location...");

      final position = await _getCurrentLocation();
      if (position == null) {
        if (!mounted) return;
        messenger.showSnackBar(
          SnackBar(
            content: const Text("Unable to obtain GPS location. Please check your location/GPS settings."),
            backgroundColor: redColor,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
        return;
      }

      final response = await _attendanceService.markAttendance(
        latitude: position.latitude,
        longitude: position.longitude,
        action: action,
        faceVerified: Platform.isIOS ? true : (requireFaceRecognition ? true : false),
        similarityScore: Platform.isIOS ? null : (requireFaceRecognition ? similarityScore : null),
        devicePlatform: Platform.isIOS ? "ios" : "android",
      );

      if (!mounted) return;
      if (response != null && response['result']?['status'] == 'success') {
        final isCheckIn = action == 'check_in';
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              isCheckIn ? "Check-In Succeeded" : "Check-Out Succeeded",
              style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
            ),
            backgroundColor: isCheckIn ? const Color(0xFF059669) : const Color(0xFFDC2626),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
        GpsTrackingService.instance.updateCheckInStatus(action == 'check_in');
        await _loadAttendanceHistory();
      } else {
        final errorMsg = response?['result']?['error'] ??
            response?['error']?['message'] ??
            "Failed to ${action == 'check_in' ? 'check in' : 'check out'}";
        
        final lowerError = errorMsg.toString().toLowerCase();
        if (lowerError.contains("already") || lowerError.contains("checked")) {
          log("⚠️ Server reported state mismatch ($errorMsg). Refreshing attendance history...");
          await _loadAttendanceHistory();
        }

        messenger.showSnackBar(
          SnackBar(
            content: Text(errorMsg.toString()),
            backgroundColor: redColor,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      log("❌ Exception handling attendance: $e");
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text("Error: ${e.toString()}"),
            backgroundColor: redColor,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// Performs native Apple Face ID authentication on iOS via [NativeBiometricService].
  ///
  /// Invariants:
  /// - Strictly enforces Face ID (`BiometricType.face`); Touch ID is rejected.
  /// - Does NOT use MobileFaceNet, custom camera, ML Kit, or custom face templates.
  /// - Returns `true` ONLY when Apple Face ID successfully verifies the user.
  /// - Returns `false` on cancel, failure, or missing enrollment, stopping attendance immediately.
  Future<bool> _verifyIosFaceId(Account activeAccount, String action) async {
    final messenger = ScaffoldMessenger.of(context);
    final isCheckIn = action == 'check_in';
    final actionLabel = isCheckIn ? 'check in' : 'check out';

    log("🔒 [Attendance-iOS] Requesting Apple Face ID for account ${activeAccount.id} (${activeAccount.employeeName})...");

    final result = await NativeBiometricService.instance.authenticateWithFaceId(
      reason: "Verify your face with Apple Face ID to $actionLabel.",
    );

    if (!mounted) return false;

    if (!result.isSuccess) {
      log("🔒 [Attendance-iOS] Face ID failed: ${result.status} - ${result.message}");

      if (result.status == FaceVerificationStatus.noEnrollment) {
        await showDialog<void>(
          context: context,
          builder: (dialogCtx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                Icon(Icons.face_unlock_rounded, color: primaryColor),
                const SizedBox(width: 8),
                const Text("Face ID Setup Required"),
              ],
            ),
            content: const Text(
              "Apple Face ID is not set up on this device.\n\n"
              "Please enroll Face ID in your iPhone Settings (Settings → Face ID & Passcode) before proceeding.",
            ),
            actions: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryColor,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () => Navigator.of(dialogCtx).pop(),
                child: const Text("OK", style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        );
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: Text(result.message),
            backgroundColor: redColor,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
      return false;
    }

    log("✅ [Attendance-iOS] Apple Face ID authenticated successfully.");
    return true;
  }

  /// Performs custom Face Lock verification on Android via ML Kit + MobileFaceNet + active liveness.
  ///
  /// Invariants:
  /// - Returns `(true, similarity)` ONLY when cosine similarity meets or exceeds threshold.
  /// - Returns `(false, null)` on cancel, failure, or missing enrollment, stopping attendance immediately.
  Future<(bool, double?)> _verifyAndroidFaceLock(Account activeAccount, String action) async {
    final messenger = ScaffoldMessenger.of(context);

    // 1. Check enrollment locally
    bool hasEnrolled = await FaceVerificationService.instance.hasEnrolledFace(activeAccount.id);
    if (!hasEnrolled) {
      // Check if backend already has registered face index
      final indexResp = await _attendanceService.getFaceIndex();
      if (indexResp != null && indexResp.isSuccess && (indexResp.faceRegistered ?? false)) {
        final emb = indexResp.parsedEmbedding;
        if (emb != null && emb.isNotEmpty) {
          await FaceVerificationService.instance.saveEnrolledEmbedding(activeAccount.id, emb);
          hasEnrolled = true;
          await AccountManager.instance.updateFaceRegistrationStatus(
            activeAccount.id,
            faceRegistered: true,
            requireFaceRecognition: indexResp.requireFaceRecognition,
            faceEmbeddingData: indexResp.faceEmbeddingData,
          );
        }
      }
    }

    if (!hasEnrolled) {
      log("🔒 [Attendance-Android] No enrolled face for account ${activeAccount.id}. Prompting registration...");
      if (!mounted) return (false, null);

      final shouldEnroll = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogCtx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(Icons.face_retouching_natural, color: primaryColor),
              const SizedBox(width: 8),
              const Expanded(
                child: Text("Face Registration Required"),
              ),
            ],
          ),
          content: const Text(
            "Face recognition is required for attendance. Please complete face registration first.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryColor,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.of(dialogCtx).pop(true),
              child: const Text("Register Face Now", style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );

      if (shouldEnroll == true && mounted) {
        final enrollmentResult = await Navigator.push<FaceVerificationResult>(
          context,
          MaterialPageRoute(
            builder: (_) => FaceEnrollmentScreen(
              accountId: activeAccount.id,
              employeeName: activeAccount.employeeName,
            ),
          ),
        );

        if (enrollmentResult != null && enrollmentResult.isSuccess) {
          messenger.showSnackBar(
            SnackBar(
              content: const Text("Face registered successfully. Please tap Check-In / Check-Out again."),
              backgroundColor: const Color(0xFF00E676),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          );
        } else {
          messenger.showSnackBar(
            SnackBar(
              content: Text(enrollmentResult?.message ?? "Face registration was not completed."),
              backgroundColor: redColor,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          );
        }
      }
      return (false, null); // MANDATORY: Return immediately without requesting GPS or calling attendance API
    }

    // 2. Launch Face Verification Gate
    log("🔒 [Attendance-Android] Launching app-side face verification for account ${activeAccount.id}...");
    if (!mounted) return (false, null);

    final verifyResult = await Navigator.push<FaceVerificationResult>(
      context,
      MaterialPageRoute(
        builder: (_) => FaceVerificationScreen(
          accountId: activeAccount.id,
          employeeName: activeAccount.employeeName,
          action: action,
        ),
      ),
    );

    if (verifyResult == null || !verifyResult.isSuccess) {
      log("🔒 [Attendance-Android] Face verification not passed: ${verifyResult?.status} - ${verifyResult?.message}");
      if (!mounted) return (false, null);
      messenger.showSnackBar(
        SnackBar(
          content: Text(verifyResult?.message ?? "Face verification failed. Attendance was not recorded."),
          backgroundColor: redColor,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
      return (false, null); // MANDATORY: Return immediately without requesting GPS or calling attendance API
    }

    log("✅ [Attendance-Android] Face verification passed (similarity: ${verifyResult.similarity}).");
    return (true, verifyResult.similarity);
  }

  /// Displays information explaining that Face ID on iOS is configured in system settings.
  void _showIosFaceIdInfoDialog() {
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.face_unlock_rounded, color: primaryColor),
            const SizedBox(width: 8),
            const Text("Face ID Management"),
          ],
        ),
        content: const Text(
          "On iOS, attendance authentication uses Apple Face ID.\n\n"
          "Face ID enrollment, reset, and appearance settings are managed directly in your iPhone system settings:\n\n"
          "Settings → Face ID & Passcode",
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text("Got It", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _handleReachLocation() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_selectedCustomer == null) {
      messenger.showSnackBar(
        SnackBar(
          content: const Text("Please select a customer first"),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final position = await _getCurrentLocation();

      if (position == null) {
        if (!mounted) return;
        messenger.showSnackBar(
          SnackBar(
            content: const Text("Unable to obtain GPS location. Please check your location settings."),
            backgroundColor: redColor,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
        return;
      }

      final response = await _attendanceService.markReached(
        stopId: _selectedCustomer!['id'],
        driverLat: position.latitude,
        driverLng: position.longitude,
      );

      if (!mounted) return;
      if (response != null && response['result']?['success'] == true) {
        messenger.showSnackBar(
          SnackBar(
            content: const Text("Location reached successfully!"),
            backgroundColor: const Color(0xFF059669),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      } else {
        final error =
            response?['result']?['error'] ?? "Failed to mark as reached";
        messenger.showSnackBar(
          SnackBar(
            content: Text(error.toString()),
            backgroundColor: redColor,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      log("❌ Exception handling reach location: $e");
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text("Error: ${e.toString()}"),
            backgroundColor: redColor,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AccountManager.instance,
      builder: (context, _) {
        final isRouteInstalled = AccountManager.instance.activeAccount?.isRouteManagementInstalled ?? false;

        return Scaffold(
          backgroundColor: const Color(0xFFF9FAFB),
          appBar: AppBar(
            backgroundColor: const Color(0xFFF9FAFB),
            elevation: 0,
            scrolledUnderElevation: 0,
            centerTitle: false,
            title: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                "Attendance",
                style: GoogleFonts.poppins(
                  fontWeight: FontWeight.w600,
                  fontSize: 20,
                  color: const Color(0xFF111827),
                ),
              ),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh_rounded, color: Color(0xFF4B5563)),
                tooltip: "Refresh",
                onPressed: () {
                  _loadCustomers();
                  _loadAttendanceHistory();
                  _syncFaceStatusFromBackend();
                },
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded, color: Color(0xFF4B5563)),
                onSelected: (value) {
                  if (value == 'face_enrollment') {
                    if (Platform.isIOS) {
                      _showIosFaceIdInfoDialog();
                    } else {
                      final active = AccountManager.instance.activeAccount;
                      if (active != null) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => FaceEnrollmentScreen(
                              accountId: active.id,
                              employeeName: active.employeeName,
                              isReenrollment: true,
                            ),
                          ),
                        );
                      }
                    }
                  } else if (value == 'switch_account') {
                    AccountSwitcherSheet.show(context);
                  } else if (value == 'logout') {
                    AccountSwitcherSheet.showLogoutDialog(context);
                  }
                },
                itemBuilder: (BuildContext context) {
                  return [
                    PopupMenuItem<String>(
                      value: 'face_enrollment',
                      child: Row(
                        children: [
                          Icon(Icons.face_retouching_natural, color: primaryColor, size: 20),
                          const SizedBox(width: 10),
                          Text('Face Biometrics',
                              style: GoogleFonts.poppins(fontSize: 14, color: const Color(0xFF111827), fontWeight: FontWeight.w500)),
                        ],
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'switch_account',
                      child: Row(
                        children: [
                          const Icon(Icons.swap_horiz_rounded, color: Color(0xFF4B5563), size: 20),
                          const SizedBox(width: 10),
                          Text('Switch Account',
                              style: GoogleFonts.poppins(fontSize: 14, color: const Color(0xFF111827))),
                        ],
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'logout',
                      child: Row(
                        children: [
                          const Icon(Icons.logout_rounded, color: Color(0xFFDC2626), size: 20),
                          const SizedBox(width: 10),
                          Text(
                            'Log Out',
                            style: GoogleFonts.poppins(
                              fontSize: 14,
                              color: const Color(0xFFDC2626),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ];
                },
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Stack(
            children: [
              SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeroSection(),
                    const SizedBox(height: 16),
                    _buildPrimaryActionButton(),
                    const SizedBox(height: 16),
                    const GpsTrackingCard(),
                    if (isRouteInstalled) ...[
                      const SizedBox(height: 16),
                      _buildCustomerActionSection(),
                    ],
                    const SizedBox(height: 20),
                    _buildSummarySection(),
                    const SizedBox(height: 20),
                    _buildRecentRecordsSection(),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
              if (_isLoading)
                Container(
                  color: Colors.black.withValues(alpha: 0.15),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                      child: const CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF6750A4)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // 1. HERO SECTION (Top)
  Widget _buildHeroSection() {
    final bool isCheckedIn = _checkInTime != "--:--" && _checkOutTime == "--:--";

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.schedule_rounded,
                      color: Color(0xFF4B5563),
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "System Clock",
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF6B7280),
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isCheckedIn ? const Color(0xFFECFDF5) : const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isCheckedIn ? const Color(0xFFA7F3D0) : const Color(0xFFE5E7EB),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: isCheckedIn ? const Color(0xFF10B981) : const Color(0xFF9CA3AF),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isCheckedIn ? "Checked In" : "Not Checked In",
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isCheckedIn ? const Color(0xFF059669) : const Color(0xFF4B5563),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          StreamBuilder<DateTime>(
            stream: _timeStream,
            builder: (context, snapshot) {
              final time = snapshot.data ?? DateTime.now();
              return Text(
                DateFormat('hh:mm:ss a').format(time),
                style: GoogleFonts.poppins(
                  color: const Color(0xFF111827),
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                  letterSpacing: -0.5,
                ),
              );
            },
          ),
          const SizedBox(height: 4),
          StreamBuilder<DateTime>(
            stream: _timeStream,
            builder: (context, snapshot) {
              final date = snapshot.data ?? DateTime.now();
              return Text(
                DateFormat('EEEE, d MMMM yyyy').format(date),
                style: GoogleFonts.poppins(
                  color: const Color(0xFF6B7280),
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // 2. PRIMARY ACTION (Modern State-Based Button)
  Widget _buildPrimaryActionButton() {
    final bool isCheckedIn = _checkInTime != "--:--" && _checkOutTime == "--:--";

    final Color primaryColor =
        isCheckedIn ? const Color(0xFFDC2626) : const Color(0xFF059669);
    final String titleText = isCheckedIn ? "Check Out" : "Check In";
    final String subtitleText = isCheckedIn
        ? "Tap to finish your workday"
        : "Tap to record your start time";
    final IconData iconData =
        isCheckedIn ? Icons.logout_rounded : Icons.login_rounded;

    return GestureDetector(
      onTap: _isLoading
          ? null
          : () async {
              await _handleAttendance(isCheckedIn ? 'check_out' : 'check_in');
            },
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: primaryColor,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  iconData,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      titleText,
                      style: GoogleFonts.poppins(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitleText,
                      style: GoogleFonts.poppins(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.arrow_forward_rounded,
                color: Colors.white,
                size: 20,
              ),
            ],
          ),
        ),
      );
    }

  // 4. CUSTOMER + ACTION GROUP
  Widget _buildCustomerActionSection() {
    final selectedId = (_selectedCustomer != null &&
            _customers.any((c) => c['id'] == _selectedCustomer!['id']))
        ? _selectedCustomer!['id']
        : null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.near_me_outlined,
                size: 18,
                color: Color(0xFF4B5563),
              ),
              const SizedBox(width: 8),
              Text(
                "Customer Visit Check-in",
                style: GoogleFonts.poppins(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF111827),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFF9FAFB),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<dynamic>(
                value: selectedId,
                isExpanded: true,
                hint: Text(
                  "Select Customer / Destination",
                  style: GoogleFonts.poppins(
                    color: const Color(0xFF9CA3AF),
                    fontSize: 13,
                  ),
                ),
                icon: const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: Color(0xFF6B7280),
                ),
                items: _customers.map((customer) {
                  return DropdownMenuItem<dynamic>(
                    value: customer['id'],
                    child: Text(
                      customer['name'] ?? '',
                      style: GoogleFonts.poppins(
                        fontSize: 13,
                        color: const Color(0xFF111827),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _selectedCustomer =
                          _customers.where((c) => c['id'] == value).firstOrNull;
                    });
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: ElevatedButton.icon(
              onPressed: _handleReachLocation,
              icon: const Icon(Icons.navigation_rounded, size: 18, color: Colors.white),
              label: Text(
                "Reach Location",
                style: GoogleFonts.poppins(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 5. SUMMARY SECTION
  Widget _buildSummarySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "Today's Summary",
          style: GoogleFonts.poppins(
            fontWeight: FontWeight.w600,
            fontSize: 15,
            color: const Color(0xFF111827),
          ),
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Row(
            children: [
              Expanded(
                child: _buildSummaryInlineItem(
                  icon: Icons.login_rounded,
                  iconColor: const Color(0xFF059669),
                  value: _checkInTime,
                  label: "Check In",
                ),
              ),
              Container(height: 36, width: 1, color: const Color(0xFFE5E7EB)),
              Expanded(
                child: _buildSummaryInlineItem(
                  icon: Icons.logout_rounded,
                  iconColor: const Color(0xFFDC2626),
                  value: _checkOutTime,
                  label: "Check Out",
                ),
              ),
              Container(height: 36, width: 1, color: const Color(0xFFE5E7EB)),
              Expanded(
                child: _buildSummaryInlineItem(
                  icon: Icons.timer_outlined,
                  iconColor: const Color(0xFF6750A4),
                  value: _hoursWorked,
                  label: "Hours",
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryInlineItem({
    required IconData icon,
    required Color iconColor,
    required String value,
    required String label,
  }) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: iconColor, size: 16),
            const SizedBox(width: 4),
            Text(
              label,
              style: GoogleFonts.poppins(
                color: const Color(0xFF6B7280),
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: GoogleFonts.poppins(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              color: const Color(0xFF111827),
            ),
          ),
        ),
      ],
    );
  }

  // 6. RECENT RECORDS (Activity Feed Style)
  Widget _buildRecentRecordsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              "Recent Activity",
              style: GoogleFonts.poppins(
                fontWeight: FontWeight.w600,
                fontSize: 15,
                color: const Color(0xFF111827),
              ),
            ),
            if (_recentRecords.isNotEmpty)
              Text(
                "${_recentRecords.length} records",
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  color: const Color(0xFF6B7280),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (_recentRecords.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Column(
              children: [
                const Icon(Icons.history_toggle_off_rounded,
                    size: 32, color: Color(0xFF9CA3AF)),
                const SizedBox(height: 8),
                Text(
                  "No recent attendance records found",
                  style: GoogleFonts.poppins(
                    color: const Color(0xFF6B7280),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          )
        else ...[
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Column(
              children: [
                ...(_showAllRecords
                        ? _recentRecords
                        : _recentRecords.take(3).toList())
                    .asMap()
                    .entries
                    .map((entry) {
                  final index = entry.key;
                  final record = entry.value;
                  final date = record['date']?.toString() ?? '';
                  final timeRange = record['time_range']?.toString() ?? '';
                  final workedHours = record['worked_hours']?.toString() ?? '';
                  final status = record['status']?.toString() ?? 'Present';
                  final isAbsent = status.toLowerCase() == 'absent';
                  final displayList = _showAllRecords
                      ? _recentRecords
                      : _recentRecords.take(3).toList();

                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: const Color(0xFFF3F4F6),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                Icons.calendar_today_rounded,
                                color: Color(0xFF6750A4),
                                size: 16,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    date,
                                    style: GoogleFonts.poppins(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                      color: const Color(0xFF111827),
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    "$timeRange • $workedHours",
                                    style: GoogleFonts.poppins(
                                      color: const Color(0xFF6B7280),
                                      fontSize: 12,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: isAbsent
                                    ? const Color(0xFFFEF2F2)
                                    : const Color(0xFFECFDF5),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                status,
                                style: GoogleFonts.poppins(
                                  color: isAbsent
                                      ? const Color(0xFFDC2626)
                                      : const Color(0xFF059669),
                                  fontWeight: FontWeight.w600,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (index < displayList.length - 1)
                        const Divider(height: 1, color: Color(0xFFF3F4F6)),
                    ],
                  );
                }),
              ],
            ),
          ),
          if (_recentRecords.length > 3)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: TextButton.icon(
                  onPressed: () {
                    setState(() {
                      _showAllRecords = !_showAllRecords;
                    });
                  },
                  icon: Icon(
                    _showAllRecords
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: const Color(0xFF6750A4),
                    size: 18,
                  ),
                  label: Text(
                    _showAllRecords
                        ? "Show Less"
                        : "See More (${_recentRecords.length - 3} more)",
                    style: GoogleFonts.poppins(
                      color: const Color(0xFF6750A4),
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }
}
