import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Renders a camera overlay with a central oval cutout, animated border,
/// and status-based visual feedback.
class FaceCameraOverlay extends StatefulWidget {
  final Color borderColor;
  final String instructionTitle;
  final String instructionSubtitle;
  final IconData instructionIcon;
  final double progress; // 0.0 to 1.0
  final bool isSuccess;
  final bool isError;
  final VoidCallback? onCancel;

  const FaceCameraOverlay({
    super.key,
    required this.borderColor,
    required this.instructionTitle,
    required this.instructionSubtitle,
    required this.instructionIcon,
    this.progress = 0.0,
    this.isSuccess = false,
    this.isError = false,
    this.onCancel,
  });

  @override
  State<FaceCameraOverlay> createState() => _FaceCameraOverlayState();
}

class _FaceCameraOverlayState extends State<FaceCameraOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.96, end: 1.04).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final ovalWidth = math.min(size.width * 0.85, 340.0);
    final ovalHeight = ovalWidth * 1.35;
    final centerOffset = Offset(size.width / 2, size.height * 0.38);
    final ovalRect = Rect.fromCenter(
      center: centerOffset,
      width: ovalWidth,
      height: ovalHeight,
    );

    return Stack(
      children: [
        // 1. Dark overlay with cutout
        CustomPaint(
          size: size,
          painter: _OvalOverlayPainter(
            cutoutRect: ovalRect,
            overlayColor: Colors.black.withAlpha(180),
          ),
        ),

        // 2. Animated Oval Border
        AnimatedBuilder(
          animation: _pulseAnimation,
          builder: (context, child) {
            final scale = widget.isSuccess || widget.isError ? 1.0 : _pulseAnimation.value;
            final scaledRect = Rect.fromCenter(
              center: centerOffset,
              width: ovalWidth * scale,
              height: ovalHeight * scale,
            );

            return CustomPaint(
              size: size,
              painter: _OvalBorderPainter(
                rect: scaledRect,
                color: widget.borderColor,
                progress: widget.progress,
              ),
            );
          },
        ),

        // 3. Close / Cancel Button at top-right
        Positioned(
          top: MediaQuery.of(context).padding.top + 12,
          right: 16,
          child: Material(
            color: Colors.black.withAlpha(100),
            shape: const CircleBorder(),
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 24),
              onPressed: widget.onCancel ?? () => Navigator.of(context).pop(),
            ),
          ),
        ),

        // 4. Instruction / Status Bottom Card
        Positioned(
          left: 20,
          right: 20,
          bottom: MediaQuery.of(context).padding.bottom + 24,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E2C).withAlpha(235),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: widget.borderColor.withAlpha(120),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(120),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: widget.borderColor.withAlpha(40),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        widget.instructionIcon,
                        color: widget.borderColor,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.instructionTitle,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.2,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.instructionSubtitle,
                            style: TextStyle(
                              color: Colors.white.withAlpha(200),
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                              height: 1.25,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (widget.progress > 0.0) ...[
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: widget.progress.clamp(0.0, 1.0),
                      backgroundColor: Colors.white.withAlpha(30),
                      valueColor: AlwaysStoppedAnimation<Color>(widget.borderColor),
                      minHeight: 5,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _OvalOverlayPainter extends CustomPainter {
  final Rect cutoutRect;
  final Color overlayColor;

  _OvalOverlayPainter({
    required this.cutoutRect,
    required this.overlayColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final backgroundPath = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final ovalPath = Path()..addOval(cutoutRect);
    final combinedPath = Path.combine(PathOperation.difference, backgroundPath, ovalPath);

    final paint = Paint()..color = overlayColor;
    canvas.drawPath(combinedPath, paint);
  }

  @override
  bool shouldRepaint(covariant _OvalOverlayPainter oldDelegate) {
    return oldDelegate.cutoutRect != cutoutRect || oldDelegate.overlayColor != overlayColor;
  }
}

class _OvalBorderPainter extends CustomPainter {
  final Rect rect;
  final Color color;
  final double progress;

  _OvalBorderPainter({
    required this.rect,
    required this.color,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final borderPaint = Paint()
      ..color = color.withAlpha(100)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    canvas.drawOval(rect, borderPaint);

    if (progress > 0.0) {
      final activePaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.0
        ..strokeCap = StrokeCap.round;

      final sweepAngle = 2 * math.pi * progress.clamp(0.0, 1.0);
      canvas.drawArc(rect, -math.pi / 2, sweepAngle, false, activePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _OvalBorderPainter oldDelegate) {
    return oldDelegate.rect != rect ||
        oldDelegate.color != color ||
        oldDelegate.progress != progress;
  }
}
