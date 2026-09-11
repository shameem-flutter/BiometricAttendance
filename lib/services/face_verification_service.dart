import 'dart:convert';
import 'dart:developer';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image/image.dart' as img;
import 'package:odoo_mobile/utils/camera_image_converter.dart';
import 'package:tflite_flutter/tflite_flutter.dart';


/// Represents the status/result of 1:1 face template matching.
class FaceVerificationMatchResult {
  final bool isMatch;
  final double similarity;
  final double threshold;
  final String? message;

  const FaceVerificationMatchResult({
    required this.isMatch,
    required this.similarity,
    required this.threshold,
    this.message,
  });

  @override
  String toString() =>
      'FaceVerificationMatchResult(isMatch: $isMatch, similarity: ${similarity.toStringAsFixed(4)}, threshold: $threshold, message: $message)';
}

/// Service managing the MobileFaceNet TFLite interpreter, image preprocessing,
/// feature embedding generation, L2 normalization, cosine similarity computation,
/// and secure multi-account template persistence.
class FaceVerificationService {
  static final FaceVerificationService instance = FaceVerificationService._internal();
  FaceVerificationService._internal();

  /// Calibrated cosine similarity threshold for MobileFaceNet (192-dim).
  ///
  /// Set to 0.68 for robust 1:1 mobile verification across real-world lighting,
  /// expressions, and hairstyle changes, while rejecting impostors (typically < 0.45).
  static const double defaultSimilarityThreshold = 0.68;

  /// Model asset path
  static const String modelAssetPath = 'assets/models/mobilefacenet.tflite';

  /// Expected embedding dimensionality
  static const int embeddingDim = 192;

  /// Expected model input image resolution
  static const int inputImageSize = 112;

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  Interpreter? _interpreter;
  bool _isInitializing = false;

  /// Initializes the TFLite interpreter if not already initialized.
  Future<void> initialize() async {
    if (_interpreter != null) return;
    if (_isInitializing) {
      while (_isInitializing) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      return;
    }

    _isInitializing = true;
    try {
      log('🧠 [FaceVerificationService] Loading MobileFaceNet model from $modelAssetPath...');
      final options = InterpreterOptions()..threads = 2;
      _interpreter = await Interpreter.fromAsset(modelAssetPath, options: options);
      log('✅ [FaceVerificationService] MobileFaceNet interpreter loaded successfully.');
      log('   Input tensors: ${_interpreter!.getInputTensors()}');
      log('   Output tensors: ${_interpreter!.getOutputTensors()}');
    } catch (e, stack) {
      log('❌ [FaceVerificationService] Failed to load model: $e\n$stack');
      rethrow;
    } finally {
      _isInitializing = false;
    }
  }

  /// Extracts a 192-dimensional L2-normalized embedding vector from a cropped and aligned face image.
  ///
  /// [fullImage]: The original image (e.g. from camera capture).
  /// [faceBoundingBox]: The bounding box detected by ML Kit.
  List<double> extractEmbedding(img.Image fullImage, Rect faceBoundingBox) {
    if (_interpreter == null) {
      throw StateError('TFLite interpreter is not initialized. Call initialize() first.');
    }

    // 1. Crop face tightly focused on facial biometrics (eyes, nose, mouth, jaw)
    // Avoid top margin expansion into hair/background to remain invariant to hairstyle changes.
    final marginW = (faceBoundingBox.width * 0.05).round();
    final marginHBottom = (faceBoundingBox.height * 0.08).round();

    final x = (faceBoundingBox.left - marginW).clamp(0, fullImage.width - 1).toInt();
    final y = faceBoundingBox.top.clamp(0, fullImage.height - 1).toInt();
    final right = (faceBoundingBox.right + marginW).clamp(0, fullImage.width).toInt();
    final bottom = (faceBoundingBox.bottom + marginHBottom).clamp(0, fullImage.height).toInt();

    final w = (right - x).clamp(1, fullImage.width - x);
    final h = (bottom - y).clamp(1, fullImage.height - y);

    final cropped = img.copyCrop(fullImage, x: x, y: y, width: w, height: h);

    // 2. Resize to 112x112 as required by MobileFaceNet
    final resized = img.copyResize(
      cropped,
      width: inputImageSize,
      height: inputImageSize,
      interpolation: img.Interpolation.linear,
    );

    // 3. Preprocess to [1, 112, 112, 3] Float32 tensor normalized to [-1.0, 1.0]
    // Formula: (pixel - 127.5) / 128.0
    final inputTensor = List.generate(
      1,
      (_) => List.generate(
        inputImageSize,
        (py) => List.generate(
          inputImageSize,
          (px) {
            final pixel = resized.getPixel(px, py);
            return [
              (pixel.r - 127.5) / 128.0,
              (pixel.g - 127.5) / 128.0,
              (pixel.b - 127.5) / 128.0,
            ];
          },
        ),
      ),
    );

    // 4. Output buffer [1, 192]
    final outputTensor = List.generate(1, (_) => List<double>.filled(embeddingDim, 0.0));

    // 5. Run inference
    _interpreter!.run(inputTensor, outputTensor);

    // 6. L2 Normalize output vector
    final rawVector = outputTensor[0];
    return l2Normalize(rawVector);
  }

