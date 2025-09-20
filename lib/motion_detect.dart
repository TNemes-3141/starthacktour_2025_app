// lib/motion_detect.dart
import 'dart:typed_data';
import 'dart:math' as math;
import 'sort.dart';

class MotionDetector {
  MotionDetector({
    required this.srcWidth,
    required this.srcHeight,
    this.smallW = 160,
    this.smallH = 90,
    this.alphaBg = 0.08,    // Slower background learning
    this.alphaFg = 0.005,   // Much slower where mask==1 (prevents ghosting)
    this.baseThresh = 25,   // Slightly higher base threshold
    this.temporalN = 5,     // Longer history for stability
    this.temporalVotes = 4, // More votes required (higher confidence)
    this.minBlobArea = 80,  // Larger minimum blob area
    this.maxBlobs = 32,     // Fewer max blobs
    this.morphIters = 2,    // More morphological operations
    this.stabilityFrames = 30, // Frames to wait before detection starts
    this.motionThresholdArea = 150, // Minimum area for motion consideration
    this.aspectRatioFilter = true,  // Filter out very thin/wide objects
  }) : _bg = Float32List(smallW * smallH),
       _curr = Float32List(smallW * smallH),
       _prev = Float32List(smallW * smallH),
       _mask = Uint8List(smallW * smallH),
       _maskStab = Uint8List(smallW * smallH),
       _tmp = Uint8List(smallW * smallH),
       _tmp2 = Uint8List(smallW * smallH),
       _visited = Uint8List(smallW * smallH),
       _hist = List.generate(7, (_) => Uint8List(smallW * smallH)), // ring > N
       _frameBuffer = List.generate(3, (_) => Float32List(smallW * smallH));

  final double alphaBg, alphaFg;
  final int baseThresh;
  final int temporalN, temporalVotes;
  final int stabilityFrames;
  final int motionThresholdArea;
  final bool aspectRatioFilter;

  final Uint8List _mask, _maskStab, _tmp, _tmp2, _visited;
  final List<Uint8List> _hist;
  final List<Float32List> _frameBuffer;
  int _histPtr = 0;
  int _frameBufferPtr = 0;

  final int srcWidth, srcHeight;
  final int smallW, smallH;
  final int minBlobArea;
  final int maxBlobs;
  final int morphIters;

  final Float32List _bg;
  final Float32List _curr;
  final Float32List _prev;

  bool _initialized = false;
  int _frameCount = 0;

  /// Process one frame's Y plane (grayscale) and return detections in source coords.
  List<Det> processYPlane(Uint8List yBytes, int strideY) {
    _downsampleY(yBytes, strideY);

    if (!_initialized) {
      for (int i = 0; i < _bg.length; i++) {
        _bg[i] = _curr[i];
        _prev[i] = _curr[i];
      }
      _initialized = true;
      _frameCount = 0;
      return const <Det>[];
    }

    _frameCount++;
    
    // Wait for stabilization period before detecting
    if (_frameCount < stabilityFrames) {
      _updateBackgroundSelective();
      _prev.setAll(0, _curr);
      return const <Det>[];
    }

    // Store current frame in circular buffer for temporal analysis
    final currentBuffer = _frameBuffer[_frameBufferPtr];
    currentBuffer.setAll(0, _curr);
    _frameBufferPtr = (_frameBufferPtr + 1) % _frameBuffer.length;

    // 1) Multi-frame difference + adaptive threshold → _mask
    _makeForegroundMaskWithTemporalDiff();

    // 2) Temporal majority voting over last N frames → _maskStab
    _pushHistoryAndVote();

    // 3) Enhanced morphological cleanup
    _enhancedMorphologicalCleanup();

    // 4) Noise reduction filter
    _noiseReductionFilter();

    // 5) Find blobs with enhanced filtering
    final rectsSmall = _findBlobsWithFiltering();

    // 6) Selective background update (slow where fg)
    _updateBackgroundSelective();

    // 7) Update previous frame
    _prev.setAll(0, _curr);

    // 8) Scale up and return
    final scaleX = srcWidth / smallW, scaleY = srcHeight / smallH;
    final out = <Det>[];
    for (final r in rectsSmall) {
      out.add(Det(r.x * scaleX, r.y * scaleY, r.w * scaleX, r.h * scaleY));
      if (out.length >= maxBlobs) break;
    }
    return out;
  }

  // --- Enhanced helper methods -----------------------------------------------

