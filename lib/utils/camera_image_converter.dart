import 'dart:io';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;


/// An immutable, copied snapshot of a single image plane.
///
/// Deep-copies the underlying buffer immediately to ensure safe asynchronous
/// processing and avoid using recycled camera memory.
class PlaneSnapshot {
  final Uint8List bytes;
  final int bytesPerRow;
  final int? bytesPerPixel;

  PlaneSnapshot({
    required this.bytes,
    required this.bytesPerRow,
    this.bytesPerPixel,
  });

  factory PlaneSnapshot.fromPlane(Plane plane) {
    return PlaneSnapshot(
      bytes: Uint8List.fromList(plane.bytes),
      bytesPerRow: plane.bytesPerRow,
      bytesPerPixel: plane.bytesPerPixel,
    );
  }
}

/// An immutable snapshot of a [CameraImage] frame and its associated face metadata.
///
/// This structure decouples biometric processing from the live camera stream buffer lifecycle.
class FaceFrameSnapshot {
  final int width;
  final int height;
  final int format;
  final int sensorOrientation;
  final CameraLensDirection lensDirection;
  final List<PlaneSnapshot> planes;
  final Rect faceBoundingBox;
  final DateTime timestamp;

  FaceFrameSnapshot({
    required this.width,
    required this.height,
    required this.format,
    required this.sensorOrientation,
    required this.lensDirection,
    required this.planes,
    required this.faceBoundingBox,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Captures an immutable snapshot from an active [CameraImage].
  factory FaceFrameSnapshot.fromCameraImage({
    required CameraImage image,
    required CameraDescription camera,
    required Rect faceBoundingBox,
  }) {
    return FaceFrameSnapshot(
      width: image.width,
      height: image.height,
      format: image.format.raw,
      sensorOrientation: camera.sensorOrientation,
      lensDirection: camera.lensDirection,
      planes: image.planes.map((p) => PlaneSnapshot.fromPlane(p)).toList(growable: false),
      faceBoundingBox: faceBoundingBox,
    );
  }
}

/// Converts camera stream frames ([FaceFrameSnapshot]) into [img.Image] representations
/// suitable for MobileFaceNet preprocessing without disk I/O or JPEG round-trips.
class CameraImageConverter {
  /// Converts a [FaceFrameSnapshot] into an upright RGB [img.Image].
  ///
  /// The returned image is rotated according to [snapshot.sensorOrientation] so that
  /// its dimensions and pixel space exactly match [snapshot.faceBoundingBox].
  static img.Image? convertSnapshotToImage(FaceFrameSnapshot snapshot) {
    try {
      if (snapshot.planes.isEmpty) return null;

      final isBgra = Platform.isIOS || snapshot.planes.length == 1 && snapshot.planes[0].bytesPerPixel == 4;

      if (isBgra) {
        return _convertBgraToRgb(snapshot);
      } else {
        return _convertYuvToRgb(snapshot);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ [CameraImageConverter] Conversion error: $e');
      }
      return null;
    }
  }

  /// Converts iOS BGRA8888 plane snapshot to an upright RGB [img.Image].
  static img.Image _convertBgraToRgb(FaceFrameSnapshot snapshot) {
    final width = snapshot.width;
    final height = snapshot.height;
    final rotation = snapshot.sensorOrientation;
    final plane = snapshot.planes[0];
    final bytes = plane.bytes;
    final bytesPerRow = plane.bytesPerRow;

    final isRotated90or270 = rotation == 90 || rotation == 270;
    final outWidth = isRotated90or270 ? height : width;
    final outHeight = isRotated90or270 ? width : height;

    final rgbImage = img.Image(width: outWidth, height: outHeight);

    for (int y = 0; y < height; y++) {
      final rowStart = y * bytesPerRow;
      for (int x = 0; x < width; x++) {
        final pixelOffset = rowStart + (x * 4);
        if (pixelOffset + 3 >= bytes.length) break;

        final b = bytes[pixelOffset];
        final g = bytes[pixelOffset + 1];
        final r = bytes[pixelOffset + 2];

        // Map (x, y) to (outX, outY) based on sensor rotation
        final outX = _mapX(x, y, width, height, rotation);
        final outY = _mapY(x, y, width, height, rotation);

        rgbImage.setPixelRgb(outX, outY, r, g, b);
      }
    }

    return rgbImage;
  }

  /// Converts Android NV21 / YUV_420_888 plane snapshot to an upright RGB [img.Image].
  static img.Image _convertYuvToRgb(FaceFrameSnapshot snapshot) {
    final width = snapshot.width;
    final height = snapshot.height;
    final rotation = snapshot.sensorOrientation;

    final isRotated90or270 = rotation == 90 || rotation == 270;
    final outWidth = isRotated90or270 ? height : width;
    final outHeight = isRotated90or270 ? width : height;

    final rgbImage = img.Image(width: outWidth, height: outHeight);

    final numPlanes = snapshot.planes.length;
    final yPlane = snapshot.planes[0];
    final yBytes = yPlane.bytes;
    final yRowStride = yPlane.bytesPerRow;
    final yPixelStride = yPlane.bytesPerPixel ?? 1;

    if (numPlanes >= 3) {
      // YUV_420_888 (Planes: Y, U, V)
      final uPlane = snapshot.planes[1];
      final vPlane = snapshot.planes[2];
      final uBytes = uPlane.bytes;
      final vBytes = vPlane.bytes;
      final uvRowStride = uPlane.bytesPerRow;
      final uvPixelStride = uPlane.bytesPerPixel ?? 1;

      for (int y = 0; y < height; y++) {
        final yOffset = y * yRowStride;
        final uvOffset = (y >> 1) * uvRowStride;

        for (int x = 0; x < width; x++) {
          final yVal = yBytes[yOffset + (x * yPixelStride)];
          final uvIdx = uvOffset + ((x >> 1) * uvPixelStride);

          final uVal = uBytes[uvIdx];
          final vVal = vBytes[uvIdx];

          final c = yVal - 16;
          final d = uVal - 128;
          final e = vVal - 128;

          final r = ((298 * c + 409 * e + 128) >> 8).clamp(0, 255);
          final g = ((298 * c - 100 * d - 208 * e + 128) >> 8).clamp(0, 255);
          final b = ((298 * c + 516 * d + 128) >> 8).clamp(0, 255);

          final outX = _mapX(x, y, width, height, rotation);
          final outY = _mapY(x, y, width, height, rotation);

          rgbImage.setPixelRgb(outX, outY, r, g, b);
        }
      }
    } else if (numPlanes == 2) {
      // NV21 with 2 planes: Plane 0 = Y, Plane 1 = VU interleaved
      final vuPlane = snapshot.planes[1];
      final vuBytes = vuPlane.bytes;
      final vuRowStride = vuPlane.bytesPerRow;
      final vuPixelStride = vuPlane.bytesPerPixel ?? 2;

      for (int y = 0; y < height; y++) {
        final yOffset = y * yRowStride;
        final vuOffset = (y >> 1) * vuRowStride;

        for (int x = 0; x < width; x++) {
          final yVal = yBytes[yOffset + (x * yPixelStride)];
          final vuIdx = vuOffset + ((x >> 1) * vuPixelStride);

          final vVal = vuBytes[vuIdx];
          final uVal = vuBytes[vuIdx + 1];

          final c = yVal - 16;
          final d = uVal - 128;
          final e = vVal - 128;

          final r = ((298 * c + 409 * e + 128) >> 8).clamp(0, 255);
          final g = ((298 * c - 100 * d - 208 * e + 128) >> 8).clamp(0, 255);
          final b = ((298 * c + 516 * d + 128) >> 8).clamp(0, 255);

          final outX = _mapX(x, y, width, height, rotation);
          final outY = _mapY(x, y, width, height, rotation);

          rgbImage.setPixelRgb(outX, outY, r, g, b);
        }
      }
    } else {
      // Single contiguous NV21 buffer: Y plane followed by VU plane
      final ySize = width * height;
      for (int y = 0; y < height; y++) {
        final yRowOffset = y * yRowStride;
        final vuRowOffset = ySize + ((y >> 1) * yRowStride);

        for (int x = 0; x < width; x++) {
          final yVal = yBytes[yRowOffset + x];
          final vuIndex = vuRowOffset + (x & ~1);
          final vVal = yBytes[vuIndex];
          final uVal = yBytes[vuIndex + 1];

          final c = yVal - 16;
          final d = uVal - 128;
          final e = vVal - 128;

          final r = ((298 * c + 409 * e + 128) >> 8).clamp(0, 255);
          final g = ((298 * c - 100 * d - 208 * e + 128) >> 8).clamp(0, 255);
          final b = ((298 * c + 516 * d + 128) >> 8).clamp(0, 255);

          final outX = _mapX(x, y, width, height, rotation);
          final outY = _mapY(x, y, width, height, rotation);

          rgbImage.setPixelRgb(outX, outY, r, g, b);
        }
      }
    }

    return rgbImage;
  }

  /// Maps input X coordinate into rotated output X coordinate.
  static int _mapX(int x, int y, int width, int height, int rotation) {
    switch (rotation) {
      case 90:
        return height - 1 - y;
      case 180:
        return width - 1 - x;
      case 270:
        return y;
      case 0:
      default:
        return x;
    }
  }

  /// Maps input Y coordinate into rotated output Y coordinate.
  static int _mapY(int x, int y, int width, int height, int rotation) {
    switch (rotation) {
      case 90:
        return x;
      case 180:
        return height - 1 - y;
      case 270:
        return width - 1 - x;
      case 0:
      default:
        return y;
    }
  }
}
