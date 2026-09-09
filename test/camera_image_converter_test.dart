import 'dart:typed_data';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:odoo_mobile/utils/camera_image_converter.dart';

void main() {
  group('CameraImageConverter Unit Tests', () {
    test('PlaneSnapshot deep copies bytes immediately', () {
      final original = Uint8List.fromList([1, 2, 3, 4]);
      final planeSnapshot = PlaneSnapshot(
        bytes: Uint8List.fromList(original),
        bytesPerRow: 4,
        bytesPerPixel: 1,
      );

      // Mutate original buffer
      original[0] = 99;

      // PlaneSnapshot copy must not be affected
      expect(planeSnapshot.bytes[0], 1);
    });

    test('NV21 single plane converts correctly with 270 deg rotation', () {
      const width = 4;
      const height = 2;
      final ySize = width * height;
      final uvSize = width * height ~/ 2;
      final nv21Bytes = Uint8List(ySize + uvSize);
      nv21Bytes.fillRange(0, ySize, 200); // Bright Y
      nv21Bytes.fillRange(ySize, ySize + uvSize, 128); // Neutral U/V

      final snapshot = FaceFrameSnapshot(
        width: width,
        height: height,
        format: 17, // NV21
        sensorOrientation: 270,
        lensDirection: CameraLensDirection.front,
        planes: [
          PlaneSnapshot(bytes: nv21Bytes, bytesPerRow: width, bytesPerPixel: 1),
        ],
        faceBoundingBox: const Rect.fromLTWH(0, 0, 2, 4),
      );

      final converted = CameraImageConverter.convertSnapshotToImage(snapshot);
      expect(converted, isNotNull);
      // With 270 deg rotation, output width is input height (2), output height is input width (4)
      expect(converted!.width, height);
      expect(converted.height, width);
    });

    test('NV21 two planes converts correctly with 90 deg rotation', () {
      const width = 4;
      const height = 2;
      final yBytes = Uint8List(width * height)..fillRange(0, width * height, 150);
      final vuBytes = Uint8List(width * height ~/ 2)..fillRange(0, width * height ~/ 2, 128);

      final snapshot = FaceFrameSnapshot(
        width: width,
        height: height,
        format: 17,
        sensorOrientation: 90,
        lensDirection: CameraLensDirection.front,
        planes: [
          PlaneSnapshot(bytes: yBytes, bytesPerRow: width, bytesPerPixel: 1),
          PlaneSnapshot(bytes: vuBytes, bytesPerRow: width, bytesPerPixel: 2),
        ],
        faceBoundingBox: const Rect.fromLTWH(0, 0, 2, 4),
      );

      final converted = CameraImageConverter.convertSnapshotToImage(snapshot);
      expect(converted, isNotNull);
      expect(converted!.width, height);
      expect(converted.height, width);
    });

    test('BGRA8888 plane converts correctly with 0 deg rotation', () {
      const width = 2;
      const height = 2;
      final bgraBytes = Uint8List(width * height * 4);
      // Red pixel at (0, 0): B=0, G=0, R=255, A=255
      bgraBytes[0] = 0;
      bgraBytes[1] = 0;
      bgraBytes[2] = 255;
      bgraBytes[3] = 255;

      final snapshot = FaceFrameSnapshot(
        width: width,
        height: height,
        format: 1111970369, // BGRA8888
        sensorOrientation: 0,
        lensDirection: CameraLensDirection.front,
        planes: [
          PlaneSnapshot(bytes: bgraBytes, bytesPerRow: width * 4, bytesPerPixel: 4),
        ],
        faceBoundingBox: const Rect.fromLTWH(0, 0, 2, 2),
      );

      final converted = CameraImageConverter.convertSnapshotToImage(snapshot);
      expect(converted, isNotNull);
      expect(converted!.width, width);
      expect(converted.height, height);

      final pixel = converted.getPixel(0, 0);
      expect(pixel.r, 255);
      expect(pixel.g, 0);
      expect(pixel.b, 0);
    });
  });
}
