import 'dart:math';
import 'sort_tracker.dart';
import 'camera_config.dart';

/// Camera configuration loaded from constants
class CameraConfig {
  final double horizontalFovDeg;
  final double verticalFovDeg;
  final double cameraLat;
  final double cameraLng;
  final double cameraAzimuthDeg;
  final double cameraElevationDeg;
  final int resolutionWidth;
  final int resolutionHeight;
  final double cameraHeightAboveGround;

  const CameraConfig({
    required this.horizontalFovDeg,
    required this.verticalFovDeg,
    required this.cameraLat,
    required this.cameraLng,
    required this.cameraAzimuthDeg,
    required this.cameraElevationDeg,
    required this.resolutionWidth,
    required this.resolutionHeight,
    required this.cameraHeightAboveGround,
  });

  /// Create a CameraConfig from the constants file
  factory CameraConfig.fromConstants() {
    return CameraConfig(
      horizontalFovDeg: CameraConstants.horizontalFovDeg,
      verticalFovDeg: CameraConstants.verticalFovDeg,
      cameraLat: CameraConstants.cameraLatitude,
      cameraLng: CameraConstants.cameraLongitude,
      cameraAzimuthDeg: CameraConstants.cameraAzimuthDeg,
      cameraElevationDeg: CameraConstants.cameraElevationDeg,
      resolutionWidth: CameraConstants.resolutionWidth,
      resolutionHeight: CameraConstants.resolutionHeight,
      cameraHeightAboveGround: CameraConstants.cameraHeightAboveGround,
    );
  }

  /// Calculate the focal length in pixels based on FOV
  double get focalLengthPixelsHorizontal {
    final fovRad = horizontalFovDeg * pi / 180.0;
    return resolutionWidth / (2.0 * tan(fovRad / 2.0));
  }

  double get focalLengthPixelsVertical {
    final fovRad = verticalFovDeg * pi / 180.0;
    return resolutionHeight / (2.0 * tan(fovRad / 2.0));
  }
}

/// Reference sizes for different object categories (in meters)
class ObjectReferenceSizes {
  static const Map<String, double> _referenceSizes = {
    // People and animals
    'person': 1.7,        // Average human height
    'bicycle': 1.7,       // Average bicycle length
    'car': 4.5,          // Average car length
    'motorbike': 2.1,    // Average motorcycle length
    'motorcycle': 2.1,   // Alternative name for motorbike
    'aeroplane': 30.0,   // Small aircraft wingspan
    'airplane': 30.0,    // Alternative name
    'bus': 12.0,         // Standard bus length
    'train': 25.0,       // Train car length
    'truck': 8.0,        // Average truck length
    'boat': 6.0,         // Small boat length
    'ship': 50.0,        // Small ship length
    
    // Animals
    'bird': 0.25,        // Medium-sized bird wingspan
    'cat': 0.5,          // Cat length
    'dog': 0.7,          // Medium dog length
    'horse': 2.4,        // Horse length
    'sheep': 1.3,        // Sheep length
    'cow': 2.5,          // Cow length
    'elephant': 5.5,     // Elephant length
    'bear': 2.0,         // Bear length
    'zebra': 2.2,        // Zebra length
    'giraffe': 4.5,      // Giraffe body length
    
    // Furniture and objects
    'traffic light': 3.0, // Traffic light height
    'fire hydrant': 0.7,  // Fire hydrant height
    'stop sign': 0.8,     // Stop sign width
    'parking meter': 1.2, // Parking meter height
    'bench': 1.5,         // Bench length
    'chair': 0.8,         // Chair height
    'sofa': 2.0,          // Sofa length
    'dining table': 1.5,  // Table length
    'bed': 2.0,           // Bed length
    'tv': 1.3,            // TV width (55 inch)
    'laptop': 0.35,       // Laptop width
    'mouse': 0.1,         // Computer mouse length
    'remote': 0.2,        // TV remote length
    'keyboard': 0.45,     // Keyboard width
    'cell phone': 0.15,   // Phone height
    'microwave': 0.5,     // Microwave width
    'oven': 0.6,          // Oven width
    'toaster': 0.3,       // Toaster width
    'sink': 0.6,          // Sink width
    'refrigerator': 0.7,  // Fridge width
    
    // Sports equipment and aviation
    'frisbee': 0.27,      // Frisbee diameter
    'skis': 1.7,          // Ski length
    'snowboard': 1.5,     // Snowboard length
    'sports ball': 0.22,  // Football diameter
    'kite': 8.0,          // Paraglider wingspan (treated as paraglider)
    'umbrella': 8.0,      // Paraglider wingspan (treated as paraglider)
    'paraglider': 8.0,    // Paraglider wingspan
    'baseball bat': 0.9,  // Bat length
    'baseball glove': 0.3, // Glove length
    'skateboard': 0.8,    // Skateboard length
    'surfboard': 8.0,     // Paraglider wingspan (treated as paraglider)
    'tennis racket': 0.7, // Racket length
    
    // Food items (approximate when visible)
    'bottle': 0.25,       // Water bottle height
    'wine glass': 0.2,    // Wine glass height
    'cup': 0.1,           // Coffee cup height
    'fork': 0.2,          // Fork length
    'knife': 0.25,        // Knife length
    'spoon': 0.18,        // Spoon length
    'bowl': 0.15,         // Bowl diameter
    'banana': 0.18,       // Banana length
    'apple': 0.08,        // Apple diameter
    'sandwich': 0.15,     // Sandwich width
    'orange': 0.07,       // Orange diameter
    'broccoli': 0.15,     // Broccoli head diameter
    'carrot': 0.15,       // Carrot length
    'hot dog': 0.15,      // Hot dog length
    'pizza': 0.3,         // Pizza slice length
    'donut': 0.08,        // Donut diameter
    'cake': 0.2,          // Cake slice width
    
    // Default fallback
    'unknown': 1.0,       // Default size for unrecognized objects
  };