  void _downsampleY(Uint8List yBytes, int strideY) {
    final fx = srcWidth / smallW;
    final fy = srcHeight / smallH;
    int idx = 0;
    for (int sy = 0; sy < smallH; sy++) {
      final ySrc = ((sy + 0.5) * fy).floor();
      final rowOff = ySrc * strideY;
      for (int sx = 0; sx < smallW; sx++) {
        final xSrc = ((sx + 0.5) * fx).floor().clamp(0, srcWidth - 1);
        final v = yBytes[rowOff + xSrc];
        _curr[idx++] = v.toDouble();
      }
    }
  }

  void _makeForegroundMaskWithTemporalDiff() {
    final n = _curr.length;
    
    // Compute background difference and frame-to-frame difference
    final bgDiffs = Float32List(n);
    final frameDiffs = Float32List(n);
    
    for (int i = 0; i < n; i++) {
      bgDiffs[i] = (_curr[i] - _bg[i]).abs();
      frameDiffs[i] = (_curr[i] - _prev[i]).abs();
    }

    // Compute adaptive thresholds using robust statistics
    final bgThresh = _computeAdaptiveThreshold(bgDiffs);
    final frameThresh = _computeAdaptiveThreshold(frameDiffs) * 0.8; // Slightly more sensitive

    // Use OR logic for better sensitivity - either diff can trigger
    for (int i = 0; i < n; i++) {
      final bgMotion = bgDiffs[i] >= bgThresh;
      final frameMotion = frameDiffs[i] >= frameThresh;
      
      // Use OR instead of AND for better sensitivity
      _mask[i] = (bgMotion || frameMotion) ? 255 : 0;
    }
  }

  double _computeAdaptiveThreshold(Float32List diffs) {
    // Create histogram for percentile calculation
    final hist = List<int>.filled(256, 0);
    for (int i = 0; i < diffs.length; i++) {
      final d = diffs[i].toInt().clamp(0, 255);
      hist[d]++;
    }

    // Use 75th percentile for moderate sensitivity
    int cum = 0;
    final target = (diffs.length * 0.75).toInt();
    for (int v = 0; v < 256; v++) {
      cum += hist[v];
      if (cum >= target) {
        return math.max(baseThresh.toDouble(), v * 1.0); // Less conservative multiplier
      }
    }
    return baseThresh.toDouble();
  }

  void _enhancedMorphologicalCleanup() {
    // Multiple iterations of opening and closing for better noise removal
    for (int k = 0; k < morphIters; k++) {
      // Opening: erode then dilate (removes small noise)
      _erode3x3(_maskStab, _tmp);
      _dilate3x3(_tmp, _tmp2);
      
      // Closing: dilate then erode (fills small gaps)
      _dilate3x3(_tmp2, _tmp);
      _erode3x3(_tmp, _maskStab);
    }
  }

