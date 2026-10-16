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

List<CameraDescription> appCameras = [];
String? naverAuthErrorMsg;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    appCameras = await availableCameras();
  } catch (e) {
    debugPrint('Camera init error: $e');
  }

  try {
    await FlutterNaverMap().init(
      clientId: 'b3agnvaern',
      onAuthFailed: (ex) {
        naverAuthErrorMsg = '인증 실패 에러:\n$ex';
      },
    );
  } catch (e) {
    naverAuthErrorMsg = '초기화 에러: $e';
  }

  runApp(const MaterialApp(
    home: CameraScreen(),
    debugShowCheckedModeBanner: false,
  ));
}

class PhotoItem {
  final String path;
  final double lat;
  final double lng;
  final double alt;
  final double acc;
  final double azimuth;
  final double pitch;
  final String timestamp;

  PhotoItem({
    required this.path,
    required this.lat,
    required this.lng,
    required this.alt,
    required this.acc,
    required this.azimuth,
    required this.pitch,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() => {
        'path': path,
        'latitude': lat,
        'longitude': lng,
        'altitude': alt,
        'accuracy': acc,
        'azimuth': azimuth,
        'pitch': pitch,
        'time': timestamp,
      };

  factory PhotoItem.fromMap(Map<String, dynamic> m) => PhotoItem(
        path: m['path'] as String,
        lat: (m['latitude'] as num).toDouble(),
        lng: (m['longitude'] as num).toDouble(),
        alt: (m['altitude'] as num).toDouble(),
        acc: (m['accuracy'] as num).toDouble(),
        azimuth: (m['azimuth'] as num).toDouble(),
        pitch: (m['pitch'] as num).toDouble(),
        timestamp: m['time'] as String,
      );
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _camController;
  Position? _pos;
  double _heading = 0;
  double _tiltPitch = 0;
  bool _busy = false;
  String _ratioMode = '16:9';
  final List<PhotoItem> _photoList = [];

  @override
  void initState() {
    super.initState();
    _setupApp();
  }

  Future<void> _setupApp() async {
    await [
      Permission.camera,
      Permission.location,
      Permission.storage,
      Permission.photos,
    ].request();
    await _restorePhotos();
    _startCamera();
    _startLocationStream();
    _startSensorStreams();
  }

  Future<void> _persistPhotos() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final metaFile = File('${dir.path}/photos_meta.json');
      final raw = jsonEncode(_photoList.map((e) => e.toMap()).toList());
      await metaFile.writeAsString(raw);
    } catch (e) {
      debugPrint('Save photo meta error: $e');
    }
  }

