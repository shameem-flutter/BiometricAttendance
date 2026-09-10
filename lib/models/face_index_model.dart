import 'dart:convert';
import 'dart:developer';

/// Strongly typed response model for GET /api/mobile/face/get_index
/// and POST /api/mobile/face/register.
class FaceIndexResponse {
  final String status;
  final int code;
  final String? message;
  final int? employeeId;
  final String? employeeName;
  final bool? requireFaceRecognition;
  final bool? faceRegistered;
  final String? faceEmbeddingData;

  const FaceIndexResponse({
    required this.status,
    required this.code,
    this.message,
    this.employeeId,
    this.employeeName,
    this.requireFaceRecognition,
    this.faceRegistered,
    this.faceEmbeddingData,
  });

  bool get isSuccess => status.toLowerCase() == 'success' && (code == 200 || code == 0);

  /// Safely parses the raw `faceEmbeddingData` string (e.g. `"[0.123, -0.456, ...]"`)
  /// into a list of double values. Returns null if data is absent or malformed.
  List<double>? get parsedEmbedding {
    if (faceEmbeddingData == null) return null;
    final trimmed = faceEmbeddingData!.trim();
    if (trimmed.isEmpty || trimmed == 'false' || trimmed == 'null') return null;

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is List) {
        return decoded.map((e) => (e as num).toDouble()).toList();
      }
    } catch (e) {
      log('⚠️ [FaceIndexResponse] Failed to parse face embedding data: $e');
    }
    return null;
  }

  factory FaceIndexResponse.fromJson(Map<String, dynamic> json) {
    // Handle both JSON-RPC wrapped `result` and flat response formats
    final data = (json['result'] is Map<String, dynamic>)
        ? json['result'] as Map<String, dynamic>
        : json;

    int? parsedEmpId;
    if (data['employee_id'] != null) {
      if (data['employee_id'] is int) {
        parsedEmpId = data['employee_id'] as int;
      } else if (data['employee_id'] is List && (data['employee_id'] as List).isNotEmpty) {
        parsedEmpId = data['employee_id'][0] as int?;
      }
    }

    String? parsedEmpName;
    if (data['employee_name'] != null && data['employee_name'] is String) {
      parsedEmpName = data['employee_name'] as String;
    } else if (data['employee_id'] is List && (data['employee_id'] as List).length > 1) {
      parsedEmpName = data['employee_id'][1] as String?;
    }

    final rawCode = data['code'];
    final int code = rawCode is num ? rawCode.toInt() : (data['status'] == 'success' ? 200 : 400);

    return FaceIndexResponse(
      status: data['status']?.toString() ?? (code == 200 ? 'success' : 'error'),
      code: code,
      message: data['message']?.toString() ?? data['error']?.toString(),
      employeeId: parsedEmpId,
      employeeName: parsedEmpName,
      requireFaceRecognition: data['require_face_recognition'] as bool?,
      faceRegistered: data['face_registered'] as bool?,
      faceEmbeddingData: data['face_embedding_data']?.toString(),
    );
  }
}
