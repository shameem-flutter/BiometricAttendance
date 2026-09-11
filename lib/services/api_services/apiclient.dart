import 'dart:developer';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode;
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:odoo_mobile/main.dart';
import 'package:odoo_mobile/services/account_manager.dart';

class ApiClient {
  static final CookieJar cookieJar = CookieJar();
  static final Dio dio = _createDio();

  static Dio _createDio() {
    final dioInstance = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 10),
      ),
    );
    // CookieManager is not supported on web — the browser handles cookies natively.
    if (!kIsWeb) {
      dioInstance.interceptors.add(CookieManager(cookieJar));
    }
    // Inject ngrok header in debug mode so ngrok does not intercept
    // mobile requests with its HTML browser-warning landing page during development.
    if (kDebugMode) {
      dioInstance.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            options.headers['ngrok-skip-browser-warning'] = 'true';
            handler.next(options);
          },
        ),
      );
    }
    dioInstance.interceptors.add(SessionInterceptor(dioInstance));
    return dioInstance;
  }

  static void updateBaseUrl(String newUrl) {
    dio.options.baseUrl = newUrl;
  }

  static Future<void> clearAllCookies() async {
    if (!kIsWeb) await cookieJar.deleteAll();
  }

  static Future<void> clearCookiesForUrl(String url) async {
    if (kIsWeb) return;
    final uri = Uri.parse(url);
    await cookieJar.delete(uri);
  }
}

class SessionInterceptor extends QueuedInterceptorsWrapper {
  final Dio _dio;
  SessionInterceptor(this._dio);

  @override
  Future<void> onResponse(
    Response response,
    ResponseInterceptorHandler handler,
  ) async {
    bool isExpired = false;

    // Check for Odoo session expired error
    if (response.statusCode == 200 &&
        response.data != null &&
        response.data is Map) {
      final data = response.data as Map;
      if (data['error'] != null && data['error'] is Map) {
        final error = data['error'] as Map;
        final message = error['message'];
        final dataName = error['data']?['name'];
        if (message == 'Odoo Session Expired' ||
            message == 'Session expired' ||
            dataName == 'odoo.http.SessionExpiredException') {
          isExpired = true;
        }
      }
    }

    if (isExpired) {
      log("SessionInterceptor: Detected Expired Session for request: ${response.requestOptions.path}");
      final account = AccountManager.instance.activeAccount;
      if (account == null) {
        log("SessionInterceptor: No active account found. Proceeding with expired response.");
        return handler.next(response);
      }

      // Prevent infinite loops by checking extra map
      if (response.requestOptions.extra['isRetry'] == true) {
        log("SessionInterceptor: Request already retried. Forcing logout to prevent infinite loop.");
        _forceLogoutAndRedirect(account.id);
        return handler.next(response);
      }

      final password = await AccountManager.instance.getPassword(account.id);
      if (password == null || password.isEmpty) {
        log("SessionInterceptor: No password stored for account. Forcing logout.");
        _forceLogoutAndRedirect(account.id);
        return handler.next(response);
      }

      log("SessionInterceptor: Pausing other requests and initiating background re-authentication...");
      // Perform re-authentication using a temporary Dio instance to avoid blocking
      final tempDio = Dio(BaseOptions(baseUrl: account.serverUrl));
      try {
        final String loginUrl = "${account.serverUrl}/web/session/authenticate";
        final loginData = {
          "jsonrpc": "2.0",
          "params": {
            "db": account.database,
            "login": account.username,
            "password": password
          },
        };

        final loginResponse = await tempDio.post(
          loginUrl,
          data: loginData,
          options: Options(headers: {"Content-Type": "application/json"}),
        );

        if (loginResponse.statusCode == 200 &&
            loginResponse.data["result"] != null) {
          var sessionId = loginResponse.data['result']['session_id'];
          if (sessionId == null) {
            final setCookie = loginResponse.headers['set-cookie'];
            if (setCookie != null) {
              for (var cookie in setCookie) {
                if (cookie.startsWith('session_id=')) {
                  sessionId =
                      cookie.split(';')[0].substring('session_id='.length);
                  break;
                }
              }
            }
          }

          if (sessionId != null) {
            log("SessionInterceptor: Background re-authentication successful! New session ID obtained.");
            final resResult = loginResponse.data['result'];
            final bool? isRouteInstalled = resResult is Map && resResult['is_route_management_installed'] != null
                ? resResult['is_route_management_installed'] == true
                : null;
            final String? accessToken = resResult is Map ? resResult['access_token']?.toString() : null;
            final bool? requireFace = resResult is Map ? resResult['require_face_recognition'] as bool? : null;
            final bool? faceReg = resResult is Map ? resResult['face_registered'] as bool? : null;
            final String? faceEmb = resResult is Map ? resResult['face_embedding_data']?.toString() : null;

            // Save new session and token
            await AccountManager.instance.addOrUpdateAccount(
              serverUrl: account.serverUrl,
              database: account.database,
              username: account.username,
              sessionId: sessionId,
              accessToken: accessToken,
              password: password,
              employeeId: account.employeeId,
              employeeName: account.employeeName,
              isRouteManagementInstalled: isRouteInstalled ?? account.isRouteManagementInstalled,
              requireFaceRecognition: requireFace ?? account.requireFaceRecognition,
              faceRegistered: faceReg ?? account.faceRegistered,
              faceEmbeddingData: faceEmb ?? account.faceEmbeddingData,
            );

            // Update ApiClient cookie jar globally (no-op on web; browser manages cookies).
            if (!kIsWeb) {
              final uri = Uri.parse(account.serverUrl);
              await ApiClient.cookieJar
                  .saveFromResponse(uri, [Cookie("session_id", sessionId)]);
            }

            log("SessionInterceptor: Retrying original request transparently: ${response.requestOptions.path}");
            // Retry original request
            final options = response.requestOptions;
            options.extra['isRetry'] = true;
            options.headers['Cookie'] =
                'session_id=$sessionId'; // Force cookie override

            final retryResponse = await _dio.fetch(options);
            log("SessionInterceptor: Original request successfully retried and data fetched.");
            return handler.resolve(retryResponse);
          }
        }
      } catch (e) {
        log("SessionInterceptor: Background login failed with error: $e");
        // Fallthrough to force logout
      }

      log("SessionInterceptor: Re-authentication failed (e.g. invalid password). Forcing logout.");
      _forceLogoutAndRedirect(account.id);
      return handler
          .next(response); // Return original expired response if it fails
    }

    return handler.next(response);
  }