  Future<void> _restorePhotos() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final metaFile = File('${dir.path}/photos_meta.json');
      if (!await metaFile.exists()) return;
      final List<dynamic> decoded = jsonDecode(await metaFile.readAsString());
      setState(() {
        _photoList.clear();
        for (final item in decoded) {
          final p = PhotoItem.fromMap(item as Map<String, dynamic>);
          if (File(p.path).existsSync()) {
            _photoList.add(p);
          }
        }
      });
    } catch (e) {
      debugPrint('Load photo meta error: $e');
    }
  }

  Future<void> _startCamera() async {
    if (appCameras.isEmpty) return;
    _camController = CameraController(
      appCameras.first,
      ResolutionPreset.high,
      enableAudio: false,
    );
    await _camController!.initialize();
    if (mounted) setState(() {});
  }

  void _startLocationStream() {
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    ).listen((Position p) {
      if (mounted) setState(() => _pos = p);
    });
  }

  void _startSensorStreams() {
    accelerometerEventStream().listen((AccelerometerEvent a) {
      if (!mounted) return;
      setState(() {
        _tiltPitch = atan2(a.y, sqrt(a.x * a.x + a.z * a.z)) * 180 / pi;
      });
    });

    FlutterCompass.events?.listen((CompassEvent c) {
      if (!mounted || c.heading == null) return;
      setState(() {
        _heading = (c.heading! % 360 + 360) % 360;
      });
    });
  }

  String _compassLabel(double deg, {bool korean = true}) {
    const enDirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    const krDirs = [
      'N (북)',
      'NE (북동)',
      'E (동)',
      'SE (남동)',
      'S (남)',
      'SW (남서)',
      'W (서)',
      'NW (북서)'
    ];
    final idx = (((deg + 22.5) % 360) ~/ 45).clamp(0, 7);
    return korean ? krDirs[idx] : enDirs[idx];
  }

  Future<void> _capturePhoto() async {
    if (_camController == null ||
        !_camController!.value.isInitialized ||
        _busy) {
      return;
    }
    setState(() => _busy = true);

    try {
      SystemSound.play(SystemSoundType.alert);
      HapticFeedback.heavyImpact();
      Future.delayed(const Duration(milliseconds: 150), () {
        HapticFeedback.heavyImpact();
      });

      final XFile rawFile = await _camController!.takePicture();
      final Uint8List rawBytes = await rawFile.readAsBytes();
      img.Image? decodedImg = img.decodeImage(rawBytes);

      if (decodedImg != null && _pos != null) {
        final int w = decodedImg.width;
        final int h = decodedImg.height;

        if (_ratioMode == '1:1') {
          final int s = min(w, h);
          decodedImg = img.copyCrop(
            decodedImg,
            x: (w - s) ~/ 2,
            y: (h - s) ~/ 2,
            width: s,
            height: s,
          );
        } else if (_ratioMode == '4:3') {
          if (h > w) {
            final int th = w * 4 ~/ 3;
            if (h > th) {
              decodedImg = img.copyCrop(
                decodedImg,
                x: 0,
                y: (h - th) ~/ 2,
                width: w,
                height: th,
              );
            }
          } else {
            final int tw = h * 4 ~/ 3;
            if (w > tw) {
              decodedImg = img.copyCrop(
                decodedImg,
                x: (w - tw) ~/ 2,
                y: 0,
                width: tw,
                height: h,
              );
            }
          }
        }

        final String nowStr = DateTime.now().toString().substring(0, 16);
        final String folderDate = nowStr.substring(0, 10);
        final String dirEn = _compassLabel(_heading, korean: false);
        final double hAcc = _pos!.accuracy;
        final double vAcc = hAcc * 1.5;

        final String stamp =
            'Lat: ${_pos!.latitude.toStringAsFixed(6)} (+-${hAcc.toStringAsFixed(1)}m)\n'
            'Lng: ${_pos!.longitude.toStringAsFixed(6)} (+-${hAcc.toStringAsFixed(1)}m)\n'
            'Alt: ${_pos!.altitude.toStringAsFixed(1)}m (+-${vAcc.toStringAsFixed(1)}m)\n'
            'Azimuth: ${_heading.toStringAsFixed(1)} deg ($dirEn)\n'
            'Pitch: ${_tiltPitch.toStringAsFixed(1)} deg\n'
            'Time: $nowStr';

        img.drawString(
          decodedImg,
          stamp,
          font: img.arial24,
          x: 20,
          y: decodedImg.height - 220,
          color: img.ColorRgb8(255, 200, 50),
        );

        final List<int> jpgBytes = img.encodeJpg(decodedImg, quality: 90);
        final Directory docDir = await getApplicationDocumentsDirectory();
        final Directory dayDir = Directory('${docDir.path}/$folderDate');
        if (!await dayDir.exists()) {
          await dayDir.create(recursive: true);
        }

        final String targetPath =
            '${dayDir.path}/photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
        await File(targetPath).writeAsBytes(jpgBytes);

        final int azRational = (_heading.clamp(0.0, 360.0) * 100).round();
        final int altRational = (_pos!.altitude.abs() * 100).round();

        final exif = await Exif.fromPath(targetPath);
        await exif.writeAttributes({
          'GPSLatitude': _pos!.latitude.abs().toString(),
          'GPSLatitudeRef': _pos!.latitude >= 0 ? 'N' : 'S',
          'GPSLongitude': _pos!.longitude.abs().toString(),
          'GPSLongitudeRef': _pos!.longitude >= 0 ? 'E' : 'W',
          'GPSAltitude': '$altRational/100',
          'GPSAltitudeRef': _pos!.altitude >= 0 ? '0' : '1',
          'GPSImgDirection': '$azRational/100',
          'GPSImgDirectionRef': 'T',
        });
        await exif.close();

        await Gal.putImage(targetPath);

        setState(() {
          _photoList.add(PhotoItem(
            path: targetPath,
            lat: _pos!.latitude,
            lng: _pos!.longitude,
            alt: _pos!.altitude,
            acc: hAcc,
            azimuth: _heading,
            pitch: _tiltPitch,
            timestamp: nowStr,
          ));
        });

        await _persistPhotos();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('사진이 촬영되어 저장되었습니다!')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('촬영 오류: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_camController == null || !_camController!.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    final String dirKr = _compassLabel(_heading, korean: true);
    String locInfo = '위치 정보 수신 중...';
    if (_pos != null) {
      final double acc = _pos!.accuracy;
      locInfo = '위도: ${_pos!.latitude.toStringAsFixed(6)} (±${acc.toStringAsFixed(1)}m)\n'
          '경도: ${_pos!.longitude.toStringAsFixed(6)} (±${acc.toStringAsFixed(1)}m)\n'
          '표고: ${_pos!.altitude.toStringAsFixed(1)}m (±${(acc * 1.5).toStringAsFixed(1)}m)';
    }

    final bool landscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final double ratio = _ratioMode == '1:1'
        ? 1.0
        : (_ratioMode == '4:3'
            ? (landscape ? 4 / 3 : 3 / 4)
            : (landscape ? 16 / 9 : 9 / 16));

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: ratio,
              child: CameraPreview(_camController!),
            ),
          ),
          Positioned(
            top: 50,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: ['16:9', '4:3', '1:1'].map((m) {
                final bool active = _ratioMode == m;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: ElevatedButton(
                    onPressed: () => setState(() => _ratioMode = m),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: active ? Colors.amber : Colors.black54,
                      foregroundColor: active ? Colors.black : Colors.white,
                    ),
                    child: Text(m),
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
                '$locInfo\n방위각: ${_heading.toStringAsFixed(1)}° ($dirKr)\n'
                '피치각: ${_tiltPitch.toStringAsFixed(1)}°\n'
                '시간: ${DateTime.now().toString().substring(0, 16)}',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
          Positioned(
            bottom: 35,
            right: 30,
            child: FloatingActionButton(
              heroTag: 'mapDashboardBtn',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => GalleryMapDashboard(photos: _photoList),
                  ),
                );
              },
              backgroundColor: Colors.blueAccent,
              child: const Icon(Icons.map, color: Colors.white),
            ),
          ),
          Positioned(
            bottom: 25,
            left: 0,
            right: 0,
            child: Center(
              child: FloatingActionButton(
                heroTag: 'shutterBtn',
                onPressed: _capturePhoto,
                backgroundColor: Colors.amber,
                child: const Icon(Icons.camera_alt, color: Colors.black, size: 30),
              ),
            ),
          ),
          if (_busy)
            const Center(child: CircularProgressIndicator(color: Colors.white)),
        ],
      ),
    );
  }
}

