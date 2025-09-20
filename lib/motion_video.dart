// lib/motion_video.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/rendering.dart';

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

  // Detection controls
  bool _classificationEnabled = true;
  bool _showDebugInfo = false;

  // Enhanced notification system
  String _notificationText = 'No motion detected';
  Color _notificationColor = Colors.white;

  // Snapshot key
  final GlobalKey _previewKey = GlobalKey();

  MotionDetector? _md;
  final int _frameSkip = 1; // Process every frame for better responsiveness
  int _counter = 0;

  // Enhanced tracking with statistics
  late SortTracker _tracker;
  List<Track> _tracks = [];
  Map<String, dynamic> _trackerStats = {};

  // Performance monitoring
  DateTime? _lastFrameTime;
  double _fps = 0.0;
  int _processedFrames = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    // Initialize balanced tracker
    _tracker = SortTracker(
      iouThreshold: 0.20,      // Lower threshold for better matching
      maxAge: 6,               // Moderate track lifetime
      minHits: 2,              // Lower hit requirement
      minDetectionScore: 0.3,  // Lower score threshold
      maxTracksPerFrame: 20,
    );
    
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
    _processedFrames = 0;
    
    await _controller.startImageStream((image) async {
      if (!_isDetecting) return;
      _lastImage = image;

      // Initialize detector with balanced parameters
      _md ??= MotionDetector(
        srcWidth: image.width,
        srcHeight: image.height,
        smallW: 160,
        smallH: 90,
        alphaBg: 0.10,           // Moderate background learning
        alphaFg: 0.01,           // Slower where foreground detected
        baseThresh: 27,          // Lower base threshold for sensitivity
        temporalN: 6,            // Shorter temporal window
        temporalVotes: 4,        // Fewer votes required
        minBlobArea: 80,         // Smaller minimum blob
        morphIters: 1,           // Less morphological cleanup
        stabilityFrames: 15,     // Shorter stabilization period
        motionThresholdArea: 100, // Lower motion threshold
        aspectRatioFilter: false, // Disable for now
      );

      if (_busy) return;
      
      // Frame skipping for performance
      _counter = (_counter + 1) % _frameSkip;
      if (_counter != 0) return;

      _busy = true;
      final frameTime = DateTime.now();
      
      try {
        if (_classificationEnabled) {
          final dets = await _detectMotionDart(image);
          _tracks = _tracker.update(dets);
          _trackerStats = _tracker.getStats();

          // Enhanced notification system
          _updateNotificationText();
        } else {
          _tracks = [];
          _trackerStats = {};
          _notificationText = 'Detection disabled';
          _notificationColor = Colors.grey;
        }

        // Update FPS calculation
        _updateFPS(frameTime);

        if (mounted) setState(() {});
      } finally {
        _busy = false;
      }
    });
    if (mounted) setState(() {});
  }

  void _updateNotificationText() {
    if (_tracks.isEmpty) {
      _notificationText = 'No motion detected';
      _notificationColor = Colors.white;
    } else {
      final activeCount = _tracks.length;
      final avgSpeed = _tracks.isNotEmpty 
          ? _tracks.map((t) => t.avgSpeed).reduce((a, b) => a + b) / _tracks.length
          : 0.0;
      
      _notificationText = 'Tracking $activeCount object(s) - Avg speed: ${avgSpeed.toStringAsFixed(1)}px/frame';
      
      // Color based on activity level
      if (avgSpeed > 5.0) {
        _notificationColor = Colors.green;
      } else if (avgSpeed > 2.0) {
        _notificationColor = Colors.yellow;
      } else {
        _notificationColor = Colors.orange;
      }
    }
  }

  void _updateFPS(DateTime frameTime) {
    _processedFrames++;
    if (_lastFrameTime != null) {
      final deltaMs = frameTime.difference(_lastFrameTime!).inMilliseconds;
      if (deltaMs > 0) {
        _fps = _fps * 0.9 + (1000.0 / deltaMs) * 0.1; // Smoothed FPS
      }
    }
    _lastFrameTime = frameTime;
  }

  Future<void> _stop() async {
    _isDetecting = false;
    if (_controller.value.isStreamingImages) {
      await _controller.stopImageStream();
    }
    _tracks = [];
    _trackerStats = {};
    if (mounted) setState(() {});
  }

  Future<void> _reset() async {
    _tracker.reset();
    _md = null; // Force re-initialization
    _tracks = [];
    _trackerStats = {};
    _processedFrames = 0;
    _fps = 0.0;
    _notificationText = 'Detection reset';
    _notificationColor = Colors.blue;
    if (mounted) setState(() {});
  }

  Future<List<Det>> _detectMotionDart(CameraImage img) async {
    final y = img.planes[0].bytes;
    final strideY = img.planes[0].bytesPerRow;
    return _md!.processYPlane(y, strideY);
  }

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
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw Exception('Failed to encode image');

      final bytes = byteData.buffer.asUint8List();
      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
      final file = File('${dir.path}/motion_snapshot_$ts.png');
      await file.writeAsBytes(bytes);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Snapshot saved: ${file.path}'))
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Snapshot failed: $e'))
      );
    }
  }

  Widget _buildControlButtons() {
    return Positioned(
      bottom: 16,
      left: 16,
      right: 16,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Main control row
          Row(
            children: [
              // Play/Stop button
              SizedBox(
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
              const SizedBox(width: 12),
              
              // Reset button
              SizedBox(
                height: 56,
                width: 56,
                child: ElevatedButton(
                  onPressed: _reset,
                  style: ElevatedButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                  ),
                  child: const Icon(Icons.refresh),
                ),
              ),
              const SizedBox(width: 12),
              
              // Snapshot button (expanded to fill remaining space)
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: ElevatedButton.icon(
                    onPressed: _takeSnapshot,
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('Snapshot'),
                  ),
                ),
              ),
            ],
          ),
          
          // Secondary controls
          if (_showDebugInfo) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  Text(
                    'FPS: ${_fps.toStringAsFixed(1)} | Frames: $_processedFrames',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  if (_trackerStats.isNotEmpty) ...[
                    Text(
                      'Active: ${_trackerStats['activeTracks']} | Total: ${_trackerStats['totalTracks']}',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    Text(
                      'Confidence: ${(_trackerStats['avgConfidence'] * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Size _previewChildSize(BuildContext context) {
    final isPortrait =
        MediaQuery.of(context).orientation == Orientation.portrait;
    final pv = _controller.value.previewSize!;
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

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Preview area
            Expanded(
              child: Center(
                child: FittedBox(
                  fit: BoxFit.contain,
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
                              ..._boxes(childSize),
                              _buildControlButtons(),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),

            // Control panel
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  // Detection toggle
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Detection',
                        style: TextStyle(color: Colors.white),
                      ),
                      const SizedBox(width: 8),
                      Switch(
                        value: _classificationEnabled,
                        onChanged: (v) => setState(() => _classificationEnabled = v),
                      ),
                    ],
                  ),
                  const Spacer(),
                  
                  // Debug info toggle
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Debug',
                        style: TextStyle(color: Colors.white),
                      ),
                      const SizedBox(width: 8),
                      Switch(
                        value: _showDebugInfo,
                        onChanged: (v) => setState(() => _showDebugInfo = v),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Status notification
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              decoration: BoxDecoration(
                border: Border.all(color: _notificationColor.withOpacity(0.7)),
                borderRadius: BorderRadius.circular(12),
                color: Colors.black.withOpacity(0.15),
              ),
              child: Text(
                _notificationText,
                style: TextStyle(color: _notificationColor),
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
    final rotation = _controller.description.sensorOrientation;

    double rx, ry, rw, rh;
    if (rotation == 90) {
      rx = imgH - (rImg.top + rImg.height);
      ry = rImg.left;
      rw = rImg.height;
      rh = rImg.width;

      final fx = renderSize.width / imgH;
      final fy = renderSize.height / imgW;
      return Rect.fromLTWH(rx * fx, ry * fy, rw * fx, rh * fy);
    } else if (rotation == 270) {
      rx = rImg.top;
      ry = imgW - (rImg.left + rImg.width);
      rw = rImg.height;
      rh = rImg.width;

      final fx = renderSize.width / imgH;
      final fy = renderSize.height / imgW;
      return Rect.fromLTWH(rx * fx, ry * fy, rw * fx, rh * fy);
    } else if (rotation == 0) {
      final fx = renderSize.width / imgW;
      final fy = renderSize.height / imgH;
      return Rect.fromLTWH(
        rImg.left * fx,
        rImg.top * fy,
        rImg.width * fx,
        rImg.height * fy,
      );
    } else {
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

      // Color based on track confidence and motion
      Color boxColor = Colors.lightGreenAccent;
      if (t.confidence > 0.8) {
        boxColor = Colors.green;
      } else if (t.confidence < 0.5) {
        boxColor = Colors.orange;
      }
      
      if (t.isStationary) {
        boxColor = Colors.blue; // Different color for stationary objects
      }

      return Positioned(
        left: r.left,
        top: r.top,
        width: r.width,
        height: r.height,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            border: Border.all(color: boxColor, width: 2),
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(6),
                  bottomRight: Radius.circular(6),
                ),
              ),
              child: Text(
                "${t.id} (${(t.confidence * 100).toInt()}%)",
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
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