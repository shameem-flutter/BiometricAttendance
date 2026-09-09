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

enum _EnrollmentStep {
  initializing,
  verifyOldFace,
  positioning,
  blink,
  capturingFrames,
  success,
  failed,
}

class FaceEnrollmentScreen extends StatefulWidget {
  final String accountId;
  final String? employeeName;
  final bool isReenrollment;

  const FaceEnrollmentScreen({
    super.key,
    required this.accountId,
    this.employeeName,
    this.isReenrollment = false,
  });

  @override
  State<FaceEnrollmentScreen> createState() => _FaceEnrollmentScreenState();
}

class _FaceEnrollmentScreenState extends State<FaceEnrollmentScreen> {
  CameraController? _cameraController;
  FaceDetector? _faceDetector;
  CameraDescription? _frontCamera;

  _EnrollmentStep _step = _EnrollmentStep.initializing;
  String _title = 'Initializing Camera';
  String _subtitle = 'Preparing face enrollment...';
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

  // OPT-6: Stream-based enrollment snapshots
  final List<FaceFrameSnapshot> _enrollmentSnapshots = [];
  DateTime? _lastEnrollmentSnapshotAt;
  static const Duration _kMinEnrollmentFrameSpacing = Duration(milliseconds: 150);
  bool _isProcessingEnrollment = false;

  // OPT-7: Debug performance timer
  final FaceLockPerformanceTimer _perfTimer = FaceLockPerformanceTimer();

  // Liveness state trackers
  int _consecutiveCenteredFrames = 0;
  bool _baselineEyesOpenConfirmed = false;
  bool _eyeClosedDetected = false;

  // Re-enrollment gate
  bool _needsOldFaceVerification = false;


  @override
  void initState() {
    super.initState();
    _perfTimer.startTotal();
    _perfTimer.startStep();
    _initializeEnrollment();
  }

  Future<void> _initializeEnrollment() async {
    try {
      // 1. Initialize TFLite service
      await FaceVerificationService.instance.initialize();

      // 2. Check if re-enrollment protection applies
      final hasExisting = await FaceVerificationService.instance.hasEnrolledFace(widget.accountId);
      if (widget.isReenrollment || hasExisting) {
        _needsOldFaceVerification = true;
      }

      // 3. Find front camera
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

      // 4. Initialize CameraController
      _cameraController = CameraController(
        _frontCamera!,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );

      await _cameraController!.initialize();
      await _cameraController!.lockCaptureOrientation(DeviceOrientation.portraitUp);

      // 5. Initialize FaceDetector (OPT-3: landmarks disabled, fast mode, minFaceSize 0.25)
      _faceDetector = FaceDetector(
        options: FaceDetectorOptions(
          enableClassification: true,
          enableLandmarks: false,
          performanceMode: FaceDetectorMode.fast,
          minFaceSize: 0.25,
        ),
      );

      if (!mounted) return;

      if (_needsOldFaceVerification) {
        setState(() {
          _step = _EnrollmentStep.verifyOldFace;
          _title = 'Verify Existing Face';
          _subtitle = 'To re-enroll, first verify your existing registered face.';
          _icon = Icons.security_rounded;
          _borderColor = Colors.amber;
          _progress = 0.10;
        });
      } else {
        setState(() {
          _step = _EnrollmentStep.positioning;
          _title = 'Position Your Face';
          _subtitle = 'Center your face inside the oval frame.';
          _icon = Icons.face_retouching_natural;
          _borderColor = primaryColor;
          _progress = 0.20;
        });
      }

      // 6. Set 30-second timeout
      _timeoutTimer = Timer(const Duration(seconds: 30), _onTimeout);

      // 7. Start stream
      await _cameraController!.startImageStream(_onCameraStreamFrame);
      _perfTimer.cameraInitMs = _perfTimer.stopStep();
      _perfTimer.startStep(); // start measuring liveness duration

    } catch (e, stack) {
      log('❌ [FaceEnrollmentScreen] Init error: $e\n$stack');
      _finishWithResult(
        FaceVerificationResult.failed(
          status: FaceVerificationStatus.cameraDenied,
          message: 'Camera permission is required for face enrollment.',
        ),
      );
    }
  }

  void _onTimeout() {
    if (_step == _EnrollmentStep.success || _step == _EnrollmentStep.failed) return;
    _finishWithResult(
      FaceVerificationResult.failed(
        status: FaceVerificationStatus.timeout,
        message: 'Face enrollment timed out. Please try again.',
      ),
    );
  }

