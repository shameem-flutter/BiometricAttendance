import 'dart:developer';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:odoo_mobile/services/account_manager.dart';
import 'package:odoo_mobile/services/api_services/apiclient.dart';

class AttendanceService {
  final Dio _dio = ApiClient.dio;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  Future<String?> _getSessionId() async {
    final activeAccount = AccountManager.instance.activeAccount;
    if (activeAccount == null) return null;
    return await _secureStorage.read(key: 'session_${activeAccount.id}');
  }

  Future<Map<String, dynamic>?> fetchCustomers() async {
    final sessionId = await _getSessionId();
    if (sessionId == null) return null;

    final activeAccount = AccountManager.instance.activeAccount;
    if (activeAccount == null) return null;

    final String url = "${activeAccount.serverUrl}/api/customers/coordinates";

    try {
      final response = await _dio.get(
        url,
        options: Options(
          headers: {
            "Content-Type": "application/json",
            "Cookie": "session_id=$sessionId"
          },
        ),
      );

      if (response.statusCode == 200) {
        return response.data as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      log("Error fetching customers: $e");
      return null;
    }
  }

  Future<Map<String, dynamic>?> markAttendance({
    required double latitude,
    required double longitude,
    required String action, // "check_in" or "check_out"
  }) async {
    final sessionId = await _getSessionId();
    if (sessionId == null) return null;

    final activeAccount = AccountManager.instance.activeAccount;
    if (activeAccount == null) return null;

    final String url = "${activeAccount.serverUrl}/api/mobile/attendance/mark/";
    final data = {
      "jsonrpc": "2.0",
      "params": {
        "latitude": latitude,
        "longitude": longitude,
        "action": action
      }
    };

    try {
      final response = await _dio.post(
        url,
        data: data,
        options: Options(
          headers: {
            "Content-Type": "application/json",
            "Cookie": "session_id=$sessionId"
          },
        ),
      );

      if (response.statusCode == 200) {
        log("✅ Attendance Response: ${response.data}");
        final result = response.data as Map<String, dynamic>;
        // Normalise: if status == 'failed', surface result.message
        // as result.error so callers use a single error-message key.
        final inner = result['result'];
        if (inner is Map && inner['status'] == 'failed' && inner['error'] == null) {
          inner['error'] = inner['message'];
        }
        return result;
      } else {
        log("❌ Attendance Failed: HTTP ${response.statusCode} - ${response.data}");
      }
      return null;
    } catch (e) {
      if (e is DioException) {
        log("❌ Dio Error marking attendance: ${e.response?.statusCode} - ${e.response?.data}");
      } else {
        log("❌ Error marking attendance: $e");
      }
      return null;
    }
  }

  Future<Map<String, dynamic>?> markReached({
    required int stopId,
    required double driverLat,
    required double driverLng,
  }) async {
    final sessionId = await _getSessionId();
    if (sessionId == null) return null;

    final activeAccount = AccountManager.instance.activeAccount;
    if (activeAccount == null) return null;

    final String url = "${activeAccount.serverUrl}/api/route/mark_reached";
    final data = {
      "jsonrpc": "2.0",
      "params": {
        "stop_id": stopId,
        "driver_lat": driverLat,
        "driver_lng": driverLng
      }
    };

    try {
      final response = await _dio.post(
        url,
        data: data,
        options: Options(
          headers: {
            "Content-Type": "application/json",
            "Cookie": "session_id=$sessionId"
          },
        ),
      );

      if (response.statusCode == 200) {
        return response.data as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      log("Error marking reached: $e");
      return null;
    }
  }

  Future<Map<String, dynamic>?> fetchAttendanceHistory() async {
    final sessionId = await _getSessionId();
    if (sessionId == null) return null;

    final activeAccount = AccountManager.instance.activeAccount;
    if (activeAccount == null) return null;

    final String url = "${activeAccount.serverUrl}/api/mobile/attendance/history";

    try {
      final response = await _dio.get(
        url,
        options: Options(
          headers: {
            "Content-Type": "application/json",
            "Cookie": "session_id=$sessionId"
          },
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        if (response.data is Map<String, dynamic>) {
          return response.data as Map<String, dynamic>;
        }
      }
      return null;
    } catch (e) {
      log("Error fetching attendance history: $e");
      return null;
    }
  }
}

