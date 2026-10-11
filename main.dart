import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image/image.dart' as img;
import 'package:gal/gal.dart';
import 'package:native_exif/native_exif.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:path_provider/path_provider.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint(e.toString());
  }

  // 네이버 지도 SDK 초기화
  await NaverMapSdk.instance.initialize(
    clientId: b3agnvaern, // 여기에 네이버 클라우드 플랫폼 Client ID 입력
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
    magnetometerEventStream().listen((MagnetometerEvent mag) {
      if (mounted) {
        setState(() {
          double calcAzimuth = atan2(mag.y, mag.x) * 180 / pi;
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
        if (_aspectRatioMode == '1:1') {
          int size = origW < origH ? origW : origH;
          int offsetX = (origW - size) ~/ 2;
          int offsetY = (origH - size) ~/ 2;
          capturedImage = img.copyCrop(capturedImage, x: offsetX, y: offsetY, width: size, height: size);
        } else if (_aspectRatioMode == '4:3') {
          int targetH = (origW * 4 ~/ 3);
          if (origH > targetH) {
            int offsetY = (origH - targetH) ~/ 2;
            capturedImage = img.copyCrop(capturedImage, x: 0, y: offsetY, width: origW, height: targetH);
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

        // EXIF 데이터 입력
        final exif = await Exif.fromPath(savedPath);
        await exif.writeAttributes({
          'GPSLatitude': _currentPosition!.latitude,
          'GPSLatitudeRef': _currentPosition!.latitude > 0 ? 'N' : 'S',
          'GPSLongitude': _currentPosition!.longitude,
          'GPSLongitudeRef': _currentPosition!.longitude > 0 ? 'E' : 'W',
          'GPSAltitude': _currentPosition!.altitude,
          'GPSAltitudeRef': 0,
          'GPSImgDirection': _azimuth,
          'GPSImgDirectionRef': 'T',
        });
        await exif.close();

        // 갤러리 저장
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

  // 갤러리 및 지도 대시보드 화면 열기
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

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: _aspectRatioMode == '1:1'
                  ? 1.0
                  : _aspectRatioMode == '4:3'
                      ? 3.0 / 4.0
                      : 9.0 / 16.0,
              child: CameraPreview(_controller!),
            ),
          ),
          // 화면 비율 변경 버튼
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
          // 촬영 정보 오버레이
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
          // 갤러리 보기 버튼 (우측 하단)
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
          // 촬영 셔터 버튼 (중앙 하단)
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

// 갤러리 및 네이버 지도 연동 대시보드 위젯
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
    _selectedIndex = widget.photos.length - 1; // 가장 최근 사진 기본 선택
  }

  @override
  Widget build(BuildContext context) {
    final currentPhoto = widget.photos[_selectedIndex];

    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        children: [
          // 상단바
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
          // 본문 좌우 분할 (좌측: 사진, 우측: 네이버 지도)
          Expanded(
            child: Row(
              children: [
                // 좌측: 선택된 사진 및 상세 정보
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
                // 우측: 네이버 지도 연동
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
          // 하단 사진 리스트 가로 스크롤
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
