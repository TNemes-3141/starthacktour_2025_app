import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_vision/flutter_vision.dart';

class YoloVideo extends StatefulWidget {
  const YoloVideo({super.key});

  @override
  State<YoloVideo> createState() => _YoloVideoState();
}

class _YoloVideoState extends State<YoloVideo> with WidgetsBindingObserver {
  late CameraController _controller;
  late FlutterVision _vision;

  // Detection state
  List<Map<String, dynamic>> _yoloResults = [];
  CameraImage? _lastCameraImage;
  bool _isLoaded = false;
  bool _isDetecting = false;
  bool _isStartingStream = false; // prevents double-start

  // Adjust to your model/labels paths
  static const String _labelsAsset = 'assets/labels.txt';
  static const String _modelAsset = 'assets/yolov8n_float32.tflite';
  // "yolov8" works for YOLOv8 and YOLOv9 TFLite variants with flutter_vision
  static const String _modelVersion = 'yolov8';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    // Get cameras first
    final cameras = await availableCameras();
    // Use back camera if available
    final CameraDescription useCam = cameras.firstWhere(
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

    if (mounted) {
      setState(() => _isLoaded = true);
    }
  }

  Future<void> _loadYoloModel() async {
    // Loads model to NNAPI/GPU if available; tweak threads/GPU as needed
    await _vision.loadYoloModel(
      labels: _labelsAsset,
      modelPath: _modelAsset,
      modelVersion: _modelVersion,
      numThreads: 2,
      useGpu: true,
    );
  }

  // Called on each camera frame while streaming
  Future<void> _yoloOnFrame(CameraImage cameraImage) async {
    final result = await _vision.yoloOnFrame(
      bytesList: cameraImage.planes.map((p) => p.bytes).toList(),
      imageHeight: cameraImage.height,
      imageWidth: cameraImage.width,
      // Tweak thresholds to your liking / dataset
      iouThreshold: 0.2,
      confThreshold: 0.2,
      classThreshold: 0.2,
    );

    if (!mounted) return;

    if (result.isNotEmpty) {
      setState(() {
        _yoloResults = result; // [{box:[x1,y1,x2,y2,score], tag:'class', ...}, ...]
      });
    } else {
      // Clear boxes if nothing detected on this frame
      setState(() => _yoloResults = []);
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
      // Avoid overlapping inference calls (simple gate)
      if (!_inferenceInProgress) {
        _inferenceInProgress = true;
        try {
          await _yoloOnFrame(image);
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
      _yoloResults.clear();
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
    } catch (_) {}
    await _controller.dispose();
    try {
      await _vision.closeYoloModel();
    } catch (_) {}
  }

  // Handle app lifecycle to free/reacquire camera
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (!_controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      // App not visible — stop stream and release camera
      if (_controller.value.isStreamingImages) {
        await _controller.stopImageStream();
      }
      await _controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      // Recreate controller when coming back
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
        // Resume detection if it was on
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
          // Camera preview
          if (_controller.value.isInitialized)
            AspectRatio(
              aspectRatio: _controller.value.aspectRatio,
              child: CameraPreview(_controller),
            )
          else
            const Center(child: CircularProgressIndicator()),

          // Boxes overlay
          ..._displayBoxes(size),

          // Play/Stop round button
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
                  border: Border.all(width: 5, color: Colors.white),
                ),
                child: _isDetecting
                    ? IconButton(
                        onPressed: _stopDetection,
                        icon: const Icon(Icons.stop, color: Colors.red),
                        iconSize: 50,
                      )
                    : IconButton(
                        onPressed: _startDetection,
                        icon: const Icon(Icons.play_arrow, color: Colors.white),
                        iconSize: 50,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _displayBoxes(Size screen) {
    if (_yoloResults.isEmpty || _lastCameraImage == null) return [];

    // NOTE: cameraImage is rotated; for the common back camera portrait case,
    // width/height are swapped. Use the same mapping as the tutorial:
    final factorX = screen.width / _lastCameraImage!.height;
    final factorY = screen.height / _lastCameraImage!.width;

    final List<Widget> boxes = [];
    for (final det in _yoloResults) {
      // det["box"] = [x1, y1, x2, y2, score]; det["tag"] = class label
      final List box = det["box"];
      final double left = (box[0] as num).toDouble() * factorX;
      final double top = (box[1] as num).toDouble() * factorY;
      final double width =
          ((box[2] as num).toDouble() - (box[0] as num).toDouble()) * factorX;
      final double height =
          ((box[3] as num).toDouble() - (box[1] as num).toDouble()) * factorY;

      final String label = det["tag"].toString();
      final double score = ((box.length >= 5 ? box[4] : 0.0) as num).toDouble();

      boxes.add(Positioned(
        left: left,
        top: top,
        width: width,
        height: height,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(10)),
            border: Border.all(color: Colors.pink, width: 2),
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: const BoxDecoration(
                color: Color.fromARGB(200, 50, 233, 30),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(8),
                  bottomRight: Radius.circular(8),
                ),
              ),
              child: Text(
                "$label ${(score * 100).toStringAsFixed(1)}%",
                style: const TextStyle(
                  color: Color.fromARGB(255, 115, 0, 255),
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      ));
    }
    return boxes;
    // If your preview rotation differs, you may need to flip factorX/Y.
  }
}