  /// Mapping for display names - converts YOLO classifications to display labels
  static const Map<String, String> _displayNameMapping = {
    'kite': 'paraglider',
    'umbrella': 'paraglider',
    'surfboard': 'paraglider',
  };

  /// Get the display name for an object type (for UI purposes)
  static String getDisplayName(String objectType) {
    final cleanType = objectType.toLowerCase().trim();
    return _displayNameMapping[cleanType] ?? cleanType;
  }

  /// Get the reference size for an object type
  static double getReferenceSize(String objectType) {
    // Clean up the object type string (lowercase, remove extra spaces)
    final cleanType = objectType.toLowerCase().trim();
    
    // Try exact match first
    if (_referenceSizes.containsKey(cleanType)) {
      return _referenceSizes[cleanType]!;
    }
    
    // Try partial matches for variations
    for (final entry in _referenceSizes.entries) {
      if (cleanType.contains(entry.key) || entry.key.contains(cleanType)) {
        return entry.value;
      }
    }
    
    // Return default if no match found
    return _referenceSizes['unknown']!;
  }

  /// Get all available object types and their reference sizes
  static Map<String, double> getAllReferenceSizes() {
    return Map.from(_referenceSizes);
  }
}

/// Represents the result of coordinate transformation
class ObjectCoordinates {
  final double latitude;
  final double longitude;
  final double height;

  const ObjectCoordinates({
    required this.latitude,
    required this.longitude,
    required this.height,
  });

  @override
  String toString() {
    return 'ObjectCoordinates(lat: ${latitude.toStringAsFixed(6)}, lng: ${longitude.toStringAsFixed(6)}, height: ${height.toStringAsFixed(2)}m)';
  }
}

/// Transforms distance and angle measurements to GPS coordinates and height
class CoordinateTransformer {
  // Earth's radius at equator (meters) - used for lat/lng conversion
  static const double _earthRadiusAtEquator = 6378137.0;
  
  static CameraConfig? _cameraConfig;

