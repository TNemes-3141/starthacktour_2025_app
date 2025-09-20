// lib/motion_detect.dart
import 'dart:typed_data';
import 'sort.dart';

class MotionDetector {
  MotionDetector({
    required this.srcWidth,
    required this.srcHeight,
    this.smallW = 160,
    this.smallH = 90,
    this.alpha = 0.1,        // background update rate
    this.thresh = 25,        // intensity threshold on [0..255]
    this.minBlobArea = 40,   // in downscaled pixels (e.g. 40 => ~ small blobs)
    this.maxBlobs = 64,      // safety cap
    this.morphIters = 1,     // 3x3 opening iterations
  })  : _bg = Float32List(smallW * smallH),
        _curr = Float32List(smallW * smallH),
        _mask = Uint8List(smallW * smallH),
        _tmp = Uint8List(smallW * smallH),
        _visited = Uint8List(smallW * smallH);

  final int srcWidth, srcHeight;
  final int smallW, smallH;
  final double alpha;
  final int thresh;
  final int minBlobArea;
  final int maxBlobs;
  final int morphIters;

  final Float32List _bg;
  final Float32List _curr;
  final Uint8List _mask;
  final Uint8List _tmp;
  final Uint8List _visited;

  bool _initialized = false;

  /// Process one frame’s Y plane (grayscale) and return detections in source coords.
  /// [yBytes] is the Y plane, [strideY] is bytesPerRow from CameraImage.
  List<Det> processYPlane(Uint8List yBytes, int strideY) {
    // 1) Downsample Y to small grid (nearest-neighbor for speed)
    _downsampleY(yBytes, strideY);

    // 2) Init background on first call
    if (!_initialized) {
      for (int i = 0; i < _bg.length; i++) {
        _bg[i] = _curr[i];
      }
      _initialized = true;
      return const <Det>[];
    }

    // 3) Diff + threshold -> _mask
    _makeForegroundMask();

    // 4) Morphological opening (erode then dilate) to clean noise
    for (int k = 0; k < morphIters; k++) {
      _erode3x3(_mask, _tmp);
      _dilate3x3(_tmp, _mask);
    }

    // 5) Connected components → bounding boxes (in small space)
    final rectsSmall = _findBlobs();

    // 6) Update background (EMA)
    for (int i = 0; i < _bg.length; i++) {
      _bg[i] = (1.0 - alpha) * _bg[i] + alpha * _curr[i];
    }

    // 7) Scale rects up to source coords
    final scaleX = srcWidth / smallW;
    final scaleY = srcHeight / smallH;
    final out = <Det>[];
    for (final r in rectsSmall) {
      final x = r.x * scaleX;
      final y = r.y * scaleY;
      final w = r.w * scaleX;
      final h = r.h * scaleY;
      out.add(Det(x, y, w, h, score: 1.0));
      if (out.length >= maxBlobs) break;
    }
    return out;
  }

  // --- helpers ----------------------------------------------------------------

  void _downsampleY(Uint8List yBytes, int strideY) {
    // Map small grid pixel (sx,sy) -> source (x,y)
    // We pick centers: (sx + 0.5) * (srcW/smallW)
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

  void _makeForegroundMask() {
    final n = _curr.length;
    for (int i = 0; i < n; i++) {
      final d = (_curr[i] - _bg[i]).abs();
      _mask[i] = (d >= thresh) ? 255 : 0;
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

  List<_RectI> _findBlobs() {
    // Flood-fill connected components on _mask (8-neighborhood)
    final w = smallW, h = smallH;
    _visited.fillRange(0, _visited.length, 0);
    final out = <_RectI>[];
    final stackX = List<int>.filled(w * h, 0);
    final stackY = List<int>.filled(w * h, 0);

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final idx = y * w + x;
        if (_mask[idx] == 0 || _visited[idx] != 0) continue;

        // start flood
        int top = 0;
        stackX[top] = x;
        stackY[top] = y;
        top++;
        _visited[idx] = 1;

        int minX = x, minY = y, maxX = x, maxY = y;
        int area = 0;

        while (top > 0) {
          top--;
          final cx = stackX[top];
          final cy = stackY[top];
          area++;

          if (cx < minX) minX = cx;
          if (cy < minY) minY = cy;
          if (cx > maxX) maxX = cx;
          if (cy > maxY) maxY = cy;

          // 8 neighbors
          for (int ny = cy - 1; ny <= cy + 1; ny++) {
            if (ny < 0 || ny >= h) continue;
            for (int nx = cx - 1; nx <= cx + 1; nx++) {
              if (nx < 0 || nx >= w) continue;
              final nidx = ny * w + nx;
              if (_mask[nidx] == 0 || _visited[nidx] != 0) continue;
              _visited[nidx] = 1;
              stackX[top] = nx;
              stackY[top] = ny;
              top++;
              if (top >= stackX.length) break;
            }
          }
        }

        // keep blobs over min area
        if (area >= minBlobArea) {
          out.add(_RectI(minX, minY, maxX - minX + 1, maxY - minY + 1));
          if (out.length >= maxBlobs) return out;
        }
      }
    }
    return out;
  }

  int _min(int a, int b) => a < b ? a : b;
  int _max(int a, int b) => a > b ? a : b;
}

class _RectI {
  _RectI(this.x, this.y, this.w, this.h);
  final int x, y, w, h;
}