class GalleryMapDashboard extends StatefulWidget {
  final List<PhotoItem> photos;
  const GalleryMapDashboard({super.key, required this.photos});

  @override
  State<GalleryMapDashboard> createState() => _GalleryMapDashboardState();
}

class _GalleryMapDashboardState extends State<GalleryMapDashboard> {
  int _selectedIdx = 0;
  NaverMapController? _mapCtrl;
  String _dateFilter = '전체 보기';

  // 도면(Blueprint) 상태 변수
  String? _bpPath;
  double? _bpLat;
  double? _bpLng;
  double _bpBaseRadius = 100.0; // 지도 절반 크기에 해당하는 기준 반경(m)
  double _bpSizeSlider = 0.5;   // 크기 슬라이더 위치 (0.0 ~ 1.0, 기본값 0.5 = 정중앙!)
  double _bpRotation = 0.0;     // 회전 각도 (-180 ~ 180, 기본값 0.0 = 정중앙!)
  double _bpOpacity = 0.5;      // 투명도 (0.1 ~ 1.0, 기본값 0.5 = 50%!)
  bool _bpShow = true;
  bool _bpEditMode = false;

  NOverlayImage? _bpCachedOverlayImg;
  bool _isRenderingBp = false;
  bool _pendingBpRender = false;

  // 슬라이더 값(0.0~1.0)을 실제 반경(m)으로 변환 (0.5일 때 정확히 기준 크기 1.0배)
  double get _currentBpRadius =>
      _bpBaseRadius * pow(9.0, _bpSizeSlider - 0.5).toDouble();

