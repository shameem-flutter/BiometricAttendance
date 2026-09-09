import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:odoo_mobile/constants/color_constants.dart';
import 'package:odoo_mobile/models/face_verification_result.dart';
import 'package:odoo_mobile/services/face_verification_service.dart';
import 'package:odoo_mobile/utils/camera_image_converter.dart';
import 'package:odoo_mobile/utils/camera_mlkit_converter.dart';
import 'package:odoo_mobile/utils/face_lock_performance_timer.dart';
import 'package:odoo_mobile/widgets/face_camera_overlay.dart';

enum _VerificationStep {
  initializing,
  positioning,
  blink,
  verifying,
  success,
  failed,
}

class FaceVerificationScreen extends StatefulWidget {
  final String accountId;
  final String? employeeName;
  final String action; // 'check_in' or 'check_out'

  const FaceVerificationScreen({
    super.key,
    required this.accountId,
    this.employeeName,
    required this.action,
  });

  @override
  State<FaceVerificationScreen> createState() => _FaceVerificationScreenState();
}

class _FaceVerificationScreenState extends State<FaceVerificationScreen> {
  CameraController? _cameraController;
  FaceDetector? _faceDetector;
  CameraDescription? _frontCamera;

  _VerificationStep _step = _VerificationStep.initializing;
  String _title = 'Initializing Camera';
  String _subtitle = 'Please wait while we prepare face verification...';
  IconData _icon = Icons.camera_alt_outlined;
  Color _borderColor = primaryColor;
  double _progress = 0.0;

  bool _isProcessingFrame = false;
  bool _isDisposed = false;
  Timer? _timeoutTimer;

  // OPT-2: Stream throttling (~10 FPS)
  static const Duration _kMlKitInterval = Duration(milliseconds: 100);
  DateTime _lastMlKitProcessedAt = DateTime.fromMillisecondsSinceEpoch(0);

  // OPT-1: Immutable frame snapshot copied from stream
  FaceFrameSnapshot? _latestValidSnapshot;

  // OPT-7: Debug performance timer
  final FaceLockPerformanceTimer _perfTimer = FaceLockPerformanceTimer();

  // Liveness state trackers
  int _consecutiveCenteredFrames = 0;
  bool _baselineEyesOpenConfirmed = false;
  bool _eyeClosedDetected = false;


  @override
  void initState() {
    super.initState();
    _perfTimer.startTotal();
    _perfTimer.startStep();
    _initializeCameraAndML();
  }

