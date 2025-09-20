// lib/sort.dart
import 'dart:math';

class Det {
  Det(this.x, this.y, this.w, this.h, {this.score = 1.0});
  double x, y, w, h, score;
  
  // Helper to get center point
  double get centerX => x + w / 2;
  double get centerY => y + h / 2;
  double get area => w * h;
}

class Track {
  Track(this.id, this.bbox)
      : vx = 0,
        vy = 0,
        age = 1,
        hits = 1,
        timeSinceUpdate = 0,
        confidence = 1.0,
        _motionHistory = <double>[],
        _sizeHistory = <double>[],
        _positionHistory = <List<double>>[];

  final int id;
  // bbox as [x,y,w,h] in source (camera) coordinates (not screen-scaled)
  List<double> bbox;
  double vx, vy; // velocity on top-left corner
  double confidence; // track confidence score
  int age;
  int hits;
  int timeSinceUpdate;
  
  // Motion analysis
  final List<double> _motionHistory;
  final List<double> _sizeHistory;
  final List<List<double>> _positionHistory;
  static const int _maxHistoryLength = 10;
  
  // Properties for filtering
  bool get isStationary {
    if (_motionHistory.length < 3) return false;
    final avgMotion = _motionHistory.reduce((a, b) => a + b) / _motionHistory.length;
    return avgMotion < 2.0; // Less than 2 pixels average movement
  }
  
  bool get hasConsistentSize {
    if (_sizeHistory.length < 3) return true;
    final avgSize = _sizeHistory.reduce((a, b) => a + b) / _sizeHistory.length;
    final variance = _sizeHistory.map((s) => pow(s - avgSize, 2)).reduce((a, b) => a + b) / _sizeHistory.length;
    return sqrt(variance) < avgSize * 0.5; // Size variance should be < 50% of average
  }
  
  double get avgSpeed {
    if (_motionHistory.length < 2) return 0.0;
    return _motionHistory.reduce((a, b) => a + b) / _motionHistory.length;
  }

  void predict() {
    // Apply velocity with some damping
    bbox[0] += vx;
    bbox[1] += vy;
    
    age += 1;
    timeSinceUpdate += 1;
    
    // Decay confidence over time without updates
    confidence *= 0.95;
    
    // More aggressive damping to prevent drift
    vx *= 0.85;
    vy *= 0.85;
  }

  void update(Det d) {
    // Calculate motion metrics
    final motionMagnitude = sqrt(pow(d.x - bbox[0], 2) + pow(d.y - bbox[1], 2));
    _motionHistory.add(motionMagnitude);
    if (_motionHistory.length > _maxHistoryLength) {
      _motionHistory.removeAt(0);
    }
    
    // Track size changes
    _sizeHistory.add(d.area);
    if (_sizeHistory.length > _maxHistoryLength) {
      _sizeHistory.removeAt(0);
    }
    
    // Track position history
    _positionHistory.add([d.centerX, d.centerY]);
    if (_positionHistory.length > _maxHistoryLength) {
      _positionHistory.removeAt(0);
    }
    
    // Update velocity with momentum-based smoothing
    final newVx = d.x - bbox[0];
    final newVy = d.y - bbox[1];
    
    // More conservative velocity update for stable tracking
    vx = 0.3 * newVx + 0.7 * vx;
    vy = 0.3 * newVy + 0.7 * vy;

    // Update bbox
    bbox = [d.x, d.y, d.w, d.h];
    
    hits += 1;
    timeSinceUpdate = 0;
    
    // Boost confidence on update, but cap it
    confidence = min(1.0, confidence + 0.2);
  }
  