  List<PhotoItem> get _visiblePhotos {
    if (_dateFilter == '전체 보기') return widget.photos;
    return widget.photos
        .where((p) => p.timestamp.startsWith(_dateFilter))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    if (_visiblePhotos.isNotEmpty) {
      _selectedIdx = _visiblePhotos.length - 1;
    }
  }

  // 저장된 도면 정보를 디스크에서 읽어오고 이미지 프리캐시 수행
  Future<void> _restoreBlueprintConfig() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final cfgFile = File('${dir.path}/blueprint_config.json');
      if (!await cfgFile.exists()) return;

      final Map<String, dynamic> data =
          jsonDecode(await cfgFile.readAsString());
      final String? savedPath = data['imagePath'] as String?;

      if (savedPath != null && File(savedPath).existsSync()) {
        // 이미지를 미리 메모리에 로드해 두어야 첫 화면에서 투명도 조작 없이 즉시 보임!
        if (mounted) {
          await precacheImage(FileImage(File(savedPath)), context);
        }
        setState(() {
          _bpPath = savedPath;
          _bpLat = (data['centerLat'] as num?)?.toDouble();
          _bpLng = (data['centerLng'] as num?)?.toDouble();
          _bpBaseRadius = (data['baseRadius'] as num?)?.toDouble() ?? 100.0;
          _bpSizeSlider =
              ((data['sizeSlider'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0);
          _bpRotation =
              ((data['rotation'] as num?)?.toDouble() ?? 0.0).clamp(-180.0, 180.0);
          _bpOpacity =
              ((data['opacity'] as num?)?.toDouble() ?? 0.5).clamp(0.1, 1.0);
          _bpShow = data['isVisible'] as bool? ?? true;
        });
      }
    } catch (e) {
      debugPrint('Blueprint restore error: $e');
    }
  }