  Future<void> _initializeCameraAndML() async {
    try {
      // 1. Initialize TFLite service (idempotent, prewarmed in AttendanceScreen)
      await FaceVerificationService.instance.initialize();

      // 2. Discover front camera
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _finishWithResult(
          FaceVerificationResult.failed(
            status: FaceVerificationStatus.error,
            message: 'No camera hardware found on this device.',
          ),
        );
        return;
      }

      _frontCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      // 3. Initialize CameraController
      _cameraController = CameraController(
        _frontCamera!,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );

      await _cameraController!.initialize();
      await _cameraController!.lockCaptureOrientation(DeviceOrientation.portraitUp);

      // 4. Initialize FaceDetector with fast mode (OPT-3: landmarks disabled, fast mode, minFaceSize 0.25)
      _faceDetector = FaceDetector(
        options: FaceDetectorOptions(
          enableClassification: true,
          enableLandmarks: false,
          performanceMode: FaceDetectorMode.fast,
          minFaceSize: 0.25,
        ),
      );

      if (!mounted) return;

      setState(() {
        _step = _VerificationStep.positioning;
        _title = 'Position Your Face';
        _subtitle = 'Center your face inside the oval frame.';
        _icon = Icons.face_retouching_natural;
        _borderColor = primaryColor;
        _progress = 0.15;
      });

      // 5. Start timeout timer (25 seconds)
      _timeoutTimer = Timer(const Duration(seconds: 25), _onTimeout);

      // 6. Start image stream for real-time tracking & liveness
      await _cameraController!.startImageStream(_onCameraStreamFrame);
      _perfTimer.cameraInitMs = _perfTimer.stopStep();
      _perfTimer.startStep(); // Start measuring liveness duration
    } catch (e, stack) {
      log('❌ [FaceVerificationScreen] Initialization error: $e\n$stack');
      _finishWithResult(
        FaceVerificationResult.failed(
          status: FaceVerificationStatus.cameraDenied,
          message: 'Camera permission is required for attendance verification.',
        ),
      );
    }
  }


  void _onTimeout() {
    if (_step == _VerificationStep.success || _step == _VerificationStep.failed) return;
    _finishWithResult(
      FaceVerificationResult.failed(
        status: FaceVerificationStatus.timeout,
        message: 'Face verification timed out. Please try again.',
      ),
    );
  }

  Future<void> _onCameraStreamFrame(CameraImage image) async {
    if (_isProcessingFrame || _isDisposed || _frontCamera == null) return;
    if (_step == _VerificationStep.verifying ||
        _step == _VerificationStep.success ||
        _step == _VerificationStep.failed) {
      return;
    }

    // OPT-2: Time-based throttling (~10 FPS)
    final now = DateTime.now();
    if (now.difference(_lastMlKitProcessedAt) < _kMlKitInterval) return;
    _lastMlKitProcessedAt = now;

    _isProcessingFrame = true;

    try {
      final inputImage = CameraMlkitConverter.convertCameraImage(
        image: image,
        camera: _frontCamera!,
      );

      if (inputImage == null) {
        _isProcessingFrame = false;
        return;
      }

      final mlKitSw = Stopwatch()..start();
      final faces = await _faceDetector!.processImage(inputImage);
      _perfTimer.recordMlKitLatency(mlKitSw.elapsedMilliseconds);

      if (!mounted || _isDisposed) return;

      // OPT-1: When exactly 1 face is present with upright frontal pose and open eyes, copy an immutable snapshot.
      // Filtering for open eyes (leftEye >= 0.60 && rightEye >= 0.60) guarantees that the snapshot used
      // for 1:1 embedding matching has clear, unclosed eyes and avoids matching against half-blink frames.
      if (faces.length == 1) {
        final f = faces.first;
        final rotZ = f.headEulerAngleZ ?? 0.0;
        final rotX = f.headEulerAngleX ?? 0.0;
        final rotY = f.headEulerAngleY ?? 0.0;
        final leftEye = f.leftEyeOpenProbability ?? 1.0;
        final rightEye = f.rightEyeOpenProbability ?? 1.0;
        if (rotZ.abs() <= 15.0 && rotX.abs() <= 20.0 && rotY.abs() <= 12.0 && leftEye >= 0.60 && rightEye >= 0.60) {
          _latestValidSnapshot = FaceFrameSnapshot.fromCameraImage(
            image: image,
            camera: _frontCamera!,
            faceBoundingBox: f.boundingBox,
          );
        }
      }

      _handleFacesDetected(faces, image.width, image.height);
    } catch (e) {
      log('⚠️ [FaceVerificationScreen] Stream processing error: $e');
    } finally {
      _isProcessingFrame = false;
    }
  }

  void _handleFacesDetected(List<Face> faces, int imgWidth, int imgHeight) {
    // RULE: Exactly one face
    if (faces.isEmpty) {
      _consecutiveCenteredFrames = 0;
      setState(() {
        _subtitle = 'Face not detected. Position your face clearly inside the camera frame.';
        _borderColor = Colors.amber;
      });
      return;
    }

    if (faces.length > 1) {
      _consecutiveCenteredFrames = 0;
      setState(() {
        _subtitle = 'Multiple faces detected. Only the logged-in employee should be visible.';
        _borderColor = redColor;
      });
      return;
    }

    final face = faces.first;

    // Quality check: pose angles
    final rotY = face.headEulerAngleY ?? 0.0;
    final rotZ = face.headEulerAngleZ ?? 0.0;
    final rotX = face.headEulerAngleX ?? 0.0;

    if (rotZ.abs() > 15.0 || rotX.abs() > 20.0) {
      setState(() {
        _subtitle = 'Hold your phone upright and look straight at the camera.';
        _borderColor = Colors.amber;
      });
      return;
    }

    // Liveness Step 1: Positioning (OPT-5: 3 consecutive centered frames)
    if (_step == _VerificationStep.positioning) {
      if (rotY.abs() < 10.0) {
        _consecutiveCenteredFrames++;
        if (_consecutiveCenteredFrames >= 3) {
          _consecutiveCenteredFrames = 0;
          _baselineEyesOpenConfirmed = false;
          _eyeClosedDetected = false;
          setState(() {
            _step = _VerificationStep.blink;
            _title = 'Blink Your Eyes';
            _subtitle = 'Blink naturally while looking directly at the camera.';
            _icon = Icons.remove_red_eye_outlined;
            _borderColor = const Color(0xFFFFB300); // Amber
            _progress = 0.50;
          });
        }
      } else {
        _consecutiveCenteredFrames = 0;
      }
      return;
    }

    // Liveness Step 2: Blink Challenge (Completes liveness verification)
    if (_step == _VerificationStep.blink) {
      final leftEye = face.leftEyeOpenProbability ?? 1.0;
      final rightEye = face.rightEyeOpenProbability ?? 1.0;

      // 1. Confirm eyes are open before expecting a blink
      if (!_baselineEyesOpenConfirmed) {
        if (leftEye >= 0.65 && rightEye >= 0.65) {
          _baselineEyesOpenConfirmed = true;
        }
        return;
      }

      // 2. Detect bilateral blink: BOTH eyes must close (or average < 0.30)
      // Using bilateral check prevents hair, shadows, or glasses glare on ONE eye from triggering a false blink
      final avgEyeOpen = (leftEye + rightEye) / 2.0;
      if (avgEyeOpen < 0.30 || (leftEye < 0.35 && rightEye < 0.35)) {
        _eyeClosedDetected = true;
      } else if (_eyeClosedDetected && leftEye >= 0.65 && rightEye >= 0.65) {
        // Blink completed -> Liveness passed! Complete verification immediately.
        _perfTimer.livenessMs = _perfTimer.stopStep();
        _triggerVerificationCapture();
      }
      return;
    }
  }

  Future<void> _triggerVerificationCapture() async {
    if (_step == _VerificationStep.verifying || _isDisposed) return;

    setState(() {
      _step = _VerificationStep.verifying;
      _title = 'Verifying Identity...';
      _subtitle = 'Hold still. Matching face against registered employee...';
      _icon = Icons.fingerprint;
      _borderColor = primaryColor;
      _progress = 0.90;
    });

    try {
      // 1. Stop image stream
      await _cameraController?.stopImageStream();

      List<double> liveEmbedding;

      final snapshot = _latestValidSnapshot;
      if (snapshot != null) {
        // OPT-1: In-memory stream frame conversion (NO JPEG round-trip, NO disk write/read)
        _perfTimer.startStep();
        final uprightImage = CameraImageConverter.convertSnapshotToImage(snapshot);
        _perfTimer.frameConversionMs = _perfTimer.stopStep();

        if (uprightImage == null) {
          throw StateError('Failed to convert camera frame snapshot.');
        }

        _perfTimer.startStep();
        liveEmbedding = FaceVerificationService.instance.extractEmbedding(
          uprightImage,
          snapshot.faceBoundingBox,
        );
        _perfTimer.mobileFaceNetMs = _perfTimer.stopStep();
      } else {
        // OPT-1C: Fallback using takePicture() if stream snapshot is unavailable
        final xfile = await _cameraController!.takePicture();
        final photoFile = File(xfile.path);
        final photoBytes = await photoFile.readAsBytes();

        final stillInputImage = InputImage.fromFilePath(xfile.path);
        final faces = await _faceDetector!.processImage(stillInputImage);

        if (await photoFile.exists()) await photoFile.delete();

        if (faces.length != 1) {
          _finishWithResult(
            FaceVerificationResult.failed(
              status: faces.isEmpty ? FaceVerificationStatus.noFace : FaceVerificationStatus.multipleFaces,
              message: faces.isEmpty
                  ? 'Face not detected. Position your face clearly inside the camera frame.'
                  : 'Multiple faces detected. Only the logged-in employee should be visible.',
            ),
          );
          return;
        }

        final decodedImage = img.decodeImage(photoBytes);
        if (decodedImage == null) {
          _finishWithResult(
            FaceVerificationResult.failed(
              status: FaceVerificationStatus.error,
              message: 'Unable to process captured frame.',
            ),
          );
          return;
        }

        _perfTimer.startStep();
        liveEmbedding = FaceVerificationService.instance.extractEmbedding(
          decodedImage,
          faces.first.boundingBox,
        );
        _perfTimer.mobileFaceNetMs = _perfTimer.stopStep();
      }

      // Verify 1:1 against enrolled template
      _perfTimer.startStep();
      final matchResult = await FaceVerificationService.instance.verifyAgainstEnrolled(
        accountId: widget.accountId,
        liveEmbedding: liveEmbedding,
      );
      _perfTimer.similarityMs = _perfTimer.stopStep();

      // OPT-7: Log debug performance timings
      _perfTimer.logResults(operation: 'Verification');

      if (!mounted || _isDisposed) return;

      if (matchResult.isMatch) {
        setState(() {
          _step = _VerificationStep.success;
          _title = 'Verified Successfully';
          _subtitle = 'Identity confirmed (${(matchResult.similarity * 100).toStringAsFixed(1)}% match).';
          _icon = Icons.check_circle_outline;
          _borderColor = const Color(0xFF00E676); // Emerald Green
          _progress = 1.0;
        });

        await Future.delayed(const Duration(milliseconds: 700));
        _finishWithResult(
          FaceVerificationResult.success(
            similarity: matchResult.similarity,
            message: 'Face verification succeeded.',
          ),
        );
      } else {
        setState(() {
          _step = _VerificationStep.failed;
          _title = 'Verification Failed';
          _subtitle = matchResult.message ?? 'The detected face does not match the logged-in employee.';
          _icon = Icons.cancel_outlined;
          _borderColor = redColor;
          _progress = 1.0;
        });

        await Future.delayed(const Duration(milliseconds: 1400));
        _finishWithResult(
          FaceVerificationResult.failed(
            status: FaceVerificationStatus.mismatch,
            similarity: matchResult.similarity,
            message: 'Face does not match the registered employee (similarity: ${(matchResult.similarity * 100).toStringAsFixed(1)}%, required: ${(matchResult.threshold * 100).toStringAsFixed(1)}%).',
          ),
        );
      }
    } catch (e, stack) {
      log('❌ [FaceVerificationScreen] Verification error: $e\n$stack');
      _finishWithResult(
        FaceVerificationResult.failed(
          status: FaceVerificationStatus.error,
          message: 'An error occurred during face verification: $e',
        ),
      );
    }
  }


  void _finishWithResult(FaceVerificationResult result) {
    if (_isDisposed) return;
    _isDisposed = true;
    _timeoutTimer?.cancel();

    if (mounted) {
      Navigator.of(context).pop(result);
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _timeoutTimer?.cancel();
    _cameraController?.dispose();
    _faceDetector?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isInitialized = _cameraController != null && _cameraController!.value.isInitialized;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _finishWithResult(
          FaceVerificationResult.failed(
            status: FaceVerificationStatus.cancelled,
            message: 'Face verification cancelled. Attendance was not recorded.',
          ),
        );
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: isInitialized
            ? Stack(
                fit: StackFit.expand,
                children: [
                  // Full-screen camera preview
                  CameraPreview(_cameraController!),

                  // Overlay with oval guide and animated feedback
                  FaceCameraOverlay(
                    borderColor: _borderColor,
                    instructionTitle: _title,
                    instructionSubtitle: _subtitle,
                    instructionIcon: _icon,
                    progress: _progress,
                    isSuccess: _step == _VerificationStep.success,
                    isError: _step == _VerificationStep.failed,
                    onCancel: () => _finishWithResult(
                      FaceVerificationResult.failed(
                        status: FaceVerificationStatus.cancelled,
                        message: 'Face verification cancelled. Attendance was not recorded.',
                      ),
                    ),
                  ),
                ],
              )
            : Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: Colors.white),
                    const SizedBox(height: 16),
                    Text(
                      'Opening front camera...',
                      style: TextStyle(color: Colors.white.withAlpha(200), fontSize: 14),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
