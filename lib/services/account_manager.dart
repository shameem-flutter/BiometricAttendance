import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:odoo_mobile/constants/api_endpoint.dart';
import 'package:odoo_mobile/models/account_model.dart';
import 'package:odoo_mobile/services/api_services/apiclient.dart';
import 'package:odoo_mobile/services/api_services/authservice.dart';
import 'package:odoo_mobile/services/gps_tracking_service.dart';

class AccountManager extends ChangeNotifier {
  static final AccountManager instance = AccountManager._internal();
  AccountManager._internal();

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final Authservice _authService = Authservice();

  List<Account> _accounts = [];
  String? _activeAccountId;
  bool _isLoading = false;

  List<Account> get accounts => List.unmodifiable(_accounts);
  Account? get activeAccount => _accounts.where((a) => a.id == _activeAccountId).firstOrNull;
  bool get isLoading => _isLoading;

  void _setLoading(bool value) {
    _isLoading = value;
    notifyListeners();
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    
    // 1. Migration from legacy single-account setup
    final legacyUrl = prefs.getString("server_url");
    final legacySession = prefs.getString("session_id");
    
    if (legacyUrl != null && legacySession != null) {
      log("AccountManager: Legacy session found. Migrating to Multi-Account structure...");
      final legacyDb = prefs.getString("db_name") ?? prefs.getString("db") ?? "odoo";
      final legacyUsername = prefs.getString("username") ?? "Migrated User";
      final cleanLegacyUrl = ApiEndpoints.normalizeUrl(legacyUrl);
      
      final migratedAccount = Account.create(
        serverUrl: cleanLegacyUrl,
        database: legacyDb,
        username: legacyUsername,
      );

      _accounts.add(migratedAccount);
      _activeAccountId = migratedAccount.id;
      
      await _secureStorage.write(key: 'session_${migratedAccount.id}', value: legacySession);
      await _saveAccountsToPrefs();
      
      // Remove legacy keys
      await prefs.remove("server_url");
      await prefs.remove("session_id");
      await prefs.remove("db_name");
      await prefs.remove("db");
      await prefs.remove("erp_url");
      log("AccountManager: Migration completed successfully.");
    } else {
      // Normal load
      final accountsJson = prefs.getString("accounts_list");
      if (accountsJson != null) {
        final List<dynamic> decoded = jsonDecode(accountsJson);
        _accounts = decoded.map((e) => Account.fromJson(e as Map<String, dynamic>)).toList();
      }
      _activeAccountId = prefs.getString("active_account_id");
    }
  }

  Future<void> _saveAccountsToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final accountsJson = jsonEncode(_accounts.map((a) => a.toJson()).toList());
    await prefs.setString("accounts_list", accountsJson);
    