  // 도면 설정 변경 시마다 즉시 영구 저장
  Future<void> _persistBlueprintConfig() async {
    if (_bpPath == null) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final cfgFile = File('${dir.path}/blueprint_config.json');
      final Map<String, dynamic> data = {
        'imagePath': _bpPath,
        'centerLat': _bpLat,
        'centerLng': _bpLng,
        'baseRadius': _bpBaseRadius,
        'sizeSlider': _bpSizeSlider,
        'rotation': _bpRotation,
        'opacity': _bpOpacity,
        'isVisible': _bpShow,
      };
      await cfgFile.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint('Blueprint save error: $e');
    }
  }

  // 현재 지도 화면 크기의 절반(50%)에 해당하는 반경(m) 계산
  Future<double> _calcHalfScreenRadius() async {
    if (_mapCtrl == null) return 100.0;
    try {
      final bounds = await _mapCtrl!.getContentBounds();
      final double widthMeters = Geolocator.distanceBetween(
        bounds.southWest.latitude,
        bounds.southWest.longitude,
        bounds.southWest.latitude,
        bounds.northEast.longitude,
      );
      final double heightMeters = Geolocator.distanceBetween(
        bounds.southWest.latitude,
        bounds.southWest.longitude,
        bounds.northEast.latitude,
        bounds.southWest.longitude,
      );
      final double minSpan = min(widthMeters, heightMeters);
      // 지도 화면 절반 크기가 되도록 전체 폭의 1/4(반경 기준)로 설정
      return (minSpan * 0.28).clamp(15.0, 1000.0);
    } catch (_) {
      return 100.0;
    }
  }

  // 갤러리에서 도면 가져온 직후 투명도 50%, 지도 절반 크기, 조절바 중간값으로 즉시 표시
  Future<void> _importBlueprintFromGallery() async {
    try {
      final picker = ImagePicker();
      final XFile? picked = await picker.pickImage(source: ImageSource.gallery);
      if (picked == null) return;

      final dir = await getApplicationDocumentsDirectory();
      final String ext = picked.path.split('.').last;
      final String destPath =
          '${dir.path}/bp_saved_${DateTime.now().millisecondsSinceEpoch}.$ext';
      await File(picked.path).copy(destPath);

      // 핵심: 파일 이미지를 메모리에 완전히 디코딩될 때까지 대기 후 지도에 렌더링
      if (!mounted) return;
      final fileProvider = FileImage(File(destPath));
      await fileProvider.evict();
      if (!mounted) return;
      await precacheImage(fileProvider, context);

      double centerLat = _visiblePhotos.isNotEmpty
          ? _visiblePhotos[_selectedIdx].lat
          : 37.4984;
      double centerLng = _visiblePhotos.isNotEmpty
          ? _visiblePhotos[_selectedIdx].lng
          : 127.1324;

      if (_mapCtrl != null) {
        final camPos = await _mapCtrl!.getCameraPosition();
        centerLat = camPos.target.latitude;
        centerLng = camPos.target.longitude;
      }

      final double halfScreenRad = await _calcHalfScreenRadius();

      setState(() {
        _bpPath = destPath;
        _bpLat = centerLat;
        _bpLng = centerLng;
        _bpBaseRadius = halfScreenRad;
        _bpSizeSlider = 0.5; // 크기 조절바 정중앙!
        _bpOpacity = 0.5;    // 투명도 50%!
        _bpRotation = 0.0;   // 회전 조절바 정중앙!
        _bpShow = true;
        _bpEditMode = true;
        _bpCachedOverlayImg = null;
      });

      await _persistBlueprintConfig();
      await _renderBlueprintOnMap(rebuildBitmap: true);
    } catch (e) {
      debugPrint('Import blueprint error: $e');
    }
  }

  // 회전이나 투명도 조절 시 프레임이 밀리지 않고 실시간으로 빠르게 돌아가도록 처리
  Future<void> _renderBlueprintOnMap({bool rebuildBitmap = false}) async {
    if (_mapCtrl == null) return;

    if (_bpPath == null || !_bpShow || _bpLat == null || _bpLng == null) {
      await _refreshAllOverlays(includeBlueprint: false);
      return;
    }

    if (rebuildBitmap) {
      if (_isRenderingBp) {
        _pendingBpRender = true;
        return;
      }
      _isRenderingBp = true;
    }

    try {
      do {
        _pendingBpRender = false;
        if (rebuildBitmap || _bpCachedOverlayImg == null) {
          if (!mounted) return;
          _bpCachedOverlayImg = await NOverlayImage.fromWidget(
            widget: Opacity(
              opacity: _bpOpacity.clamp(0.1, 1.0),
              child: Transform.rotate(
                angle: _bpRotation * (pi / 180.0),
                child: Padding(
                  padding: const EdgeInsets.all(36),
                  child: Image.file(
                    File(_bpPath!),
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
            // 320x320 사이즈로 최적화하여 회전 슬라이더 드래그 시에도 크기 조절처럼 즉각 회전!
            size: const Size(320, 320),
            context: context,
          );
        }

        final double rad = _currentBpRadius;
        final double dLat = rad / 111320.0;
        final double cosLat = cos(_bpLat! * pi / 180.0).abs().clamp(0.1, 1.0);
        final double dLng = rad / (111320.0 * cosLat);

        final bounds = NLatLngBounds(
          southWest: NLatLng(_bpLat! - dLat, _bpLng! - dLng),
          northEast: NLatLng(_bpLat! + dLat, _bpLng! + dLng),
        );

        final groundOverlay = NGroundOverlay(
          id: 'blueprint_ground_overlay',
          bounds: bounds,
          image: _bpCachedOverlayImg!,
        );

        await _mapCtrl!.addOverlay(groundOverlay);
      } while (_pendingBpRender && mounted);
    } catch (e) {
      debugPrint('Render blueprint error: $e');
    } finally {
      _isRenderingBp = false;
    }
  }

  void _shiftBlueprintMeters(double northM, double eastM) {
    if (_bpLat == null || _bpLng == null) return;
    final double dLat = northM / 111320.0;
    final double cosLat = cos(_bpLat! * pi / 180.0).abs().clamp(0.1, 1.0);
    final double dLng = eastM / (111320.0 * cosLat);

    setState(() {
      _bpLat = _bpLat! + dLat;
      _bpLng = _bpLng! + dLng;
    });
    _renderBlueprintOnMap(rebuildBitmap: false);
    _persistBlueprintConfig();
  }

  void _panMapKeepZoom(double lat, double lng) {
    if (_mapCtrl == null) return;
    _mapCtrl!.updateCamera(
      NCameraUpdate.scrollAndZoomTo(target: NLatLng(lat, lng)),
    );
  }

  Widget _buildBlueprintControlBox() {
    return Container(
      color: Colors.grey[900],
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '📐 도면 정렬 (지도 터치 시 즉시 이동)',
                  style: TextStyle(
                    color: Colors.amber,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: () async {
                    await _persistBlueprintConfig();
                    setState(() => _bpEditMode = false);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('도면이 영구 저장되었습니다! (앱 재실행 시 유지)'),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.check, size: 15),
                  label: const Text('고정 및 저장', style: TextStyle(fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ],
            ),
            const Divider(color: Colors.white24, height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                ElevatedButton.icon(
                  onPressed: () async {
                    if (_mapCtrl == null) return;
                    final pos = await _mapCtrl!.getCameraPosition();
                    final halfRad = await _calcHalfScreenRadius();
                    setState(() {
                      _bpLat = pos.target.latitude;
                      _bpLng = pos.target.longitude;
                      _bpBaseRadius = halfRad;
                      _bpSizeSlider = 0.5;
                    });
                    await _renderBlueprintOnMap(rebuildBitmap: false);
                    await _persistBlueprintConfig();
                  },
                  icon: const Icon(Icons.center_focus_strong, size: 15),
                  label: const Text('화면 중앙·절반크기 초기화',
                      style: TextStyle(fontSize: 11)),
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
                      onPressed: () => _shiftBlueprintMeters(0, -3),
                    ),
                    IconButton(
                      icon: const Icon(Icons.arrow_upward,
                          color: Colors.white, size: 20),
                      onPressed: () => _shiftBlueprintMeters(3, 0),
                    ),
                    IconButton(
                      icon: const Icon(Icons.arrow_downward,
                          color: Colors.white, size: 20),
                      onPressed: () => _shiftBlueprintMeters(-3, 0),
                    ),
                    IconButton(
                      icon: const Icon(Icons.arrow_forward,
                          color: Colors.white, size: 20),
                      onPressed: () => _shiftBlueprintMeters(0, 3),
                    ),
                  ],
                ),
              ],
            ),
            // 1. 크기 슬라이더 (0.5가 정중앙 기본값)
            Row(
              children: [
                SizedBox(
                  width: 82,
                  child: Text(
                    '크기: ${_currentBpRadius.toInt()}m',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline,
                      color: Colors.white70, size: 20),
                  onPressed: () {
                    setState(() {
                      _bpSizeSlider = (_bpSizeSlider - 0.05).clamp(0.0, 1.0);
                    });
                    _renderBlueprintOnMap(rebuildBitmap: false);
                    _persistBlueprintConfig();
                  },
                ),
                Expanded(
                  child: Slider(
                    value: _bpSizeSlider,
                    min: 0.0,
                    max: 1.0,
                    activeColor: Colors.amber,
                    onChanged: (val) {
                      setState(() => _bpSizeSlider = val);
                      _renderBlueprintOnMap(rebuildBitmap: false);
                    },
                    onChangeEnd: (_) => _persistBlueprintConfig(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline,
                      color: Colors.white70, size: 20),
                  onPressed: () {
                    setState(() {
                      _bpSizeSlider = (_bpSizeSlider + 0.05).clamp(0.0, 1.0);
                    });
                    _renderBlueprintOnMap(rebuildBitmap: false);
                    _persistBlueprintConfig();
                  },
                ),
              ],
            ),
            // 2. 회전 슬라이더 (드래그하는 즉시 빠르게 실시간 회전!)
            Row(
              children: [
                SizedBox(
                  width: 82,
                  child: Text(
                    '회전: ${_bpRotation.toStringAsFixed(0)}°',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.rotate_left,
                      color: Colors.white70, size: 20),
                  onPressed: () {
                    setState(() {
                      _bpRotation = (_bpRotation - 5.0).clamp(-180.0, 180.0);
                    });
                    _renderBlueprintOnMap(rebuildBitmap: true);
                    _persistBlueprintConfig();
                  },
                ),
                Expanded(
                  child: Slider(
                    value: _bpRotation.clamp(-180.0, 180.0),
                    min: -180.0,
                    max: 180.0,
                    activeColor: Colors.amber,
                    onChanged: (val) {
                      setState(() => _bpRotation = val);
                      _renderBlueprintOnMap(rebuildBitmap: true);
                    },
                    onChangeEnd: (_) => _persistBlueprintConfig(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.rotate_right,
                      color: Colors.white70, size: 20),
                  onPressed: () {
                    setState(() {
                      _bpRotation = (_bpRotation + 5.0).clamp(-180.0, 180.0);
                    });
                    _renderBlueprintOnMap(rebuildBitmap: true);
                    _persistBlueprintConfig();
                  },
                ),
              ],
            ),
            // 3. 투명도 슬라이더 (기본값 50%에서 시작, 드래그 즉시 반영)
            Row(
              children: [
                SizedBox(
                  width: 82,
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
                      setState(() => _bpOpacity = val);
                      _renderBlueprintOnMap(rebuildBitmap: true);
                    },
                    onChangeEnd: (_) => _persistBlueprintConfig(),
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
    final List<String> dateTabs = ['전체 보기'];
    final Set<String> days =
        widget.photos.map((p) => p.timestamp.substring(0, 10)).toSet();
    final List<String> sortedDays = days.toList()..sort((a, b) => b.compareTo(a));
    dateTabs.addAll(sortedDays);

    final bool portrait =
        MediaQuery.of(context).orientation == Orientation.portrait;

    final PhotoItem? activePhoto = _visiblePhotos.isNotEmpty
        ? _visiblePhotos[_selectedIdx.clamp(0, _visiblePhotos.length - 1)]
        : null;

    final Widget leftOrTopPane = _bpEditMode
        ? _buildBlueprintControlBox()
        : (activePhoto != null
            ? Container(
                color: Colors.black,
                width: double.infinity,
                height: double.infinity,
                child: InteractiveViewer(
                  panEnabled: true,
                  boundaryMargin: const EdgeInsets.all(20),
                  minScale: 0.5,
                  maxScale: 4.0,
                  child: Center(
                    child: Image.file(File(activePhoto.path), fit: BoxFit.contain),
                  ),
                ),
              )
            : const Center(
                child: Text(
                  '저장된 사진이 없습니다.',
                  style: TextStyle(color: Colors.white),
                ),
              ));

    final double initLat = activePhoto?.lat ?? _bpLat ?? 37.4984;
    final double initLng = activePhoto?.lng ?? _bpLng ?? 127.1324;

    final Widget mapPane = naverAuthErrorMsg != null
        ? Container(
            color: Colors.white,
            padding: const EdgeInsets.all(20),
            child: Center(
              child: Text(
                '🚨 네이버 지도 차단됨!\n\n$naverAuthErrorMsg',
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
                target: NLatLng(initLat, initLng),
                zoom: 16,
              ),
            ),
            onMapReady: (ctrl) async {
              _mapCtrl = ctrl;
              await _restoreBlueprintConfig();
              await _refreshAllOverlays(includeBlueprint: true);
            },
            onMapTapped: (point, latLng) {
              if (_bpEditMode && _bpPath != null) {
                setState(() {
                  _bpLat = latLng.latitude;
                  _bpLng = latLng.longitude;
                });
                _renderBlueprintOnMap(rebuildBitmap: false);
                _persistBlueprintConfig();
              }
            },
          );

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: DropdownButton<String>(
          value: _dateFilter,
          dropdownColor: Colors.black87,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
          underline: const SizedBox.shrink(),
          icon: const Icon(Icons.arrow_drop_down, color: Colors.white),
          items: dateTabs
              .map((d) => DropdownMenuItem(value: d, child: Text(d)))
              .toList(),
          onChanged: (val) {
            if (val == null) return;
            setState(() {
              _dateFilter = val;
              _selectedIdx =
                  _visiblePhotos.isNotEmpty ? _visiblePhotos.length - 1 : 0;
            });
            _refreshAllOverlays(includeBlueprint: true);
            if (_visiblePhotos.isNotEmpty) {
              final p = _visiblePhotos[_selectedIdx];
              _panMapKeepZoom(p.lat, p.lng);
            }
          },
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          TextButton.icon(
            onPressed: _importBlueprintFromGallery,
            icon: const Icon(Icons.add_photo_alternate,
                color: Colors.amber, size: 18),
            label: const Text(
              '도면가져오기',
              style: TextStyle(color: Colors.amber, fontSize: 12),
            ),
          ),
          if (_bpPath != null) ...[
            IconButton(
              icon: Icon(
                _bpShow ? Icons.layers : Icons.layers_clear,
                color: _bpShow ? Colors.lightGreenAccent : Colors.grey,
              ),
              onPressed: () async {
                setState(() {
                  _bpShow = !_bpShow;
                  if (!_bpShow) _bpEditMode = false;
                });
                await _persistBlueprintConfig();
                await _refreshAllOverlays(includeBlueprint: true);
              },
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ElevatedButton(
                onPressed: () async {
                  await _persistBlueprintConfig();
                  setState(() => _bpEditMode = !_bpEditMode);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      _bpEditMode ? Colors.amber : Colors.blueAccent,
                  foregroundColor: _bpEditMode ? Colors.black : Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: Text(
                  _bpEditMode ? '고정저장' : '도면정렬',
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
            child: portrait
                ? Column(
                    children: [
                      Expanded(flex: 5, child: leftOrTopPane),
                      const SizedBox(height: 4),
                      Expanded(flex: 5, child: mapPane),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(flex: 5, child: leftOrTopPane),
                      const SizedBox(width: 4),
                      Expanded(flex: 5, child: mapPane),
                    ],
                  ),
          ),
          if (_visiblePhotos.isNotEmpty)
            SizedBox(
              height: 80,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _visiblePhotos.length,
                itemBuilder: (context, idx) {
                  final bool selected = _selectedIdx == idx;
                  return GestureDetector(
                    onTap: () {
                      setState(() => _selectedIdx = idx);
                      _refreshAllOverlays(includeBlueprint: true);
                      _panMapKeepZoom(
                        _visiblePhotos[idx].lat,
                        _visiblePhotos[idx].lng,
                      );
                    },
                    child: Container(
                      margin: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: selected ? Colors.amber : Colors.transparent,
                          width: 3,
                        ),
                      ),
                      child: Image.file(
                        File(_visiblePhotos[idx].path),
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

  Future<void> _refreshAllOverlays({bool includeBlueprint = true}) async {
    if (_mapCtrl == null) return;
    await _mapCtrl!.clearOverlays();

    if (includeBlueprint && _bpPath != null && _bpShow) {
      await _renderBlueprintOnMap(rebuildBitmap: false);
    }

    final List<int> order = [];
    for (int i = 0; i < _visiblePhotos.length; i++) {
      if (i != _selectedIdx) order.add(i);
    }
    if (_selectedIdx >= 0 && _selectedIdx < _visiblePhotos.length) {
      order.add(_selectedIdx);
    }

    for (final int i in order) {
      final PhotoItem item = _visiblePhotos[i];
      final bool selected = i == _selectedIdx;
      final Color c = selected ? Colors.blueAccent : Colors.red;

      try {
        final icon = await NOverlayImage.fromWidget(
          widget: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: c.withOpacity(0.3),
                  shape: BoxShape.circle,
                  border: Border.all(color: c, width: 2),
                ),
              ),
              Transform.rotate(
                angle: item.azimuth * (pi / 180.0),
                child: Icon(Icons.navigation, color: c, size: 20),
              ),
            ],
          ),
          size: const Size(28, 28),
          context: context,
        );

        final marker = NMarker(
          id: 'photo_marker_$i',
          position: NLatLng(item.lat, item.lng),
          icon: icon,
        );

        marker.setOnTapListener((_) async {
          final List<int> nearby = [];
          for (int j = 0; j < _visiblePhotos.length; j++) {
            final double dist = Geolocator.distanceBetween(
              item.lat,
              item.lng,
              _visiblePhotos[j].lat,
              _visiblePhotos[j].lng,
            );
            if (dist <= 20.0) nearby.add(j);
          }

          int nextIdx = i;
          if (nearby.length > 1 && nearby.contains(_selectedIdx)) {
            final int pos = nearby.indexOf(_selectedIdx);
            nextIdx = nearby[(pos + 1) % nearby.length];
          }

          setState(() => _selectedIdx = nextIdx);
          await _refreshAllOverlays(includeBlueprint: true);
          final target = _visiblePhotos[_selectedIdx];
          _panMapKeepZoom(target.lat, target.lng);
        });

        await _mapCtrl!.addOverlay(marker);
      } catch (e) {
        debugPrint('Marker error: $e');
      }
    }
  }
}
