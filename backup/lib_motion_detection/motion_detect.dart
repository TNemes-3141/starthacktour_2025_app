// lib/motion_detect.dart
import 'dart:typed_data';
import 'sort.dart';

class MotionDetector {
  MotionDetector({
    required this.srcWidth,
    required this.srcHeight,
    this.smallW = 160,
    this.smallH = 90,
    this.alphaBg = 0.12, // bg learning where mask==0
    this.alphaFg = 0.02, // MUCH slower where mask==1 (prevents ghosting)
    this.baseThresh = 22, // base intensity threshold
    this.temporalN = 3, // history length
    this.temporalVotes = 2, // majority votes required
    this.minBlobArea = 30,
    this.maxBlobs = 64,
    this.morphIters = 1,
  }) : _bg = Float32List(smallW * smallH),
       _curr = Float32List(smallW * smallH),
       _mask = Uint8List(smallW * smallH),
       _maskStab = Uint8List(smallW * smallH),
       _tmp = Uint8List(smallW * smallH),
       _visited = Uint8List(smallW * smallH),
       _hist = List.generate(5, (_) => Uint8List(smallW * smallH)); // ring > N

  final double alphaBg, alphaFg;
  final int baseThresh;
  final int temporalN, temporalVotes;

  final Uint8List _mask, _maskStab, _tmp, _visited;
  final List<Uint8List> _hist;
  int _histPtr = 0;

  final int srcWidth, srcHeight;
  final int smallW, smallH;
  final int minBlobArea;
  final int maxBlobs;
  final int morphIters;

  final Float32List _bg;
  final Float32List _curr;

  bool _initialized = false;

  /// Process one frame’s Y plane (grayscale) and return detections in source coords.
  /// [yBytes] is the Y plane, [strideY] is bytesPerRow from CameraImage.
  List<Det> processYPlane(Uint8List yBytes, int strideY) {
    _downsampleY(yBytes, strideY);

    if (!_initialized) {
      for (int i = 0; i < _bg.length; i++) {
        _bg[i] = _curr[i];
      }
      _initialized = true;
      return const <Det>[];
    }

    // 1) Diff + adaptive threshold → _mask
    _makeForegroundMaskAdaptive();

    // 2) Temporal majority voting over last N frames → _maskStab
    _pushHistoryAndVote();

    // 3) Morphological cleanup: CLOSE then OPEN (fills gaps, removes salt)
    for (int k = 0; k < morphIters; k++) {
      _dilate3x3(_maskStab, _tmp);
      _erode3x3(_tmp, _maskStab);
    }
    for (int k = 0; k < morphIters; k++) {
      _erode3x3(_maskStab, _tmp);
      _dilate3x3(_tmp, _maskStab);
    }

    // 4) Blobs from _maskStab
    final rectsSmall = _findBlobsFrom(_maskStab);

    // 5) Selective background update (slow where fg)
    _updateBackgroundSelective();

    // 6) Scale up and return
    final scaleX = srcWidth / smallW, scaleY = srcHeight / smallH;
    final out = <Det>[];
    for (final r in rectsSmall) {
      out.add(Det(r.x * scaleX, r.y * scaleY, r.w * scaleX, r.h * scaleY));
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

  void _makeForegroundMaskAdaptive() {
    // Compute absolute diff + robust threshold (base + k*MAD)
    // Cheap MAD: median(|curr - bg|) approximated by percentile via histogram.
    final n = _curr.length;
    // build small histogram of diffs (0..255)
    final hist = List<int>.filled(256, 0);
    for (int i = 0; i < n; i++) {
      final d = (_curr[i] - _bg[i]).abs().toInt().clamp(0, 255);
      hist[d]++;
    }
    // 75th percentile for adaptivity
    int cum = 0, p75 = 0, target = (n * 0.75).toInt();
    for (int v = 0; v < 256; v++) {
      cum += hist[v];
      if (cum >= target) {
        p75 = v;
        break;
      }
    }
    final thr = (baseThresh + (0.3 * p75)).clamp(8, 80).toInt();

    for (int i = 0; i < n; i++) {
      final d = (_curr[i] - _bg[i]).abs();
      _mask[i] = (d >= thr) ? 255 : 0;
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

  void _pushHistoryAndVote() {
    // write current mask into ring buffer
    final dst = _hist[_histPtr];
    dst.setAll(0, _mask);
    _histPtr = (_histPtr + 1) % _hist.length;

    // vote over last temporalN buffers
    final n = _curr.length;
    _maskStab.fillRange(0, n, 0);
    for (int i = 0; i < n; i++) {
      int votes = 0;
      for (int k = 0; k < temporalN; k++) {
        final idx = (_histPtr - 1 - k);
        final buf = _hist[(idx < 0 ? idx + _hist.length : idx)];
        // treat 255 as 1 vote
        votes += (buf[i] >= 128) ? 1 : 0;
      }
      _maskStab[i] = (votes >= temporalVotes) ? 255 : 0;
    }
  }

  void _updateBackgroundSelective() {
    final n = _bg.length;
    for (int i = 0; i < n; i++) {
      final a = (_maskStab[i] == 0)
          ? alphaBg
          : alphaFg; // slower where foreground
      _bg[i] = (1.0 - a) * _bg[i] + a * _curr[i];
    }
  }

  // Variants to use custom source masks
  List<_RectI> _findBlobsFrom(Uint8List mask) {
    final w = smallW, h = smallH;
    _visited.fillRange(0, _visited.length, 0);
    final out = <_RectI>[];
    final stackX = List<int>.filled(w * h, 0);
    final stackY = List<int>.filled(w * h, 0);

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final idx = y * w + x;
        if (mask[idx] == 0 || _visited[idx] != 0) continue;

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
              if (mask[nidx] == 0 || _visited[nidx] != 0) continue;
              _visited[nidx] = 1;
              stackX[top] = nx;
              stackY[top] = ny;
              top++;
            }
          }
        }
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
