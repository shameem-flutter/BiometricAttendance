import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:odoo_mobile/services/gps_tracking_service.dart';

class GpsTrackingCard extends StatefulWidget {
  const GpsTrackingCard({super.key});

  @override
  State<GpsTrackingCard> createState() => _GpsTrackingCardState();
}

class _GpsTrackingCardState extends State<GpsTrackingCard> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: GpsTrackingService.instance,
      builder: (context, _) {
        final service = GpsTrackingService.instance;
        final status = service.trackingStatus;

        Color statusColor;
        Color statusBgColor;
        String statusText;
        IconData statusIcon;

        switch (status) {
          case GpsTrackingStatus.active:
            statusColor = const Color(0xFF059669); // Emerald
            statusBgColor = const Color(0xFFECFDF5);
            statusText = service.isUploading ? "Uploading..." : "Tracking Active";
            statusIcon = Icons.my_location_rounded;
            break;
          case GpsTrackingStatus.waitingForGps:
            statusColor = const Color(0xFFD97706); // Amber
            statusBgColor = const Color(0xFFFFFBEB);
            statusText = "Waiting for GPS";
            statusIcon = Icons.location_searching_rounded;
            break;
          case GpsTrackingStatus.permissionRequired:
            statusColor = const Color(0xFFDC2626); // Rose
            statusBgColor = const Color(0xFFFEF2F2);
            statusText = "Permission Required";
            statusIcon = Icons.location_off_rounded;
            break;
          case GpsTrackingStatus.sessionExpired:
            statusColor = const Color(0xFFDC2626);
            statusBgColor = const Color(0xFFFEF2F2);
            statusText = "Session Expired";
            statusIcon = Icons.error_outline_rounded;
            break;
          case GpsTrackingStatus.checkedOut:
            statusColor = const Color(0xFF6B7280); // Slate
            statusBgColor = const Color(0xFFF3F4F6);
            statusText = "Tracking Paused";
            statusIcon = Icons.location_disabled_rounded;
            break;
          case GpsTrackingStatus.disabled:
            statusColor = const Color(0xFF6B7280);
            statusBgColor = const Color(0xFFF3F4F6);
            statusText = "Tracking Disabled";
            statusIcon = Icons.location_disabled_rounded;
            break;
        }

        final lastSyncFormatted = service.lastSyncTime != null
            ? DateFormat('hh:mm:ss a').format(service.lastSyncTime!)
            : "Never";

        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Main Minimal Status Header
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: statusBgColor,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        statusIcon,
                        color: statusColor,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                "Live Location",
                                style: GoogleFonts.poppins(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: const Color(0xFF111827),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: statusBgColor,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color: statusColor.withValues(alpha: 0.3)),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        color: statusColor,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      statusText,
                                      style: GoogleFonts.poppins(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: statusColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            service.isUploading
                                ? "Uploading location..."
                                : "Last sync: $lastSyncFormatted",
                            style: GoogleFonts.poppins(
                              fontSize: 12,
                              color: const Color(0xFF6B7280),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // Action button if permission is required
              if (status == GpsTrackingStatus.permissionRequired) ...[
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16).copyWith(bottom: 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => service.requestPermissionFromUser(),
                      icon: const Icon(Icons.security_rounded,
                          size: 16, color: Color(0xFFDC2626)),
                      label: Text(
                        "Grant Location Permission",
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFFDC2626),
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: const Color(0xFFFEF2F2),
                        side: const BorderSide(color: Color(0xFFFCA5A5)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                ),
              ],

              // Compact info strip (Employee & Interval & Debug toggle)
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: const BoxDecoration(
                  color: Color(0xFFF9FAFB),
                  border: Border(
                    top: BorderSide(color: Color(0xFFF3F4F6)),
                  ),
                  borderRadius: BorderRadius.vertical(bottom: Radius.circular(20)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          const Icon(Icons.person_outline_rounded,
                              size: 14, color: Color(0xFF9CA3AF)),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              service.employeeName ?? "Not Authenticated",
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: const Color(0xFF4B5563),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Row(
                      children: [
                        const Icon(Icons.timer_outlined,
                            size: 14, color: Color(0xFF9CA3AF)),
                        const SizedBox(width: 4),
                        Text(
                          service.isEnabled
                              ? "${service.uploadInterval}s interval"
                              : "Disabled",
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: const Color(0xFF4B5563),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    InkWell(
                      onTap: () {
                        setState(() {
                          _isExpanded = !_isExpanded;
                        });
                      },
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 2),
                        child: Row(
                          children: [
                            Text(
                              "Debug",
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: const Color(0xFF6B7280),
                              ),
                            ),
                            Icon(
                              _isExpanded
                                  ? Icons.keyboard_arrow_up_rounded
                                  : Icons.keyboard_arrow_down_rounded,
                              size: 16,
                              color: const Color(0xFF6B7280),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Expandable Debug Panel Content
              AnimatedCrossFade(
                firstChild: const SizedBox.shrink(),
                secondChild: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: const BoxDecoration(
                    color: Color(0xFF1E293B),
                    borderRadius:
                        BorderRadius.vertical(bottom: Radius.circular(20)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "DIAGNOSTICS",
                        style: GoogleFonts.poppins(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF94A3B8),
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _buildDebugConsoleRow(
                          "Latitude",
                          service.currentLatitude?.toStringAsFixed(6) ?? "N/A"),
                      _buildDebugConsoleRow(
                          "Longitude",
                          service.currentLongitude?.toStringAsFixed(6) ?? "N/A"),
                      _buildDebugConsoleRow(
                          "Accuracy",
                          service.accuracy != null
                              ? "±${service.accuracy!.toStringAsFixed(1)} m"
                              : "N/A"),
                      _buildDebugConsoleRow(
                          "Permission", service.permissionStatus.name),
                      if (service.lastError != null)
                        _buildDebugConsoleRow("Last Error", service.lastError!,
                            isError: true),
                    ],
                  ),
                ),
                crossFadeState:
                    _isExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 250),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDebugConsoleRow(String label, String value,
      {bool isError = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: GoogleFonts.poppins(
              fontSize: 11,
              color: const Color(0xFF94A3B8),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: GoogleFonts.poppins(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color:
                    isError ? const Color(0xFFF87171) : const Color(0xFF38BDF8),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

