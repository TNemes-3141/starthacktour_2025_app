import 'coordinate_transformer.dart';
import 'dart:math';

// ---- Geo utils ----
class GeoUtils {
  static const double _earthRadiusMeters = 6371000.0;

  /// Haversine horizontal distance in meters between two lat/lon (degrees).
  static double haversineMeters(double lat1, double lon1, double lat2, double lon2) {
    final rLat1 = lat1 * (3.141592653589793 / 180.0);
    final rLat2 = lat2 * (3.141592653589793 / 180.0);
    final dLat = (lat2 - lat1) * (3.141592653589793 / 180.0);
    final dLon = (lon2 - lon1) * (3.141592653589793 / 180.0);
    final a =
        (sin(dLat / 2) * sin(dLat / 2)) +
        cos(rLat1) * cos(rLat2) * (sin(dLon / 2) * sin(dLon / 2));
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return _earthRadiusMeters * c;
  }

  /// 3D distance: sqrt(horizontal^2 + vertical^2)
  static double distance3DMeters(ObjectCoordinates a, ObjectCoordinates b) {
    final horiz = haversineMeters(
      a.latitude,
      a.longitude,
      b.latitude,
      b.longitude,
    );
    final vert = (b.height - a.height).abs();
    return sqrt(horiz * horiz + vert * vert);
  }
}