  void _noiseReductionFilter() {
    // Apply median-like filter to reduce salt-and-pepper noise
    final w = smallW, h = smallH;
    _tmp.setAll(0, _maskStab);
    
    for (int y = 1; y < h - 1; y++) {
      for (int x = 1; x < w - 1; x++) {
        final idx = y * w + x;
        
        // Count neighbors
        int whiteCount = 0;
        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            if (_tmp[(y + dy) * w + (x + dx)] >= 128) {
              whiteCount++;
            }
          }
        }
        
        // Keep pixel only if it has sufficient support from neighbors
        _maskStab[idx] = (whiteCount >= 4) ? 255 : 0;
      }
    }
  }

  List<_RectI> _findBlobsWithFiltering() {
    final w = smallW, h = smallH;
    _visited.fillRange(0, _visited.length, 0);
    final out = <_RectI>[];
    final stackX = List<int>.filled(w * h, 0);
    final stackY = List<int>.filled(w * h, 0);

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final idx = y * w + x;
        if (_maskStab[idx] == 0 || _visited[idx] != 0) continue;

        int top = 0;
        stackX[top] = x;
        stackY[top] = y;
        top++;
        _visited[idx] = 1;
        int minX = x, minY = y, maxX = x, maxY = y, area = 0;

        while (top > 0) {
          top--;
          final cx = stackX[top], cy = stackY[top];
          area++;
          if (cx < minX) minX = cx;
          if (cy < minY) minY = cy;
          if (cx > maxX) maxX = cx;
          if (cy > maxY) maxY = cy;

          for (int ny = cy - 1; ny <= cy + 1; ny++) {
            if (ny < 0 || ny >= h) continue;
            for (int nx = cx - 1; nx <= cx + 1; nx++) {
              if (nx < 0 || nx >= w) continue;
              final nidx = ny * w + nx;
              if (_maskStab[nidx] == 0 || _visited[nidx] != 0) continue;
              _visited[nidx] = 1;
              stackX[top] = nx;
              stackY[top] = ny;
              top++;
            }
          }
        }

        // Enhanced filtering
        if (_isValidBlob(area, minX, minY, maxX, maxY)) {
          out.add(_RectI(minX, minY, maxX - minX + 1, maxY - minY + 1));
          if (out.length >= maxBlobs) return out;
        }
      }
    }
    return out;
  }

  bool _isValidBlob(int area, int minX, int minY, int maxX, int maxY) {
    // Basic area filter
    if (area < minBlobArea) return false;
    
    final width = maxX - minX + 1;
    final height = maxY - minY + 1;
    
    // Basic size filters - more permissive
    if (width < 2 || height < 2) return false; // Very small
    if (width > smallW * 0.9 || height > smallH * 0.9) return false; // Very large
    
    // More permissive aspect ratio filter (only if enabled)
    if (aspectRatioFilter) {
      final aspectRatio = width > height ? width / height : height / width;
      if (aspectRatio > 8.0) return false; // Very elongated
    }
    
    // More permissive density filter
    final bboxArea = width * height;
    final density = area.toDouble() / bboxArea;
    if (density < 0.1) return false; // Very sparse
    
    return true; // Remove edge position filter for now
  }

  void _pushHistoryAndVote() {
    // Write current mask into ring buffer
    final dst = _hist[_histPtr];
    dst.setAll(0, _mask);
    _histPtr = (_histPtr + 1) % _hist.length;

    // Simple majority voting over last temporalN buffers
    final n = _curr.length;
    _maskStab.fillRange(0, n, 0);
    
    for (int i = 0; i < n; i++) {
      int votes = 0;
      
      for (int k = 0; k < temporalN; k++) {
        final idx = (_histPtr - 1 - k);
        final buf = _hist[(idx < 0 ? idx + _hist.length : idx)];
        
        if (buf[i] >= 128) {
          votes++;
        }
      }
      
      // Simple majority voting
      _maskStab[i] = (votes >= temporalVotes) ? 255 : 0;
    }
  }

  void _updateBackgroundSelective() {
    final n = _bg.length;
    for (int i = 0; i < n; i++) {
      final a = (_maskStab[i] == 0) ? alphaBg : alphaFg;
      _bg[i] = (1.0 - a) * _bg[i] + a * _curr[i];
    }
  }

  void _erode3x3(Uint8List src, Uint8List dst) {
    final w = smallW, h = smallH;
    for (int y = 0; y < h; y++) {
      final y0 = (y > 0) ? y - 1 : y;
      final y1 = y;
      final y2 = (y < h - 1) ? y + 1 : y;
      for (int x = 0; x < w; x++) {
        final x0 = (x > 0) ? x - 1 : x;
        final x1 = x;
        final x2 = (x < w - 1) ? x + 1 : x;
        int minv = 255;
        minv = _min(minv, src[y0 * w + x0]);
        minv = _min(minv, src[y0 * w + x1]);
        minv = _min(minv, src[y0 * w + x2]);
        minv = _min(minv, src[y1 * w + x0]);
        minv = _min(minv, src[y1 * w + x1]);
        minv = _min(minv, src[y1 * w + x2]);
        minv = _min(minv, src[y2 * w + x0]);
        minv = _min(minv, src[y2 * w + x1]);
        minv = _min(minv, src[y2 * w + x2]);
        dst[y * w + x] = minv;
      }
    }
  }

  void _dilate3x3(Uint8List src, Uint8List dst) {
    final w = smallW, h = smallH;
    for (int y = 0; y < h; y++) {
      final y0 = (y > 0) ? y - 1 : y;
      final y1 = y;
      final y2 = (y < h - 1) ? y + 1 : y;
      for (int x = 0; x < w; x++) {
        final x0 = (x > 0) ? x - 1 : x;
        final x1 = x;
        final x2 = (x < w - 1) ? x + 1 : x;
        int maxv = 0;
        maxv = _max(maxv, src[y0 * w + x0]);
        maxv = _max(maxv, src[y0 * w + x1]);
        maxv = _max(maxv, src[y0 * w + x2]);
        maxv = _max(maxv, src[y1 * w + x0]);
        maxv = _max(maxv, src[y1 * w + x1]);
        maxv = _max(maxv, src[y1 * w + x2]);
        maxv = _max(maxv, src[y2 * w + x0]);
        maxv = _max(maxv, src[y2 * w + x1]);
        maxv = _max(maxv, src[y2 * w + x2]);
        dst[y * w + x] = maxv;
      }
    }
  }

  int _min(int a, int b) => a < b ? a : b;
  int _max(int a, int b) => a > b ? a : b;
}

class _RectI {
  _RectI(this.x, this.y, this.w, this.h);
  final int x, y, w, h;
}