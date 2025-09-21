/// Represents one row in `public.object_updates`.
class DbRecord {
  final String objectId;       // corresponds to trackId (stringified)
  final DateTime timestamp;    // with TZ info
  final double bboxTop;
  final double bboxLeft;
  final double bboxBottom;
  final double bboxRight;
  final String objectClass;    // "class" is reserved in Dart
  final double? speedMps;
  final double? distanceM;
  final double? latitude;
  final double? longitude;
  final String snapshotPath;   // local/relative path to saved screenshot
  final String? snapshotUrl;   // if uploaded externally (e.g. S3)
  final double confidence;     // detection confidence

  DbRecord({
    required this.objectId,
    required this.timestamp,
    required this.bboxTop,
    required this.bboxLeft,
    required this.bboxBottom,
    required this.bboxRight,
    required this.objectClass,
    required this.snapshotPath,
    required this.confidence,
    this.speedMps,
    this.distanceM,
    this.latitude,
    this.longitude,
    this.snapshotUrl,
  });
}


Map<String, dynamic> dbRowFromRecord(
  DbRecord r, {
  String? snapshotPath,
  String? snapshotUrl,
}) {
  return {
    // ---- Key columns (match quoted camelCase in your schema) ----
    "objectId": r.objectId,
    "timestamp": r.timestamp.toUtc().toIso8601String(), // timestamptz
    "bboxTop": r.bboxTop,
    "bboxLeft": r.bboxLeft,
    "bboxBottom": r.bboxBottom,
    "bboxRight": r.bboxRight,
    "class": r.objectClass,
    "speedMps": r.speedMps,
    "distanceM": r.distanceM,
    "latitude": r.latitude,
    "longitude": r.longitude,

    // Snapshot: use overrides if provided (i.e., upload result), else record’s own
    "snapshotPath": snapshotPath ?? r.snapshotPath, // NOT NULL in schema
    "snapshotUrl": snapshotUrl ?? r.snapshotUrl,    // nullable

    // Confidence has a DB default, but we send the value to be explicit
    "confidence": r.confidence,
  };
}