import 'dart:math';

/// Represents a single tracked object with its properties.
class Track {
  final int id;
  List<double> box; // Bounding box [x1, y1, x2, y2]
  String label;
  double score;

  /// A simple velocity vector [vx, vy] representing the change in the box center.
  List<double>? _velocity;

  /// How many consecutive frames this track has been seen and matched.
  /// We use this to confirm a track and avoid displaying fleeting false positives.
  int hits = 0;

  /// How many consecutive frames this track has been missed by the detector.
  int framesSinceSeen = 0;
  
  /// How many frames this track has existed.
  int age = 0;

  Track({
    required this.id,
    required this.box,
    required this.label,
    required this.score,
  }) {
    hits = 1;
  }

  /// Predicts the next bounding box position based on the current velocity.
  List<double> predict() {
    if (_velocity == null) return box;
    return [
      box[0] + _velocity![0],
      box[1] + _velocity![1],
      box[2] + _velocity![0],
      box[3] + _velocity![1],
    ];
  }

  /// Updates the track's state with a new detection.
  void update(List<double> newBox, double newScore, String newLabel) {
    // Calculate velocity based on the change in the center point of the box.
    final oldCenter = [(box[0] + box[2]) / 2, (box[1] + box[3]) / 2];
    final newCenter = [(newBox[0] + newBox[2]) / 2, (newBox[1] + newBox[3]) / 2];
    _velocity = [newCenter[0] - oldCenter[0], newCenter[1] - oldCenter[1]];

    // Update properties with the new detection
    box = newBox;
    score = newScore;
    label = newLabel;
    hits++;
    framesSinceSeen = 0;
  }
}

/// A simple tracker that uses IoU matching and motion prediction.
class ObjectTracker {
  final List<Track> _tracks = [];
  int _nextId = 0;

  /// Maximum number of frames a track can be missed before it's deleted.
  final int maxFramesToDisappear;

  /// The minimum IoU threshold for matching a detection with an existing track.
  final double iouThreshold;

  /// The minimum number of consecutive hits before a track is considered "confirmed"
  /// and returned. This helps filter out noisy, one-off detections.
  final int minHitsToConfirm;

  ObjectTracker({
    this.maxFramesToDisappear = 15,
    this.iouThreshold = 0.3,
    this.minHitsToConfirm = 3,
  });

  /// Returns the current list of confirmed, active tracks.
  List<Track> get tracks => _tracks.where((t) => t.hits >= minHitsToConfirm).toList();

  /// Updates the tracker with a new set of detections from a video frame.
  void update(List<Map<String, dynamic>> detections) {
    // 1. Predict the next state for all existing tracks.
    final List<List<double>> predictedBoxes = _tracks.map((t) => t.predict()).toList();

    final Set<int> matchedTrackIndices = {};
    final Set<int> matchedDetectionIndices = {};
    
    // 2. Match detections to existing tracks using the predicted boxes.
    if (predictedBoxes.isNotEmpty) {
      for (int i = 0; i < detections.length; i++) {
        final detBox = (detections[i]['box'] as List).sublist(0, 4).map((e) => (e as num).toDouble()).toList();
        double bestIoU = 0.0;
        int bestTrackIndex = -1;

        for (int j = 0; j < _tracks.length; j++) {
          if (matchedTrackIndices.contains(j)) continue;

          final iou = _calculateIoU(detBox, predictedBoxes[j]);
          if (iou > bestIoU) {
            bestIoU = iou;
            bestTrackIndex = j;
          }
        }

        if (bestIoU > iouThreshold) {
          final matchedDet = detections[i];
          _tracks[bestTrackIndex].update(
            detBox,
            ((matchedDet['box'] as List)[4] as num).toDouble(),
            matchedDet['tag'].toString(),
          );
          matchedTrackIndices.add(bestTrackIndex);
          matchedDetectionIndices.add(i);
        }
      }
    }
    
    // 3. Handle unmatched tracks and detections.
    for (int i = 0; i < _tracks.length; i++) {
      if (!matchedTrackIndices.contains(i)) {
        _tracks[i].framesSinceSeen++;
      }
      _tracks[i].age++;
    }

    for (int i = 0; i < detections.length; i++) {
      if (!matchedDetectionIndices.contains(i)) {
        _tracks.add(_createTrackFromDetection(detections[i]));
      }
    }

    // 4. Remove old tracks that have been lost for too long.
    _tracks.removeWhere((track) => track.framesSinceSeen > maxFramesToDisappear);
  }

  Track _createTrackFromDetection(Map<String, dynamic> detection) {
    final box = (detection['box'] as List);
    return Track(
      id: _nextId++,
      box: box.sublist(0, 4).map((e) => (e as num).toDouble()).toList(),
      score: (box.length > 4 ? box[4] as num : 0.0).toDouble(),
      label: detection['tag'].toString(),
    );
  }

  double _calculateIoU(List<double> boxA, List<double> boxB) {
    final double xA = max(boxA[0], boxB[0]);
    final double yA = max(boxA[1], boxB[1]);
    final double xB = min(boxA[2], boxB[2]);
    final double yB = min(boxA[3], boxB[3]);

    final double intersectionArea = max(0, xB - xA) * max(0, yB - yA);
    if (intersectionArea == 0) return 0.0;

    final double boxAArea = (boxA[2] - boxA[0]) * (boxA[3] - boxA[1]);
    final double boxBArea = (boxB[2] - boxB[0]) * (boxB[3] - boxB[1]);

    final double unionArea = boxAArea + boxBArea - intersectionArea;
    return unionArea > 0 ? intersectionArea / unionArea : 0.0;
  }
}