  /// Load camera configuration from constants
  static CameraConfig getCameraConfig() {
    _cameraConfig ??= CameraConfig.fromConstants();
    return _cameraConfig!;
  }

  /// Estimates distance based on object type and bounding box size using pinhole camera model
  static double estimateDistance(String objectType, List<double> boundingBox, {CameraConfig? config}) {
    config ??= getCameraConfig();
    
    // Get reference size for this object type
    final realSize = ObjectReferenceSizes.getReferenceSize(objectType);
    
    // Calculate bounding box dimensions in pixels
    final boxWidth = boundingBox[2] - boundingBox[0];  // x2 - x1
    final boxHeight = boundingBox[3] - boundingBox[1]; // y2 - y1
    
    // Use the larger dimension for more stable distance estimation
    // This helps when objects are partially occluded or at angles
    final pixelSize = max(boxWidth, boxHeight);
    
    // Calculate distance using pinhole camera model: distance = (real_size * focal_length) / pixel_size
    // We'll use the average of horizontal and vertical focal lengths for robustness
    final focalLengthH = config.focalLengthPixelsHorizontal;
    final focalLengthV = config.focalLengthPixelsVertical;
    final avgFocalLength = (focalLengthH + focalLengthV) / 2.0;
    
    // Calculate estimated distance
    final estimatedDistance = (realSize * avgFocalLength) / pixelSize;
    
    // Apply reasonable bounds to prevent extreme values
    final minDistance = 0.5;  // 50cm minimum
    final maxDistance = 1000.0; // 1km maximum
    
    final clampedDistance = estimatedDistance.clamp(minDistance, maxDistance);
    
    // Debug output (can be removed in production)
    if (clampedDistance != estimatedDistance) {
      print('Distance clamped for $objectType: ${estimatedDistance.toStringAsFixed(2)}m -> ${clampedDistance.toStringAsFixed(2)}m');
    }
    
    return clampedDistance;
  }

  /// Alternative distance estimation using diagonal size (for backward compatibility)
  static double estimateDistanceFromDiagonal(String objectType, double diagonalPixels, {CameraConfig? config}) {
    config ??= getCameraConfig();
    
    final realSize = ObjectReferenceSizes.getReferenceSize(objectType);
    final avgFocalLength = (config.focalLengthPixelsHorizontal + config.focalLengthPixelsVertical) / 2.0;
    
    final estimatedDistance = (realSize * avgFocalLength) / diagonalPixels;
    return estimatedDistance.clamp(0.5, 1000.0);
  }

  /// Converts pixel coordinates to azimuth and elevation angles relative to camera center
  static Map<String, double> pixelToAngles(
    double pixelX, 
    double pixelY, 
    CameraConfig config,
  ) {
    // Convert pixel coordinates to normalized coordinates (-1 to 1)
    // (0,0) is top-left, center of image is (width/2, height/2)
    final normalizedX = (pixelX - config.resolutionWidth / 2) / (config.resolutionWidth / 2);
    final normalizedY = (pixelY - config.resolutionHeight / 2) / (config.resolutionHeight / 2);
    
    // Convert normalized coordinates to angles relative to camera center
    final relativeAzimuthDeg = normalizedX * (config.horizontalFovDeg / 2);
    final relativeElevationDeg = -normalizedY * (config.verticalFovDeg / 2); // Negative because Y increases downward
    
    // Calculate absolute angles
    final absoluteAzimuthDeg = (config.cameraAzimuthDeg + relativeAzimuthDeg) % 360;
    final absoluteElevationDeg = config.cameraElevationDeg + relativeElevationDeg;
    
    return {
      'azimuth': absoluteAzimuthDeg,
      'elevation': absoluteElevationDeg,
    };
  }

