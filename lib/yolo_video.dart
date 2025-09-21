import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_vision/flutter_vision.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'sort_tracker.dart';
import 'coordinate_transformer.dart';
import 'tracked_state.dart';
import 'geo_utils.dart';
import 'db_utils.dart';
import 'snapshot_uploaded_result.dart';

class YoloVideo extends StatefulWidget {
  const YoloVideo({super.key});

  @override
  State<YoloVideo> createState() => _YoloVideoState();
}

class _YoloVideoState extends State<YoloVideo> with WidgetsBindingObserver {
  late CameraController _controller;
  late FlutterVision _vision;
  late ObjectTracker _tracker;
  final GlobalKey _previewKey = GlobalKey();

  // Tracking state
  List<Track> _trackedObjects = [];
  final Map<int, TrackedState> _trackedState = {};
  CameraImage? _lastCameraImage;
  bool _isLoaded = false;
  bool _isDetecting = false;
  bool _isStartingStream = false;

  // For assigning a unique and persistent color to each track ID
  final Map<int, Color> _trackColors = {};
  final Random _random = Random();

  // Coordinate tracking properties (still calculated but not displayed)
  final Map<int, ObjectCoordinates> _objectCoordinates = {};
  final Map<int, double> _objectDistances =
      {}; // NEW: Store estimated distances
  CameraConfig? _cameraConfig;
  bool _showDistance = true; // Toggle for showing distance in UI

  DateTime? _lastSendAt;
  final Duration _minSendInterval = const Duration(seconds: 2);

  // Model and label paths
  static const String _labelsAsset = 'assets/labels.txt';
  static const String _modelAsset = 'assets/yolov8n_float32.tflite';
  static const String _modelVersion = 'yolov8';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    final cameras = await availableCameras();
    final useCam = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    _controller = CameraController(
      useCam,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await _controller.initialize();

    _vision = FlutterVision();
    await _loadYoloModel();

    // Initialize the object tracker with tuned parameters
    _tracker = ObjectTracker(
      maxFramesToDisappear: 5, // More forgiving for brief occlusions
      iouThreshold: 0.05, // Stricter matching to prevent ID swaps
      minHitsToConfirm: 2, // Requires 2 consecutive frames to show a box
    );

    // Initialize camera configuration
    _initCameraConfig();

    if (mounted) {
      setState(() => _isLoaded = true);
    }
  }

  // Initialize camera config
  void _initCameraConfig() {
    try {
      _cameraConfig = CoordinateTransformer.getCameraConfig();
      print(
        'Camera config loaded: ${_cameraConfig!.cameraLat}, ${_cameraConfig!.cameraLng}',
      );
    } catch (e) {
      print('Failed to load camera config: $e');
    }
  }

  Future<void> _loadYoloModel() async {
    await _vision.loadYoloModel(
      labels: _labelsAsset,
      modelPath: _modelAsset,
      modelVersion: _modelVersion,
      numThreads: 2,
      useGpu: true,
    );
  }

  // Calculate coordinates and distances for all tracked objects
  void _updateObjectCoordinatesAndDistances() {
    if (_cameraConfig == null) return;

    _objectCoordinates.clear();
    _objectDistances.clear();

    for (final track in _trackedObjects) {
      try {
        // Calculate distance using the new pinhole camera model
        final distance = CoordinateTransformer.estimateDistance(
          track.label,
          track.box,
          config: _cameraConfig,
        );
        _objectDistances[track.id] = distance;

        // Still calculate coordinates (needed for later use but not displayed)
        final coordinates = track.calculateCoordinatesFromPixels(
          config: _cameraConfig,
        );
        _objectCoordinates[track.id] = coordinates;
      } catch (e) {
        print(
          'Error calculating coordinates/distance for track ${track.id}: $e',
        );
      }
    }
  }

  /// Processes a single camera frame for object detection and tracking.
  Future<void> _processFrame(CameraImage cameraImage) async {
    final result = await _vision.yoloOnFrame(
      bytesList: cameraImage.planes.map((p) => p.bytes).toList(),
      imageHeight: cameraImage.height,
      imageWidth: cameraImage.width,
      iouThreshold: 0.05,
      confThreshold: 0.2,
      classThreshold: 0.2,
    );

    if (!mounted) return;

    // Update the tracker with the new detections from the frame.
    _tracker.update(result);

    // Update the UI state with the list of current tracks.
    setState(() {
      _trackedObjects = _tracker.tracks;
    });

    // Calculate coordinates and distances for all tracked objects
    _updateObjectCoordinatesAndDistances();

    final now = DateTime.now();
    if (_lastSendAt == null ||
        now.difference(_lastSendAt!) >= _minSendInterval) {
      _lastSendAt = now;
      processFrameAndMaybeSend();
    }
  }

