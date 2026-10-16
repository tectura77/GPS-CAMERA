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

  runApp(const MaterialApp(
    home: CameraScreen(),
    debugShowCheckedModeBanner: false,
  ));
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
    await [
      Permission.camera,
      Permission.location,
      Permission.storage,
      Permission.photos,
    ].request();
    await _loadSavedPhotos();
    _initCamera(ResolutionPreset.high);
    _initLocation();
    _initSensors();
  }

  Future<void> _savePhotosData() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/photos_meta.json');
      final String contents =
          jsonEncode(_capturedPhotos.map((e) => e.toJson()).toList());
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
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    ).listen((Position position) {
      if (mounted) {
        setState(() {
          _currentPosition = position;
        });
      }
    });
  }

  void _initSensors() {
    accelerometerEventStream().listen((AccelerometerEvent acc) {
      if (mounted) {
        setState(() {
          _pitch =
              (atan2(acc.y, sqrt(acc.x * acc.x + acc.z * acc.z)) * 180 / pi);
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
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isProcessing) return;
    setState(() {
      _isProcessing = true;
    });

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
          capturedImage = img.copyCrop(
            capturedImage,
            x: offsetX,
            y: offsetY,
            width: size,
            height: size,
          );
        } else if (_aspectRatioMode == '4:3') {
          if (origH > origW) {
            int targetH = (origW * 4 ~/ 3);
            if (origH > targetH) {
              int offsetY = (origH - targetH) ~/ 2;
              capturedImage = img.copyCrop(
                capturedImage,
                x: 0,
                y: offsetY,
                width: origW,
                height: targetH,
              );
            }
          } else {
            int targetW = (origH * 4 ~/ 3);
            if (origW > targetW) {
              int offsetX = (origW - targetW) ~/ 2;
              capturedImage = img.copyCrop(
                capturedImage,
                x: offsetX,
                y: 0,
                width: targetW,
                height: origH,
              );
            }
          }
        }

        String dateTime = DateTime.now().toString().substring(0, 16);
        String dateOnly = dateTime.substring(0, 10);
        String directionEn = _getDirectionEn(_azimuth);

        double acc = _currentPosition!.accuracy;
        double altAcc = acc * 1.5;

        String waterMarkText =
            'Lat: ${_currentPosition!.latitude.toStringAsFixed(6)} (+-${acc.toStringAsFixed(1)}m)\n'
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

        final savedPath =
            '$folderPath/photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final savedFile = File(savedPath);
        await savedFile.writeAsBytes(outBytes);

        final int azimuthNum = (_azimuth.clamp(0.0, 360.0) * 100).round();
        final int altitudeNum = (_currentPosition!.altitude.abs() * 100).round();

        final exif = await Exif.fromPath(savedPath);
        await exif.writeAttributes({
          'GPSLatitude': _currentPosition!.latitude.abs().toString(),
          'GPSLatitudeRef': _currentPosition!.latitude >= 0 ? 'N' : 'S',
          'GPSLongitude': _currentPosition!.longitude.abs().toString(),
          'GPSLongitudeRef': _currentPosition!.longitude >= 0 ? 'E' : 'W',
          'GPSAltitude': '$altitudeNum/100',
          'GPSAltitudeRef': _currentPosition!.altitude >= 0 ? '0' : '1',
          'GPSImgDirection': '$azimuthNum/100',
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('사진이 촬영되어 저장되었습니다!')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('에러 발생: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
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
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    String directionStr = _getDirection(_azimuth);
    String displayLocation = "위치 정보 찾는 중...";
    if (_currentPosition != null) {
      double acc = _currentPosition!.accuracy;
      double altAcc = acc * 1.5;
      displayLocation =
          "위도: ${_currentPosition!.latitude.toStringAsFixed(6)} (±${acc.toStringAsFixed(1)}m)\n"
          "경도: ${_currentPosition!.longitude.toStringAsFixed(6)} (±${acc.toStringAsFixed(1)}m)\n"
          "표고: ${_currentPosition!.altitude.toStringAsFixed(1)}m (±${altAcc.toStringAsFixed(1)}m)";
    }

    String displaySensor =
        "방위각: ${_azimuth.toStringAsFixed(1)}° ($directionStr)\n피치각: ${_pitch.toStringAsFixed(1)}°";

    bool isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
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
                      backgroundColor:
                          isSelected ? Colors.amber : Colors.black54,
                      foregroundColor:
                          isSelected ? Colors.black : Colors.white,
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
                '$displayLocation\n$displaySensor\n시간: ${DateTime.now().toString().substring(0, 16)}',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
          Positioned(
            bottom: 35,
            right: 30,
            child: FloatingActionButton(
              heroTag: 'galleryBtn',
              onPressed:
                  _capturedPhotos.isEmpty ? null : _openGalleryMapDashboard,
              backgroundColor:
                  _capturedPhotos.isEmpty ? Colors.grey : Colors.blueAccent,
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
                child: const Icon(
                  Icons.camera_alt,
                  color: Colors.black,
                  size: 30,
                ),
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

  String? _bpImagePath;
  double? _bpCenterLat;
  double? _bpCenterLng;
  double _bpRadiusMeters = 150.0;
  double _bpRotation = 0.0;
  double _bpOpacity = 0.5; // 💡 도면 최초 가져오기 시 투명도 50%로 기본 설정
  bool _bpVisible = true;
  bool _isEditingBlueprint = false;
  NOverlayImage? _cachedBlueprintIcon;

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
    _loadBlueprintData();
  }

  Future<void> _loadBlueprintData() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/blueprint_meta.json');
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        final String? path = data['imagePath'];
        if (path != null && File(path).existsSync()) {
          setState(() {
            _bpImagePath = path;
            _bpCenterLat = (data['centerLat'] as num?)?.toDouble();
            _bpCenterLng = (data['centerLng'] as num?)?.toDouble();
            _bpRadiusMeters =
                (data['radiusMeters'] as num?)?.toDouble() ?? 150.0;
            _bpRotation = (data['rotation'] as num?)?.toDouble() ?? 0.0;
            _bpOpacity = (data['opacity'] as num?)?.toDouble() ?? 0.5;
            _bpVisible = data['isVisible'] ?? true;
          });
          if (_mapController != null) {
            await _updateBlueprintOverlay(rebuildImage: true);
          }
        }
      }
    } catch (e) {
      debugPrint("도면 데이터 로드 에러: $e");
    }
  }

  Future<void> _saveBlueprintData() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/blueprint_meta.json');
      final data = {
        'imagePath': _bpImagePath,
        'centerLat': _bpCenterLat,
        'centerLng': _bpCenterLng,
        'radiusMeters': _bpRadiusMeters,
        'rotation': _bpRotation,
        'opacity': _bpOpacity,
        'isVisible': _bpVisible,
      };
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint("도면 데이터 저장 에러: $e");
    }
  }

  Future<void> _pickBlueprintImage() async {
    try {
      final picker = ImagePicker();
      final XFile? picked = await picker.pickImage(source: ImageSource.gallery);
      if (picked == null) return;

      final dir = await getApplicationDocumentsDirectory();
      final String ext = picked.path.split('.').last;
      final String savedPath =
          '${dir.path}/blueprint_${DateTime.now().millisecondsSinceEpoch}.$ext';
      await File(picked.path).copy(savedPath);

      double initLat = _filteredPhotos.isNotEmpty
          ? _filteredPhotos[_selectedIndex].latitude
          : 37.5665;
      double initLng = _filteredPhotos.isNotEmpty
          ? _filteredPhotos[_selectedIndex].longitude
          : 126.9780;
      if (_mapController != null) {
        final pos = await _mapController!.getCameraPosition();
        initLat = pos.target.latitude;
        initLng = pos.target.longitude;
      }

      setState(() {
        _bpImagePath = savedPath;
        _bpCenterLat = initLat;
        _bpCenterLng = initLng;
        _bpRadiusMeters = 150.0; // 💡 지도 화면 크기의 약 60%에 해당하는 기본 반경 설정
        _bpOpacity = 0.5;       // 💡 투명도 50% 즉시 적용
        _bpRotation = 0.0;
        _bpVisible = true;
        _isEditingBlueprint = true;
      });

      await _saveBlueprintData();
      await _updateBlueprintOverlay(rebuildImage: true);
    } catch (e) {
      debugPrint("도면 가져오기 에러: $e");
    }
  }

  Future<void> _updateBlueprintOverlay({bool rebuildImage = false}) async {
    if (_mapController == null) return;

    if (_bpImagePath == null ||
        !_bpVisible ||
        _bpCenterLat == null ||
        _bpCenterLng == null) {
      await _updateMarkers(skipBlueprint: true);
      return;
    }

    try {
      if (rebuildImage || _cachedBlueprintIcon == null) {
        if (!mounted) return;
        _cachedBlueprintIcon = await NOverlayImage.fromWidget(
          widget: Opacity(
            opacity: _bpOpacity.clamp(0.1, 1.0),
            child: Transform.rotate(
              angle: _bpRotation * (pi / 180),
              child: Padding(
                padding: const EdgeInsets.all(60),
                child: Image.file(
                  File(_bpImagePath!),
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
          size: const Size(500, 500),
          context: context,
        );
      }

      final double dLat = _bpRadiusMeters / 111320.0;
      final double cosLat =
          cos(_bpCenterLat! * pi / 180.0).abs().clamp(0.1, 1.0);
      final double dLng = _bpRadiusMeters / (111320.0 * cosLat);

      final bounds = NLatLngBounds(
        southWest: NLatLng(_bpCenterLat! - dLat, _bpCenterLng! - dLng),
        northEast: NLatLng(_bpCenterLat! + dLat, _bpCenterLng! + dLng),
      );

      final groundOverlay = NGroundOverlay(
        id: 'blueprint_ground_overlay',
        bounds: bounds,
        image: _cachedBlueprintIcon!,
      );

      _mapController!.addOverlay(groundOverlay);
    } catch (e) {
      debugPrint("도면 오버레이 업데이트 에러: $e");
    }
  }

  void _nudgeBlueprint(double dNorthMeters, double dEastMeters) {
    if (_bpCenterLat == null || _bpCenterLng == null) return;
    final double dLat = dNorthMeters / 111320.0;
    final double cosLat =
        cos(_bpCenterLat! * pi / 180.0).abs().clamp(0.1, 1.0);
    final double dLng = dEastMeters / (111320.0 * cosLat);

    setState(() {
      _bpCenterLat = _bpCenterLat! + dLat;
      _bpCenterLng = _bpCenterLng! + dLng;
    });
    _updateBlueprintOverlay(rebuildImage: false);
  }

  void _moveCameraKeepZoom(double lat, double lng) {
    if (_mapController == null) return;
    _mapController!.updateCamera(
      NCameraUpdate.scrollAndZoomTo(
        target: NLatLng(lat, lng),
      ),
    );
  }

  void _onDateChanged(String? newDate) {
    if (newDate != null) {
      setState(() {
        _selectedDate = newDate;
        _selectedIndex =
            _filteredPhotos.isNotEmpty ? _filteredPhotos.length - 1 : 0;
      });
      _updateMarkers();

      if (_filteredPhotos.isNotEmpty) {
        final photo = _filteredPhotos[_selectedIndex];
        _moveCameraKeepZoom(photo.latitude, photo.longitude);
      }
    }
  }

  Widget _buildBlueprintEditPanel() {
    return Container(
      color: Colors.grey[900],
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '📐 도면 정렬 모드 (지도 터치 시 이동)',
                  style: TextStyle(
                    color: Colors.amber,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: () async {
                    await _saveBlueprintData();
                    setState(() {
                      _isEditingBlueprint = false;
                    });
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('도면 위치와 설정이 지도에 영구 고정되었습니다!'),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('고정 및 저장'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber,
                    foregroundColor: Colors.black,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  ),
                ),
              ],
            ),
            const Divider(color: Colors.white24, height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                ElevatedButton.icon(
                  onPressed: () async {
                    if (_mapController != null) {
                      final pos = await _mapController!.getCameraPosition();
                      setState(() {
                        _bpCenterLat = pos.target.latitude;
                        _bpCenterLng = pos.target.longitude;
                      });
                      _updateBlueprintOverlay(rebuildImage: false);
                    }
                  },
                  icon: const Icon(Icons.my_location, size: 15),
                  label: const Text('화면 중앙으로', style: TextStyle(fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueGrey,
                    foregroundColor: Colors.white,
                  ),
                ),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back,
                          color: Colors.white, size: 20),
                      onPressed: () => _nudgeBlueprint(0, -3),
                    ),
                    IconButton(
                      icon: const Icon(Icons.arrow_upward,
                          color: Colors.white, size: 20),
                      onPressed: () => _nudgeBlueprint(3, 0),
                    ),
                    IconButton(
                      icon: const Icon(Icons.arrow_downward,
                          color: Colors.white, size: 20),
                      onPressed: () => _nudgeBlueprint(-3, 0),
                    ),
                    IconButton(
                      icon: const Icon(Icons.arrow_forward,
                          color: Colors.white, size: 20),
                      onPressed: () => _nudgeBlueprint(0, 3),
                    ),
                  ],
                ),
              ],
            ),
            Row(
              children: [
                SizedBox(
                  width: 85,
                  child: Text(
                    '크기: ${_bpRadiusMeters.toInt()}m',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline,
                      color: Colors.white70, size: 20),
                  onPressed: () {
                    setState(() {
                      _bpRadiusMeters =
                          (_bpRadiusMeters - 5).clamp(10.0, 2000.0);
                    });
                    _updateBlueprintOverlay(rebuildImage: false);
                  },
                ),
                Expanded(
                  child: Slider(
                    value: _bpRadiusMeters.clamp(10.0, 2000.0),
                    min: 10.0,
                    max: 2000.0,
                    activeColor: Colors.amber,
                    onChanged: (val) {
                      setState(() {
                        _bpRadiusMeters = val;
                      });
                      _updateBlueprintOverlay(rebuildImage: false);
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline,
                      color: Colors.white70, size: 20),
                  onPressed: () {
                    setState(() {
                      _bpRadiusMeters =
                          (_bpRadiusMeters + 5).clamp(10.0, 2000.0);
                    });
                    _updateBlueprintOverlay(rebuildImage: false);
                  },
                ),
              ],
            ),
            Row(
              children: [
                SizedBox(
                  width: 85,
                  child: Text(
                    '회전: ${_bpRotation.toStringAsFixed(1)}°',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.rotate_left,
                      color: Colors.white70, size: 20),
                  onPressed: () {
                    setState(() {
                      _bpRotation = (_bpRotation - 1.0).clamp(-180.0, 180.0);
                    });
                    _updateBlueprintOverlay(rebuildImage: true);
                  },
                ),
                Expanded(
                  child: Slider(
                    value: _bpRotation.clamp(-180.0, 180.0),
                    min: -180.0,
                    max: 180.0,
                    activeColor: Colors.amber,
                    onChanged: (val) {
                      setState(() {
                        _bpRotation = val;
                      });
                    },
                    onChangeEnd: (val) {
                      _updateBlueprintOverlay(rebuildImage: true);
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.rotate_right,
                      color: Colors.white70, size: 20),
                  onPressed: () {
                    setState(() {
                      _bpRotation = (_bpRotation + 1.0).clamp(-180.0, 180.0);
                    });
                    _updateBlueprintOverlay(rebuildImage: true);
                  },
                ),
              ],
            ),
            Row(
              children: [
                SizedBox(
                  width: 85,
                  child: Text(
                    '투명도: ${(_bpOpacity * 100).toInt()}%',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: _bpOpacity.clamp(0.1, 1.0),
                    min: 0.1,
                    max: 1.0,
                    activeColor: Colors.amber,
                    onChanged: (val) {
                      setState(() {
                        _bpOpacity = val;
                      });
                    },
                    onChangeEnd: (val) {
                      _updateBlueprintOverlay(rebuildImage: true);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    List<String> dateOptions = ['전체 보기'];
    Set<String> uniqueDates =
        widget.photos.map((p) => p.time.substring(0, 10)).toSet();
    List<String> sortedDates = uniqueDates.toList()
      ..sort((a, b) => b.compareTo(a));
    dateOptions.addAll(sortedDates);

    bool isPortrait =
        MediaQuery.of(context).orientation == Orientation.portrait;

    if (_filteredPhotos.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: const Text('지도 대시보드'),
        ),
        body: const Center(
          child: Text(
            "해당 날짜에 찍은 사진이 없습니다.",
            style: TextStyle(color: Colors.white),
          ),
        ),
      );
    }

    final currentPhoto = _filteredPhotos[_selectedIndex];

    // 💡 사진을 두 손가락으로 확대/축소(Pinch-to-Zoom)해서 볼 수 있도록 InteractiveViewer 적용
    Widget photoSection = _isEditingBlueprint
        ? _buildBlueprintEditPanel()
        : Container(
            color: Colors.black,
            width: double.infinity,
            height: double.infinity,
            child: InteractiveViewer(
              panEnabled: true,
              boundaryMargin: const EdgeInsets.all(20),
              minScale: 0.5,
              maxScale: 4.0,
              child: Center(
                child: Image.file(File(currentPhoto.path), fit: BoxFit.contain),
              ),
            ),
          );

    Widget mapSection = globalNaverAuthError != null
        ? Container(
            color: Colors.white,
            padding: const EdgeInsets.all(20),
            child: Center(
              child: Text(
                '🚨 네이버 지도 차단됨!\n\n$globalNaverAuthError',
                style: const TextStyle(
                  color: Colors.red,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
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
            onMapReady: (controller) async {
              _mapController = controller;
              await _updateMarkers();
            },
            onMapTapped: (point, latLng) {
              if (_isEditingBlueprint && _bpImagePath != null) {
                setState(() {
                  _bpCenterLat = latLng.latitude;
                  _bpCenterLng = latLng.longitude;
                });
                _updateBlueprintOverlay(rebuildImage: false);
              }
            },
          );

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: DropdownButton<String>(
          value: _selectedDate,
          dropdownColor: Colors.black87,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
          underline: Container(),
          icon: const Icon(Icons.arrow_drop_down, color: Colors.white),
          items: dateOptions
              .map((date) => DropdownMenuItem(value: date, child: Text(date)))
              .toList(),
          onChanged: _onDateChanged,
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          TextButton.icon(
            onPressed: _pickBlueprintImage,
            icon: const Icon(Icons.add_photo_alternate,
                color: Colors.amber, size: 18),
            label: const Text(
              '도면가져오기',
              style: TextStyle(color: Colors.amber, fontSize: 12),
            ),
          ),
          if (_bpImagePath != null) ...[
            IconButton(
              icon: Icon(
                _bpVisible ? Icons.layers : Icons.layers_clear,
                color: _bpVisible ? Colors.lightGreenAccent : Colors.grey,
              ),
              onPressed: () async {
                setState(() {
                  _bpVisible = !_bpVisible;
                  if (!_bpVisible) _isEditingBlueprint = false;
                });
                await _saveBlueprintData();
                await _updateMarkers();
              },
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: ElevatedButton(
                onPressed: () async {
                  if (_isEditingBlueprint) {
                    await _saveBlueprintData();
                  }
                  setState(() {
                    _isEditingBlueprint = !_isEditingBlueprint;
                  });
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      _isEditingBlueprint ? Colors.amber : Colors.blueAccent,
                  foregroundColor:
                      _isEditingBlueprint ? Colors.black : Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: Text(
                  _isEditingBlueprint ? '고정저장' : '도면정렬',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ],
        ],
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
                    setState(() {
                      _selectedIndex = index;
                    });
                    _updateMarkers();
                    _moveCameraKeepZoom(
                      _filteredPhotos[index].latitude,
                      _filteredPhotos[index].longitude,
                    );
                  },
                  child: Container(
                    margin:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: isSelected ? Colors.amber : Colors.transparent,
                        width: 3,
                      ),
                    ),
                    child: Image.file(
                      File(_filteredPhotos[index].path),
                      width: 70,
                      height: 70,
                      fit: BoxFit.cover,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _updateMarkers({bool skipBlueprint = false}) async {
    if (_mapController == null) return;
    _mapController!.clearOverlays();

    if (!skipBlueprint && _bpImagePath != null && _bpVisible) {
      await _updateBlueprintOverlay(rebuildImage: false);
    }

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
          List<int> overlappingIndices = [];
          for (int j = 0; j < _filteredPhotos.length; j++) {
            double dist = Geolocator.distanceBetween(
              photo.latitude,
              photo.longitude,
              _filteredPhotos[j].latitude,
              _filteredPhotos[j].longitude,
            );
            if (dist <= 20.0) {
              overlappingIndices.add(j);
            }
          }

          int nextIndex = i;
          if (overlappingIndices.length > 1 &&
              overlappingIndices.contains(_selectedIndex)) {
            int currentOrder = overlappingIndices.indexOf(_selectedIndex);
            nextIndex =
                overlappingIndices[(currentOrder + 1) % overlappingIndices.length];
          } else {
            nextIndex = i;
          }

          setState(() {
            _selectedIndex = nextIndex;
          });

          await _updateMarkers();
          final targetPhoto = _filteredPhotos[_selectedIndex];
          _moveCameraKeepZoom(targetPhoto.latitude, targetPhoto.longitude);
        });

        _mapController!.addOverlay(marker);
      } catch (e) {
        debugPrint('마커 생성 에러: $e');
      }
    }
  }
}
