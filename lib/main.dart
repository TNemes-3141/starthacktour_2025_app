import 'package:flutter/material.dart';
import 'yolo_video.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://szctehfhcijgnwwlvvco.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InN6Y3RlaGZoY2lqZ253d2x2dmNvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTgyMDU0OTAsImV4cCI6MjA3Mzc4MTQ5MH0.Unkm5Rx4IC7S1HGWLGovV2Az22Sieh2up_dU-SC57K4',
  );

  runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: YoloVideo()),
  );
}
