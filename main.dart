import 'dart:io';
import 'dart:math';
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

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 가로/세로 자유롭게 회전할 수 있도록 세로 고정(setPreferredOrientations) 삭제!

  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint(e.toString());
  }

  await NaverMapSdk.instance.initialize(
    clientId: 'b3agnvaern',
    onAuthFailed: (ex) {
      debugPrint("네이버 지도 인증 실패: $ex");
    },
  );

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
    _initCamera(ResolutionPreset.high);
    _initLocation();
    _initSensors();
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
    
    // 나침반 센서 가로/세로 보정 적용
    FlutterCompass.events?.listen((CompassEvent event) {
      if (mounted && event.heading != null) {
        setState(() {
          double calcAzimuth = event.heading!;
          
          if (_controller != null) {
            final orientation = _controller!.value.deviceOrientation;
            // 스마트폰이 가로로 누워있을 경우 90도씩 틀어지는 것을 뺄셈/덧셈으로 완벽하게 보정!
            if (orientation == DeviceOrientation.landscapeLeft) {
              calcAzimuth += 90;
            } else if (orientation == DeviceOrientation.landscapeRight) {
              calcAzimuth -= 90;
            } else if (orientation == DeviceOrientation.portraitDown) {
              calcAzimuth += 180;
            }
          }
          
          calcAzimuth = calcAzimuth % 360;
          if (calcAzimuth < 0) calcAzimuth += 360;
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

  Future<void> _takePicture() async {
    if (_controller == null || !_controller!.value.isInitialized || _isProcessing) return;
    setState(() { _isProcessing = true; });

    try {
      SystemSound.play(SystemSoundType.click);
      HapticFeedback.mediumImpact();

      final XFile file = await _controller!.takePicture();
      final bytes = await file.readAsBytes();
      img.Image? capturedImage = img.decodeImage(bytes);

      if (capturedImage != null && _currentPosition != null) {
        int origW = capturedImage.width;
        int origH = capturedImage.height;
        
        // 가로, 세로 방향에 맞춰 안전하게 자르기 비율 조정
        if (_aspectRatioMode == '1:1') {
          int size = origW < origH ? origW : origH;
          int offsetX = (origW - size) ~/ 2;
          int offsetY = (origH - size) ~/ 2;
          capturedImage = img.copyCrop(capturedImage, x: offsetX, y: offsetY, width: size, height: size);
        } else if (_aspectRatioMode == '4:3') {
          if (origH > origW) { // 세로 화면일 때
            int targetH = (origW * 4 ~/ 3);
            if (origH > targetH) {
              int offsetY = (origH - targetH) ~/ 2;
              capturedImage = img.copyCrop(capturedImage, x: 0, y: offsetY, width: origW, height: targetH);
            }
          } else { // 가로 화면일 때
            int targetW = (origH * 4 ~/ 3);
            if (origW > targetW) {
              int offsetX = (origW - targetW) ~/ 2;
              capturedImage = img.copyCrop(capturedImage, x: offsetX, y: 0, width: targetW, height: origH);
            }
          }
        }

        String waterMarkText = "";
        String dateTime = DateTime.now().toString().substring(0, 16);
        String directionStr = _getDirection(_azimuth);
        
        double acc = _currentPosition!.accuracy;
        double altAcc = acc * 1.5;
        
        waterMarkText = 'Lat: ${_currentPosition!.latitude.toStringAsFixed(6)} (±${acc.toStringAsFixed(1)}m)\n'
            'Lng: ${_currentPosition!.longitude.toStringAsFixed(6)} (±${acc.toStringAsFixed(1)}m)\n'
            'Alt: ${_currentPosition!.altitude.toStringAsFixed(1)}m (±${altAcc.toStringAsFixed(1)}m)\n'
            'Azimuth: ${_azimuth.toStringAsFixed(1)}° ($directionStr)\n'
            'Pitch: ${_pitch.toStringAsFixed(1)}°\n'
            'Time: $dateTime';

        img.drawString(
          capturedImage,
          waterMarkText,
          font: img.arial24,
          x: 20,
          y: capturedImage.height - 220,
          color: img.ColorRgb8(255, 200, 50),
        );

        final outBytes = img.encodeJpg(capturedImage, quality: 90);
        final appDir = await getApplicationDocumentsDirectory();
        final savedPath = '${appDir.path}/photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final savedFile = File(savedPath);
        await savedFile.writeAsBytes(outBytes);

        // 시스템 충돌 없이 소수점 문자열로 변경하여 완벽하게 EXIF 저장!
        final exif = await Exif.fromPath(savedPath);
        await exif.writeAttributes({
          'GPSLatitude': _currentPosition!.latitude.toString(),
          'GPSLatitudeRef': _currentPosition!.latitude > 0 ? 'N' : 'S',
          'GPSLongitude': _currentPosition!.longitude.toString(),
          'GPSLongitudeRef': _currentPosition!.longitude > 0 ? 'E' : 'W',
          'GPSAltitude': _currentPosition!.altitude.toString(),
          'GPSAltitudeRef': '0',
          'GPSImgDirection': _azimuth.toString(),
          'GPSImgDirectionRef': 'T',
        });
        await exif.close();

        await Gal.putImage(savedPath);

        setState(() {
          _capturedPhotos.add(PhotoData(
            path: savedPath,
            latitude: _currentPosition!.latitude,
            longitude: _currentPosition!.longitude,
            altitude: _currentPosition!.altitude,
            accuracy: acc,
            azimuth: _azimuth,
            pitch: _pitch,
            time: dateTime,
          ));
        });
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('사진이 촬영되어 저장되었습니다!')));
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

  void _openGalleryMapModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black87,
      builder: (context) {
        return FractionallySizedBox(
          heightFactor: 0.85,
          child: GalleryMapDashboard(photos: _capturedPhotos),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(backgroundColor: Colors.black, body: Center(child: CircularProgressIndicator(color: Colors.white)));
    }

    String directionStr = _getDirection(_azimuth);
    String displayLocation = "위치 정보 찾는 중...";
    if (_currentPosition != null) {
      double acc = _currentPosition!.accuracy;
      double altAcc = acc * 1.5;
      displayLocation = "위도: ${_currentPosition!.latitude.toStringAsFixed(6)} (±${acc.toStringAsFixed(1)}m)\n"
          "경도: ${_currentPosition!.longitude.toStringAsFixed(6)} (±${acc.toStringAsFixed(1)}m)\n"
          "표고: ${_currentPosition!.altitude.toStringAsFixed(1)}m (±${altAcc.toStringAsFixed(1)}m)";
    }
    
    String displaySensor = "방위각: ${_azimuth.toStringAsFixed(1)}° ($directionStr)\n피치각: ${_pitch.toStringAsFixed(1)}°";

    // 현재 화면 회전 상태에 맞춰서 카메라 뷰 비율 적용
    bool isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    double previewRatio;
    if (_aspectRatioMode == '1:1') {
      previewRatio = 1.0;
    } else if (_aspectRatioMode == '4:3') {
      previewRatio = isLandscape ? 4.0 / 3.0 : 3.0 / 4.0;
    } else {
      previewRatio = isLandscape ? 16.0 / 9.0 : 9.0 / 16.0;
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: previewRatio,
              child: CameraPreview(_controller!),
            ),
          ),
          Positioned(
            top: 50,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: ['16:9', '4:3', '1:1'].map((mode) {
                bool isSelected = _aspectRatioMode == mode;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: ElevatedButton(
                    onPressed: () => setState(() => _aspectRatioMode = mode),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isSelected ? Colors.amber : Colors.black54,
                      foregroundColor: isSelected ? Colors.black : Colors.white,
                    ),
                    child: Text(mode),
                  ),
                );
              }).toList(),
            ),
          ),
          Positioned(
            bottom: 110,
            left: 20,
            child: Container(
              padding: const EdgeInsets.all(8),
              color: Colors.black45,
              child: Text(
                '$displayLocation\n$displaySensor\n시간: ${DateTime.now().toString().substring(0,16)}',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
          Positioned(
            bottom: 35,
            right: 30,
            child: FloatingActionButton(
              heroTag: 'galleryBtn',
              onPressed: _capturedPhotos.isEmpty ? null : _openGalleryMapModal,
              backgroundColor: _capturedPhotos.isEmpty ? Colors.grey : Colors.blueAccent,
              child: const Icon(Icons.map, color: Colors.white),
            ),
          ),
          Positioned(
            bottom: 25,
            left: 0,
            right: 0,
            child: Center(
              child: FloatingActionButton(
                heroTag: 'captureBtn',
                onPressed: _takePicture,
                backgroundColor: Colors.amber,
                child: const Icon(Icons.camera_alt, color: Colors.black, size: 30),
              ),
            ),
          ),
          if (_isProcessing)
            const Center(child: CircularProgressIndicator(color: Colors.white)),
        ],
      ),
    );
  }
}

class GalleryMapDashboard extends StatefulWidget {
  final List<PhotoData> photos;
  const GalleryMapDashboard({super.key, required this.photos});

  @override
  State<GalleryMapDashboard> createState() => _GalleryMapDashboardState();
}

class _GalleryMapDashboardState extends State<GalleryMapDashboard> {
  int _selectedIndex = 0;
  NaverMapController? _mapController;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.photos.length - 1;
  }

  @override
  Widget build(BuildContext context) {
    final currentPhoto = widget.photos[_selectedIndex];

    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('촬영 사진 & 지도 위치 대시보드', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const Divider(color: Colors.white24),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: Column(
                    children: [
                      Expanded(
                        child: Image.file(File(currentPhoto.path), fit: BoxFit.contain),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(8),
                        color: Colors.black54,
                        width: double.infinity,
                        child: Text(
                          '위도: ${currentPhoto.latitude.toStringAsFixed(6)} (±${currentPhoto.accuracy.toStringAsFixed(1)}m)\n'
                          '경도: ${currentPhoto.longitude.toStringAsFixed(6)} (±${currentPhoto.accuracy.toStringAsFixed(1)}m)\n'
                          '표고: ${currentPhoto.altitude.toStringAsFixed(1)}m\n'
                          '방위각: ${currentPhoto.azimuth.toStringAsFixed(1)}° | 시간: ${currentPhoto.time}',
                          style: const TextStyle(color: Colors.white, fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 5,
                  child: NaverMap(
                    options: NaverMapViewOptions(
                      initialCameraPosition: NCameraPosition(
                        target: NLatLng(currentPhoto.latitude, currentPhoto.longitude),
                        zoom: 16,
                      ),
                    ),
                    onMapReady: (controller) {
                      _mapController = controller;
                      _updateMarkers();
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 70,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: widget.photos.length,
              itemBuilder: (context, index) {
                bool isSelected = _selectedIndex == index;
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _selectedIndex = index;
                    });
                    if (_mapController != null) {
                      _mapController!.updateCamera(
                        NCameraUpdate.fromCameraPosition(
                          NCameraPosition(
                            target: NLatLng(widget.photos[index].latitude, widget.photos[index].longitude),
                            zoom: 16,
                          ),
                        ),
                      );
                    }
                  },
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      border: Border.all(color: isSelected ? Colors.amber : Colors.transparent, width: 3),
                    ),
                    child: Image.file(File(widget.photos[index].path), width: 70, height: 70, fit: BoxFit.cover),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _updateMarkers() {
    if (_mapController == null) return;
    for (int i = 0; i < widget.photos.length; i++) {
      final photo = widget.photos[i];
      final marker = NMarker(
        id: 'photo_$i',
        position: NLatLng(photo.latitude, photo.longitude),
      );
      marker.setOnTapListener((_) {
        setState(() {
          _selectedIndex = i;
        });
      });
      _mapController!.addOverlay(marker);
    }
  }
}
