// lib/motion_video.dart
import 'dart:async';
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'snapshot_object_result.dart';

import 'motion_detect.dart';
import 'sort.dart';

class MotionVideo extends StatefulWidget {
  const MotionVideo({super.key});
  @override
  State<MotionVideo> createState() => _MotionVideoState();
}

class _MotionVideoState extends State<MotionVideo> with WidgetsBindingObserver {
  late CameraController _controller;
  bool _isLoaded = false;
  bool _isDetecting = false;
  bool _busy = false;
  CameraImage? _lastImage;

  // New: toggle for classification
  bool _classificationEnabled = true;

  // New: notification text (defaults as requested)
  String _notificationText = 'No relevant objects';

  // New: key to snapshot the preview + overlays
  final GlobalKey _previewKey = GlobalKey();

  MotionDetector? _md; // <— add this
  final int _frameSkip = 1; // process every frame; set to 2/3 if too slow
  int _counter = 0;

  // tracking
  final _tracker = SortTracker(iouThreshold: 0.3, maxAge: 10, minHits: 2);
  List<Track> _tracks = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    final cams = await availableCameras();
    final back = cams.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cams.first,
    );
    _controller = CameraController(
      back,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    await _controller.initialize();

    if (mounted) setState(() => _isLoaded = true);
  }

  Future<void> _start() async {
    if (_controller.value.isStreamingImages) return;
    _isDetecting = true;
    await _controller.startImageStream((image) async {
      if (!_isDetecting) return;
      _lastImage = image;

      // Init detector on first frame (Dart-only)
      _md ??= MotionDetector(
        srcWidth: image.width,
        srcHeight: image.height,
        smallW: 160,
        smallH: 90,
        alpha: 0.10,
        thresh: 25,
        minBlobArea: 40,
        morphIters: 1,
      );

      if (_busy) return;
      // Optional frame skipping for speed
      _counter = (_counter + 1) % _frameSkip;
      if (_counter != 0) return;

      _busy = true;
      try {
        // Gate heavy processing behind the classification toggle if desired.
        // If motion detection should always run, remove this 'if'.
        if (_classificationEnabled) {
          final dets = await _detectMotionDart(image);
          _tracks = _tracker.update(dets);

          // Example: update the notification text (customize as needed)
          if (_tracks.isEmpty) {
            _notificationText = 'No relevant objects';
          } else {
            _notificationText = 'Tracking ${_tracks.length} object(s)';
          }
        } else {
          // If classification is off, clear tracks (or keep last known – your call)
          _tracks = [];
          _notificationText = 'Classification disabled';
        }

        if (mounted) setState(() {});
      } finally {
        _busy = false;
      }
    });
    if (mounted) setState(() {});
  }

  Future<void> _stop() async {
    _isDetecting = false;
    if (_controller.value.isStreamingImages) {
      await _controller.stopImageStream();
    }
    _tracks = [];
    if (mounted) setState(() {});
  }

  Future<List<Det>> _detectMotionDart(CameraImage img) async {
    // Use Y plane only
    final y = img.planes[0].bytes;
    final strideY = img.planes[0].bytesPerRow;
    return _md!.processYPlane(y, strideY);
  }

  /// NEW: Snapshot the RepaintBoundary (camera + overlays) and save as PNG.
  Future<void> _takeSnapshot() async {
    try {
      final boundary =
          _previewKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) {
        throw Exception('Preview not ready');
      }

      final pixelRatio = MediaQuery.of(context).devicePixelRatio;
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

      print("Uploading snapshot (JPG) to DB...");

      final result = await _uploadSnapshotToSupabase(
        Uint8List.fromList(jpgBytes),
      );

      if (!mounted) return;
      
      if (result != null) {
        // 2) Push dummy record into the DB
        await _insertDummyObjectUpdate(
          objectId:
              'dummy-001', // <— for POC; later use your Track.id.toString()
          snapshotPath: result.objectPath, // stored path in bucket
          snapshotUrl: result.publicUrl, // public/signed URL
        );

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Uploaded & recorded to DB')),
        );

        setState(() {
          _notificationText = 'Uploaded: ${result.publicUrl}';
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Upload completed (no URL)')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Snapshot upload failed: $e')));
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

  Future<void> _insertDummyObjectUpdate({
    required String objectId,
    required String snapshotPath,
    required String snapshotUrl,
  }) async {
    final supa = Supabase.instance.client;

    // Example dummy values — replace with real ones from your tracker/GPS
    final now = DateTime.now().toUtc(); // timestamptz with ms
    final bboxTop = 0.10;
    final bboxLeft = 0.20;
    final bboxBottom = 0.55;
    final bboxRight = 0.70;

    final detectedClass = 'person';
    final speedMps = 1.23;
    final distanceM = 3.45;

    // If you don't have GPS yet, you can null these or use a default
    final latitude = 47.3769; // Zurich demo
    final longitude = 8.5417;

    await supa.from('object_updates').insert({
      'object_id': objectId,
      'timestamp': now.toIso8601String(), // or just pass DateTime.now().toUtc()
      'bbox_top': bboxTop,
      'bbox_left': bboxLeft,
      'bbox_bottom': bboxBottom,
      'bbox_right': bboxRight,
      'class': detectedClass,
      'speed_mps': speedMps,
      'distance_m': distanceM,
      'latitude': latitude,
      'longitude': longitude,
      'snapshot_path': snapshotPath, // e.g. <uid>/<date>/snapshot_...jpg
      'snapshot_url': snapshotUrl, // optional convenience
    });
  }

  Widget _playStopButton() {
    return Positioned(
      bottom: 16,
      left: 16,
      child: SizedBox(
        height: 56,
        width: 56,
        child: ElevatedButton(
          onPressed: _isDetecting ? _stop : _start,
          style: ElevatedButton.styleFrom(
            shape: const CircleBorder(),
            padding: EdgeInsets.zero,
          ),
          child: Icon(_isDetecting ? Icons.stop : Icons.play_arrow),
        ),
      ),
    );
  }

  Size _previewChildSize(BuildContext context) {
    final isPortrait =
        MediaQuery.of(context).orientation == Orientation.portrait;
    final pv = _controller.value.previewSize!; // this is landscape w>h
    // swap when in portrait so width < height
    final previewW = isPortrait ? pv.height : pv.width;
    final previewH = isPortrait ? pv.width : pv.height;
    return Size(previewW, previewH);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stop();
    _controller.dispose();
    super.dispose();
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
      final back = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      _controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await _controller.initialize();
      if (_isDetecting) await _start();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isLoaded) {
      return const Scaffold(body: Center(child: Text('Loading camera...')));
    }

    // New layout: Column with (1) preview, (2) controls row, (3) bottom notification
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // (1) Preview area with room beneath for controls/notification
            Expanded(
              child: Center(
                child: FittedBox(
                  fit: BoxFit.contain, // preserve aspect; no stretching
                  child: RepaintBoundary(
                    key: _previewKey,
                    child: Builder(
                      builder: (context) {
                        final childSize = _previewChildSize(context);
                        return SizedBox(
                          width: childSize.width,
                          height: childSize.height,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              CameraPreview(_controller),
                              ..._boxes(
                                childSize,
                              ), // <-- pass the SAME childSize
                              _playStopButton(),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),

            // (2) Controls row
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  // Snapshot button
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _takeSnapshot,
                      icon: const Icon(Icons.camera),
                      label: const Text('Snapshot'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Classification toggle
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Classification',
                        style: TextStyle(color: Colors.white),
                      ),
                      const SizedBox(width: 8),
                      Switch(
                        value: _classificationEnabled,
                        onChanged: (v) {
                          setState(() => _classificationEnabled = v);
                          // If disabling, you may also want to clear tracks:
                          // setState(() { _tracks = []; _notificationText = 'Classification disabled'; });
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // (3) Bottom notification window (reserved space with border)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white70),
                borderRadius: BorderRadius.circular(12),
                color: Colors.black.withOpacity(0.15),
              ),
              child: Text(
                _notificationText,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Rect _mapImageRectToRender(Rect rImg, Size renderSize) {
    final imgW = _lastImage!.width.toDouble();
    final imgH = _lastImage!.height.toDouble();

    // Most Android back cameras report 90 or 270
    final rotation = _controller.description.sensorOrientation;

    double rx, ry, rw, rh;
    if (rotation == 90) {
      // rotate 90° CW: (x,y,w,h) -> (ih - (y+h), x, h, w)
      rx = imgH - (rImg.top + rImg.height);
      ry = rImg.left;
      rw = rImg.height;
      rh = rImg.width;

      final fx = renderSize.width / imgH;
      final fy = renderSize.height / imgW;
      return Rect.fromLTWH(rx * fx, ry * fy, rw * fx, rh * fy);
    } else if (rotation == 270) {
      // rotate 90° CCW: (x,y,w,h) -> (y, iw - (x+w), h, w)
      rx = rImg.top;
      ry = imgW - (rImg.left + rImg.width);
      rw = rImg.height;
      rh = rImg.width;

      final fx = renderSize.width / imgH;
      final fy = renderSize.height / imgW;
      return Rect.fromLTWH(rx * fx, ry * fy, rw * fx, rh * fy);
    } else if (rotation == 0) {
      // landscape, no rotation
      final fx = renderSize.width / imgW;
      final fy = renderSize.height / imgH;
      return Rect.fromLTWH(
        rImg.left * fx,
        rImg.top * fy,
        rImg.width * fx,
        rImg.height * fy,
      );
    } else {
      // 180
      // upside-down landscape
      final fx = renderSize.width / imgW;
      final fy = renderSize.height / imgH;
      rx = imgW - (rImg.left + rImg.width);
      ry = imgH - (rImg.top + rImg.height);
      return Rect.fromLTWH(rx * fx, ry * fy, rImg.width * fx, rImg.height * fy);
    }
  }

  List<Widget> _boxes(Size renderSize) {
    if (_tracks.isEmpty || _lastImage == null) return [];

    return _tracks.map((t) {
      final rImg = Rect.fromLTWH(t.bbox[0], t.bbox[1], t.bbox[2], t.bbox[3]);
      final r = _mapImageRectToRender(rImg, renderSize);

      return Positioned(
        left: r.left,
        top: r.top,
        width: r.width,
        height: r.height,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(10)),
            border: Border.all(color: Colors.lightGreenAccent, width: 2),
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: const BoxDecoration(
                color: Color.fromARGB(200, 30, 30, 30),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(8),
                  bottomRight: Radius.circular(8),
                ),
              ),
              child: Text(
                "Track #${t.id}",
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      );
    }).toList();
  }
}
