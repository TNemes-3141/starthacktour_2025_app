import './coordinate_transformer.dart';

class _CoordSample {
  final ObjectCoordinates coord;
  final DateTime ts;
  _CoordSample(this.coord, this.ts);
}

class TrackedState {
  // Ring buffer of recent samples to compute speed robustly
  final List<_CoordSample> _history = [];
  // Exponential moving average of speed (m/s)
  double? emaSpeedMps;

  // Keep last computed 3D displacement components (optional, for debugging)
  double? lastDxMeters;
  double? lastDyMeters;
  double? lastDzMeters;

  // Add a sample; keep at most maxLen
  void addSample(ObjectCoordinates c, DateTime t, {int maxLen = 20}) {
    _history.add(_CoordSample(c, t));
    if (_history.length > maxLen) _history.removeAt(0);
  }

  int get sampleCount => _history.length;
  List<_CoordSample> get history => _history;
}