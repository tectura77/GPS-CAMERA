import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image/image.dart' as img;
import 'package:gal/gal.dart';
import 'package:native_exif/native_exif.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart';

List<CameraDescription> cameras = [];
String? globalNaverAuthError;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint(e.toString());
  }

  try {
    await FlutterNaverMap().init(
      clientId: 'b3agnvaern',
      onAuthFailed: (ex) {
        globalNaverAuthError = "인증 실패 에러:\n$ex";
        debugPrint("네이버 지도 인증 실패: $ex");
      },
    );
  } catch (e) {
    globalNaverAuthError = "초기화 에러: $e";
  }

  runApp(const MaterialApp(home: CameraScreen(), debugShowCheckedModeBanner: false));
}

class PhotoData {
  final String path;
  final double latitude;
  final double longitude;
  final double altitude;
  final double accuracy;
  final double azimuth;
  final double pitch;
  final String time;

  PhotoData({
    required this.path,
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.accuracy,
    required this.azimuth,
    required this.pitch,
    required this.time,
  });

  Map<String, dynamic> toJson() => {
    'path': path,
    'latitude': latitude,
    'longitude': longitude,
    'altitude': altitude,
    'accuracy': accuracy,
    'azimuth': azimuth,
    'pitch': pitch,
    'time': time,
  };

  factory PhotoData.fromJson(Map<String, dynamic> json) => PhotoData(
    path: json['path'],
    latitude: (json['latitude'] as num).toDouble(),
    longitude: (json['longitude'] as num).toDouble(),
    altitude: (json['altitude'] as num).toDouble(),
    accuracy: (json['accuracy'] as num).toDouble(),
    azimuth: (json['azimuth'] as num).toDouble(),
    pitch: (json['pitch'] as num).toDouble(),
    time: json['time'],
  );
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  Position? _currentPosition;
  double _azimuth = 0;
  double _pitch = 0;
  bool _isProcessing = false;
  String _aspectRatioMode = '16:9';
  
  final List<PhotoData> _capturedPhotos = [];

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    await [Permission.camera, Permission.location, Permission.storage, Permission.photos].request();
    await _loadSavedPhotos();
    _initCamera(ResolutionPreset.high);
    _initLocation();
    _initSensors();
  }

  Future<void> _savePhotosData() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/photos_meta.json');
      final String contents = jsonEncode(_capturedPhotos.map((e) => e.toJson()).toList());
      await file.writeAsString(contents);
    } catch (e) {
      debugPrint("데이터 저장 에러: $e");
    }
  }

  Future<void> _loadSavedPhotos() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/photos_meta.json');
      if (await file.exists()) {
        final String contents = await file.readAsString();
        final List<dynamic> jsonList = jsonDecode(contents);
        
        setState(() {
          _capturedPhotos.clear();
          for (var item in jsonList) {
            final photo = PhotoData.fromJson(item);
            if (File(photo.path).existsSync()) {
              _capturedPhotos.add(photo);
            }
          }
        });
      }
    } catch (e) {
      debugPrint("데이터 로드 에러: $e");
    }
  }

  void _initCamera(ResolutionPreset preset) async {
    if (cameras.isEmpty) return;
    _controller = CameraController(cameras[0], preset, enableAudio: false);
    await _controller!.initialize();
    if (!mounted) return;
    setState(() {});
  }

  void _initLocation() {
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high)
    ).listen((Position position) {
      if (mounted) setState(() { _currentPosition = position; });
    });
  }

  void _initSensors() {
    accelerometerEventStream().listen((AccelerometerEvent acc) {
      if (mounted) {
        setState(() {
          _pitch = (atan2(acc.y, sqrt(acc.x * acc.x + acc.z * acc.z)) * 180 / pi);
        });
      }
    });
    
    FlutterCompass.events?.listen((CompassEvent event) {
      if (mounted && event.heading != null) {
        setState(() {
          double calcAzimuth = event.heading!;
          calcAzimuth = (calcAzimuth % 360 + 360) % 360;
          _azimuth = calcAzimuth;
        });
      }
    });
  }

  String _getDirection(double azimuth) {
    if (azimuth >= 337.5 || azimuth < 22.5) return 'N (북)';
    if (azimuth >= 22.5 && azimuth < 67.5) return 'NE (북동)';
    if (azimuth >= 67.5 && azimuth < 112.5) return 'E (동)';
    if (azimuth >= 112.5 && azimuth < 157.5) return 'SE (남동)';
    if (azimuth >= 157.5 && azimuth < 202.5) return 'S (남)';
    if (azimuth >= 202.5 && azimuth < 247.5) return 'SW (남서)';
    if (azimuth >= 247.5 && azimuth < 292.5) return 'W (서)';
    if (azimuth >= 292.5 && azimuth < 337.5) return 'NW (북서)';
    return 'N (북)';
  }

  String _getDirectionEn(double azimuth) {
    if (azimuth >= 337.5 || azimuth < 22.5) return 'N';
    if (azimuth >= 22.5 && azimuth < 67.5) return 'NE';
    if (azimuth >= 67.5 && azimuth < 112.5) return 'E';
    if (azimuth >= 112.5 && azimuth < 157.5) return 'SE';
    if (azimuth >= 157.5 && azimuth < 2