  Future<void> _onCameraStreamFrame(CameraImage image) async {
    if (_isProcessingFrame || _isDisposed || _frontCamera == null) return;
    if (_step == _EnrollmentStep.success || _step == _EnrollmentStep.failed) {
      return;
    }

    // OPT-2: Stream throttling (~10 FPS)
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

      // OPT-1: Capture snapshot when single face with upright frontal pose and open eyes is detected
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

      _handleFacesDetected(faces, image);
    } catch (e) {
      log('⚠️ [FaceEnrollmentScreen] Stream processing error: $e');
    } finally {
      _isProcessingFrame = false;
    }
  }

  void _handleFacesDetected(List<Face> faces, CameraImage image) {
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

    // Step: Verify Old Face before allowing re-enrollment (OPT-5: 3 consecutive centered frames)
    if (_step == _EnrollmentStep.verifyOldFace) {
      if (rotY.abs() < 10.0) {
        _consecutiveCenteredFrames++;
        if (_consecutiveCenteredFrames >= 3) {
          _verifyOldFaceBeforeReenrollment();
        }
      } else {
        _consecutiveCenteredFrames = 0;
      }
      return;
    }

    // Step: Positioning (OPT-5: 3 consecutive centered frames)
    if (_step == _EnrollmentStep.positioning) {
      if (rotY.abs() < 10.0) {
        _consecutiveCenteredFrames++;
        if (_consecutiveCenteredFrames >= 3) {
          _consecutiveCenteredFrames = 0;
          _baselineEyesOpenConfirmed = false;
          _eyeClosedDetected = false;
          setState(() {
            _step = _EnrollmentStep.blink;
            _title = 'Blink Your Eyes';
            _subtitle = 'Blink naturally for liveness verification.';
            _icon = Icons.remove_red_eye_outlined;
            _borderColor = const Color(0xFFFFB300);
            _progress = 0.50;
          });
        }
      } else {
        _consecutiveCenteredFrames = 0;
      }
      return;
    }

    // Step: Blink Challenge (Completes liveness verification)
    if (_step == _EnrollmentStep.blink) {
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
      final avgEyeOpen = (leftEye + rightEye) / 2.0;
      if (avgEyeOpen < 0.30 || (leftEye < 0.35 && rightEye < 0.35)) {
        _eyeClosedDetected = true;
      } else if (_eyeClosedDetected && leftEye >= 0.65 && rightEye >= 0.65) {
        // Blink completed -> Liveness passed! Start stream-based multi-frame capture (OPT-6)
        _perfTimer.livenessMs = _perfTimer.stopStep();
        _step = _EnrollmentStep.capturingFrames;
        _enrollmentSnapshots.clear();
        _lastEnrollmentSnapshotAt = null;
        _isProcessingEnrollment = false;
        setState(() {
          _title = 'Capturing Face Template';
          _subtitle = 'Hold still. Capturing quality stream frames...';
          _icon = Icons.camera_enhance;
          _borderColor = primaryColor;
          _progress = 0.65;
        });
      }
      return;
    }

    // Step: Stream-based multi-frame capture (OPT-6 & OPT-6A)
    if (_step == _EnrollmentStep.capturingFrames) {
      if (_isProcessingEnrollment) return;

      final leftEye = face.leftEyeOpenProbability ?? 1.0;
      final rightEye = face.rightEyeOpenProbability ?? 1.0;
      if (rotY.abs() < 12.0 && rotZ.abs() <= 15.0 && rotX.abs() <= 20.0 && leftEye >= 0.60 && rightEye >= 0.60) {
        final now = DateTime.now();
        if (_lastEnrollmentSnapshotAt == null ||
            now.difference(_lastEnrollmentSnapshotAt!) >= _kMinEnrollmentFrameSpacing) {
          _lastEnrollmentSnapshotAt = now;
          _enrollmentSnapshots.add(
            FaceFrameSnapshot.fromCameraImage(
              image: image,
              camera: _frontCamera!,
              faceBoundingBox: face.boundingBox,
            ),
          );

          setState(() {
            _title = 'Capturing Sample ${_enrollmentSnapshots.length} of 3';
            _subtitle = 'Hold steady...';
            _progress = 0.75 + (_enrollmentSnapshots.length * 0.08);
          });

          if (_enrollmentSnapshots.length >= 3) {
            _isProcessingEnrollment = true;
            _processEnrollmentSnapshots();
          }
        }
      }
      return;
    }
  }

  Future<void> _verifyOldFaceBeforeReenrollment() async {
    try {
      List<double> liveEmbedding;

      final snapshot = _latestValidSnapshot;
      if (snapshot != null) {
        // OPT-1: In-memory verification of existing template without stopping stream or taking picture
        final uprightImage = CameraImageConverter.convertSnapshotToImage(snapshot);
        if (uprightImage == null) throw StateError('Failed to convert camera frame snapshot.');
        liveEmbedding = FaceVerificationService.instance.extractEmbedding(
          uprightImage,
          snapshot.faceBoundingBox,
        );
      } else {
        // Fallback: takePicture()
        await _cameraController?.stopImageStream();
        final xfile = await _cameraController!.takePicture();
        final photoFile = File(xfile.path);
        final photoBytes = await photoFile.readAsBytes();

        final stillInputImage = InputImage.fromFilePath(xfile.path);
        final faces = await _faceDetector!.processImage(stillInputImage);

        if (await photoFile.exists()) await photoFile.delete();

        if (faces.length != 1) {
          _finishWithResult(
            FaceVerificationResult.failed(
              status: FaceVerificationStatus.mismatch,
              message: 'Existing face could not be verified for re-enrollment.',
            ),
          );
          return;
        }

        final decodedImage = img.decodeImage(photoBytes);
        if (decodedImage == null) {
          _finishWithResult(
            FaceVerificationResult.failed(
              status: FaceVerificationStatus.error,
              message: 'Unable to process camera frame.',
            ),
          );
          return;
        }

        liveEmbedding = FaceVerificationService.instance.extractEmbedding(
          decodedImage,
          faces.first.boundingBox,
        );
      }

      final match = await FaceVerificationService.instance.verifyAgainstEnrolled(
        accountId: widget.accountId,
        liveEmbedding: liveEmbedding,
      );

      if (!match.isMatch) {
        await _cameraController?.stopImageStream();
        setState(() {
          _step = _EnrollmentStep.failed;
          _title = 'Re-enrollment Blocked';
          _subtitle = 'Current face does not match existing template. Re-enrollment denied.';
          _icon = Icons.block;
          _borderColor = redColor;
        });

        await Future.delayed(const Duration(milliseconds: 1500));
        _finishWithResult(
          FaceVerificationResult.failed(
            status: FaceVerificationStatus.mismatch,
            message: 'Re-enrollment denied. You must verify your existing face before re-enrolling.',
          ),
        );
        return;
      }

      // Old face verified! Proceed to new enrollment
      _consecutiveCenteredFrames = 0;
      _eyeClosedDetected = false;

      setState(() {
        _step = _EnrollmentStep.positioning;
        _title = 'Verified! Position Face';
        _subtitle = 'Now position face to create the new enrollment.';
        _icon = Icons.face_retouching_natural;
        _borderColor = primaryColor;
        _progress = 0.30;
      });

      // If stream was stopped during fallback, restart it
      if (!(_cameraController?.value.isStreamingImages ?? false)) {
        await _cameraController!.startImageStream(_onCameraStreamFrame);
      }
    } catch (e) {
      log('❌ [FaceEnrollmentScreen] Re-enrollment verification error: $e');
      _finishWithResult(
        FaceVerificationResult.failed(
          status: FaceVerificationStatus.error,
          message: 'Error verifying existing face template: $e',
        ),
      );
    }
  }

  Future<void> _processEnrollmentSnapshots() async {
    if (_isDisposed) return;

    try {
      await _cameraController?.stopImageStream();

      // OPT-6B: Extract 3 embeddings from stream snapshots without JPEG disk round-trips
      _perfTimer.startStep();
      final List<img.Image> convertedImages = [];
      for (final snapshot in _enrollmentSnapshots) {
        final img = CameraImageConverter.convertSnapshotToImage(snapshot);
        if (img != null) {
          convertedImages.add(img);
        }
      }
      _perfTimer.frameConversionMs = _perfTimer.stopStep();

      if (convertedImages.length < 3) {
        // Fall back to takePicture() multi-frame capture if stream snapshots failed conversion
        await _startMultiFrameEnrollmentFallback();
        return;
      }

      _perfTimer.startStep();
      final List<List<double>> sampledEmbeddings = [];
      for (int i = 0; i < convertedImages.length; i++) {
        final emb = FaceVerificationService.instance.extractEmbedding(
          convertedImages[i],
          _enrollmentSnapshots[i].faceBoundingBox,
        );
        sampledEmbeddings.add(emb);
      }
      _perfTimer.mobileFaceNetMs = _perfTimer.stopStep();

      if (sampledEmbeddings.length < 3) {
        await _startMultiFrameEnrollmentFallback();
        return;
      }

      // Compute normalized composite template from 3 sampled frames
      _perfTimer.startStep();
      final compositeTemplate = FaceVerificationService.computeCompositeTemplate(sampledEmbeddings);

      // Save securely for current account
      await FaceVerificationService.instance.saveEnrolledEmbedding(
        widget.accountId,
        compositeTemplate,
      );
      _perfTimer.similarityMs = _perfTimer.stopStep();

      // OPT-7: Log debug performance timings
      _perfTimer.logResults(operation: 'Enrollment');

      if (!mounted || _isDisposed) return;

      setState(() {
        _step = _EnrollmentStep.success;
        _title = 'Enrollment Complete!';
        _subtitle = 'Your face template has been securely saved.';
        _icon = Icons.check_circle_outline;
        _borderColor = const Color(0xFF00E676);
        _progress = 1.0;
      });

      await Future.delayed(const Duration(milliseconds: 1000));
      _finishWithResult(
        FaceVerificationResult.success(
          message: 'Face enrolled successfully.',
        ),
      );
    } catch (e, stack) {
      log('❌ [FaceEnrollmentScreen] Stream enrollment error: $e\n$stack');
      // Fallback
      await _startMultiFrameEnrollmentFallback();
    }
  }

  Future<void> _startMultiFrameEnrollmentFallback() async {
    if (_isDisposed) return;

    setState(() {
      _step = _EnrollmentStep.capturingFrames;
      _title = 'Capturing Face Template';
      _subtitle = 'Hold still. Capturing quality frames...';
      _icon = Icons.camera_enhance;
      _borderColor = primaryColor;
      _progress = 0.75;
    });

    try {
      if (_cameraController?.value.isStreamingImages ?? false) {
        await _cameraController?.stopImageStream();
      }

      final List<List<double>> sampledEmbeddings = [];

      for (int i = 0; i < 3; i++) {
        if (!mounted || _isDisposed) return;

        setState(() {
          _title = 'Capturing Sample ${i + 1} of 3';
          _subtitle = 'Hold steady...';
          _progress = 0.75 + (i * 0.08);
        });

        final xfile = await _cameraController!.takePicture();
        final photoFile = File(xfile.path);
        final photoBytes = await photoFile.readAsBytes();

        final stillInputImage = InputImage.fromFilePath(xfile.path);
        final faces = await _faceDetector!.processImage(stillInputImage);

        if (await photoFile.exists()) await photoFile.delete();

        if (faces.length == 1) {
          final decoded = img.decodeImage(photoBytes);
          if (decoded != null) {
            final emb = FaceVerificationService.instance.extractEmbedding(
              decoded,
              faces.first.boundingBox,
            );
            sampledEmbeddings.add(emb);
          }
        }

        await Future.delayed(const Duration(milliseconds: 300));
      }

      if (sampledEmbeddings.isEmpty) {
        _finishWithResult(
          FaceVerificationResult.failed(
            status: FaceVerificationStatus.noFace,
            message: 'Failed to capture sufficient quality frames. Please try again in good lighting.',
          ),
        );
        return;
      }

      final compositeTemplate = FaceVerificationService.computeCompositeTemplate(sampledEmbeddings);
      await FaceVerificationService.instance.saveEnrolledEmbedding(
        widget.accountId,
        compositeTemplate,
      );

      if (!mounted || _isDisposed) return;

      setState(() {
        _step = _EnrollmentStep.success;
        _title = 'Enrollment Complete!';
        _subtitle = 'Your face template has been securely saved.';
        _icon = Icons.check_circle_outline;
        _borderColor = const Color(0xFF00E676);
        _progress = 1.0;
      });

      await Future.delayed(const Duration(milliseconds: 1000));
      _finishWithResult(
        FaceVerificationResult.success(
          message: 'Face enrolled successfully.',
        ),
      );
    } catch (e, stack) {
      log('❌ [FaceEnrollmentScreen] Fallback enrollment error: $e\n$stack');
      _finishWithResult(
        FaceVerificationResult.failed(
          status: FaceVerificationStatus.error,
          message: 'Failed to complete face enrollment: $e',
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
            message: 'Face enrollment cancelled.',
          ),
        );
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: isInitialized
            ? Stack(
                fit: StackFit.expand,
                children: [
                  CameraPreview(_cameraController!),
                  FaceCameraOverlay(
                    borderColor: _borderColor,
                    instructionTitle: _title,
                    instructionSubtitle: _subtitle,
                    instructionIcon: _icon,
                    progress: _progress,
                    isSuccess: _step == _EnrollmentStep.success,
                    isError: _step == _EnrollmentStep.failed,
                    onCancel: () => _finishWithResult(
                      FaceVerificationResult.failed(
                        status: FaceVerificationStatus.cancelled,
                        message: 'Face enrollment cancelled.',
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