  /// Extracts a 192-dimensional embedding directly from an immutable stream [FaceFrameSnapshot].
  ///
  /// Converts the frame snapshot into an upright RGB image via [CameraImageConverter]
  /// and forwards to [extractEmbedding] using the associated face bounding box.
  List<double> extractEmbeddingFromSnapshot(FaceFrameSnapshot snapshot) {
    final image = CameraImageConverter.convertSnapshotToImage(snapshot);
    if (image == null) {
      throw StateError('Failed to convert camera frame snapshot to RGB image.');
    }
    return extractEmbedding(image, snapshot.faceBoundingBox);
  }


  /// Computes L2 normalization of an embedding vector so that ||v||_2 == 1.0.
  static List<double> l2Normalize(List<double> vector) {
    double sumSq = 0.0;
    for (final val in vector) {
      sumSq += val * val;
    }
    double norm = math.sqrt(sumSq);
    if (norm == 0.0) norm = 1e-6;
    return vector.map((v) => v / norm).toList();
  }

  /// Calculates cosine similarity between two unit vectors: dot(A, B).
  ///
  /// Returns a value in the range [-1.0, 1.0].
  static double computeCosineSimilarity(List<double> emb1, List<double> emb2) {
    if (emb1.length != emb2.length) {
      throw ArgumentError('Embedding dimensions must match: ${emb1.length} vs ${emb2.length}');
    }

    double dotProduct = 0.0;
    for (int i = 0; i < emb1.length; i++) {
      dotProduct += emb1[i] * emb2[i];
    }
    return dotProduct.clamp(-1.0, 1.0);
  }

  /// Computes an aggregated enrollment template from multiple high-quality frame embeddings.
  ///
  /// Averages the vectors element-wise and L2-normalizes the composite vector.
  static List<double> computeCompositeTemplate(List<List<double>> embeddings) {
    if (embeddings.isEmpty) {
      throw ArgumentError('Cannot create composite template from empty embeddings list.');
    }
    if (embeddings.length == 1) {
      return embeddings.first;
    }

    final dim = embeddings.first.length;
    final composite = List<double>.filled(dim, 0.0);

    for (final emb in embeddings) {
      if (emb.length != dim) {
        throw ArgumentError('Inconsistent embedding dimension in sample set.');
      }
      for (int i = 0; i < dim; i++) {
        composite[i] += emb[i];
      }
    }

    return l2Normalize(composite);
  }

  final Map<String, List<double>> _cachedEmbeddings = {};

  // ===========================================================================
  // SECURE STORAGE / IN-MEMORY TEMPLATE CACHING METHODS
  // ===========================================================================

