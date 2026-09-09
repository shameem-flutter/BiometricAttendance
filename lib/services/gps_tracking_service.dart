import 'dart:async';
import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import 'package:odoo_mobile/models/gps_config_model.dart';
import 'package:odoo_mobile/services/account_manager.dart';
import 'package:odoo_mobile/services/api_services/gps_api_service.dart';
import 'package:odoo_mobile/services/api_services/attendance_service.dart';

enum GpsTrackingStatus {
  active,
  disabled,
  waitingForGps,
  permissionRequired,
  sessionExpired,
  checkedOut,
}

class GpsTrackingService extends ChangeNotifier with WidgetsBindingObserver {
  static final GpsTrackingService instance = GpsTrackingService._internal();
  GpsTrackingService._internal();

  final GpsApiService _apiService = GpsApiService();

  Timer? _timer;
  bool _isInitializing = false;
  bool _isUploading = false;
  bool _isObserverRegistered = false;

  // Centralized Tracking State
  GpsTrackingStatus _trackingStatus = GpsTrackingStatus.disabled;
  LocationPermission _permissionStatus = LocationPermission.denied;
  int? _employeeId;
  String? _employeeName;
  int _uploadInterval = 7;
  bool _isEnabled = false;
  bool _isCheckedIn = false;
  DateTime? _lastSyncTime;
  double? _currentLatitude;
  double? _currentLongitude;
  double? _accuracy;
  String? _lastError;

  // Getters for Centralized Tracking State
  GpsTrackingStatus get trackingStatus => _trackingStatus;
  LocationPermission get permissionStatus => _permissionStatus;
  int? get employeeId => _employeeId;
  String? get employeeName => _employeeName;
  int get uploadInterval => _uploadInterval;
  bool get isEnabled => _isEnabled;
  bool get isCheckedIn => _isCheckedIn;
  DateTime? get lastSyncTime => _lastSyncTime;
  double? get currentLatitude => _currentLatitude;
  double? get currentLongitude => _currentLongitude;
  double? get accuracy => _accuracy;
  bool get isUploading => _isUploading;
  String? get lastError => _lastError;
  bool get isTimerRunning => _timer != null && _timer!.isActive;

  /// Updates check-in status and manages periodic timer accordingly
  void updateCheckInStatus(bool isCheckedIn) {
    log("📌 [GPS] Attendance Check-In Status updated: isCheckedIn=$isCheckedIn");
    _isCheckedIn = isCheckedIn;
    if (!_isCheckedIn) {
      _stopTimerOnly();
      _trackingStatus = GpsTrackingStatus.checkedOut;
    } else {
      if (_isEnabled) {
        _startPeriodicTimer();
      }
    }
    notifyListeners();
  }

  /// Syncs attendance check-in status directly from backend history
  Future<void> syncAttendanceCheckInStatus() async {
    try {
      final response = await AttendanceService().fetchAttendanceHistory();
      if (response != null && response['status'] == 'success') {
        final summary = response['today_summary'] as Map<String, dynamic>?;
        if (summary != null) {
          if (summary['is_checked_in'] is bool) {
            updateCheckInStatus(summary['is_checked_in'] as bool);
            return;
          }
          final String rawIn = summary['check_in']?.toString().trim() ?? "";
          final String rawOut = summary['check_out']?.toString().trim() ?? "";
          final bool hasCheckIn = rawIn.isNotEmpty && rawIn != "false" && rawIn != "null" && rawIn != "--:--";
          final bool hasCheckOut = rawOut.isNotEmpty && rawOut != "false" && rawOut != "null" && rawOut != "--:--";
          
          final bool checked = hasCheckIn && !hasCheckOut;
          updateCheckInStatus(checked);
          return;
        }
      }
    } catch (e) {
      log("⚠️ [GPS] Failed to sync attendance check-in status: $e");
    }
  }

  /// Register app lifecycle observer
  void _ensureObserverRegistered() {
    if (!_isObserverRegistered) {
      WidgetsBinding.instance.addObserver(this);
      _isObserverRegistered = true;
    }
  }