  double? _updateObjectSpeedEma(
    int trackId, {
    int minSamples = 5,
    double alpha = 0.3,
  }) {
    final st = _trackedState[trackId];
    if (st == null || st.sampleCount < minSamples) return null;

    // Aggregate distance and time over all consecutive pairs (reduces noise)
    double totalDist = 0.0;
    double totalSecs = 0.0;
    for (var i = 1; i < st.history.length; i++) {
      final prev = st.history[i - 1];
      final cur = st.history[i];
      final dt = cur.ts.difference(prev.ts).inMilliseconds / 1000.0;
      if (dt <= 0) continue;
      final d = GeoUtils.distance3DMeters(prev.coord, cur.coord);
      totalDist += d;
      totalSecs += dt;

      // (Optional) stash last components for debugging
      // Approximate local dx,dy from lat/lon deltas (Equirectangular small-angle):
      final horiz = GeoUtils.haversineMeters(
        prev.coord.latitude,
        prev.coord.longitude,
        cur.coord.latitude,
        cur.coord.longitude,
      );
      st.lastDzMeters = cur.coord.height - prev.coord.height;
      st.lastDxMeters =
          horiz; // you can compute east/north components if needed
      st.lastDyMeters = 0; // left 0 for brevity in this skeleton
    }
    if (totalSecs <= 0) return st.emaSpeedMps;

    final avgSpeed = totalDist / totalSecs; // m/s over the whole window

    if (st.emaSpeedMps == null) {
      st.emaSpeedMps = avgSpeed;
    } else {
      st.emaSpeedMps = alpha * avgSpeed + (1 - alpha) * st.emaSpeedMps!;
    }
    return st.emaSpeedMps;
  }

  /// Call this once per frame after you update `_trackedObjects` and `_objectCoordinates`.
  Future<void> processFrameAndMaybeSend() async {
    final DateTime now = DateTime.now();

    final currentIds = <int>{};

    // 1) Update state for every track present this frame
    for (final tr in _trackedObjects) {
      currentIds.add(tr.id);

      final coords = _objectCoordinates[tr.id];
      if (coords == null) continue;
      final st = _trackedState.putIfAbsent(tr.id, () => TrackedState());
      st.addSample(coords, now);

      _updateObjectSpeedEma(tr.id);
    }

    // 2) Filter relevant objects present *in this frame*
    final List<DbRecord> recordsToSend = [];
    for (final tr in _trackedObjects) {
      final coords = _objectCoordinates[tr.id];
      if (coords == null) continue;

      final isLongLived = tr.hits >= 5; // seen in ≥5 frames
      final isRelevantClass = ObjectReferenceSizes.isRelevantLabel(tr.label);
      if (!isLongLived || !isRelevantClass) continue;

      // Pull current speed if available (null until ≥5 samples)
      final speed = _trackedState[tr.id]?.emaSpeedMps;

      // Prepare the DB payload record
      recordsToSend.add(
        DbRecord(
          objectId: tr.id.toString(),
          timestamp: now,
          bboxTop: tr.box[1],
          bboxLeft: tr.box[0],
          bboxBottom: tr.box[3],
          bboxRight: tr.box[2],
          objectClass: ObjectReferenceSizes.getDisplayName(tr.label),
          confidence: tr.score,
          snapshotPath: "", // decide path logic
          snapshotUrl: null, // if you upload separately, set it later
          speedMps: speed,
          distanceM: _objectDistances[tr.id],
          latitude: coords.latitude,
          longitude: coords.longitude,
        ),
      );
    }

    // 3) If any relevant objects: take ONE screenshot and send batch
    if (recordsToSend.isNotEmpty) {
      // Single capture for this frame
      final Uint8List? screenshot = await _takeScreenshot(); // implement below
      await _sendBatchToDatabase(recordsToSend, screenshot);
    }

    // 4) Cleanup state for tracks that vanished (optional but recommended)
    final idsToRemove = _trackedState.keys
        .where((id) => !currentIds.contains(id))
        .toList();
    for (final id in idsToRemove) {
      _trackedState.remove(id);
      // Also remove from any of your other per-track maps if needed
      _objectCoordinates.remove(id);
      _objectDistances.remove(id);
    }
  }

