import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image/image.dart' as img;
import 'package:gal/gal.dart';
import 'package:native_exif/native_exif.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint(e.toString());
  }
  runApp(const MaterialApp(home: CameraScreen(), debugShowCheckedModeBanner: false));
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

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    await [Permission.camera, Permission.location, Permission.storage, Permission.photos].request();
    _initCamera();
    _initLocation();
    _initSensors();
  }

  void _initCamera() {
    if (cameras.isEmpty) return;
    _controller = CameraController(cameras[0], ResolutionPreset.high, enableAudio: false);
    _controller!.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
    });
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
    magnetometerEventStream().listen((MagnetometerEvent mag) {
      if (mounted) {
        setState(() {
          _azimuth = (atan2(mag.y, mag.x) * 180 / pi);
          if (_azimuth < 0) _azimuth += 360;
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
    return '';
  }

  Future<void> _takePicture() async {
    if (_controller == null || !_controller!.value.isInitialized || _isProcessing) return;
    setState(() { _isProcessing = true; });

    try {
      final XFile file = await _controller!.takePicture();
      final bytes = await file.readAsBytes();
      img.Image? capturedImage = img.decodeImage(bytes);

      if (capturedImage != null) {
        String waterMarkText = "";
        String dateTime = DateTime.now().toString().substring(0, 16);
        
        if (_currentPosition != null) {
          waterMarkText = 'Lat: ${_currentPosition!.latitude.toStringAsFixed(6)}\n'
              'Lng: ${_currentPosition!.longitude.toStringAsFixed(6)}\n'
              'Alt: ${_currentPosition!.altitude.toStringAsFixed(1)}m\n'
              'Acc: ${_currentPosition!.accuracy.toStringAsFixed(1)}m\n';
        }
        waterMarkText += 'Azimuth: ${_azimuth.toStringAsFixed(1)} deg\n'
            'Pitch: ${_pitch.toStringAsFixed(1)} deg\n'
            'Time: $dateTime';

        // 1. 사진 겉면에 텍스트(워터마크) 그리기
        img.drawString(
          capturedImage,
          waterMarkText,
          font: img.arial24,
          x: 20,
          y: capturedImage.height - 200,
          color: img.ColorRgb8(255, 200, 50), // 노란색 글씨
        );

        final outBytes = img.encodeJpg(capturedImage, quality: 90);
        final tempDir = Directory.systemTemp;
        final tempFilePath = '${tempDir.path}/photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final tempFile = File(tempFilePath);
        await tempFile.writeAsBytes(outBytes);

        // 2. 사진 속옷(EXIF)에 실제 GPS 데이터 심기
        if (_currentPosition != null) {
          final exif = await Exif.fromPath(tempFilePath);
          await exif.writeAttributes({
            'GPSLatitude': _currentPosition!.latitude,
            'GPSLatitudeRef': _currentPosition!.latitude > 0 ? 'N' : 'S',
            'GPSLongitude': _currentPosition!.longitude,
            'GPSLongitudeRef': _currentPosition!.longitude > 0 ? 'E' : 'W',
          });
          await exif.close();
        }

        // 3. 갤러리에 최종 저장
        await Gal.putImage(tempFilePath);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('갤러리에 저장되었습니다!')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('에러 발생: $e')));
      }
    } finally {
      if (mounted) setState(() { _isProcessing = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(backgroundColor: Colors.black, body: Center(child: CircularProgressIndicator(color: Colors.white)));
    }

    String displayLocation = _currentPosition == null
        ? "위치 정보 찾는 중..."
        : "위도: ${_currentPosition!.latitude.toStringAsFixed(6)}\n경도: ${_currentPosition!.longitude.toStringAsFixed(6)}\n표고: ${_currentPosition!.altitude.toStringAsFixed(1)}m\n정확도: ±${_currentPosition!.accuracy.toStringAsFixed(1)}m";
    
    String displaySensor = "방위각: ${_azimuth.toStringAsFixed(1)}° (${_getDirection(_azimuth)})\n피치각: ${_pitch.toStringAsFixed(1)}°";

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_controller!),
          Positioned(
            bottom: 120,
            left: 20,
            child: Container(
              padding: const EdgeInsets.all(8),
              color: Colors.black45,
              child: Text(
                '$displayLocation\n$displaySensor\n시간: ${DateTime.now().toString().substring(0,16)}',
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ),
          if (_isProcessing)
            const Center(child: CircularProgressIndicator(color: Colors.white)),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _takePicture,
        backgroundColor: Colors.amber,
        child: const Icon(Icons.camera_alt, color: Colors.black, size: 30),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}
