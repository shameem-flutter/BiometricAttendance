import 'dart:developer';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:odoo_mobile/models/gps_config_model.dart';
import 'package:odoo_mobile/services/account_manager.dart';
import 'package:odoo_mobile/services/api_services/apiclient.dart';

class GpsAuthException implements Exception {
  final String message;
  GpsAuthException(this.message);
  @override
  String toString() => "GpsAuthException: $message";
}

class GpsApiException implements Exception {
  final String message;
  GpsApiException(this.message);
  @override
  String toString() => "GpsApiException: $message";
}

class GpsApiService {
  final Dio _dio = ApiClient.dio;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  Future<String?> _getSessionId() async {
    final activeAccount = AccountManager.instance.activeAccount;
    if (activeAccount == null) return null;
    return await _secureStorage.read(key: 'session_${activeAccount.id}');
  }

  Future<String?> _getAccessToken() async {
    final activeAccount = AccountManager.instance.activeAccount;
    if (activeAccount == null) return null;
    return await AccountManager.instance.getAccessToken(activeAccount.id);
  }

  /// Fetches GPS tracking configuration from backend.
  /// Throws GpsAuthException if session is invalid or expired.
  Future<GpsConfig> fetchGpsConfig() async {
    final activeAccount = AccountManager.instance.activeAccount;
    if (activeAccount == null) {
      throw GpsAuthException("No active account session found.");
    }

    final sessionId = await _getSessionId();
    final token = await _getAccessToken();
    if ((sessionId == null || sessionId.isEmpty) && (token == null || token.isEmpty)) {
      throw GpsAuthException("No session or token found for active account.");
    }

    final String url = "${activeAccount.serverUrl}/api/mobile/gps/config";
    final headers = <String, String>{
      "Content-Type": "application/json",
    };
    if (token != null && token.isNotEmpty) {
      headers["Authorization"] = "Bearer $token";
    }
    if (sessionId != null && sessionId.isNotEmpty) {
      headers["Cookie"] = "session_id=$sessionId";
    }

    try {
      final response = await _dio.get(
        url,
        options: Options(
          headers: headers,
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw GpsAuthException("Session expired or unauthorized (HTTP ${response.statusCode})");
      }

      if (response.statusCode == 200 && response.data != null) {
        final data = response.data;
        if (data is Map<String, dynamic>) {
          if (data["error"] != null) {
            final errorMsg = data["error"]["message"] ?? "Unknown server error";
            if (errorMsg.toString().toLowerCase().contains("session") ||
                errorMsg.toString().toLowerCase().contains("login") ||
                errorMsg.toString().toLowerCase().contains("expired")) {
              throw GpsAuthException("Session expired: $errorMsg");
            }
            throw GpsApiException(errorMsg);
          }
          return GpsConfig.fromJson(data);
        }
      }

      throw GpsApiException("Invalid response status ${response.statusCode}");
    } on DioException catch (e) {
      if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
        throw GpsAuthException("Session expired (HTTP ${e.response?.statusCode})");
      }
      log("❌ [GPS] Dio error fetching config: $e");
      rethrow;
    } catch (e) {
      log("❌ [GPS] Error fetching config: $e");
      rethrow;
    }
  }

  /// Uploads current latitude and longitude to backend.
  /// Throws GpsAuthException if session is invalid or expired.
  Future<bool> uploadGpsLocation({
    required double latitude,
    required double longitude,
    required int employeeId,
  }) async {
    final activeAccount = AccountManager.instance.activeAccount;
    if (activeAccount == null) {
      throw GpsAuthException("No active account session found.");
    }

    final sessionId = await _getSessionId();
    final token = await _getAccessToken();
    if ((sessionId == null || sessionId.isEmpty) && (token == null || token.isEmpty)) {
      throw GpsAuthException("No session or token found for active account.");
    }

    final String url = "${activeAccount.serverUrl}/api/mobile/gps/update";
    final headers = <String, String>{
      "Content-Type": "application/json",
    };
    if (token != null && token.isNotEmpty) {
      headers["Authorization"] = "Bearer $token";
    }
    if (sessionId != null && sessionId.isNotEmpty) {
      headers["Cookie"] = "session_id=$sessionId";
    }

    final data = {
      "jsonrpc": "2.0",
      "params": {
        "access_token": token ?? "",
        "latitude": latitude,
        "longitude": longitude,
        "employee_id": employeeId,
      }
    };

    try {
      final response = await _dio.post(
        url,
        data: data,
        options: Options(
          headers: headers,
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw GpsAuthException("Session expired or unauthorized (HTTP ${response.statusCode})");
      }

      if (response.statusCode == 200 && response.data != null) {
        final respData = response.data;
        if (respData is Map<String, dynamic>) {
          if (respData["error"] != null) {
            final errorMsg = respData["error"]["message"] ?? "Server returned error";
            if (errorMsg.toString().toLowerCase().contains("session") ||
                errorMsg.toString().toLowerCase().contains("login") ||
                errorMsg.toString().toLowerCase().contains("expired")) {
              throw GpsAuthException("Session expired: $errorMsg");
            }
            log("⚠️ [GPS] Server returned error response: $errorMsg");
            return false;
          }
          return true;
        }
      }

      return false;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
        throw GpsAuthException("Session expired (HTTP ${e.response?.statusCode})");
      }
      log("❌ [GPS] Dio error uploading location: ${e.message}");
      return false;
    } catch (e) {
      if (e is GpsAuthException) rethrow;
      log("❌ [GPS] Exception uploading location: $e");
      return false;
    }
  }
}
