import 'dart:convert';
import 'package:crypto/crypto.dart';

class Account {
  final String id;
  final String serverUrl;
  final String database;
  final String username;
  final DateTime lastLogin;
  final int? employeeId;
  final String? employeeName;

  final bool isRouteManagementInstalled;
  final bool? requireFaceRecognition;
  final bool? faceRegistered;
  final String? faceEmbeddingData;

  Account({
    required this.id,
    required this.serverUrl,
    required this.database,
    required this.username,
    required this.lastLogin,
    this.employeeId,
    this.employeeName,
    this.isRouteManagementInstalled = false,
    this.requireFaceRecognition,
    this.faceRegistered,
    this.faceEmbeddingData,
  });

  /// Generates a unique, deterministic ID using SHA-256
  static String generateId({
    required String serverUrl,
    required String database,
    required String username,
  }) {
    final rawString = "$serverUrl|$database|$username";
    final bytes = utf8.encode(rawString);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Helper to create a new Account and generate its ID
  factory Account.create({
    required String serverUrl,
    required String database,
    required String username,
    DateTime? lastLogin,
    int? employeeId,
    String? employeeName,
    bool isRouteManagementInstalled = false,
    bool? requireFaceRecognition,
    bool? faceRegistered,
    String? faceEmbeddingData,
  }) {
    return Account(
      id: generateId(
        serverUrl: serverUrl,
        database: database,
        username: username,
      ),
      serverUrl: serverUrl,
      database: database,
      username: username,
      lastLogin: lastLogin ?? DateTime.now(),
      employeeId: employeeId,
      employeeName: employeeName,
      isRouteManagementInstalled: isRouteManagementInstalled,
      requireFaceRecognition: requireFaceRecognition,
      faceRegistered: faceRegistered,
      faceEmbeddingData: faceEmbeddingData,
    );
  }

  /// Extracts initials from the username for the Avatar
  String get initials {
    if (username.trim().isEmpty) return "?";
    
    final words = username.trim().split(RegExp(r'\s+'));
    if (words.length == 1) {
      return words.first[0].toUpperCase();
    }
    
    return "${words.first[0].toUpperCase()}${words.last[0].toUpperCase()}";
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'serverUrl': serverUrl,
      'database': database,
      'username': username,
      'lastLogin': lastLogin.toIso8601String(),
      'employeeId': employeeId,
      'employeeName': employeeName,
      'isRouteManagementInstalled': isRouteManagementInstalled,
      'requireFaceRecognition': requireFaceRecognition,
      'faceRegistered': faceRegistered,
      'faceEmbeddingData': faceEmbeddingData,
    };
  }

  factory Account.fromJson(Map<String, dynamic> json) {
    return Account(
      id: json['id'] as String,
      serverUrl: json['serverUrl'] as String,
      database: json['database'] as String,
      username: json['username'] as String,
      lastLogin: DateTime.parse(json['lastLogin'] as String),
      employeeId: json['employeeId'] as int?,
      employeeName: json['employeeName'] as String?,
      isRouteManagementInstalled: json['isRouteManagementInstalled'] as bool? ?? json['is_route_management_installed'] as bool? ?? false,
      requireFaceRecognition: json['requireFaceRecognition'] as bool? ?? json['require_face_recognition'] as bool?,
      faceRegistered: json['faceRegistered'] as bool? ?? json['face_registered'] as bool?,
      faceEmbeddingData: json['faceEmbeddingData']?.toString() ?? json['face_embedding_data']?.toString(),
    );
  }

  Account copyWith({
    String? id,
    String? serverUrl,
    String? database,
    String? username,
    DateTime? lastLogin,
    int? employeeId,
    String? employeeName,
    bool? isRouteManagementInstalled,
    bool? requireFaceRecognition,
    bool? faceRegistered,
    String? faceEmbeddingData,
  }) {
    return Account(
      id: id ?? this.id,
      serverUrl: serverUrl ?? this.serverUrl,
      database: database ?? this.database,
      username: username ?? this.username,
      lastLogin: lastLogin ?? this.lastLogin,
      employeeId: employeeId ?? this.employeeId,
      employeeName: employeeName ?? this.employeeName,
      isRouteManagementInstalled: isRouteManagementInstalled ?? this.isRouteManagementInstalled,
      requireFaceRecognition: requireFaceRecognition ?? this.requireFaceRecognition,
      faceRegistered: faceRegistered ?? this.faceRegistered,
      faceEmbeddingData: faceEmbeddingData ?? this.faceEmbeddingData,
    );
  }
}
