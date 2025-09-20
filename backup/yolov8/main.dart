import 'package:flutter/material.dart';
import 'yolo_video.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: YoloVideo(),
  ));
}
