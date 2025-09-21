/// Camera configuration constants
/// Edit these values to match your camera setup
class CameraConstants {
  // Field of View angles in degrees
  static const double horizontalFovDeg = 49.5503;
  static const double verticalFovDeg = 69.3903;
  static const double diagonalFovDeg = 79.5243;
  
  // Half-angles (often used for calculations)
  static const double horizontalHalfFovDeg = 24.7751;
  static const double verticalHalfFovDeg = 34.6952;
  static const double diagonalHalfFovDeg = 39.7622;
  
  // Camera GPS position
  static const double cameraLatitude = 47.30658844506907;
  static const double cameraLongitude = 9.431777965149525;
  
  // Camera orientation
  /// Direction the camera is pointing, in degrees azimuth:
  /// 0 = North, 90 = East, 180 = South, 270 = West
  static const double cameraAzimuthDeg = 225;
  
  /// Elevation angle above the horizontal plane:
  /// 0° = looking along the horizon, 90° = straight up
  static const double cameraElevationDeg = 0;
  
  // Camera resolution in pixels
  static const int resolutionWidth = 1920;
  static const int resolutionHeight = 1080;
  
  // Camera physical height above ground level in meters
  static const double cameraHeightAboveGround = 1.7;
  
  /// Cone half-angle (i.e., half the FOV) in degrees.
  /// Example: a 60° FOV camera has half-angle = 30°.
  static const double coneHalfAngleDeg = diagonalHalfFovDeg;
}