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
    'path': path, 'latitude': latitude, 'longitude': longitude,
    'altitude': altitude, 'accuracy': accuracy, 'azimuth': azimuth,
    'pitch': pitch, 'time': time
  };

  factory PhotoData.fromJson(Map<String, dynamic> json) => PhotoData(
    path: json['path'], latitude: json['latitude'], longitude: json['longitude'],
    altitude: json['altitude'], accuracy: json['accuracy'],
    azimuth: json['azimuth'], pitch: json['pitch'], time: json['time']
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
    if (azimuth >= 157.5 && azimuth < 202.5) return 'S';
    if (azimuth >= 202.5 && azimuth < 247.5) return 'SW';
    if (azimuth >= 247.5 && azimuth < 292.5) return 'W';
    if (azimuth >= 292.5 && azimuth < 337.5) return 'NW';
    return 'N';
  }

  Future<void> _takePicture() async {
    if (_controller == null || !_controller!.value.isInitialized || _isProcessing) return;
    setState(() { _isProcessing = true; });

    try {
      SystemSound.play(SystemSoundType.alert);
      HapticFeedback.heavyImpact();
      Future.delayed(const Duration(milliseconds: 150), () {
        HapticFeedback.heavyImpact();
      });

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
          if (origH > origW) {
            int targetH = (origW * 4 ~/ 3);
            if (origH > targetH) {
              int offsetY = (origH - targetH) ~/ 2;
              capturedImage = img.copyCrop(capturedImage, x: 0, y: offsetY, width: origW, height: targetH);
            }
          } else {
            int targetW = (origH * 4 ~/ 3);
            if (origW > targetW) {
              int offsetX = (origW - targetW) ~/ 2;
              capturedImage = img.copyCrop(capturedImage, x: offsetX, y: 0, width: targetW, height: origH);
            }
          }
        }

        String dateTime = DateTime.now().toString().substring(0, 16);
        String dateOnly = dateTime.substring(0, 10);
        String directionEn = _getDirectionEn(_azimuth);
        
        double acc = _currentPosition!.accuracy;
        double altAcc = acc * 1.5;
        
        String waterMarkText = 'Lat: ${_currentPosition!.latitude.toStringAsFixed(6)} (+-${acc.toStringAsFixed(1)}m)\n'
            'Lng: ${_currentPosition!.longitude.toStringAsFixed(6)} (+-${acc.toStringAsFixed(1)}m)\n'
            'Alt: ${_currentPosition!.altitude.toStringAsFixed(1)}m (+-${altAcc.toStringAsFixed(1)}m)\n'
            'Azimuth: ${_azimuth.toStringAsFixed(1)} deg ($directionEn)\n'
            'Pitch: ${_pitch.toStringAsFixed(1)} deg\n'
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
        
        final folderPath = '${appDir.path}/$dateOnly';
        final folder = Directory(folderPath);
        if (!await folder.exists()) await folder.create(recursive: true);
        
        final savedPath = '$folderPath/photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final savedFile = File(savedPath);
        await savedFile.writeAsBytes(outBytes);

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
        
        await _savePhotosData();
        
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

  void _openGalleryMapDashboard() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GalleryMapDashboard(photos: _capturedPhotos),
      ),
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
              onPressed: _capturedPhotos.isEmpty ? null : _openGalleryMapDashboard,
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
  String _selectedDate = '전체 보기';

  List<PhotoData> get _filteredPhotos {
    if (_selectedDate == '전체 보기') return widget.photos;
    return widget.photos.where((p) => p.time.startsWith(_selectedDate)).toList();
  }

  @override
  void initState() {
    super.initState();
    if (widget.photos.isNotEmpty) {
      _selectedIndex = _filteredPhotos.length - 1;
    }
  }

  // 💡 현재 확대(줌) 배율을 그대로 유지하면서 지도 중심만 이동시키는 함수
  Future<void> _moveCameraKeepZoom(double lat, double lng) async {
    if (_mapController == null) return;
    try {
      final currentPos = await _mapController!.getCameraPosition();
      await _mapController!.updateCamera(
        NCameraUpdate.fromCameraPosition(
          NCameraPosition(
            target: NLatLng(lat, lng),
            zoom: currentPos.zoom,
            tilt: currentPos.tilt,
            bearing: currentPos.bearing,
          ),
        ),
      );
    } catch (e) {
      debugPrint('카메라 이동 에러: $e');
    }
  }

  void _onDateChanged(String? newDate) {
    if (newDate != null) {
      setState(() {
        _selectedDate = newDate;
        _selectedIndex = _filteredPhotos.isNotEmpty ? _filteredPhotos.length - 1 : 0;
      });
      _updateMarkers();
      
      if (_filteredPhotos.isNotEmpty) {
        final photo = _filteredPhotos[_selectedIndex];
        _moveCameraKeepZoom(photo.latitude, photo.longitude);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    List<String> dateOptions = ['전체 보기'];
    Set<String> uniqueDates = widget.photos.map((p) => p.time.substring(0, 10)).toSet();
    List<String> sortedDates = uniqueDates.toList()..sort((a, b) => b.compareTo(a));
    dateOptions.addAll(sortedDates);

    bool isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;

    if (_filteredPhotos.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, title: const Text('지도 대시보드')),
        body: const Center(child: Text("해당 날짜에 찍은 사진이 없습니다.", style: TextStyle(color: Colors.white))),
      );
    }

    final currentPhoto = _filteredPhotos[_selectedIndex];

    // 💡 아래쪽 위도/경도 텍스트 박스를 제거해서 사진이 옆의 지도만큼 꽉 차게 보이도록 수정!
    Widget photoSection = Container(
      color: Colors.black,
      width: double.infinity,
      height: double.infinity,
      child: Image.file(File(currentPhoto.path), fit: BoxFit.contain),
    );

    Widget mapSection = globalNaverAuthError != null
        ? Container(
            color: Colors.white,
            padding: const EdgeInsets.all(20),
            child: Center(
              child: Text(
                '🚨 네이버 지도 차단됨!\n\n$globalNaverAuthError',
                style: const TextStyle(color: Colors.red, fontSize: 15, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
          )
        : NaverMap(
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
          );

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: DropdownButton<String>(
          value: _selectedDate,
          dropdownColor: Colors.black87,
          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
          underline: Container(),
          icon: const Icon(Icons.arrow_drop_down, color: Colors.white),
          items: dateOptions.map((date) => DropdownMenuItem(value: date, child: Text(date))).toList(),
          onChanged: _onDateChanged,
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: isPortrait
                ? Column(
                    children: [
                      Expanded(flex: 5, child: photoSection),
                      const SizedBox(height: 4),
                      Expanded(flex: 5, child: mapSection),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(flex: 5, child: photoSection),
                      const SizedBox(width: 4),
                      Expanded(flex: 5, child: mapSection),
                    ],
                  ),
          ),
          SizedBox(
            height: 80,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _filteredPhotos.length,
              itemBuilder: (context, index) {
                bool isSelected = _selectedIndex == index;
                return GestureDetector(
                  onTap: () {
                    setState(() { _selectedIndex = index; });
                    _updateMarkers();
                    _moveCameraKeepZoom(
                      _filteredPhotos[index].latitude,
                      _filteredPhotos[index].longitude,
                    );
                  },
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    decoration: BoxDecoration(
                      border: Border.all(color: isSelected ? Colors.amber : Colors.transparent, width: 3),
                    ),
                    child: Image.file(File(_filteredPhotos[index].path), width: 70, height: 70, fit: BoxFit.cover),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _updateMarkers() async {
    if (_mapController == null) return;
    _mapController!.clearOverlays();

    // 💡 빨간색(선택 안 된) 마커들을 먼저 그리고, 파란색(선택된) 마커를 맨 마지막에 그려서
    // 겹쳐 있을 때도 파란색 화살표가 항상 맨 위에 선명하게 보이도록 순서 정렬!
    List<int> drawOrder = [];
    for (int i = 0; i < _filteredPhotos.length; i++) {
      if (i != _selectedIndex) drawOrder.add(i);
    }
    if (_selectedIndex >= 0 && _selectedIndex < _filteredPhotos.length) {
      drawOrder.add(_selectedIndex);
    }

    for (int i in drawOrder) {
      final photo = _filteredPhotos[i];
      bool isSelected = (i == _selectedIndex);
      Color markerColor = isSelected ? Colors.blueAccent : Colors.red;

      try {
        final markerIcon = await NOverlayImage.fromWidget(
          widget: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: markerColor.withOpacity(0.3),
                  shape: BoxShape.circle,
                  border: Border.all(color: markerColor, width: 2),
                ),
              ),
              Transform.rotate(
                angle: photo.azimuth * (pi / 180),
                child: Icon(Icons.navigation, color: markerColor, size: 20),
              ),
            ],
          ),
          size: const Size(28, 28),
          context: context,
        );

        final marker = NMarker(
          id: 'photo_$i',
          position: NLatLng(photo.latitude, photo.longitude),
          icon: markerIcon,
        );
        
        marker.setOnTapListener((overlay) async {
          // 💡 클릭한 동그라미 주변(반경 20m 이내)에 겹쳐 있는 사진들을 모두 찾아서
          // 누를 때마다 다음 사진으로 순환(Cycle)하도록 처리!
          List<int> overlappingIndices = [];
          for (int j = 0; j < _filteredPhotos.length; j++) {
            double dist = Geolocator.distanceBetween(
              photo.latitude, photo.longitude,
              _filteredPhotos[j].latitude, _filteredPhotos[j].longitude,
            );
            if (dist <= 20.0) {
              overlappingIndices.add(j);
            }
          }

          int nextIndex = i;
          if (overlappingIndices.length > 1 && overlappingIndices.contains(_selectedIndex)) {
            int currentOrder = overlappingIndices.indexOf(_selectedIndex);
            nextIndex = overlappingIndices[(currentOrder + 1) % overlappingIndices.length];
          } else {
            nextIndex = i;
          }

          setState(() {
            _selectedIndex = nextIndex;
          });

          await _updateMarkers();
          final targetPhoto = _filteredPhotos[_selectedIndex];
          await _moveCameraKeepZoom(targetPhoto.latitude, targetPhoto.longitude);
        });

        _mapController!.addOverlay(marker);
      } catch (e) {
        debugPrint('마커 생성 에러: $e');
      }
    }
  }
}
