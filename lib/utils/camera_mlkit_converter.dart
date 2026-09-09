import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// Converts a [CameraImage] from the camera stream to an ML Kit [InputImage].
class CameraMlkitConverter {
  static InputImage? convertCameraImage({
    required CameraImage image,
    required CameraDescription camera,
  }) {
    // Determine rotation
    final rotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    if (rotation == null) return null;

    // Determine format
    InputImageFormat? format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) {
      if (Platform.isAndroid) {
        format = InputImageFormat.nv21;
      } else if (Platform.isIOS) {
        format = InputImageFormat.bgra8888;
      } else {
        return null;
      }
    }

    // Concatenate plane bytes
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    // Use bytesPerRow of first plane
    final bytesPerRow = image.planes.isNotEmpty ? image.planes.first.bytesPerRow : image.width;

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: bytesPerRow,
      ),
    );
  }
}
