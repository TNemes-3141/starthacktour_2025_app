import 'package:flutter/material.dart';
import 'motion_video.dart';


Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: MotionVideo(),
  ));
}
