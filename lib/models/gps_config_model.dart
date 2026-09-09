class GpsConfig {
  final String status;
  final bool enableLiveGpsTracking;
  final int gpsRefreshInterval;
  final int? employeeId;
  final String? employeeName;

  GpsConfig({
    required this.status,
    required this.enableLiveGpsTracking,
    required this.gpsRefreshInterval,
    this.employeeId,
    this.employeeName,
  });

  factory GpsConfig.fromJson(Map<String, dynamic> json) {
    int? parsedEmpId;
    if (json['employee_id'] != null) {
      if (json['employee_id'] is int) {
        parsedEmpId = json['employee_id'] as int;
      } else if (json['employee_id'] is List && (json['employee_id'] as List).isNotEmpty) {
        parsedEmpId = json['employee_id'][0] as int?;
      }
    }

    String? parsedEmpName;
    if (json['employee_name'] != null && json['employee_name'] is String) {
      parsedEmpName = json['employee_name'] as String;
    } else if (json['employee_id'] is List && (json['employee_id'] as List).length > 1) {
      parsedEmpName = json['employee_id'][1] as String?;
    }

    return GpsConfig(
      status: json['status']?.toString() ?? 'success',
      enableLiveGpsTracking: json['enable_live_gps_tracking'] == true,
      gpsRefreshInterval: (json['gps_refresh_interval'] as num?)?.toInt() ?? 7,
      employeeId: parsedEmpId,
      employeeName: parsedEmpName,
    );
  }
}