  /// Transforms pixel coordinates and distance to GPS coordinates
  static ObjectCoordinates transformPixelToCoordinates({
    required double pixelX,
    required double pixelY,
    required double distance,
    CameraConfig? config,
  }) {
    config ??= getCameraConfig();
    
    final angles = pixelToAngles(pixelX, pixelY, config);
    
    return transformToCoordinates(
      distance: distance,
      azimuthAngle: angles['azimuth']!,
      elevationAngle: angles['elevation']!,
      cameraLatitude: config.cameraLat,
      cameraLongitude: config.cameraLng,
      cameraHeight: config.cameraHeightAboveGround,
    );
  }
  
  /// Transforms camera-relative measurements to absolute coordinates
  static ObjectCoordinates transformToCoordinates({
    required double distance,
    required double azimuthAngle,
    required double elevationAngle,
    required double cameraLatitude,
    required double cameraLongitude,
    double cameraHeight = 2.0,
  }) {
    // Convert angles to radians
    final azimuthRad = _degreesToRadians(azimuthAngle);
    final elevationRad = _degreesToRadians(elevationAngle);
    
    // Calculate 3D displacement from camera to object
    final horizontalDistance = distance * cos(elevationRad);
    final verticalDisplacement = distance * sin(elevationRad);
    
    // Calculate horizontal displacement components
    // Note: In standard navigation, 0° is North, 90° is East
    final northDisplacement = horizontalDistance * cos(azimuthRad);
    final eastDisplacement = horizontalDistance * sin(azimuthRad);
    
    // Calculate object height (camera height + vertical displacement)
    final objectHeight = cameraHeight + verticalDisplacement;
    
    // Convert displacement to latitude/longitude changes
    // For small distances, we can use flat earth approximation
    final deltaLatitude = _metersToLatitudeDegrees(northDisplacement);
    final deltaLongitude = _metersToLongitudeDegrees(eastDisplacement, cameraLatitude);
    
    // Calculate final object coordinates
    final objectLatitude = cameraLatitude + deltaLatitude;
    final objectLongitude = cameraLongitude + deltaLongitude;
    
    return ObjectCoordinates(
      latitude: objectLatitude,
      longitude: objectLongitude,
      height: objectHeight,
    );
  }
  
  /// Converts meters of north/south displacement to degrees of latitude
  static double _metersToLatitudeDegrees(double meters) {
    return meters / (_earthRadiusAtEquator * pi / 180.0);
  }
  
  /// Converts meters of east/west displacement to degrees of longitude
  /// Accounts for latitude-dependent longitude scaling
  static double _metersToLongitudeDegrees(double meters, double latitude) {
    final latitudeRad = _degreesToRadians(latitude);
    final longitudeRadius = _earthRadiusAtEquator * cos(latitudeRad);
    return meters / (longitudeRadius * pi / 180.0);
  }
  
  /// Converts degrees to radians
  static double _degreesToRadians(double degrees) {
    return degrees * pi / 180.0;
  }
  
  /// Converts radians to degrees
  static double _radiansToDegrees(double radians) {
    return radians * 180.0 / pi;
  }
}

/// Enhanced Track class with coordinate calculation capabilities
extension TrackCoordinateExtension on Track {
  /// Get the center pixel coordinates of this track's bounding box
  Map<String, double> get centerPixel {
    return {
      'x': (box[0] + box[2]) / 2,
      'y': (box[1] + box[3]) / 2,
    };
  }
  
  /// Get the diagonal size of the bounding box in pixels
  double get diagonalPixels {
    final width = box[2] - box[0];
    final height = box[3] - box[1];
    return sqrt(width * width + height * height);
  }

  /// Get the display name for this track's label
  String get displayLabel {
    return ObjectReferenceSizes.getDisplayName(label);
  }
  
  /// Calculates coordinates for this tracked object using pixel position
  ObjectCoordinates calculateCoordinatesFromPixels({
    CameraConfig? config,
  }) {
    final center = centerPixel;
    
    // Use the new distance estimation with bounding box
    final distance = CoordinateTransformer.estimateDistance(label, box, config: config);
    
    return CoordinateTransformer.transformPixelToCoordinates(
      pixelX: center['x']!,
      pixelY: center['y']!,
      distance: distance,
      config: config,
    );
  }
}