  // Check if track appears to be valid based on motion patterns
  bool isValidTrack() {
    if (hits < 2) return true; // Give new tracks more chance
    
    // More lenient stationary object filtering
    if (hits > 8 && isStationary && avgSpeed < 0.3) return false;
    
    // Only filter very inconsistent sizes
    if (hits > 5 && !hasConsistentSize) {
      final avgSize = _sizeHistory.reduce((a, b) => a + b) / _sizeHistory.length;
      final variance = _sizeHistory.map((s) => pow(s - avgSize, 2)).reduce((a, b) => a + b) / _sizeHistory.length;
      if (sqrt(variance) > avgSize * 0.8) return false; // Very inconsistent
    }
    
    return true;
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

// Enhanced distance metric combining IoU with size and motion consistency
double _enhancedDistance(Track track, Det detection) {
  final trackBbox = track.bbox;
  final detBbox = [detection.x, detection.y, detection.w, detection.h];
  
  // Base IoU score
  final iou = _iou(trackBbox, detBbox);
  if (iou == 0) return 0.0;
  
  // Size consistency bonus
  final trackArea = trackBbox[2] * trackBbox[3];
  final detArea = detection.w * detection.h;
  final sizeRatio = min(trackArea, detArea) / max(trackArea, detArea);
  
  // Motion prediction bonus
  final predictedX = trackBbox[0] + track.vx;
  final predictedY = trackBbox[1] + track.vy;
  final predictionError = sqrt(pow(detection.x - predictedX, 2) + pow(detection.y - predictedY, 2));
  final maxDimension = max(detection.w, detection.h);
  final motionBonus = max(0.0, 1.0 - (predictionError / maxDimension));
  
  // Combined score with weights
  return iou * 0.6 + sizeRatio * 0.2 + motionBonus * 0.2;
}

class SortTracker {
  SortTracker({
    this.iouThreshold = 0.25,    // Slightly lower for better matching
    this.maxAge = 8,             // Shorter max age to remove stale tracks faster
    this.minHits = 3,            // Require more hits for confidence
    this.minDetectionScore = 0.5, // Minimum detection score to consider
    this.maxTracksPerFrame = 20,  // Limit total tracks
  });

  final double iouThreshold;
  final int maxAge;
  final int minHits;
  final double minDetectionScore;
  final int maxTracksPerFrame;

  final List<Track> _tracks = [];
  int _nextId = 1;
  int _frameCount = 0;

  /// Update with detections for this frame.
  /// Returns active tracks that meet quality criteria.
  List<Track> update(List<Det> detections) {
    _frameCount++;
    
    // Filter detections by score and basic sanity checks
    final validDetections = detections.where((d) => 
      d.score >= minDetectionScore && 
      d.w > 5 && d.h > 5 &&    // Lower minimum size
      d.w < 2000 && d.h < 2000 // Higher maximum size
    ).toList();
    
    // Limit detections to prevent explosion of tracks
    if (validDetections.length > maxTracksPerFrame) {
      validDetections.sort((a, b) => b.score.compareTo(a.score));
      validDetections.removeRange(maxTracksPerFrame, validDetections.length);
    }
    
    // 1) predict all tracks forward
    for (final t in _tracks) {
      t.predict();
    }

    // 2) Enhanced matching using combined distance metric
    final unmatchedTracks = <int>{for (var i=0; i<_tracks.length; i++) i};
    final unmatchedDets = <int>{for (var i=0; i<validDetections.length; i++) i};
    final matches = <MapEntry<int,int>>[];

    // Build enhanced distance scores
    final scores = <Tuple>[];
    for (var ti = 0; ti < _tracks.length; ti++) {
      for (var di = 0; di < validDetections.length; di++) {
        final score = _enhancedDistance(_tracks[ti], validDetections[di]);
        if (score >= iouThreshold) {
          scores.add(Tuple(ti, di, score));
        }
      }
    }
    
    // Greedy pick highest scoring pairs
    scores.sort((a,b) => b.iou.compareTo(a.iou));
    for (final s in scores) {
      if (unmatchedTracks.contains(s.ti) && unmatchedDets.contains(s.di)) {
        matches.add(MapEntry(s.ti, s.di));
        unmatchedTracks.remove(s.ti);
        unmatchedDets.remove(s.di);
      }
    }

    // 3) update matched tracks with detections
    for (final m in matches) {
      final track = _tracks[m.key];
      final det = validDetections[m.value];
      track.update(det);
    }

    // 4) create tracks for unmatched detections (be more permissive)
    for (final di in unmatchedDets) {
      final d = validDetections[di];
      
      // More permissive filtering for new tracks
      if (d.w * d.h > 50 && d.score > 0.3) { // Lower requirements
        _tracks.add(Track(_nextId++, [d.x, d.y, d.w, d.h]));
      }
    }

    // 5) Enhanced track pruning
    _tracks.removeWhere((t) => 
      t.timeSinceUpdate > maxAge || 
      !t.isValidTrack() ||
      t.confidence < 0.1
    );
    
    // Limit total number of tracks
    if (_tracks.length > maxTracksPerFrame) {
      _tracks.sort((a, b) => b.confidence.compareTo(a.confidence));
      _tracks.removeRange(maxTracksPerFrame, _tracks.length);
    }

    // 6) return only confirmed tracks with lower confidence threshold
    final validTracks = _tracks.where((t) => 
      t.hits >= minHits && 
      t.confidence > 0.2 &&  // Lower confidence threshold
      t.isValidTrack()
    ).toList(growable: false);
    
    // Sort by confidence for consistent ordering
    validTracks.sort((a, b) => b.confidence.compareTo(a.confidence));
    
    return validTracks;
  }
  
  // Reset tracker state (useful for scene changes)
  void reset() {
    _tracks.clear();
    _nextId = 1;
    _frameCount = 0;
  }
  
  // Get statistics about current tracking state
  Map<String, dynamic> getStats() {
    final activeTracks = _tracks.where((t) => t.hits >= minHits).length;
    final totalTracks = _tracks.length;
    final avgConfidence = _tracks.isEmpty ? 0.0 : 
        _tracks.map((t) => t.confidence).reduce((a, b) => a + b) / _tracks.length;
    
    return {
      'activeTracks': activeTracks,
      'totalTracks': totalTracks,
      'avgConfidence': avgConfidence,
      'frameCount': _frameCount,
    };
  }
}

class Tuple {
  Tuple(this.ti, this.di, this.iou);
  final int ti;
  final int di;
  final double iou;
}