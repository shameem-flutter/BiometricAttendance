import 'dart:developer';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:odoo_mobile/constants/api_endpoint.dart';
import 'package:odoo_mobile/models/login_result.dart';
import 'package:odoo_mobile/services/api_services/apiclient.dart';

class Authservice {
  final Dio _dio = ApiClient.dio;

  Authservice();

  /// Authenticates with Odoo and returns a typed LoginResult with session, employee, and face lock configuration
  Future<LoginResult> login({
    required String baseUrl,
    required String db,
    required String username,
    required String password,
  }) async {
    final cleanUrl = ApiEndpoints.normalizeUrl(baseUrl);
    final String url = "$cleanUrl/web/session/authenticate";
    final data = {
      "jsonrpc": "2.0",
      "params": {"db": db, "login": username, "password": password},
    };

    try {
      final response = await _dio.post(
        url,
        data: data,
        options: Options(
          headers: {"Content-Type": "application/json"},
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );

      if (response.statusCode == 200 && response.data != null && response.data is Map) {
        final mapData = response.data as Map<String, dynamic>;

        if (mapData["error"] != null) {
          final errorMsg = mapData['error']['message'] ?? "Server returned error";
          log("Server returned an error: $errorMsg");
          return LoginResult.failed(message: errorMsg.toString());
        }

        if (mapData["result"] != null) {
          final result = mapData['result'];
          
          if (result is Map<String, dynamic>) {
            final uid = result['uid'];
            // In Odoo, failed auth returns uid == false or null
            if (uid == null || uid == false) {
              log("Odoo authentication failed: uid is false or null.");
              return LoginResult.failed(message: "Invalid credentials");
            }

            log("Login successful. Extracting session ID, employee info, and face recognition configuration.");

            var sessionId = result['session_id']?.toString();
            var accessToken = result['access_token']?.toString();
            int? employeeId;
            String? employeeName;
            bool isRouteManagementInstalled = false;

            // Extract Face Recognition fields (Odoo 19)
            bool? requireFaceRecognition;
            if (result['require_face_recognition'] != null) {
              if (result['require_face_recognition'] is bool) {
                requireFaceRecognition = result['require_face_recognition'] as bool;
              } else if (result['require_face_recognition'].toString().toLowerCase() == 'true') {
                requireFaceRecognition = true;
              } else if (result['require_face_recognition'].toString().toLowerCase() == 'false') {
                requireFaceRecognition = false;
              }
            }

            bool? faceRegistered;
            if (result['face_registered'] != null) {
              if (result['face_registered'] is bool) {
                faceRegistered = result['face_registered'] as bool;
              } else if (result['face_registered'].toString().toLowerCase() == 'true') {
                faceRegistered = true;
              } else if (result['face_registered'].toString().toLowerCase() == 'false') {
                faceRegistered = false;
              }
            }

            String? faceEmbeddingData;
            if (result['face_embedding_data'] != null) {
              final raw = result['face_embedding_data'].toString().trim();
              if (raw.isNotEmpty && raw != 'false' && raw != 'null') {
                faceEmbeddingData = raw;
              }
            }

            if (result['is_route_management_installed'] != null) {
              if (result['is_route_management_installed'] is bool) {
                isRouteManagementInstalled = result['is_route_management_installed'] as bool;
              } else if (result['is_route_management_installed'].toString().toLowerCase() == 'true') {
                isRouteManagementInstalled = true;
              }
            }

            if (result['employee_id'] != null) {
              if (result['employee_id'] is int) {
                employeeId = result['employee_id'] as int;
              } else if (result['employee_id'] is List && (result['employee_id'] as List).isNotEmpty) {
                employeeId = result['employee_id'][0] as int?;
                if ((result['employee_id'] as List).length > 1) {
                  employeeName = result['employee_id'][1]?.toString();
                }
              }
            }
            if (employeeName == null && result['employee_name'] != null) {
              employeeName = result['employee_name']?.toString();
            }
            if (employeeName == null && result['name'] != null) {
              employeeName = result['name']?.toString();
            }

            // Extract session_id from response set-cookie header if missing in result JSON
            if (sessionId == null || sessionId.isEmpty) {
              final setCookie = response.headers['set-cookie'];
              if (setCookie != null) {
                for (var cookieStr in setCookie) {
                  if (cookieStr.contains('session_id=')) {
                    final match = RegExp(r'session_id=([^;]+)').firstMatch(cookieStr);
                    if (match != null) {
                      sessionId = match.group(1);
                      break;
                    }
                  }
                }
              }
            }

            // If still missing, check CookieJar
            if (sessionId == null || sessionId.isEmpty) {
              final cookies = await ApiClient.cookieJar.loadForRequest(
                Uri.parse(cleanUrl),
              );
              final sessionCookie = cookies.firstWhere(
                (cookie) => cookie.name == "session_id",
                orElse: () => Cookie("session_id", ""),
              );
              if (sessionCookie.value.isNotEmpty) {
                sessionId = sessionCookie.value;
                log("Extracted session_id from CookieJar: $sessionId");
              }
            }

            if (sessionId != null && sessionId.isNotEmpty) {
              // Save cookie to ApiClient.cookieJar immediately
              await ApiClient.cookieJar.saveFromResponse(
                Uri.parse(cleanUrl),
                [Cookie("session_id", sessionId)],
              );
              return LoginResult(
                isSuccess: true,
                sessionId: sessionId,
                accessToken: accessToken ?? sessionId,
                employeeId: employeeId,
                employeeName: employeeName,
                isRouteManagementInstalled: isRouteManagementInstalled,
                requireFaceRecognition: requireFaceRecognition,
                faceRegistered: faceRegistered,
                faceEmbeddingData: faceEmbeddingData,
              );
            } else {
              log("⚠️ No session_id found in JSON, headers, or cookies.");
              return LoginResult.failed(message: "No session ID returned");
            }
          }
        }
      }

      return LoginResult.failed(message: "Authentication failed");
    } catch (e) {
      log("Login failed with an exception: $e");
      return LoginResult.failed(message: e.toString());
    }
  }

  /// Validates a session by hitting an authenticated endpoint
  Future<bool> validateSession({
    required String serverUrl,
    required String sessionId,
  }) async {
    try {
      final cleanUrl = ApiEndpoints.normalizeUrl(serverUrl);
      final String url = "$cleanUrl/web/session/get_session_info";
      // We must pass the session_id as a cookie
      final response = await _dio.post(
        url,
        data: {"jsonrpc": "2.0", "params": {}},
        options: Options(
          headers: {
            "Content-Type": "application/json",
            "Cookie": "session_id=$sessionId"
          },
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );

      if (response.statusCode == 200 && response.data != null && response.data["result"] != null) {
        // If the result contains a uid, the session is valid.
        final uid = response.data["result"]["uid"];
        if (uid != null && uid != false) {
          return true;
        }
      }
      return false;
    } catch (e) {
      log("Session validation failed: $e");
      return false;
    }
  }

  /// Destroys a specific session on the server
  Future<void> logOut({
    required String serverUrl,
    required String sessionId,
  }) async {
    final cleanUrl = ApiEndpoints.normalizeUrl(serverUrl);
    const String endpoint = "/web/session/destroy";
    try {
      await _dio.post(
        "$cleanUrl$endpoint",
        data: {"jsonrpc": "2.0", "params": {}},
        options: Options(
          headers: {
            "Content-Type": "application/json",
            "Cookie": "session_id=$sessionId"
          },
          sendTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 3),
        ),
      );
      log("Odoo logout successful for $cleanUrl");
    } catch (e) {
      log("Odoo logout failed: $e");
    }
  }
}
