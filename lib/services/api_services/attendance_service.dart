import 'dart:developer';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:odoo_mobile/models/face_index_model.dart';
import 'package:odoo_mobile/services/account_manager.dart';
import 'package:odoo_mobile/services/api_services/apiclient.dart';

class AttendanceService {
  final Dio _dio = ApiClient.dio;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  Future<String?> _getAccessToken() async {
    final activeAccount = AccountManager.instance.activeAccount;
    if (activeAccount == null) return null;
    return await AccountManager.instance.getAccessToken(activeAccount.id);
  }

  Future<Map<String, String>> _getAuthHeaders() async {
    final headers = <String, String>{
      "Content-Type": "application/json",
    };
    final activeAccount = AccountManager.instance.activeAccount;
    if (activeAccount != null) {
      final token = await AccountManager.instance.getAccessToken(activeAccount.id);
      if (token != null && token.isNotEmpty) {
        headers["Authorization"] = "Bearer $token";
      }
      final sessionId = await _secureStorage.read(key: 'session_${activeAccount.id}');
      if (sessionId != null && sessionId.isNotEmpty) {
        headers["Cookie"] = "session_id=$sessionId";
      }
    }
    return headers;
  }

  /// Synchronizes the registered face index from Odoo (GET /api/mobile/face/get_index)
  Future<FaceIndexResponse?> getFaceIndex() async {
    final activeAccount = AccountManager.instance.activeAccount;
    if (activeAccount == null) return null;

    final String url = "${activeAccount.serverUrl}/api/mobile/face/get_index";
    final headers = await _getAuthHeaders();

    try {
      final response = await _dio.get(
        url,
        options: Options(
          headers: headers,
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        if (response.data is Map<String, dynamic>) {
          final data = response.data as Map<String, dynamic>;
          final parsed = FaceIndexResponse.fromJson(data);
          log("👤 [AttendanceService] Face index fetched: status=${parsed.status}, face_registered=${parsed.faceRegistered}");
          return parsed;
        }
      }
      log("⚠️ [AttendanceService] getFaceIndex returned HTTP ${response.statusCode}");
      return null;
    } catch (e) {
      log("❌ [AttendanceService] Exception in getFaceIndex: $e");
      return null;
    }
  }

  /// Registers a new face index on Odoo backend (POST /api/mobile/face/register)
  Future<FaceIndexResponse?> registerFace({
    required String faceEmbeddingData,
    required String faceImage,
  }) async {
    final activeAccount = AccountManager.instance.activeAccount;
    if (activeAccount == null) return null;

    final token = await _getAccessToken();
    final String url = "${activeAccount.serverUrl}/api/mobile/face/register";
    final headers = await _getAuthHeaders();

    final data = {
      "jsonrpc": "2.0",
      "params": {
        "access_token": token ?? "",
        "face_embedding_data": faceEmbeddingData,
        "face_image": faceImage,
      }
    };

    try {
      log("👤 [AttendanceService] Registering face index on backend...");
      final response = await _dio.post(
        url,
        data: data,
        options: Options(
          headers: headers,
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 20),
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        if (response.data is Map<String, dynamic>) {
          final dataMap = response.data as Map<String, dynamic>;
          final parsed = FaceIndexResponse.fromJson(dataMap);
          log("✅ [AttendanceService] Face registration response: ${parsed.status}, message: ${parsed.message}");
          return parsed;
        }
      }
      log("❌ [AttendanceService] registerFace failed: HTTP ${response.statusCode}");
      return null;
    } catch (e) {
      log("❌ [AttendanceService] Exception in registerFace: $e");
      return null;
    }
  }

  Future<Map<String, dynamic>?> fetchCustomers() async {
    final activeAccount = AccountManager.instance.activeAccount;
    if (activeAccount == null) return null;

    final String url = "${activeAccount.serverUrl}/api/customers/coordinates";
    final headers = await _getAuthHeaders();

    try {
      final response = await _dio.get(
        url,
        options: Options(headers: headers),
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
    bool? faceVerified,
    double? similarityScore,
    String? devicePlatform,
  }) async {
    final activeAccount = AccountManager.instance.activeAccount;
    if (activeAccount == null) return null;

    final token = await _getAccessToken();
    final String url = "${activeAccount.serverUrl}/api/mobile/attendance/mark";
    final headers = await _getAuthHeaders();

    final params = <String, dynamic>{
      "access_token": token ?? "",
      "latitude": latitude,
      "longitude": longitude,
      "action": action,
      "device_platform": devicePlatform ?? (Platform.isIOS ? "ios" : "android"),
    };

    if (faceVerified != null) {
      params["face_verified"] = faceVerified;
    }
    if (similarityScore != null) {
      params["similarity_score"] = double.parse(similarityScore.toStringAsFixed(4));
    }

    final data = {
      "jsonrpc": "2.0",
      "params": params,
    };

    try {
      final response = await _dio.post(
        url,
        data: data,
        options: Options(headers: headers),
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
    final activeAccount = AccountManager.instance.activeAccount;
    if (activeAccount == null) return null;

    final token = await _getAccessToken();
    final String url = "${activeAccount.serverUrl}/api/route/mark_reached";
    final headers = await _getAuthHeaders();

    final data = {
      "jsonrpc": "2.0",
      "params": {
        "access_token": token ?? "",
        "stop_id": stopId,
        "driver_lat": driverLat,
        "driver_lng": driverLng,
      }
    };

    try {
      final response = await _dio.post(
        url,
        data: data,
        options: Options(headers: headers),
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
    final activeAccount = AccountManager.instance.activeAccount;
    if (activeAccount == null) return null;

    final String url = "${activeAccount.serverUrl}/api/mobile/attendance/history";
    final headers = await _getAuthHeaders();

    try {
      final response = await _dio.get(
        url,
        options: Options(headers: headers),
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

