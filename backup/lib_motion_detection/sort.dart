// lib/sort.dart
import 'dart:math';

class Det {
  Det(this.x, this.y, this.w, this.h, {this.score = 1.0});
  double x, y, w, h, score;
}

class Track {
  Track(this.id, this.bbox)
      : vx = 0,
        vy = 0,
        age = 1,
        hits = 1,
        timeSinceUpdate = 0;

  final int id;
  // bbox as [x,y,w,h] in source (camera) coordinates (not screen-scaled)
  List<double> bbox;
  double vx, vy; // simple velocity on top-left corner
  int age;
  int hits;
  int timeSinceUpdate;

  void predict() {
    bbox[0] += vx;
    bbox[1] += vy;
    age += 1;
    timeSinceUpdate += 1;
    // mild damping so predictions don't drift forever
    vx *= 0.9;
    vy *= 0.9;
  }

  void update(Det d) {
    // velocity from last update
    final newVx = d.x - bbox[0];
    final newVy = d.y - bbox[1];
    // EMA smoothing for velocity
    vx = 0.6 * newVx + 0.4 * vx;
    vy = 0.6 * newVy + 0.4 * vy;

    bbox = [d.x, d.y, d.w, d.h];
    hits += 1;
    timeSinceUpdate = 0;
  }
}

double _iou(List<double> a, List<double> b) {
  final ax1 = a[0], ay1 = a[1], ax2 = a[0] + a[2], ay2 = a[1] + a[3];
  final bx1 = b[0], by1 = b[1], bx2 = b[0] + b[2], by2 = b[1] + b[3];
  final ix1 = max(ax1, bx1);
  final iy1 = max(ay1, by1);
  final ix2 = min(ax2, bx2);
  final iy2 = min(ay2, by2);
  final iw = max(0.0, ix2 - ix1);
  final ih = max(0.0, iy2 - iy1);
  final inter = iw * ih;
  final ua = a[2]*a[3] + b[2]*b[3] - inter;
  if (ua <= 0) return 0.0;
  return inter / ua;
}

class SortTracker {
  SortTracker({
    this.iouThreshold = 0.3,
    this.maxAge = 10,     // frames to keep a track without seeing it
    this.minHits = 2,     // only display tracks with >= minHits
  });

  final double iouThreshold;
  final int maxAge;
  final int minHits;

  final List<Track> _tracks = [];
  int _nextId = 1;

  /// Update with detections for this frame.
  /// Returns active tracks that have at least [minHits] and age gating.
  List<Track> update(List<Det> detections) {
    // 1) predict all tracks forward
    for (final t in _tracks) {
      t.predict();
    }

    // 2) match detections to predicted tracks by greedy IoU
    final unmatchedTracks = <int>{for (var i=0; i<_tracks.length; i++) i};
    final unmatchedDets = <int>{for (var i=0; i<detections.length; i++) i};
    final matches = <MapEntry<int,int>>[];

    // Build all IoUs
    final ious = <Tuple>[];
    for (var ti = 0; ti < _tracks.length; ti++) {
      for (var di = 0; di < detections.length; di++) {
        final iou = _iou(_tracks[ti].bbox, [detections[di].x, detections[di].y, detections[di].w, detections[di].h]);
        if (iou >= iouThreshold) {
          ious.add(Tuple(ti, di, iou));
        }
      }
    }
    // Greedy pick highest IoU pairs
    ious.sort((a,b) => b.iou.compareTo(a.iou));
    for (final t in ious) {
      if (unmatchedTracks.contains(t.ti) && unmatchedDets.contains(t.di)) {
        matches.add(MapEntry(t.ti, t.di));
        unmatchedTracks.remove(t.ti);
        unmatchedDets.remove(t.di);
      }
    }

    // 3) update matched tracks with detections
    for (final m in matches) {
      final track = _tracks[m.key];
      final det = detections[m.value];
      track.update(det);
    }

    // 4) create tracks for unmatched detections
    for (final di in unmatchedDets) {
      final d = detections[di];
      _tracks.add(Track(_nextId++, [d.x, d.y, d.w, d.h]));
    }

    // 5) cull stale tracks
    _tracks.removeWhere((t) => t.timeSinceUpdate > maxAge);

    // 6) return only confirmed tracks (minHits), but keep all internally
    return _tracks.where((t) => t.hits >= minHits).toList(growable: false);
  }
}

class Tuple {
  Tuple(this.ti, this.di, this.iou);
  final int ti;
  final int di;
  final double iou;
}
