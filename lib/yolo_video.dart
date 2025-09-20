import 'dart:async';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_vision/flutter_vision.dart';

import 'sort_tracker.dart';

class YoloVideo extends StatefulWidget {
  const YoloVideo({super.key});

  @override
  State<YoloVideo> createState() => _YoloVideoState();
}

class _YoloVideoState extends State<YoloVideo> with WidgetsBindingObserver {
  late CameraController _controller;
  late FlutterVision _vision;
  late ObjectTracker _tracker;

  // Tracking state
  List<Track> _trackedObjects = [];
  CameraImage? _lastCameraImage;
  bool _isLoaded = false;
  bool _isDetecting = false;
  bool _isStartingStream = false;

  // For assigning a unique and persistent color to each track ID
  final Map<int, Color> _trackColors = {};
  final Random _random = Random();

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
      maxFramesToDisappear: 10,  // More forgiving for brief occlusions
      iouThreshold: 0.05,        // Stricter matching to prevent ID swaps
      minHitsToConfirm: 2,      // Requires 2 consecutive frames to show a box
    );

    if (mounted) {
      setState(() => _isLoaded = true);
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

  /// Processes a single camera frame for object detection and tracking.
  Future<void> _processFrame(CameraImage cameraImage) async {
    final result = await _vision.yoloOnFrame(
      bytesList: cameraImage.planes.map((p) => p.bytes).toList(),
      imageHeight: cameraImage.height,
      imageWidth: cameraImage.width,
      iouThreshold: 0.05,
      confThreshold: 0.3,
      classThreshold: 0.4,
    );

    if (!mounted) return;

    // Update the tracker with the new detections from the frame.
    _tracker.update(result);

    // Update the UI state with the list of current tracks.
    setState(() {
      _trackedObjects = _tracker.tracks;
    });
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
      // Re-initialize the tracker to reset its state (e.g., nextId)
      _tracker = ObjectTracker(
        maxFramesToDisappear: 10,
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
    } catch (_) {}
    await _controller.dispose();
    try {
      await _vision.closeYoloModel();
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (!_controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
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

  @override
  Widget build(BuildContext context) {
    if (!_isLoaded) {
      return const Scaffold(
        body: Center(child: Text('Loading model & camera...')),
      );
    }

    final size = MediaQuery.of(context).size;
    return Scaffold(
      body: Stack(
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
                  border: Border.all(width: 5, color: Colors.white, style: BorderStyle.solid),
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
                        icon: const Icon(Icons.stop_rounded, color: Colors.red),
                        iconSize: 50,
                      )
                    : IconButton(
                        onPressed: _startDetection,
                        icon: const Icon(Icons.play_arrow_rounded, color: Colors.white),
                        iconSize: 50,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
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

  /// Displays the bounding boxes for all tracked objects.
  List<Widget> _displayTrackedBoxes(Size screen) {
    if (_trackedObjects.isEmpty || _lastCameraImage == null) return [];

    final factorX = screen.width / _lastCameraImage!.height;
    final factorY = screen.height / _lastCameraImage!.width;

    return _trackedObjects.map((track) {
      final box = track.box;
      final color = _getColorForTrack(track.id);

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
                "${track.label} ID: ${track.id}",
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  shadows: [
                    Shadow(color: Colors.black, blurRadius: 4, offset: Offset(1,1))
                  ]
                ),
              ),
            ),
          ),
        ),
      );
    }).toList();
  }
}