  /// Safely parses an embedding JSON string or list into `List<double>`
  List<double>? parseEmbeddingString(dynamic raw) {
    if (raw == null) return null;
    if (raw is List) {
      return raw.map((e) => (e as num).toDouble()).toList();
    }
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty || trimmed == 'false' || trimmed == 'null') return null;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List) {
          return decoded.map((e) => (e as num).toDouble()).toList();
        }
      } catch (e) {
        log('⚠️ [FaceVerificationService] Error parsing face embedding string: $e');
      }
    }
    return null;
  }

  /// Key format scoped strictly by account ID to ensure complete template isolation.
  String _storageKeyForAccount(String accountId) => 'face_embedding_$accountId';

  /// Checks if the given account has an enrolled face template (in memory or secure storage).
  Future<bool> hasEnrolledFace(String accountId) async {
    if (_cachedEmbeddings.containsKey(accountId) && _cachedEmbeddings[accountId]!.isNotEmpty) {
      return true;
    }
    final raw = await _secureStorage.read(key: _storageKeyForAccount(accountId));
    return raw != null && raw.isNotEmpty;
  }

  /// Retrieves the enrolled 192-dim template for the given account.
  /// Checks fast in-memory cache first, then falls back to secure storage.
  Future<List<double>?> getEnrolledEmbedding(String accountId) async {
    if (_cachedEmbeddings.containsKey(accountId) && _cachedEmbeddings[accountId]!.isNotEmpty) {
      return _cachedEmbeddings[accountId];
    }

    final raw = await _secureStorage.read(key: _storageKeyForAccount(accountId));
    if (raw == null || raw.isEmpty) return null;

    try {
      final List<dynamic> decoded = jsonDecode(raw);
      final embedding = decoded.map((e) => (e as num).toDouble()).toList();
      _cachedEmbeddings[accountId] = embedding;
      return embedding;
    } catch (e) {
      log('❌ [FaceVerificationService] Corrupted face template for $accountId: $e');
      return null;
    }
  }

  /// Saves the enrolled 192-dim template for the given account in both memory and secure storage.
  Future<void> saveEnrolledEmbedding(String accountId, List<double> embedding) async {
    if (embedding.length != embeddingDim) {
      throw ArgumentError('Expected $embeddingDim-dimensional embedding, got ${embedding.length}');
    }
    final normalized = l2Normalize(embedding);
    _cachedEmbeddings[accountId] = normalized;
    final jsonStr = jsonEncode(normalized);
    await _secureStorage.write(key: _storageKeyForAccount(accountId), value: jsonStr);
    log('💾 [FaceVerificationService] Enrolled template saved securely for account: $accountId (${embedding.length} dims)');
  }

  /// Deletes the enrolled face template for the given account.
  Future<void> deleteEnrolledFace(String accountId) async {
    _cachedEmbeddings.remove(accountId);
    await _secureStorage.delete(key: _storageKeyForAccount(accountId));
    log('🗑️ [FaceVerificationService] Enrolled template deleted for account: $accountId');
  }

  /// Verifies a live face embedding against the enrolled template for the active account.
  Future<FaceVerificationMatchResult> verifyAgainstEnrolled({
    required String accountId,
    required List<double> liveEmbedding,
    double threshold = defaultSimilarityThreshold,
  }) async {
    final enrolledTemplate = await getEnrolledEmbedding(accountId);
    if (enrolledTemplate == null) {
      return const FaceVerificationMatchResult(
        isMatch: false,
        similarity: 0.0,
        threshold: defaultSimilarityThreshold,
        message: 'Face verification is required for attendance. Please complete face enrollment first.',
      );
    }

    final similarity = computeCosineSimilarity(liveEmbedding, enrolledTemplate);
    final isMatch = similarity >= threshold;

    if (kDebugMode) {
      log('🔍 [FaceVerificationService] 1:1 Match result for account $accountId:');
      log('   Similarity: ${similarity.toStringAsFixed(4)} | Threshold: $threshold | Pass: $isMatch');
    }

    return FaceVerificationMatchResult(
      isMatch: isMatch,
      similarity: similarity,
      threshold: threshold,
      message: isMatch
          ? 'Face verification succeeded.'
          : 'Face verification failed. The detected face does not match the logged-in employee.',
    );
  }

  /// Releases TFLite interpreter resources cleanly.
  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    log('🧹 [FaceVerificationService] Interpreter closed and resources released.');
  }
}