  Future<SnapshotUploadResult?> _uploadSnapshotToSupabase(
    Uint8List jpgBytes,
  ) async {
    final supa = Supabase.instance.client;

    // Ensure we have a user (anonymous is fine)
    if (supa.auth.currentUser == null) {
      await supa.auth.signInAnonymously();
    }

    final uid = supa.auth.currentUser?.id ?? 'anonymous';
    final now = DateTime.now();
    final date =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final ts = now.toIso8601String().replaceAll(':', '-');

    // Path inside bucket "images"
    final objectPath = '$uid/$date/snapshot_$ts.jpg';

    // Upload
    await supa.storage
        .from('images')
        .uploadBinary(
          objectPath,
          jpgBytes,
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: false,
          ),
        );

    // Public (or signed) URL
    final publicUrl = supa.storage.from('images').getPublicUrl(objectPath);

    return SnapshotUploadResult(objectPath: objectPath, publicUrl: publicUrl);
  }

  Future<void> _sendBatchToDatabase(
    List<DbRecord> recordsToSend,
    Uint8List? screenshot,
  ) async {
    if (recordsToSend.isEmpty) return;

    final supa = Supabase.instance.client;

    String? overrideSnapshotPath;
    String? overrideSnapshotUrl;

    try {
      // 1) Try to upload the single frame screenshot (optional)
      if (screenshot != null && screenshot.isNotEmpty) {
        final SnapshotUploadResult? upload = await _uploadSnapshotToSupabase(
          screenshot,
        );
        if (upload != null) {
          overrideSnapshotPath = upload.objectPath;
          overrideSnapshotUrl = upload.publicUrl;
        }
      }

      // 2) Build rows for Supabase with correct column names (camelCase)
      final rows = recordsToSend.map((r) {
        return dbRowFromRecord(
          r,
          // If we got a shared upload path/url, apply to all rows
          snapshotPath: overrideSnapshotPath ?? r.snapshotPath,
          snapshotUrl: overrideSnapshotUrl ?? r.snapshotUrl,
        );
      }).toList();

      // 3) Insert batch
      await supa.from('object_updates').insert(rows);
    } catch (e, st) {
      // Handle/log as you prefer (snackbar, logger, crashlytics, etc.)
      debugPrint('Failed to send batch to database: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to store object updates: $e')),
        );
      }
    }
  }

  Future<Uint8List?> _takeScreenshot() async {
    try {
      final boundary =
          _previewKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) {
        throw Exception('Preview not ready');
      }

      final dpr = MediaQuery.of(context).devicePixelRatio;
      final pixelRatio = dpr * 0.5;
      final ui.Image image = await boundary.toImage(pixelRatio: pixelRatio);
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (byteData == null) throw Exception('Failed to get RGBA data');

      final rgbaBytes = byteData.buffer.asUint8List();
      final baseSizeImage = img.Image.fromBytes(
        width: image.width,
        height: image.height,
        bytes: rgbaBytes.buffer,
        order: img.ChannelOrder.rgba,
      );

      // Compress to JPG with quality 80
      final jpgBytes = img.encodeJpg(baseSizeImage, quality: 80);

      return Uint8List.fromList(jpgBytes);
    } catch (e) {
      if (!mounted) return null;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Snapshot capture failed: $e')));
      return null;
    }
  }

  Future<void> _startDetection() async {
    if (_isStartingStream || _controller.value.isStreamingImages) return;
    setState(() {
      _isDetecting = true;
      _isStartingStream = true;
    });
    await _controller.startImageStream((image) async {
      if (!_isDetecting) return;
      _lastCameraImage = image;
      if (!_inferenceInProgress) {
        _inferenceInProgress = true;
        try {
          await _processFrame(image);
        } finally {
          _inferenceInProgress = false;
        }
      }
    });
    if (mounted) {
      setState(() => _isStartingStream = false);
    }
  }

  Future<void> _stopDetection() async {
    if (!_controller.value.isStreamingImages) {
      setState(() => _isDetecting = false);
      return;
    }
    setState(() {
      _isDetecting = false;
      _trackedObjects.clear();
      _trackColors.clear();
      // Clear coordinate and distance cache
      _objectCoordinates.clear();
      _objectDistances.clear();
      // Re-initialize the tracker to reset its state (e.g., nextId)
      _tracker = ObjectTracker(
        maxFramesToDisappear: 5,
        iouThreshold: 0.05,
        minHitsToConfirm: 2,
      );
    });
    await _controller.stopImageStream();
  }

  bool _inferenceInProgress = false;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _teardown();
    super.dispose();
  }

  Future<void> _teardown() async {
    try {
      if (_controller.value.isStreamingImages) {
        await _controller.stopImageStream();
      }
      _trackedObjects.clear();
      // Clear coordinate and distance cache
      _objectCoordinates.clear();
      _objectDistances.clear();
    } catch (_) {}
    await _controller.dispose();
    try {
      await _vision.closeYoloModel();
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (!_controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      if (_controller.value.isStreamingImages) {
        await _controller.stopImageStream();
      }
      await _controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      final cams = await availableCameras();
      final useCam = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      _controller = CameraController(
        useCam,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await _controller.initialize();
      if (_isDetecting) {
        await _startDetection();
      }
      if (mounted) setState(() {});
    }
  }

  /// Gets a persistent color for a given track ID.
  Color _getColorForTrack(int trackId) {
    return _trackColors.putIfAbsent(trackId, () {
      // Generate a random, bright color.
      return Color.fromARGB(
        255,
        _random.nextInt(200) + 55,
        _random.nextInt(200) + 55,
        _random.nextInt(200) + 55,
      );
    });
  }

  // Get distance info for display
  String _getDistanceInfo(Track track) {
    final distance = _objectDistances[track.id];
    if (distance == null || !_showDistance) return '';

    return '\nDist: ${distance.toStringAsFixed(1)}m';
  }

  // Print all coordinates and distances (useful for debugging/logging)
  void _printAllCoordinatesAndDistances() {
    print('\n=== Object Tracking Data ===');
    for (final track in _trackedObjects) {
      final coords = _objectCoordinates[track.id];
      final distance = _objectDistances[track.id];
      if (coords != null && distance != null) {
        // Use display name for logging
        final displayName = ObjectReferenceSizes.getDisplayName(track.label);
        print(
          '$displayName ID:${track.id} -> Distance: ${distance.toStringAsFixed(1)}m, $coords',
        );
      }
    }
    print('===========================\n');
  }

  /// Displays the bounding boxes for all tracked objects.
  List<Widget> _displayTrackedBoxes(Size screen) {
    if (_trackedObjects.isEmpty || _lastCameraImage == null) return [];

    final factorX = screen.width / _lastCameraImage!.height;
    final factorY = screen.height / _lastCameraImage!.width;

    return _trackedObjects.map((track) {
      final box = track.box;
      final color = _getColorForTrack(track.id);
      // Include distance info if enabled
      final distanceInfo = _getDistanceInfo(track);
      // Get display name for UI
      final displayName = ObjectReferenceSizes.getDisplayName(track.label);

      return Positioned(
        left: box[0] * factorX,
        top: box[1] * factorY,
        width: (box[2] - box[0]) * factorX,
        height: (box[3] - box[1]) * factorY,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            border: Border.all(color: color, width: 2.5),
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: color,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(6),
                  bottomRight: Radius.circular(6),
                ),
              ),
              child: Text(
                "$displayName ID: ${track.id} (${(track.score * 100).toStringAsFixed(0)}%)$distanceInfo",
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11, // Slightly larger since we have less text
                  fontWeight: FontWeight.bold,
                  shadows: [
                    Shadow(
                      color: Colors.black,
                      blurRadius: 4,
                      offset: Offset(1, 1),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isLoaded) {
      return const Scaffold(
        body: Center(child: Text('Loading model & camera...')),
      );
    }

    final size = MediaQuery.of(context).size;
    return Scaffold(
      body: RepaintBoundary(
        key: _previewKey,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_controller.value.isInitialized)
              AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: CameraPreview(_controller),
              )
            else
              const Center(child: CircularProgressIndicator()),

            ..._displayTrackedBoxes(size),

            // Distance toggle button (replaces coordinate toggle)
            Positioned(
              top: 50,
              right: 20,
              child: FloatingActionButton(
                mini: true,
                backgroundColor: _showDistance ? Colors.blue : Colors.grey,
                onPressed: () {
                  setState(() {
                    _showDistance = !_showDistance;
                  });
                },
                child: const Icon(Icons.straighten, color: Colors.white),
              ),
            ),

            // Print coordinates and distances button (for debugging)
            Positioned(
              top: 100,
              right: 20,
              child: FloatingActionButton(
                mini: true,
                backgroundColor: Colors.green,
                onPressed: _printAllCoordinatesAndDistances,
                child: const Icon(Icons.print, color: Colors.white),
              ),
            ),

            Positioned(
              bottom: 48,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  height: 80,
                  width: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      width: 5,
                      color: Colors.white,
                      style: BorderStyle.solid,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        spreadRadius: 2,
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: _isDetecting
                      ? IconButton(
                          onPressed: _stopDetection,
                          icon: const Icon(
                            Icons.stop_rounded,
                            color: Colors.red,
                          ),
                          iconSize: 50,
                        )
                      : IconButton(
                          onPressed: _startDetection,
                          icon: const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                          ),
                          iconSize: 50,
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