  void _forceLogoutAndRedirect(String accountId) {
    if (navigatorKey.currentContext != null) {
      AccountManager.instance
          .forceSessionLogout(accountId, navigatorKey.currentContext!);
    }
  }

  @override
  Future<void> onError(
      DioException err, ErrorInterceptorHandler handler) async {
    if (err.response?.statusCode == 401) {
      log("SessionInterceptor: Detected 401 Unauthorized for request: ${err.requestOptions.path}");
      final account = AccountManager.instance.activeAccount;
      if (account == null) {
        log("SessionInterceptor: No active account found for 401. Proceeding with error.");
        return handler.next(err);
      }

      if (err.requestOptions.extra['isRetry'] == true) {
        log("SessionInterceptor: Request already retried (401). Forcing logout to prevent infinite loop.");
        _forceLogoutAndRedirect(account.id);
        return handler.next(err);
      }

      final password = await AccountManager.instance.getPassword(account.id);
      if (password == null || password.isEmpty) {
        log("SessionInterceptor: No password stored for account (401). Forcing logout.");
        _forceLogoutAndRedirect(account.id);
        return handler.next(err);
      }

      log("SessionInterceptor: Pausing requests and initiating background re-authentication (401)...");
      final tempDio = Dio(BaseOptions(baseUrl: account.serverUrl));
      try {
        final String loginUrl = "${account.serverUrl}/web/session/authenticate";
        final loginData = {
          "jsonrpc": "2.0",
          "params": {
            "db": account.database,
            "login": account.username,
            "password": password
          },
        };

        final loginResponse = await tempDio.post(
          loginUrl,
          data: loginData,
          options: Options(headers: {"Content-Type": "application/json"}),
        );

        if (loginResponse.statusCode == 200 &&
            loginResponse.data["result"] != null) {
          var sessionId = loginResponse.data['result']['session_id'];
          if (sessionId == null) {
            final setCookie = loginResponse.headers['set-cookie'];
            if (setCookie != null) {
              for (var cookie in setCookie) {
                if (cookie.startsWith('session_id=')) {
                  sessionId =
                      cookie.split(';')[0].substring('session_id='.length);
                  break;
                }
              }
            }
          }

          if (sessionId != null) {
            log("SessionInterceptor: Background re-authentication successful! (401)");
            final resResult = loginResponse.data['result'];
            final bool? isRouteInstalled = resResult is Map && resResult['is_route_management_installed'] != null
                ? resResult['is_route_management_installed'] == true
                : null;
            final String? accessToken = resResult is Map ? resResult['access_token']?.toString() : null;
            final bool? requireFace = resResult is Map ? resResult['require_face_recognition'] as bool? : null;
            final bool? faceReg = resResult is Map ? resResult['face_registered'] as bool? : null;
            final String? faceEmb = resResult is Map ? resResult['face_embedding_data']?.toString() : null;

            await AccountManager.instance.addOrUpdateAccount(
              serverUrl: account.serverUrl,
              database: account.database,
              username: account.username,
              sessionId: sessionId,
              accessToken: accessToken,
              password: password,
              employeeId: account.employeeId,
              employeeName: account.employeeName,
              isRouteManagementInstalled: isRouteInstalled ?? account.isRouteManagementInstalled,
              requireFaceRecognition: requireFace ?? account.requireFaceRecognition,
              faceRegistered: faceReg ?? account.faceRegistered,
              faceEmbeddingData: faceEmb ?? account.faceEmbeddingData,
            );

            if (!kIsWeb) {
              final uri = Uri.parse(account.serverUrl);
              await ApiClient.cookieJar
                  .saveFromResponse(uri, [Cookie("session_id", sessionId)]);
            }

            log("SessionInterceptor: Retrying original request transparently (401): ${err.requestOptions.path}");
            final options = err.requestOptions;
            options.extra['isRetry'] = true;
            options.headers['Cookie'] = 'session_id=$sessionId';

            final retryResponse = await _dio.fetch(options);
            log("SessionInterceptor: Original request successfully retried and data fetched (401).");
            return handler.resolve(retryResponse);
          }
        }
      } catch (e) {
        log("SessionInterceptor: Background login failed with error (401): $e");
      }
      log("SessionInterceptor: Re-authentication failed (401). Forcing logout.");
      _forceLogoutAndRedirect(account.id);
    }
    return handler.next(err);
  }
}