  /// App Lifecycle callback
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      log("📱 [GPS] App resumed. Refreshing configuration and tracking state.");
      refreshConfigurationAndState();
    }
  }

  /// Single Initialization Entry Point - Safe to call multiple times.
  /// Prevents duplicate initialization and duplicate timers.
  Future<void> initialize() async {
    _ensureObserverRegistered();

    if (_isInitializing) {
      log("⏳ [GPS] Initialization already in progress. Skipping.");
      return;
    }

    _isInitializing = true;
    try {
      log("🚀 [GPS] Initializing GPS Tracking Service...");
      await _syncEmployeeSessionData();
      await refreshConfigurationAndState();
    } finally {
      _isInitializing = false;
    }
  }

  /// Synchronizes employee session data from AccountManager (Source of Truth)
  Future<void> _syncEmployeeSessionData() async {
    final activeAccount = AccountManager.instance.activeAccount;
    if (activeAccount != null) {
      if (activeAccount.employeeId != null) {
        _employeeId = activeAccount.employeeId;
      }
      if (activeAccount.employeeName != null && activeAccount.employeeName!.isNotEmpty) {
        _employeeName = activeAccount.employeeName;
      } else {
        _employeeName = activeAccount.username;
      }
    }
  }

  /// Explicitly update Employee session info (called after authentication)
  void setEmployeeSessionInfo({required int employeeId, required String employeeName}) {
    log("👤 [GPS] Authenticated session set: employee_id=$employeeId, employee_name=$employeeName");
    _employeeId = employeeId;
    _employeeName = employeeName;
    notifyListeners();
  }

  /// Refreshes GPS Configuration from backend and updates tracking service accordingly.
  Future<void> refreshConfigurationAndState() async {
    final activeAccount = AccountManager.instance.activeAccount;
    if (activeAccount == null) {
      log("⚠️ [GPS] No active account logged in. Stopping tracking.");
      stopTrackingAndClear();
      return;
    }

    // Refresh employee info if not set
    await _syncEmployeeSessionData();

    GpsConfig config;
    try {
      config = await _apiService.fetchGpsConfig();
      log("📋 [GPS] Configuration received: enabled=${config.enableLiveGpsTracking}, interval=${config.gpsRefreshInterval}s");
    } on GpsAuthException catch (e) {
      log("⛔ [GPS] Auth/Session Exception during config fetch: ${e.message}");
      _handleSessionExpired(e.message);
      return;
    } catch (e) {
      log("⚠️ [GPS] Failed to fetch GPS configuration: $e");
      // Keep existing settings if available, or retry on next check
      if (!_isEnabled) {
        _trackingStatus = GpsTrackingStatus.disabled;
        notifyListeners();
        return;
      }
      return;
    }

    // Check backend employee info against single source of truth
    if (config.employeeId != null && _employeeId != null && config.employeeId != _employeeId) {
      log("⚠️ [GPS] Warning: Server config employee_id (${config.employeeId}) differs from session employee_id ($_employeeId). Using session ID as single source of truth.");
    }
    if (_employeeId == null && config.employeeId != null) {
      _employeeId = config.employeeId;
    }
    if ((_employeeName == null || _employeeName!.isEmpty) && config.employeeName != null) {
      _employeeName = config.employeeName;
    }

    _isEnabled = config.enableLiveGpsTracking;
    final int newInterval = config.gpsRefreshInterval > 0 ? config.gpsRefreshInterval : 7;
    final bool intervalChanged = (_uploadInterval != newInterval);
    _uploadInterval = newInterval;

    if (!_isEnabled) {
      log("⏸️ [GPS] Tracking Disabled by backend server config.");
      _stopTimerOnly();
      _trackingStatus = GpsTrackingStatus.disabled;
      notifyListeners();
      return;
    }

    await syncAttendanceCheckInStatus();

    if (!_isCheckedIn) {
      log("⏸️ [GPS] User is NOT checked in. Pausing periodic GPS tracking.");
      _stopTimerOnly();
      _trackingStatus = GpsTrackingStatus.checkedOut;
      notifyListeners();
      return;
    }

    log("🟢 [GPS] Tracking Enabled. Interval: $_uploadInterval seconds.");

    // Check Permissions
    final permissionGranted = await _checkAndRequestPermissions();
    if (!permissionGranted) {
      _stopTimerOnly();
      _trackingStatus = GpsTrackingStatus.permissionRequired;
      notifyListeners();
      return;
    }

    // If tracking is active but interval changed or timer stopped, re-schedule timer safely
    if (intervalChanged || _timer == null || !_timer!.isActive) {
      _startPeriodicTimer();
    }
  }

  /// Request Location Permissions cleanly
  Future<bool> _checkAndRequestPermissions() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      log("⚠️ [GPS] Location services are disabled on device.");
      _permissionStatus = LocationPermission.denied;
      _lastError = "Location services disabled";
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      log("🔑 [GPS] Requesting location permission...");
      permission = await Geolocator.requestPermission();
    }

    _permissionStatus = permission;

    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      log("❌ [GPS] Permission Denied: $permission");
      _lastError = "Location permission denied";
      return false;
    }

    return true;
  }

  /// Request permission from UI button action
  Future<void> requestPermissionFromUser() async {
    LocationPermission permission = await Geolocator.requestPermission();
    _permissionStatus = permission;
    if (permission == LocationPermission.always || permission == LocationPermission.whileInUse) {
      log("✅ [GPS] Location permission granted by user.");
      await refreshConfigurationAndState();
    } else if (permission == LocationPermission.deniedForever) {
      log("❌ [GPS] Location permission permanently denied.");
      await Geolocator.openAppSettings();
    }
    notifyListeners();
  }

  /// Safely starts/restarts periodic timer (Deduplication Guaranteed)
  void _startPeriodicTimer() {
    _stopTimerOnly();

    if (!_isCheckedIn) {
      log("⏸️ [GPS] User is NOT checked in. Skipping periodic GPS upload timer.");
      _trackingStatus = GpsTrackingStatus.checkedOut;
      notifyListeners();
      return;
    }

    log("⏰ [GPS] Starting periodic GPS upload timer every $_uploadInterval seconds.");
    _trackingStatus = GpsTrackingStatus.active;
    notifyListeners();

    // Trigger immediate location upload tick
    _performTick();

    // Schedule timer
    _timer = Timer.periodic(Duration(seconds: _uploadInterval), (_) {
      _performTick();
    });
  }

  /// Periodic tick execution with full safety checks
  Future<void> _performTick() async {
    // 1. Prevent concurrent uploads
    if (_isUploading) {
      log("⏳ [GPS] Upload already in progress. Skipping tick.");
      return;
    }

    if (!_isEnabled || _employeeId == null || !_isCheckedIn) {
      return;
    }

    // 2. Check Internet Connectivity
    final hasInternet = await InternetConnection().hasInternetAccess;
    if (!hasInternet) {
      log("🌐 [GPS] No internet connection. Skipping upload, will retry next interval.");
      _lastError = "No internet connection";
      notifyListeners();
      return;
    }

    _isUploading = true;
    notifyListeners();

    try {
      // 3. Obtain Location
      _trackingStatus = GpsTrackingStatus.waitingForGps;
      notifyListeners();

      Position? position;
      try {
        position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 10),
          ),
        );
      } catch (_) {
        position = await Geolocator.getLastKnownPosition();
      }

      if (position == null) {
        log("📍 [GPS] Unable to determine location.");
        _lastError = "Unable to fetch GPS position";
        _trackingStatus = GpsTrackingStatus.waitingForGps;
        notifyListeners();
        return;
      }

      _currentLatitude = position.latitude;
      _currentLongitude = position.longitude;
      _accuracy = position.accuracy;
      log("📍 [GPS] Current Location: lat=${_currentLatitude?.toStringAsFixed(5)}, lng=${_currentLongitude?.toStringAsFixed(5)}, acc=${_accuracy?.toStringAsFixed(1)}m");

      // 4. Upload Location
      final success = await _apiService.uploadGpsLocation(
        latitude: _currentLatitude!,
        longitude: _currentLongitude!,
        employeeId: _employeeId!,
      );

      if (success) {
        _lastSyncTime = DateTime.now();
        _lastError = null;
        _trackingStatus = GpsTrackingStatus.active;
        log("✅ [GPS] Upload Success at ${_lastSyncTime!.toIso8601String()}");
      } else {
        _lastError = "Upload failed";
        _trackingStatus = GpsTrackingStatus.active;
        log("❌ [GPS] Upload Failed. Will retry on next interval.");
      }
    } on GpsAuthException catch (e) {
      log("⛔ [GPS] Session expired during upload: ${e.message}");
      _handleSessionExpired(e.message);
    } catch (e) {
      log("❌ [GPS] Unexpected error during GPS tick: $e");
      _lastError = e.toString();
    } finally {
      _isUploading = false;
      notifyListeners();
    }
  }

  /// Handles session expiration gracefully
  void _handleSessionExpired(String reason) {
    log("⛔ [GPS] Session Expired: $reason. Stopping GPS tracking.");
    _stopTimerOnly();
    _trackingStatus = GpsTrackingStatus.sessionExpired;
    _lastError = reason;
    notifyListeners();
  }

  /// Stops periodic timer without clearing stored state
  void _stopTimerOnly() {
    if (_timer != null) {
      _timer!.cancel();
      _timer = null;
    }
  }

  /// Stops tracking cleanly and resets state (e.g. on Logout or Account Switch)
  void stopTrackingAndClear() {
    log("⏹️ [GPS] Tracking Stopped and state cleared.");
    _stopTimerOnly();
    _isEnabled = false;
    _isCheckedIn = false;
    _trackingStatus = GpsTrackingStatus.disabled;
    _employeeId = null;
    _employeeName = null;
    _currentLatitude = null;
    _currentLongitude = null;
    _accuracy = null;
    _lastSyncTime = null;
    _lastError = null;
    _isUploading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_isObserverRegistered) {
      WidgetsBinding.instance.removeObserver(this);
      _isObserverRegistered = false;
    }
    _stopTimerOnly();
    super.dispose();
  }
}
