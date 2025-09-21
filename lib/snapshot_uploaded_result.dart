class SnapshotUploadResult {
  final String objectPath; // e.g. images/<uid>/<date>/snapshot_...jpg (no leading bucket unless you add it)
  final String publicUrl;  // or signed URL if you use private bucket
  SnapshotUploadResult({required this.objectPath, required this.publicUrl});
}