    if (_activeAccountId != null) {
      await prefs.setString("active_account_id", _activeAccountId!);
    } else {
      await prefs.remove("active_account_id");
    }
    notifyListeners();
  }

  Future<void> addOrUpdateAccount({
    required String serverUrl,
    required String database,
    required String username,
    required String sessionId,
    String? password,
    int? employeeId,
    String? employeeName,
    bool? isRouteManagementInstalled,
  }) async {
    final cleanUrl = ApiEndpoints.normalizeUrl(serverUrl);
    final id = Account.generateId(serverUrl: cleanUrl, database: database, username: username);
    
    final existingIndex = _accounts.indexWhere((a) => a.id == id);
    if (existingIndex != -1) {
      log("AccountManager: Updating existing account: $username");
      _accounts[existingIndex] = _accounts[existingIndex].copyWith(
        serverUrl: cleanUrl,
        lastLogin: DateTime.now(),
        employeeId: employeeId ?? _accounts[existingIndex].employeeId,
        employeeName: employeeName ?? _accounts[existingIndex].employeeName,
        isRouteManagementInstalled: isRouteManagementInstalled ?? _accounts[existingIndex].isRouteManagementInstalled,
      );
    } else {
      log("AccountManager: Adding new account: $username");
      final newAccount = Account(
        id: id,
        serverUrl: cleanUrl,
        database: database,
        username: username,
        lastLogin: DateTime.now(),
        employeeId: employeeId,
        employeeName: employeeName,
        isRouteManagementInstalled: isRouteManagementInstalled ?? false,
      );
      _accounts.add(newAccount);
    }

    await _secureStorage.write(key: 'session_$id', value: sessionId);
    if (password != null) {
      await _secureStorage.write(key: 'password_$id', value: password);
    }
    await _saveAccountsToPrefs();
  }

  /// Retrieves the password for a given account ID
  Future<String?> getPassword(String accountId) async {
    return await _secureStorage.read(key: 'password_$accountId');
  }

  /// Account Switching & Synchronization Flow
  Future<bool> switchAccount(
    String accountId, 
    BuildContext context, {
    bool force = false,
    bool skipValidation = false,
  }) async {
    final targetAccount = _accounts.where((a) => a.id == accountId).firstOrNull;
    if (targetAccount == null) return false;

    final cleanUrl = ApiEndpoints.normalizeUrl(targetAccount.serverUrl);

    if (!force && _activeAccountId == accountId) {
      // Ensure cookies and baseUrl are populated for current session
      final sessionId = await _secureStorage.read(key: 'session_${targetAccount.id}');
      if (sessionId != null && sessionId.isNotEmpty) {
        final uri = Uri.parse(cleanUrl);
        ApiClient.updateBaseUrl(cleanUrl);
        await ApiClient.cookieJar.saveFromResponse(
          uri,
          [io.Cookie("session_id", sessionId)],
        );
        await CookieManager.instance().setCookie(
          url: WebUri(cleanUrl),
          name: "session_id",
          value: sessionId,
          domain: uri.host,
          path: "/",
        );
      }
      return true;
    }

    final previousAccountId = _activeAccountId;

    try {
      _setLoading(true);

      // Stop current GPS tracking cleanly before switching accounts
      GpsTrackingService.instance.stopTrackingAndClear();

      // Clear cookies
      await CookieManager.instance().deleteAllCookies();
      await Future.delayed(const Duration(milliseconds: 50));
      await ApiClient.clearAllCookies();

      // Set active account
      _activeAccountId = accountId;
      await _saveAccountsToPrefs();

      // Update ApiClient URL
      ApiClient.updateBaseUrl(cleanUrl);

      // Read session ID
      final sessionId = await _secureStorage.read(key: 'session_${targetAccount.id}');
      if (sessionId == null || sessionId.isEmpty) {
        throw Exception("No session ID found for this account.");
      }

      final uri = Uri.parse(cleanUrl);

      // Save cookie to ApiClient Dio cookieJar
      await ApiClient.cookieJar.saveFromResponse(
        uri,
        [io.Cookie("session_id", sessionId)],
      );

      // Inject session cookie for InAppWebView
      await CookieManager.instance().setCookie(
        url: WebUri(cleanUrl),
        name: "session_id",
        value: sessionId,
        domain: uri.host,
        path: "/",
      );

      await CookieManager.instance().setCookie(
        url: WebUri(uri.origin),
        name: "session_id",
        value: sessionId,
        domain: uri.host,
        path: "/",
      );

      if (skipValidation) {
        _setLoading(false);
        unawaited(GpsTrackingService.instance.initialize());
        return true;
      }

      // Validate session
      final isValid = await _authService.validateSession(
        serverUrl: cleanUrl, 
        sessionId: sessionId,
      );

      _setLoading(false);

      if (isValid) {
        unawaited(GpsTrackingService.instance.initialize());
        return true; 
      } else {
        return false;
      }
    } catch (e) {
      log("AccountManager: Switch account failed: $e");
      _activeAccountId = previousAccountId;
      await _saveAccountsToPrefs();
      _setLoading(false);
      return false;
    }
  }
  Future<void> forceSessionLogout(String accountId, BuildContext context) async {
    final account = _accounts.where((a) => a.id == accountId).firstOrNull;
    if (account == null) return;

    _setLoading(true);

    if (_activeAccountId == accountId) {
      GpsTrackingService.instance.stopTrackingAndClear();
      await CookieManager.instance().deleteAllCookies();
      await ApiClient.clearAllCookies();
      _activeAccountId = null;
      await _saveAccountsToPrefs();
    }

    await _secureStorage.delete(key: 'session_${account.id}');
    await _secureStorage.delete(key: 'password_${account.id}');

    _setLoading(false);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Your session expired on the server. Please log in again."),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 4),
        ),
      );
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
    }
  }

  Future<void> removeAccount(String accountId, BuildContext context) async {
    final account = _accounts.where((a) => a.id == accountId).firstOrNull;
    if (account == null) return;

    _setLoading(true);

    if (_activeAccountId == accountId) {
      GpsTrackingService.instance.stopTrackingAndClear();
    }

    // Call backend logout endpoint (fire-and-forget attempt)
    final sessionId = await _secureStorage.read(key: 'session_${account.id}');
    if (sessionId != null) {
      try {
        await _authService
            .logOut(serverUrl: account.serverUrl, sessionId: sessionId)
            .timeout(const Duration(seconds: 3));
      } catch (e) {
        log("AccountManager: Backend logout request failed or timed out (server offline/crashed): $e");
      }
    }

    // Delete secure storage session, password, and face biometric template
    await _secureStorage.delete(key: 'session_${account.id}');
    await _secureStorage.delete(key: 'password_${account.id}');
    await _secureStorage.delete(key: 'face_embedding_${account.id}');

    // Remove from account list
    _accounts.removeWhere((a) => a.id == accountId);
    
    if (_activeAccountId == accountId) {
      // Clear cookies if active
      await CookieManager.instance().deleteAllCookies();
      await ApiClient.clearAllCookies();

      _activeAccountId = null;
      await _saveAccountsToPrefs();

      if (_accounts.isNotEmpty) {
        // Switch to next available
        final nextAccount = _accounts.first;
        _setLoading(false);
        if (context.mounted) {
          await switchAccount(nextAccount.id, context);
        }
      } else {
        // No accounts remain
        _setLoading(false);
        if (context.mounted) {
          Navigator.pushNamedAndRemoveUntil(context, "/login", (route) => false);
        }
      }
    } else {
      await _saveAccountsToPrefs();
      _setLoading(false);
    }
  }
}
