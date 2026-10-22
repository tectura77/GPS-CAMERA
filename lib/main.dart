```dart
import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
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
import 'package:share_plus/share_plus.dart';
import 'package:archive/archive.dart';

List<CameraDescription> appCameras = [];
String? naverAuthErrorMsg;

// 마지막으로 설정하거나 변경한 카테고리를 기억하는 전역 변수 (다음 촬영 시 자동 적용)
String currentDefaultCategory = '미분류';

// 내 위치 표기 유지 및 강제 이동 좌표 전역 변수 (null이면 실시간 GPS 사용)
bool globalShowMyLocation = false;
NLatLng? forcedUserLocation;

Future<void> saveDefaultCategory(String cat) async {
  currentDefaultCategory = cat.trim().isEmpty ? '미분류' : cat.trim();
  try {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/last_category.txt');
    await f.writeAsString(currentDefaultCategory);
  } catch (e) {
    debugPrint('Save default category error: $e');
  }
}

Future<void> loadDefaultCategory(List<PhotoItem> photos) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/last_category.txt');
    if (await f.exists()) {
      final saved = (await f.readAsString()).trim();
      if (saved.isNotEmpty) {
        currentDefaultCategory = saved;
        return;
      }
    }
    if (photos.isNotEmpty && photos.last.category.isNotEmpty) {
      currentDefaultCategory = photos.last.category;
    }
  } catch (e) {
    debugPrint('Load default category error: $e');
  }
}

// 대시보드 재진입 및 사진 전환 속도를 극대화하는 전역 오버레이 캐시
final Map<String, NOverlayImage> globalMarkerIconCache = {};
final Map<String, NOverlayImage> globalBpOverlayCache = {};

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
  String category;
  String memo;

  PhotoItem({
    required this.path,
    required this.lat,
    required this.lng,
    required this.alt,
    required this.acc,
    required this.azimuth,
    required this.pitch,
    required this.timestamp,
    this.category = '미분류',
    this.memo = '',
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
        'category': category,
        'memo': memo,
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
        category: m['category'] as String? ?? '미분류',
        memo: m['memo'] as String? ?? '',
      );
}

class BlueprintItem {
  final String id;
  String name;
  final String imagePath;
  double centerLat;
  double centerLng;
  double baseRadius;
  double sizeSlider;
  double rotation;
  double opacity;
  bool isVisible;

  Uint8List? fastBytes;
  NOverlayImage? cachedOverlayImg;
  double? bakedRotation;
  double? bakedOpacity;

  BlueprintItem({
    required this.id,
    required this.name,
    required this.imagePath,
    required this.centerLat,
    required this.centerLng,
    this.baseRadius = 200.0,
    this.sizeSlider = 0.5,
    this.rotation = 0.0,
    this.opacity = 0.5,
    this.isVisible = true,
    this.fastBytes,
    this.cachedOverlayImg,
  });

  double get currentRadius =>
      baseRadius * pow(9.0, sizeSlider - 0.5).toDouble();

  void setRadiusDirectly(double newRadiusMeters) {
    final double clamped = newRadiusMeters.clamp(5.0, 5000.0);
    double newSlider = 0.5 + log(clamped / baseRadius) / log(9.0);
    if (newSlider < 0.05 || newSlider > 0.95) {
      baseRadius = clamped;
      newSlider = 0.5;
    }
    sizeSlider = newSlider.clamp(0.0, 1.0);
  }

  String get cacheKey =>
      '${id}_hq_${rotation.toStringAsFixed(1)}_${opacity.toStringAsFixed(2)}';

  bool get needsBake =>
      cachedOverlayImg == null ||
      bakedRotation != rotation ||
      bakedOpacity != opacity;

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'imagePath': imagePath,
        'centerLat': centerLat,
        'centerLng': centerLng,
        'baseRadius': baseRadius,
        'sizeSlider': sizeSlider,
        'rotation': rotation,
        'opacity': opacity,
        'isVisible': isVisible,
      };

  factory BlueprintItem.fromMap(Map<String, dynamic> m, int idx) =>
      BlueprintItem(
        id: m['id'] as String? ??
            'bp_${DateTime.now().millisecondsSinceEpoch}_$idx',
        name: m['name'] as String? ?? '도면 ${idx + 1}',
        imagePath: m['imagePath'] as String,
        centerLat: (m['centerLat'] as num?)?.toDouble() ?? 37.4984,
        centerLng: (m['centerLng'] as num?)?.toDouble() ?? 127.1324,
        baseRadius: (m['baseRadius'] as num?)?.toDouble() ?? 200.0,
        sizeSlider:
            ((m['sizeSlider'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0),
        rotation:
            ((m['rotation'] as num?)?.toDouble() ?? 0.0).clamp(-180.0, 180.0),
        opacity: ((m['opacity'] as num?)?.toDouble() ?? 0.5).clamp(0.1, 1.0),
        isVisible: m['isVisible'] as bool? ?? true,
      );
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  static const MethodChannel _shutterChannel =
      MethodChannel('gps_camera/shutter');
  static Uint8List? _shutterWavBytes;

  CameraController? _camController;
  Position? _pos;
  double _heading = 0;
  double _tiltPitch = 0;
  bool _busy = false;
  bool _shutterFlash = false;
  String _ratioMode = '16:9';
  final List<PhotoItem> _photoList = [];

  double _currentZoom = 1.0;
  double _baseScaleZoom = 1.0;
  double _hwMinZoom = 1.0;
  double _hwMaxZoom = 2.0;
  int _activeCamIdx = 0;
  List<int> _backCameraIndices = [];

  @override
  void initState() {
    super.initState();
    _shutterWavBytes ??= _generateMechanicalShutterWav();
    _setupApp();
  }

  // 순수 비트 연산으로 생성하는 고출력 기계식 카메라 셔터음("찰-칵!") WAV 데이터
  Uint8List _generateMechanicalShutterWav() {
    const int sampleRate = 22050;
    const int durationMs = 180;
    final int numSamples = (sampleRate * durationMs) ~/ 1000;
    final int dataSize = numSamples * 2;
    final Uint8List out = Uint8List(44 + dataSize);

    void writeStr(int offset, String s) {
      for (int i = 0; i < s.length; i++) {
        out[offset + i] = s.codeUnitAt(i) & 0xFF;
      }
    }

    void writeU16LE(int offset, int val) {
      out[offset] = val & 0xFF;
      out[offset + 1] = (val >> 8) & 0xFF;
    }

    void writeU32LE(int offset, int val) {
      out[offset] = val & 0xFF;
      out[offset + 1] = (val >> 8) & 0xFF;
      out[offset + 2] = (val >> 16) & 0xFF;
      out[offset + 3] = (val >> 24) & 0xFF;
    }

    writeStr(0, 'RIFF');
    writeU32LE(4, 36 + dataSize);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    writeU32LE(16, 16);
    writeU16LE(20, 1); // PCM
    writeU16LE(22, 1); // Mono
    writeU32LE(24, sampleRate);
    writeU32LE(28, sampleRate * 2);
    writeU16LE(32, 2);
    writeU16LE(34, 16);
    writeStr(36, 'data');
    writeU32LE(40, dataSize);

    final Random rng = Random(42);
    for (int i = 0; i < numSamples; i++) {
      final double t = i / sampleRate;
      double amp = 0.0;

      // 첫 번째 "찰-" (0~28ms)
      if (t < 0.028) {
        final double env = exp(-t * 145.0);
        final double noise = (rng.nextDouble() * 2.0 - 1.0) * 0.85;
        final double tone = sin(2.0 * pi * 1500.0 * t) * 0.6 +
            sin(2.0 * pi * 3100.0 * t) * 0.45;
        amp += (noise + tone) * env;
      }

      // 두 번째 "-칵!" (46~105ms)
      if (t >= 0.046 && t < 0.105) {
        final double dt = t - 0.046;
        final double env = exp(-dt * 120.0);
        final double noise = (rng.nextDouble() * 2.0 - 1.0) * 0.95;
        final double tone = sin(2.0 * pi * 1150.0 * dt) * 0.6 +
            sin(2.0 * pi * 2450.0 * dt) * 0.5;
        amp += (noise + tone) * env;
      }

      int pcm = (amp.clamp(-1.0, 1.0) * 32767.0).round();
      if (pcm < 0) pcm += 65536;
      writeU16LE(44 + i * 2, pcm);
    }

    return out;
  }

  Future<void> _playShutterSoundAndFeedback() async {
    if (mounted) {
      setState(() => _shutterFlash = true);
      Future.delayed(const Duration(milliseconds: 90), () {
        if (mounted) setState(() => _shutterFlash = false);
      });
    }

    HapticFeedback.heavyImpact();
    SystemSound.play(SystemSoundType.click);
    Future.delayed(const Duration(milliseconds: 55), () {
      SystemSound.play(SystemSoundType.click);
      HapticFeedback.mediumImpact();
    });

    try {
      await _shutterChannel.invokeMethod('playShutter', {
        'wav': _shutterWavBytes,
      });
    } catch (_) {}
  }

  Future<void> _setupApp() async {
    await [
      Permission.camera,
      Permission.location,
      Permission.storage,
      Permission.photos,
    ].request();
    await _restorePhotos();
    await loadDefaultCategory(_photoList);
    if (mounted) setState(() {});

    _backCameraIndices = [];
    for (int i = 0; i < appCameras.length; i++) {
      if (appCameras[i].lensDirection == CameraLensDirection.back) {
        _backCameraIndices.add(i);
      }
    }

    await _startCamera(
        _backCameraIndices.isNotEmpty ? _backCameraIndices.first : 0);
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

  Future<void> _startCamera(int camIndex, {double targetUiZoom = 1.0}) async {
    if (appCameras.isEmpty) return;
    final prevCtrl = _camController;
    final newCtrl = CameraController(
      appCameras[camIndex],
      ResolutionPreset.high,
      enableAudio: false,
    );
    _camController = newCtrl;
    _activeCamIdx = camIndex;

    if (prevCtrl != null) {
      await prevCtrl.dispose();
    }

    try {
      await newCtrl.initialize();
      _hwMinZoom = await newCtrl.getMinZoomLevel();
      _hwMaxZoom = await newCtrl.getMaxZoomLevel();

      final double clampedHw =
          targetUiZoom.clamp(_hwMinZoom, min(_hwMaxZoom, 2.0));
      await newCtrl.setZoomLevel(clampedHw);
      _currentZoom = targetUiZoom;
    } catch (e) {
      debugPrint('Camera start error: $e');
    }
    if (mounted) setState(() {});
  }

  Future<void> _applyCameraZoom(double desiredZoom) async {
    if (_camController == null || !_camController!.value.isInitialized) return;
    final double target = desiredZoom.clamp(0.6, 2.0);

    if (_hwMinZoom <= 0.7) {
      final double actual = target.clamp(_hwMinZoom, min(_hwMaxZoom, 2.0));
      setState(() => _currentZoom = actual);
      await _camController!.setZoomLevel(actual);
      return;
    }

    if (target < 0.85 && _backCameraIndices.length > 1) {
      final int ultraWideIdx = _backCameraIndices.last;
      if (_activeCamIdx != ultraWideIdx) {
        await _startCamera(ultraWideIdx, targetUiZoom: 0.6);
        return;
      }
      setState(() => _currentZoom = 0.6);
      return;
    } else if (target >= 0.85 &&
        _backCameraIndices.isNotEmpty &&
        _activeCamIdx != _backCameraIndices.first) {
      await _startCamera(_backCameraIndices.first, targetUiZoom: target);
      return;
    }

    final double actual = target.clamp(_hwMinZoom, min(_hwMaxZoom, 2.0));
    setState(() => _currentZoom = actual);
    await _camController!.setZoomLevel(actual);
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
      await _playShutterSoundAndFeedback();

      final XFile rawFile = await _camController!.takePicture();
      final Uint8List rawBytes = await rawFile.readAsBytes();
      img.Image? decodedImg = img.decodeImage(rawBytes);

      final double? useLat = forcedUserLocation?.latitude ?? _pos?.latitude;
      final double? useLng = forcedUserLocation?.longitude ?? _pos?.longitude;
      final double useAlt = _pos?.altitude ?? 0.0;
      final double useAcc =
          forcedUserLocation != null ? 1.0 : (_pos?.accuracy ?? 5.0);

      if (decodedImg != null && useLat != null && useLng != null) {
        decodedImg = img.bakeOrientation(decodedImg);

        final int w = decodedImg.width;
        final int h = decodedImg.height;

        double targetAspect;
        if (_ratioMode == '1:1') {
          targetAspect = 1.0;
        } else if (_ratioMode == '4:3') {
          targetAspect = (w >= h) ? (4.0 / 3.0) : (3.0 / 4.0);
        } else {
          targetAspect = (w >= h) ? (16.0 / 9.0) : (9.0 / 16.0);
        }

        final double currentAspect = w / h;
        int cropW = w;
        int cropH = h;

        if (currentAspect > targetAspect) {
          cropW = (h * targetAspect).round().clamp(1, w);
        } else if (currentAspect < targetAspect) {
          cropH = (w / targetAspect).round().clamp(1, h);
        }

        if (cropW != w || cropH != h) {
          decodedImg = img.copyCrop(
            decodedImg,
            x: (w - cropW) ~/ 2,
            y: (h - cropH) ~/ 2,
            width: cropW,
            height: cropH,
          );
        }

        final String nowStr = DateTime.now().toString().substring(0, 16);
        final String folderDate = nowStr.substring(0, 10);
        final String dirEn = _compassLabel(_heading, korean: false);
        final double hAcc = useAcc;
        final double vAcc = hAcc * 1.5;

        final String stamp =
            'Lat: ${useLat.toStringAsFixed(6)} (+-${hAcc.toStringAsFixed(1)}m)\n'
            'Lng: ${useLng.toStringAsFixed(6)} (+-${hAcc.toStringAsFixed(1)}m)\n'
            'Alt: ${useAlt.toStringAsFixed(1)}m (+-${vAcc.toStringAsFixed(1)}m)\n'
            'Azimuth: ${_heading.toStringAsFixed(1)} deg ($dirEn)\n'
            'Pitch: ${_tiltPitch.toStringAsFixed(1)} deg\n'
            'Time: $nowStr';

        img.drawString(
          decodedImg,
          stamp,
          font: img.arial24,
          x: 20,
          y: max(20, decodedImg.height - 220),
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
        final int altRational = (useAlt.abs() * 100).round();

        final exif = await Exif.fromPath(targetPath);
        await exif.writeAttributes({
          'GPSLatitude': useLat.abs().toString(),
          'GPSLatitudeRef': useLat >= 0 ? 'N' : 'S',
          'GPSLongitude': useLng.abs().toString(),
          'GPSLongitudeRef': useLng >= 0 ? 'E' : 'W',
          'GPSAltitude': '$altRational/100',
          'GPSAltitudeRef': useAlt >= 0 ? '0' : '1',
          'GPSImgDirection': '$azRational/100',
          'GPSImgDirectionRef': 'T',
        });
        await exif.close();

        await Gal.putImage(targetPath);

        final String assignedCat = currentDefaultCategory;

        setState(() {
          _photoList.add(PhotoItem(
            path: targetPath,
            lat: useLat,
            lng: useLng,
            alt: useAlt,
            acc: hAcc,
            azimuth: _heading,
            pitch: _tiltPitch,
            timestamp: nowStr,
            category: assignedCat,
          ));
        });

        await _persistPhotos();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('📸 찰칵! [$assignedCat] 카테고리로 저장되었습니다.'),
              duration: const Duration(milliseconds: 1100),
            ),
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
    if (forcedUserLocation != null) {
      final double altVal = _pos?.altitude ?? 0.0;
      locInfo =
          '위도: ${forcedUserLocation!.latitude.toStringAsFixed(6)} (📌강제위치)\n'
          '경도: ${forcedUserLocation!.longitude.toStringAsFixed(6)} (📌강제위치)\n'
          '표고: ${altVal.toStringAsFixed(1)}m';
    } else if (_pos != null) {
      final double acc = _pos!.accuracy;
      locInfo =
          '위도: ${_pos!.latitude.toStringAsFixed(6)} (±${acc.toStringAsFixed(1)}m)\n'
          '경도: ${_pos!.longitude.toStringAsFixed(6)} (±${acc.toStringAsFixed(1)}m)\n'
          '표고: ${_pos!.altitude.toStringAsFixed(1)}m (±${(acc * 1.5).toStringAsFixed(1)}m)';
    }

    final bool landscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    final double bottomSafe = MediaQuery.of(context).viewPadding.bottom;
    final double liftOffset = bottomSafe + 28.0;

    final double targetFrameRatio = _ratioMode == '1:1'
        ? 1.0
        : (_ratioMode == '4:3'
            ? (landscape ? 4.0 / 3.0 : 3.0 / 4.0)
            : (landscape ? 16.0 / 9.0 : 9.0 / 16.0));

    final Size? rawPreviewSize = _camController!.value.previewSize;
    final double sensorW = rawPreviewSize != null
        ? (landscape ? rawPreviewSize.width : rawPreviewSize.height)
        : (landscape ? 1920.0 : 1080.0);
    final double sensorH = rawPreviewSize != null
        ? (landscape ? rawPreviewSize.height : rawPreviewSize.width)
        : (landscape ? 1080.0 : 1920.0);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            onScaleStart: (_) {
              _baseScaleZoom = _currentZoom;
            },
            onScaleUpdate: (details) {
              if ((details.scale - 1.0).abs() > 0.01) {
                _applyCameraZoom(_baseScaleZoom * details.scale);
              }
            },
            child: Center(
              child: AspectRatio(
                aspectRatio: targetFrameRatio,
                child: ClipRect(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: sensorW,
                      height: sensorH,
                      child: CameraPreview(_camController!),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_shutterFlash)
            IgnorePointer(
              child: Container(
                color: Colors.white.withOpacity(0.55),
              ),
            ),
          Positioned(
            top: landscape ? 14 : 45,
            left: 0,
            right: 0,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: ['16:9', '4:3', '1:1'].map((m) {
                  final bool active = _ratioMode == m;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: ElevatedButton(
                      onPressed: () => setState(() => _ratioMode = m),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: active ? Colors.amber : Colors.black54,
                        foregroundColor: active ? Colors.black : Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 4),
                        minimumSize: const Size(54, 34),
                      ),
                      child: Text(m),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          Positioned(
            left: 16,
            bottom: (landscape ? 16 : 88) + liftOffset,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (forcedUserLocation != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: InkWell(
                      onTap: () {
                        setState(() => forcedUserLocation = null);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('🛰️ 실시간 GPS 위치 모드로 복귀했습니다.'),
                            duration: Duration(milliseconds: 1100),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.amber,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.push_pin, size: 14, color: Colors.black),
                            SizedBox(width: 4),
                            Text(
                              '강제 이동 위치 적용 중 (터치 시 GPS 복귀)',
                              style: TextStyle(
                                color: Colors.black,
                                fontSize: 11.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                IgnorePointer(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '카테고리: $currentDefaultCategory\n'
                      '$locInfo\n방위각: ${_heading.toStringAsFixed(1)}° ($dirKr)\n'
                      '피치각: ${_tiltPitch.toStringAsFixed(1)}° | 배율: ${_currentZoom.toStringAsFixed(1)}x\n'
                      '시간: ${DateTime.now().toString().substring(0, 16)}',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: 22 + liftOffset,
            left: 0,
            right: 0,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [0.6, 1.0, 2.0].map((z) {
                  final bool selected = (_currentZoom - z).abs() < 0.15;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    child: InkWell(
                      onTap: () => _applyCameraZoom(z),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: selected ? Colors.amber : Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: selected ? Colors.amber : Colors.white54,
                          ),
                        ),
                        child: Text(
                          '${z.toStringAsFixed(1)}x',
                          style: TextStyle(
                            color: selected ? Colors.black : Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          Positioned(
            bottom: 16 + liftOffset,
            right: 48,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton(
                  heroTag: 'shutterBtn',
                  onPressed: _capturePhoto,
                  backgroundColor: Colors.amber,
                  child: const Icon(Icons.camera_alt,
                      color: Colors.black, size: 28),
                ),
                const SizedBox(width: 12),
                FloatingActionButton(
                  heroTag: 'mapDashboardBtn',
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => GalleryMapDashboard(photos: _photoList),
                      ),
                    );
                    if (mounted) setState(() {});
                  },
                  backgroundColor: Colors.blueAccent,
                  child: const Icon(Icons.map, color: Colors.white),
                ),
              ],
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
  String _categoryFilter = '전체 카테고리';

  final Set<String> _customCategories = {};

  final List<BlueprintItem> _blueprints = [];
  int _activeBpIdx = 0;
  bool _bpGlobalShow = true;
  bool _bpEditMode = false;

  bool _bpTouchModeIsBlueprint = true;
  bool _isSliderManipulating = false;
  double _nudgeStepMeters = 1.0;
  double _metersPerPixel = 0.5;
  NLatLngBounds? _currentMapBounds;
  Size _mapWidgetSize = const Size(360, 360);

  final Map<int, Offset> _activePointers = {};
  bool _isExporting = false;
  Future<void>? _bpLoadFuture;

  // 내 위치 표시 상태 및 위치 스트림 변수
  bool _showMyLocation = false;
  Position? _myCurrentPos;
  StreamSubscription<Position>? _myLocStreamSub;

  BlueprintItem? get _activeBp =>
      (_blueprints.isNotEmpty &&
              _activeBpIdx >= 0 &&
              _activeBpIdx < _blueprints.length)
          ? _blueprints[_activeBpIdx]
          : null;

  bool get _hasAnyVisibleBlueprint =>
      _bpGlobalShow && _blueprints.any((b) => b.isVisible);

  bool get _useLiveActiveBpOverlay =>
      _bpEditMode &&
      _bpGlobalShow &&
      _activeBp != null &&
      _activeBp!.isVisible &&
      _currentMapBounds != null &&
      (_bpTouchModeIsBlueprint || _isSliderManipulating);

  List<String> get _allCategories {
    final Set<String> cats = {..._customCategories};
    for (var p in widget.photos) {
      if (p.category.isNotEmpty && p.category != '미분류') {
        cats.add(p.category);
      }
    }
    final List<String> sorted = cats.toList()..sort((a, b) => a.compareTo(b));
    sorted.add('미분류');
    return sorted;
  }

  List<PhotoItem> get _visiblePhotos {
    return widget.photos.where((p) {
      final bool matchDate =
          (_dateFilter == '전체 보기') || p.timestamp.startsWith(_dateFilter);
      final bool matchCat =
          (_categoryFilter == '전체 카테고리') || (p.category == _categoryFilter);
      return matchDate && matchCat;
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _showMyLocation = globalShowMyLocation || forcedUserLocation != null;
    if (_showMyLocation) {
      _startMyLocationStream();
    }
    _restoreCategories();
    _bpLoadFuture = _restoreBlueprintConfig();
    if (_visiblePhotos.isNotEmpty) {
      _selectedIdx = _visiblePhotos.length - 1;
    }
  }

  @override
  void dispose() {
    _myLocStreamSub?.cancel();
    super.dispose();
  }

  Future<void> _restoreCategories() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final catFile = File('${dir.path}/custom_categories.json');
      if (await catFile.exists()) {
        final List<dynamic> list = jsonDecode(await catFile.readAsString());
        if (mounted) {
          setState(() {
            for (final c in list) {
              final s = c.toString().trim();
              if (s.isNotEmpty && s != '미분류') {
                _customCategories.add(s);
              }
            }
          });
        }
      } else {
        for (final p in widget.photos) {
          if (p.category.isNotEmpty && p.category != '미분류') {
            _customCategories.add(p.category);
          }
        }
      }
    } catch (e) {
      debugPrint('Restore categories error: $e');
    }
  }

  Future<void> _persistCategories() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final catFile = File('${dir.path}/custom_categories.json');
      for (final p in widget.photos) {
        if (p.category.isNotEmpty && p.category != '미분류') {
          _customCategories.add(p.category);
        }
      }
      await catFile.writeAsString(jsonEncode(_customCategories.toList()));
    } catch (e) {
      debugPrint('Persist categories error: $e');
    }
  }

  Future<void> _deleteCategory(String targetCat) async {
    if (targetCat == '미분류') return;
    setState(() {
      _customCategories.remove(targetCat);
      for (final p in widget.photos) {
        if (p.category == targetCat) {
          p.category = '미분류';
        }
      }
      if (_categoryFilter == targetCat) {
        _categoryFilter = '전체 카테고리';
      }
    });
    if (currentDefaultCategory == targetCat) {
      await saveDefaultCategory('미분류');
    }
    await _persistCategories();
    await _persistPhotoMetadata();
    await _refreshAllOverlays(includeBlueprint: true);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("'$targetCat' 카테고리가 삭제되었습니다. (해당 사진은 미분류로 전환)"),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _restoreBlueprintConfig() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final cfgFile = File('${dir.path}/blueprint_config.json');
      if (!await cfgFile.exists()) return;

      final dynamic decoded = jsonDecode(await cfgFile.readAsString());
      final List<BlueprintItem> loaded = [];

      if (decoded is Map<String, dynamic>) {
        if (decoded.containsKey('blueprints') &&
            decoded['blueprints'] is List) {
          _bpGlobalShow = decoded['globalShow'] as bool? ?? true;
          final List<dynamic> rawList = decoded['blueprints'] as List<dynamic>;
          for (int i = 0; i < rawList.length; i++) {
            final item =
                BlueprintItem.fromMap(rawList[i] as Map<String, dynamic>, i);
            if (File(item.imagePath).existsSync()) {
              await _prepareFastBlueprintBytes(item);
              if (globalBpOverlayCache.containsKey(item.cacheKey)) {
                item.cachedOverlayImg = globalBpOverlayCache[item.cacheKey];
                item.bakedRotation = item.rotation;
                item.bakedOpacity = item.opacity;
              }
              loaded.add(item);
            }
          }
        } else if (decoded.containsKey('imagePath')) {
          final String? savedPath = decoded['imagePath'] as String?;
          if (savedPath != null && File(savedPath).existsSync()) {
            final item = BlueprintItem.fromMap(decoded, 0);
            await _prepareFastBlueprintBytes(item);
            loaded.add(item);
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _blueprints
          ..clear()
          ..addAll(loaded);
        if (_activeBpIdx >= _blueprints.length) {
          _activeBpIdx = _blueprints.isNotEmpty ? _blueprints.length - 1 : 0;
        }
      });
    } catch (e) {
      debugPrint('Blueprint restore error: $e');
    }
  }

  Future<void> _persistBlueprintConfig() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final cfgFile = File('${dir.path}/blueprint_config.json');
      final Map<String, dynamic> data = {
        'globalShow': _bpGlobalShow,
        'blueprints': _blueprints.map((b) => b.toMap()).toList(),
      };
      await cfgFile.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint('Blueprint save error: $e');
    }
  }

  Future<void> _persistPhotoMetadata() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final metaFile = File('${dir.path}/photos_meta.json');
      final raw = jsonEncode(widget.photos.map((e) => e.toMap()).toList());
      await metaFile.writeAsString(raw);
    } catch (e) {
      debugPrint('Photo meta save error: $e');
    }
  }

  // 현재 선택된 사진 삭제 (파일 + 목록 + 지도 마커 갱신)
  Future<void> _deletePhoto(PhotoItem targetPhoto) async {
    try {
      final file = File(targetPhoto.path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('Delete photo file error: $e');
    }

    setState(() {
      widget.photos.remove(targetPhoto);
      if (_visiblePhotos.isEmpty) {
        _selectedIdx = 0;
      } else if (_selectedIdx >= _visiblePhotos.length) {
        _selectedIdx = _visiblePhotos.length - 1;
      }
    });

    await _persistPhotoMetadata();
    await _refreshAllOverlays(includeBlueprint: true);

    if (_visiblePhotos.isNotEmpty) {
      final current = _visiblePhotos[_selectedIdx];
      _panMapKeepZoom(current.lat, current.lng);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🗑️ 사진이 삭제되었습니다.'),
          duration: Duration(milliseconds: 1000),
        ),
      );
    }
  }

  // 내 위치 표시용 초록색 원형 마커 아이콘 생성 (캐시 사용)
  Future<NOverlayImage> _getMyLocationIcon() async {
    const String key = 'my_loc_dot_icon';
    if (globalMarkerIconCache.containsKey(key)) {
      return globalMarkerIconCache[key]!;
    }
    final icon = await NOverlayImage.fromWidget(
      widget: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: Colors.greenAccent.withOpacity(0.35),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
        ),
        alignment: Alignment.center,
        child: Container(
          width: 12,
          height: 12,
          decoration: const BoxDecoration(
            color: Colors.greenAccent,
            shape: BoxShape.circle,
          ),
        ),
      ),
      size: const Size(26, 26),
      context: context,
    );
    globalMarkerIconCache[key] = icon;
    return icon;
  }

  // 지도 위에 내 위치 마커만 단독 갱신 (강제 이동 위치가 있으면 해당 위치 우선 표시)
  Future<void> _updateMyLocationMarkerOnly() async {
    if (_mapCtrl == null || !_showMyLocation) return;
    final NLatLng? targetLatLng = forcedUserLocation ??
        (_myCurrentPos != null
            ? NLatLng(_myCurrentPos!.latitude, _myCurrentPos!.longitude)
            : null);
    if (targetLatLng == null) return;
    try {
      final icon = await _getMyLocationIcon();
      final myMarker = NMarker(
        id: 'my_current_location_marker',
        position: targetLatLng,
        icon: icon,
      );
      await _mapCtrl!.addOverlay(myMarker);
    } catch (e) {
      debugPrint('My location marker error: $e');
    }
  }

  Future<void> _startMyLocationStream() async {
    try {
      final pos = await Geolocator.getLastKnownPosition() ??
          await Geolocator.getCurrentPosition(
            locationSettings:
                const LocationSettings(accuracy: LocationAccuracy.high),
          );
      if (!mounted || !_showMyLocation) return;
      setState(() => _myCurrentPos = pos);
      await _updateMyLocationMarkerOnly();
    } catch (e) {
      debugPrint('Get current pos error: $e');
    }

    await _myLocStreamSub?.cancel();
    _myLocStreamSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    ).listen((Position p) {
      if (!mounted || !_showMyLocation) return;
      _myCurrentPos = p;
      _updateMyLocationMarkerOnly();
    });
  }

  // 내 위치 표기 버튼 ON / OFF 토글
  Future<void> _toggleMyLocation() async {
    if (_showMyLocation) {
      await _myLocStreamSub?.cancel();
      _myLocStreamSub = null;
      setState(() {
        _showMyLocation = false;
        globalShowMyLocation = false;
        forcedUserLocation = null;
      });
      await _refreshAllOverlays(includeBlueprint: true);
      return;
    }

    setState(() {
      _showMyLocation = true;
      globalShowMyLocation = true;
    });
    await _startMyLocationStream();
    final NLatLng? target = forcedUserLocation ??
        (_myCurrentPos != null
            ? NLatLng(_myCurrentPos!.latitude, _myCurrentPos!.longitude)
            : null);
    if (target != null) {
      _panMapKeepZoom(target.latitude, target.longitude);
    }
  }

  Future<void> _showBlueprintActionMenuDialog() async {
    await showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.grey[900],
          insetPadding: const EdgeInsets.symmetric(horizontal: 50),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.map, color: Colors.amber, size: 18),
                        SizedBox(width: 6),
                        Text(
                          '도면 작업 선택',
                          style: TextStyle(
                            color: Colors.amber,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    InkWell(
                      onTap: () => Navigator.pop(ctx),
                      child: const Icon(Icons.close,
                          color: Colors.white54, size: 18),
                    ),
                  ],
                ),
                const Divider(color: Colors.white24, height: 18),
                ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _importBlueprintFromGallery();
                  },
                  icon: const Icon(Icons.add_photo_alternate, size: 18),
                  label: const Text(
                    '도면 추가 (사진에서 가져오기)',
                    style:
                        TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                const SizedBox(height: 10),
                ElevatedButton.icon(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    if (_blueprints.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('등록된 도면이 없습니다. 먼저 [도면 추가]를 눌러주세요.'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                      return;
                    }
                    await _updateMapViewportInfo();
                    setState(() {
                      _bpEditMode = true;
                      _bpTouchModeIsBlueprint = true;
                      _bpGlobalShow = true;
                      if (_activeBp != null) {
                        _activeBp!.isVisible = true;
                      }
                    });
                    await _persistBlueprintConfig();
                    await _refreshAllOverlays(includeBlueprint: true);
                  },
                  icon: const Icon(Icons.tune, size: 18),
                  label: Text(
                    _blueprints.isEmpty
                        ? '도면 수정 (등록된 도면 없음)'
                        : '도면 수정 (기존 도면 ${_blueprints.length}개 편집)',
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _blueprints.isEmpty
                        ? Colors.white12
                        : Colors.blueAccent,
                    foregroundColor:
                        _blueprints.isEmpty ? Colors.white54 : Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<String?> _promptBlueprintNameDialog({
    required String defaultName,
    String title = '도면 이름 설정',
  }) async {
    final TextEditingController nameCtrl =
        TextEditingController(text: defaultName);
    nameCtrl.selection =
        TextSelection(baseOffset: 0, extentOffset: defaultName.length);

    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.grey[900],
          insetPadding: const EdgeInsets.symmetric(horizontal: 55),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.amber,
                    fontSize: 13.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  '층수나 구역 이름을 입력하세요',
                  style: TextStyle(color: Colors.white60, fontSize: 11),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: 185,
                  child: TextField(
                    controller: nameCtrl,
                    autofocus: true,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 12.5),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                      hintText: '예: 지하1층, 지상1층, 기준층',
                      hintStyle:
                          TextStyle(color: Colors.white38, fontSize: 11.5),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.amber),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.amber, width: 1.5),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(44, 30),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: () => Navigator.pop(ctx, null),
                      child: const Text('취소',
                          style:
                              TextStyle(color: Colors.white60, fontSize: 12)),
                    ),
                    const SizedBox(width: 4),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber,
                        minimumSize: const Size(54, 30),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: () {
                        final String input = nameCtrl.text.trim();
                        Navigator.pop(
                            ctx, input.isNotEmpty ? input : defaultName);
                      },
                      child: const Text('확인',
                          style: TextStyle(
                              color: Colors.black,
                              fontSize: 12,
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showBlueprintLayerSelectorDialog() async {
    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return Dialog(
              backgroundColor: Colors.grey[900],
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.layers,
                                color: Colors.lightGreenAccent, size: 18),
                            SizedBox(width: 6),
                            Text(
                              '층별 · 구역별 도면 선택',
                              style: TextStyle(
                                color: Colors.amber,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        InkWell(
                          onTap: () => Navigator.pop(ctx),
                          child: const Icon(Icons.close,
                              color: Colors.white54, size: 18),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '도면 이름을 누르면 해당 층 도면만 단독으로 켜집니다.',
                      style: TextStyle(color: Colors.white60, fontSize: 11),
                    ),
                    const Divider(color: Colors.white24, height: 14),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 240),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _blueprints.length,
                        itemBuilder: (_, i) {
                          final bp = _blueprints[i];
                          final bool isShown = _bpGlobalShow && bp.isVisible;
                          return Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            decoration: BoxDecoration(
                              color: isShown
                                  ? Colors.lightGreenAccent.withOpacity(0.14)
                                  : Colors.white10,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isShown
                                    ? Colors.lightGreenAccent
                                    : Colors.white24,
                                width: isShown ? 1.4 : 1.0,
                              ),
                            ),
                            child: ListTile(
                              dense: true,
                              visualDensity: const VisualDensity(
                                  horizontal: -2, vertical: -3),
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 10),
                              leading: Icon(
                                isShown
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_unchecked,
                                color: isShown
                                    ? Colors.lightGreenAccent
                                    : Colors.white54,
                                size: 18,
                              ),
                              title: Text(
                                bp.name,
                                style: TextStyle(
                                  color: isShown
                                      ? Colors.lightGreenAccent
                                      : Colors.white,
                                  fontSize: 12.5,
                                  fontWeight: isShown
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                              onTap: () async {
                                setState(() {
                                  _bpGlobalShow = true;
                                  for (int j = 0; j < _blueprints.length; j++) {
                                    _blueprints[j].isVisible = (j == i);
                                  }
                                  _activeBpIdx = i;
                                });
                                Navigator.pop(ctx);
                                await _persistBlueprintConfig();
                                await _refreshAllOverlays(
                                    includeBlueprint: true);
                              },
                              trailing: IconButton(
                                icon: Icon(
                                  isShown
                                      ? Icons.visibility
                                      : Icons.visibility_off,
                                  color: isShown
                                      ? Colors.amberAccent
                                      : Colors.white38,
                                  size: 18,
                                ),
                                tooltip: '개별 겹쳐 켜기/끄기',
                                onPressed: () async {
                                  setState(() {
                                    if (!_bpGlobalShow) {
                                      _bpGlobalShow = true;
                                      for (final b in _blueprints) {
                                        b.isVisible = false;
                                      }
                                      bp.isVisible = true;
                                    } else {
                                      bp.isVisible = !bp.isVisible;
                                    }
                                    if (bp.isVisible) _activeBpIdx = i;
                                    if (!_blueprints.any((b) => b.isVisible)) {
                                      _bpGlobalShow = false;
                                    }
                                  });
                                  setDialogState(() {});
                                  await _persistBlueprintConfig();
                                  await _refreshAllOverlays(
                                      includeBlueprint: true);
                                },
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const Divider(color: Colors.white24, height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              setState(() {
                                _bpGlobalShow = false;
                                _bpEditMode = false;
                              });
                              Navigator.pop(ctx);
                              await _persistBlueprintConfig();
                              await _refreshAllOverlays(includeBlueprint: true);
                            },
                            icon: const Icon(Icons.layers_clear,
                                size: 15, color: Colors.redAccent),
                            label: const Text(
                              '전부 끄기',
                              style: TextStyle(
                                color: Colors.redAccent,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.redAccent),
                              padding: const EdgeInsets.symmetric(vertical: 8),
                            ),
                          ),
                        ),
                        if (_blueprints.length > 1) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                setState(() {
                                  _bpGlobalShow = true;
                                  for (final b in _blueprints) {
                                    b.isVisible = true;
                                  }
                                });
                                Navigator.pop(ctx);
                                await _persistBlueprintConfig();
                                await _refreshAllOverlays(
                                    includeBlueprint: true);
                              },
                              icon: const Icon(Icons.done_all,
                                  size: 15, color: Colors.lightBlueAccent),
                              label: const Text(
                                '전체 함께 켜기',
                                style: TextStyle(
                                  color: Colors.lightBlueAccent,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(
                                    color: Colors.lightBlueAccent),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 8),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showAddCategoryDialog(PhotoItem photo) async {
    final TextEditingController textCtrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.grey[900],
          insetPadding: const EdgeInsets.symmetric(horizontal: 65),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '새 카테고리 입력',
                  style: TextStyle(
                    color: Colors.amber,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: 165,
                  child: TextField(
                    controller: textCtrl,
                    autofocus: true,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                      hintText: '예: 철근, 수장, 108동',
                      hintStyle:
                          TextStyle(color: Colors.white54, fontSize: 11.5),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.amber),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.amber, width: 1.5),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(44, 30),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('취소',
                          style:
                              TextStyle(color: Colors.white60, fontSize: 12)),
                    ),
                    const SizedBox(width: 4),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber,
                        minimumSize: const Size(54, 30),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: () {
                        final String newCat = textCtrl.text.trim();
                        if (newCat.isNotEmpty) {
                          setState(() {
                            if (newCat != '미분류') {
                              _customCategories.add(newCat);
                            }
                            photo.category = newCat;
                          });
                          saveDefaultCategory(newCat);
                          _persistCategories();
                          _persistPhotoMetadata();
                        }
                        Navigator.pop(ctx);
                      },
                      child: const Text('추가',
                          style: TextStyle(
                              color: Colors.black,
                              fontSize: 12,
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // 키보드가 올라올 때 세로 폭이 줄어드는 영향을 받지 않도록 지도 가로 폭(widthMeters) 기준으로 화면의 약 60% 크기(반지름 0.32배) 산출
  Future<double> _calcScreen80Radius() async {
    if (_mapCtrl == null) return 200.0;
    try {
      final bounds = await _mapCtrl!.getContentBounds();
      final double widthMeters = Geolocator.distanceBetween(
        bounds.southWest.latitude,
        bounds.southWest.longitude,
        bounds.southWest.latitude,
        bounds.northEast.longitude,
      );
      return (widthMeters * 0.32).clamp(15.0, 3000.0);
    } catch (_) {
      return 200.0;
    }
  }

  Future<void> _updateMapViewportInfo() async {
    if (_mapCtrl == null) return;
    try {
      final bounds = await _mapCtrl!.getContentBounds();
      final camPos = await _mapCtrl!.getCameraPosition();
      final double latRad = camPos.target.latitude * pi / 180.0;
      if (mounted) {
        setState(() {
          _currentMapBounds = bounds;
          _metersPerPixel =
              (156543.03392 * cos(latRad).abs()) / pow(2.0, camPos.zoom);
        });
      }
    } catch (_) {
      _metersPerPixel = 0.5;
    }
  }

  // 도면 이미지 리사이징 해상도를 1600px로 높여 확대 시 선명도 확보 및 버벅임 방지
  Future<void> _prepareFastBlueprintBytes(BlueprintItem item) async {
    try {
      final File fastCacheFile = File('${item.imagePath}.fast_hq.png');
      if (await fastCacheFile.exists()) {
        item.fastBytes = await fastCacheFile.readAsBytes();
      } else {
        final raw = await File(item.imagePath).readAsBytes();
        final decoded = img.decodeImage(raw);
        if (decoded != null) {
          final resized = (decoded.width > 1600 || decoded.height > 1600)
              ? img.copyResize(
                  decoded,
                  width: decoded.width >= decoded.height ? 1600 : null,
                  height: decoded.height > decoded.width ? 1600 : null,
                  interpolation: img.Interpolation.average,
                )
              : decoded;
          item.fastBytes = Uint8List.fromList(img.encodePng(resized, level: 1));
          await fastCacheFile.writeAsBytes(item.fastBytes!);
        } else {
          item.fastBytes = raw;
        }
      }
      if (mounted && item.fastBytes != null) {
        await precacheImage(MemoryImage(item.fastBytes!), context);
      }
    } catch (e) {
      debugPrint('Fast blueprint bytes error: $e');
    }
  }

  Future<void> _importBlueprintFromGallery() async {
    try {
      final picker = ImagePicker();
      final XFile? picked = await picker.pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      if (!mounted) return;

      // 이름 입력 다이얼로그(키보드)가 뜨기 전에 현재 지도 화면 기준 60% 반지름과 중심 좌표를 먼저 계산
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

      final double screen60Rad = await _calcScreen80Radius();
      await _updateMapViewportInfo();

      final String defaultName = '도면 ${_blueprints.length + 1}';
      final String? chosenName = await _promptBlueprintNameDialog(
        defaultName: defaultName,
        title: '새 도면 이름 설정',
      );
      if (chosenName == null) return;

      final dir = await getApplicationDocumentsDirectory();
      final String ext = picked.path.split('.').last;
      final int nowMs = DateTime.now().millisecondsSinceEpoch;
      final String destPath = '${dir.path}/bp_saved_$nowMs.$ext';
      await File(picked.path).copy(destPath);

      final newBp = BlueprintItem(
        id: 'bp_$nowMs',
        name: chosenName,
        imagePath: destPath,
        centerLat: centerLat,
        centerLng: centerLng,
        baseRadius: screen60Rad,
        sizeSlider: 0.5,
        rotation: 0.0,
        opacity: 0.5,
        isVisible: true,
      );

      await _prepareFastBlueprintBytes(newBp);
      if (!mounted) return;

      setState(() {
        _blueprints.add(newBp);
        _activeBpIdx = _blueprints.length - 1;
        _bpGlobalShow = true;
        _bpEditMode = true;
        _bpTouchModeIsBlueprint = true;
      });

      await _persistBlueprintConfig();
      await _refreshAllOverlays(includeBlueprint: true);
    } catch (e) {
      debugPrint('Import blueprint error: $e');
    }
  }

  Future<void> _deleteBlueprintAt(int idx) async {
    if (idx < 0 || idx >= _blueprints.length) return;
    final removed = _blueprints[idx];
    setState(() {
      _blueprints.removeAt(idx);
      if (_blueprints.isEmpty) {
        _activeBpIdx = 0;
        _bpEditMode = false;
      } else if (_activeBpIdx >= _blueprints.length) {
        _activeBpIdx = _blueprints.length - 1;
      }
    });
    try {
      final f = File(removed.imagePath);
      if (await f.exists()) await f.delete();
      final fastF = File('${removed.imagePath}.fast.png');
      if (await fastF.exists()) await fastF.delete();
      final fastHqF = File('${removed.imagePath}.fast_hq.png');
      if (await fastHqF.exists()) await fastHqF.delete();
    } catch (_) {}
    await _persistBlueprintConfig();
    await _refreshAllOverlays(includeBlueprint: true);
  }

  // 네이버 지도 오버레이 이미지 굽기 해상도를 900 (여백 40)으로 유지
  Future<void> _bakeSingleBlueprintOverlay(BlueprintItem bp) async {
    if (!mounted) return;
    final String key = bp.cacheKey;
    if (globalBpOverlayCache.containsKey(key)) {
      bp.cachedOverlayImg = globalBpOverlayCache[key];
      bp.bakedRotation = bp.rotation;
      bp.bakedOpacity = bp.opacity;
      return;
    }

    const double boxSize = 900.0;
    const double padSize = 40.0;

    final Widget imgWidget = bp.fastBytes != null
        ? Image.memory(
            bp.fastBytes!,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
          )
        : Image.file(
            File(bp.imagePath),
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
          );

    final builtImg = await NOverlayImage.fromWidget(
      widget: Opacity(
        opacity: bp.opacity.clamp(0.1, 1.0),
        child: Transform.rotate(
          angle: bp.rotation * (pi / 180.0),
          child: Padding(
            padding: const EdgeInsets.all(padSize),
            child: imgWidget,
          ),
        ),
      ),
      size: const Size(boxSize, boxSize),
      context: context,
    );

    globalBpOverlayCache[key] = builtImg;
    bp.cachedOverlayImg = builtImg;
    bp.bakedRotation = bp.rotation;
    bp.bakedOpacity = bp.opacity;
  }

  Future<void> _syncBlueprintsToMap() async {
    if (_mapCtrl == null || !_bpGlobalShow) return;

    final List<NAddableOverlay> bpOverlays = [];
    for (int i = 0; i < _blueprints.length; i++) {
      final bp = _blueprints[i];
      if (!bp.isVisible) continue;
      if (_useLiveActiveBpOverlay && i == _activeBpIdx) continue;

      if (bp.needsBake) {
        await _bakeSingleBlueprintOverlay(bp);
      }
      if (bp.cachedOverlayImg == null) continue;

      final double rad = bp.currentRadius;
      final double dLat = rad / 111320.0;
      final double cosLat =
          cos(bp.centerLat * pi / 180.0).abs().clamp(0.1, 1.0);
      final double dLng = rad / (111320.0 * cosLat);

      final bounds = NLatLngBounds(
        southWest: NLatLng(bp.centerLat - dLat, bp.centerLng - dLng),
        northEast: NLatLng(bp.centerLat + dLat, bp.centerLng + dLng),
      );

      bpOverlays.add(NGroundOverlay(
        id: bp.id,
        bounds: bounds,
        image: bp.cachedOverlayImg!,
      ));
    }

    if (bpOverlays.isNotEmpty) {
      await _mapCtrl!.addOverlayAll(bpOverlays.toSet());
    }
  }

  void _handleBlueprintPointerMove(PointerMoveEvent event) {
    if (!_activePointers.containsKey(event.pointer)) return;
    final bp = _activeBp;
    if (bp == null || !bp.isVisible) return;

    double latPerPx = (_metersPerPixel / 111320.0);
    final double cosLat = cos(bp.centerLat * pi / 180.0).abs().clamp(0.1, 1.0);
    double lngPerPx = _metersPerPixel / (111320.0 * cosLat);

    if (_currentMapBounds != null &&
        _mapWidgetSize.width > 10 &&
        _mapWidgetSize.height > 10) {
      latPerPx = (_currentMapBounds!.northEast.latitude -
              _currentMapBounds!.southWest.latitude) /
          _mapWidgetSize.height;
      lngPerPx = (_currentMapBounds!.northEast.longitude -
              _currentMapBounds!.southWest.longitude) /
          _mapWidgetSize.width;
    }

    if (_activePointers.length == 1) {
      final Offset prev = _activePointers[event.pointer]!;
      final Offset curr = event.localPosition;
      _activePointers[event.pointer] = curr;

      final double dx = curr.dx - prev.dx;
      final double dy = curr.dy - prev.dy;

      setState(() {
        bp.centerLat -= dy * latPerPx;
        bp.centerLng += dx * lngPerPx;
      });
    } else if (_activePointers.length >= 2) {
      final List<int> keys = _activePointers.keys.toList();
      final int k1 = keys[0];
      final int k2 = keys[1];

      final Offset oldP1 = _activePointers[k1]!;
      final Offset oldP2 = _activePointers[k2]!;
      _activePointers[event.pointer] = event.localPosition;
      final Offset newP1 = _activePointers[k1]!;
      final Offset newP2 = _activePointers[k2]!;

      final Offset oldCenter = (oldP1 + oldP2) / 2.0;
      final Offset newCenter = (newP1 + newP2) / 2.0;
      final double dx = newCenter.dx - oldCenter.dx;
      final double dy = newCenter.dy - oldCenter.dy;

      final double oldDist = (oldP2 - oldP1).distance;
      final double newDist = (newP2 - newP1).distance;

      final double oldAngle = atan2(oldP2.dy - oldP1.dy, oldP2.dx - oldP1.dx);
      final double newAngle = atan2(newP2.dy - newP1.dy, newP2.dx - newP1.dx);
      double angleDiffDeg = (newAngle - oldAngle) * (180.0 / pi);
      if (angleDiffDeg > 180.0) angleDiffDeg -= 360.0;
      if (angleDiffDeg < -180.0) angleDiffDeg += 360.0;

      setState(() {
        bp.centerLat -= dy * latPerPx;
        bp.centerLng += dx * lngPerPx;

        if (oldDist > 8.0 && newDist > 8.0) {
          final double scaleRatio = newDist / oldDist;
          if ((scaleRatio - 1.0).abs() > 0.001) {
            bp.setRadiusDirectly(bp.currentRadius * scaleRatio);
          }
        }

        if (angleDiffDeg.abs() > 0.005) {
          double nextRot = bp.rotation + angleDiffDeg;
          nextRot = ((nextRot + 180.0) % 360.0 + 360.0) % 360.0 - 180.0;
          bp.rotation = nextRot;
        }
      });
    }
  }

  void _shiftBlueprintMeters(double northM, double eastM) {
    final bp = _activeBp;
    if (bp == null) return;
    final double dLat = northM / 111320.0;
    final double cosLat = cos(bp.centerLat * pi / 180.0).abs().clamp(0.1, 1.0);
    final double dLng = eastM / (111320.0 * cosLat);

    setState(() {
      bp.centerLat += dLat;
      bp.centerLng += dLng;
    });
    if (!_useLiveActiveBpOverlay) {
      _syncBlueprintsToMap();
    }
    _persistBlueprintConfig();
  }

  void _panMapKeepZoom(double lat, double lng) {
    if (_mapCtrl == null) return;
    _mapCtrl!.updateCamera(
      NCameraUpdate.scrollAndZoomTo(target: NLatLng(lat, lng)),
    );
  }

  Future<NOverlayImage> _getCachedMarkerIcon(
      double azimuth, bool selected) async {
    final int degStep = (((azimuth % 360 + 360) % 360) / 5).round() * 5 % 360;
    final String key = '${selected ? "sel" : "unsel"}_$degStep';
    if (globalMarkerIconCache.containsKey(key)) {
      return globalMarkerIconCache[key]!;
    }

    final Color c = selected ? Colors.blueAccent : Colors.red;
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
            angle: degStep * (pi / 180.0),
            child: Icon(Icons.navigation, color: c, size: 20),
          ),
        ],
      ),
      size: const Size(28, 28),
      context: context,
    );
    globalMarkerIconCache[key] = icon;
    return icon;
  }

  // 현재 지도 확대 배율(화면 픽셀당 미터)을 계산해, 화면상 동그라미(28dp)가 실제로 겹치는 거리(m)만 반환
  Future<double> _getMarkerOverlapThresholdMeters() async {
    double mPerPx = _metersPerPixel;
    if (_mapCtrl != null) {
      try {
        final camPos = await _mapCtrl!.getCameraPosition();
        final double latRad = camPos.target.latitude * pi / 180.0;
        final double zoomMPerPx =
            (156543.03392 * cos(latRad).abs()) / pow(2.0, camPos.zoom);

        final bounds = await _mapCtrl!.getContentBounds();
        final double widthMeters = Geolocator.distanceBetween(
          bounds.southWest.latitude,
          bounds.southWest.longitude,
          bounds.southWest.latitude,
          bounds.northEast.longitude,
        );
        if (_mapWidgetSize.width > 10 && widthMeters > 0) {
          final double boundsMPerPx = widthMeters / _mapWidgetSize.width;
          mPerPx = min(zoomMPerPx, boundsMPerPx);
        } else {
          mPerPx = zoomMPerPx;
        }
        _metersPerPixel = mPerPx;
      } catch (_) {}
    }
    // 마커 아이콘 지름(28dp) 기준, 화면상 중심 거리가 20dp 이하로 겹쳐 보일 때만 순환
    return (mPerPx * 20.0).clamp(0.1, 5000.0);
  }

  NMarker _buildPhotoMarker(int idx, PhotoItem item, NOverlayImage icon) {
    final marker = NMarker(
      id: 'photo_marker_$idx',
      position: NLatLng(item.lat, item.lng),
      icon: icon,
    );

    marker.setOnTapListener((_) async {
      final double overlapMeters = await _getMarkerOverlapThresholdMeters();
      final List<int> nearby = [];
      for (int j = 0; j < _visiblePhotos.length; j++) {
        final double dist = Geolocator.distanceBetween(
          item.lat,
          item.lng,
          _visiblePhotos[j].lat,
          _visiblePhotos[j].lng,
        );
        if (dist <= overlapMeters) nearby.add(j);
      }

      int nextIdx = idx;
      if (nearby.length > 1 && nearby.contains(_selectedIdx)) {
        final int pos = nearby.indexOf(_selectedIdx);
        nextIdx = nearby[(pos + 1) % nearby.length];
      }

      await _selectPhotoFast(nextIdx);
    });

    return marker;
  }

  Future<void> _selectPhotoFast(int newIdx) async {
    if (newIdx < 0 || newIdx >= _visiblePhotos.length) return;
    final int prevIdx = _selectedIdx;
    setState(() => _selectedIdx = newIdx);

    final target = _visiblePhotos[newIdx];
    _panMapKeepZoom(target.lat, target.lng);

    if (_mapCtrl == null) return;
    try {
      final List<NAddableOverlay> updates = [];
      if (prevIdx >= 0 &&
          prevIdx < _visiblePhotos.length &&
          prevIdx != newIdx) {
        final prevItem = _visiblePhotos[prevIdx];
        final prevIcon = await _getCachedMarkerIcon(prevItem.azimuth, false);
        updates.add(_buildPhotoMarker(prevIdx, prevItem, prevIcon));
      }
      final newIcon = await _getCachedMarkerIcon(target.azimuth, true);
      updates.add(_buildPhotoMarker(newIdx, target, newIcon));
      await _mapCtrl!.addOverlayAll(updates.toSet());
    } catch (e) {
      debugPrint('Fast select marker update error: $e');
    }
  }

  void _showExportOptionsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    '📤 내보내기 방식을 선택하세요',
                    style: TextStyle(
                      color: Colors.amber,
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const Divider(color: Colors.white24),
                ListTile(
                  leading:
                      const Icon(Icons.public, color: Colors.lightBlueAccent),
                  title: const Text(
                    '① 웹 뷰어 파일(.html)로 내보내기',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    '현재 필터(날짜: $_dateFilter, 카테고리: $_categoryFilter) 상태 + 켜진 도면 불투명 100%로 내보내기',
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _exportAsHtmlViewer();
                  },
                ),
                ListTile(
                  leading:
                      const Icon(Icons.folder_zip, color: Colors.amberAccent),
                  title: const Text(
                    '② 프로젝트 압축파일(.zip)로 내보내기',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text(
                    '현재 필터링된 원본 사진들과 저장된 모든 도면 설정 데이터를 통째로 묶어 전달',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _exportAsZipArchive();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.burst_mode,
                      color: Colors.lightGreenAccent),
                  title: const Text(
                    '③ [사진 + 도면 지도] 합본 이미지(.jpg) 공유',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text(
                    '현재 선택된 사진과 도면이 얹어진 지도를 1장의 이미지로 합쳐 즉시 공유',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _exportAsCombinedImage();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _exportAsHtmlViewer() async {
    final visibleBps =
        _bpGlobalShow ? _blueprints.where((b) => b.isVisible).toList() : [];
    if (_visiblePhotos.isEmpty && visibleBps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('내보낼 사진이나 도면이 없습니다.')),
      );
      return;
    }

    setState(() => _isExporting = true);
    try {
      final List<Map<String, dynamic>> encodedPhotos = [];
      for (final p in _visiblePhotos) {
        final f = File(p.path);
        if (!f.existsSync()) continue;
        final raw = await f.readAsBytes();
        img.Image? decoded = img.decodeImage(raw);
        Uint8List outBytes = raw;
        if (decoded != null && decoded.width > 960) {
          decoded = img.copyResize(decoded, width: 960);
          outBytes = Uint8List.fromList(img.encodeJpg(decoded, quality: 78));
        }
        encodedPhotos.add({
          'b64': 'data:image/jpeg;base64,${base64Encode(outBytes)}',
          'lat': p.lat,
          'lng': p.lng,
          'alt': p.alt,
          'acc': p.acc,
          'azimuth': p.azimuth,
          'pitch': p.pitch,
          'time': p.timestamp,
          'category': p.category,
          'memo': p.memo,
        });
      }

      final List<Map<String, dynamic>> bpJsonList = [];
      for (final bp in visibleBps) {
        if (!File(bp.imagePath).existsSync()) continue;
        final bpBytes = await File(bp.imagePath).readAsBytes();
        final String ext = bp.imagePath.split('.').last.toLowerCase();
        final String mime = ext == 'png' ? 'image/png' : 'image/jpeg';
        final double rad = bp.currentRadius;
        final double dLat = rad / 111320.0;
        final double cosLat =
            cos(bp.centerLat * pi / 180.0).abs().clamp(0.1, 1.0);
        final double dLng = rad / (111320.0 * cosLat);

        bpJsonList.add({
          'name': bp.name,
          'b64': 'data:$mime;base64,${base64Encode(bpBytes)}',
          'lat': bp.centerLat,
          'lng': bp.centerLng,
          'swLat': bp.centerLat - dLat,
          'swLng': bp.centerLng - dLng,
          'neLat': bp.centerLat + dLat,
          'neLng': bp.centerLng + dLng,
          'rotation': bp.rotation,
          'opacity': 1.0,
        });
      }

      double currentMapZoom = 18.0;
      if (_mapCtrl != null) {
        try {
          final cam = await _mapCtrl!.getCameraPosition();
          currentMapZoom = cam.zoom;
        } catch (_) {}
      }

      final String photosJs = jsonEncode(encodedPhotos);
      final String bpsJs = jsonEncode(bpJsonList);

      final String htmlContent = '''
<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<title>GPS 도면 & 현장 사진 대시보드</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"/>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<style>
  body, html { margin: 0; padding: 0; height: 100%; background: #111; color: #fff; font-family: sans-serif; display: flex; flex-direction: column; overflow: hidden; }
  header { padding: 10px 14px; background: #000; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #333; flex-wrap: wrap; gap: 6px; }
  .main-wrap { flex: 1; display: flex; flex-direction: row; overflow: hidden; }
  @media (max-width: 768px) { .main-wrap { flex-direction: column; } }
  #photo-pane { flex: 1; background: #000; display: flex; align-items: center; justify-content: center; overflow: hidden; position: relative; touch-action: none; }
  #photo-pane img { max-width: 100%; max-height: 100%; object-fit: contain; transform-origin: center center; user-select: none; -webkit-user-drag: none; }
  .zoom-hint { position: absolute; bottom: 8px; right: 10px; background: rgba(0,0,0,0.6); color: #ddd; font-size: 11px; padding: 3px 8px; border-radius: 12px; pointer-events: none; }
  #map-pane { flex: 1; position: relative; }
  #thumbs { height: 82px; background: #000; display: flex; overflow-x: auto; padding: 4px; border-top: 1px solid #333; }
  #thumbs img { width: 70px; height: 70px; object-fit: cover; margin-right: 6px; border: 3px solid transparent; cursor: pointer; flex-shrink: 0; }
  #thumbs img.active { border-color: #ffc107; }
</style>
</head>
<body>
<header>
  <strong>📍 날짜: $_dateFilter | 카테고리: $_categoryFilter</strong>
  <span id="info-txt" style="font-size:12px; color:#ffc107;"></span>
</header>
<div class="main-wrap">
  <div id="photo-pane">
    <img id="main-photo" src="" alt="현장 사진"/>
    <div class="zoom-hint">두 손가락 확대/이동 · 더블터치 초기화</div>
  </div>
  <div id="map-pane"></div>
</div>
<div id="thumbs"></div>
<script>
const photos = $photosJs;
const bps = $bpsJs;
let selectedIdx = photos.length > 0 ? 0 : 0;

const photoPane = document.getElementById('photo-pane');
const mainImg = document.getElementById('main-photo');
let pScale = 1.0, pX = 0, pY = 0;
let startDist = 0, startScale = 1.0;
let isDragging = false, dragStartX = 0, dragStartY = 0;
let lastTapTime = 0;

function applyPhotoTransform() {
  mainImg.style.transform = `translate(\${pX}px, \${pY}px) scale(\${pScale})`;
}

function resetPhotoZoom() {
  pScale = 1.0; pX = 0; pY = 0;
  applyPhotoTransform();
}

function getTouchDist(t1, t2) {
  const dx = t1.clientX - t2.clientX;
  const dy = t1.clientY - t2.clientY;
  return Math.hypot(dx, dy);
}

photoPane.addEventListener('touchstart', (e) => {
  if (e.touches.length === 2) {
    isDragging = false;
    startDist = getTouchDist(e.touches[0], e.touches[1]);
    startScale = pScale;
  } else if (e.touches.length === 1) {
    const now = Date.now();
    if (now - lastTapTime < 300) {
      pScale = pScale > 1.2 ? 1.0 : 2.5;
      pX = 0; pY = 0;
      applyPhotoTransform();
      lastTapTime = 0;
      return;
    }
    lastTapTime = now;
    if (pScale > 1.02) {
      isDragging = true;
      dragStartX = e.touches[0].clientX - pX;
      dragStartY = e.touches[0].clientY - pY;
    }
  }
}, { passive: false });

photoPane.addEventListener('touchmove', (e) => {
  e.preventDefault();
  if (e.touches.length === 2 && startDist > 0) {
    const dist = getTouchDist(e.touches[0], e.touches[1]);
    pScale = Math.min(5.0, Math.max(1.0, startScale * (dist / startDist)));
    if (pScale <= 1.02) { pX = 0; pY = 0; }
    applyPhotoTransform();
  } else if (e.touches.length === 1 && isDragging && pScale > 1.02) {
    pX = e.touches[0].clientX - dragStartX;
    pY = e.touches[0].clientY - dragStartY;
    applyPhotoTransform();
  }
}, { passive: false });

photoPane.addEventListener('touchend', (e) => {
  if (e.touches.length < 2) startDist = 0;
  if (e.touches.length === 0) isDragging = false;
});

photoPane.addEventListener('wheel', (e) => {
  e.preventDefault();
  const delta = e.deltaY < 0 ? 0.2 : -0.2;
  pScale = Math.min(5.0, Math.max(1.0, pScale + delta));
  if (pScale <= 1.02) { pX = 0; pY = 0; }
  applyPhotoTransform();
}, { passive: false });

const initLat = photos.length > 0 ? photos[selectedIdx].lat : (bps.length > 0 ? bps[0].lat : 37.4984);
const initLng = photos.length > 0 ? photos[selectedIdx].lng : (bps.length > 0 ? bps[0].lng : 127.1324);

const map = L.map('map-pane', { maxZoom: 22 }).setView([initLat, initLng], ${currentMapZoom.toStringAsFixed(1)});
L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
  maxNativeZoom: 19,
  maxZoom: 22,
  attribution: '© OpenStreetMap'
}).addTo(map);

bps.forEach((bp) => {
  const bpImg = new Image();
  bpImg.onload = () => {
    const size = 900;
    const pad = 40;
    const inner = size - pad * 2;
    const canvas = document.createElement('canvas');
    canvas.width = size;
    canvas.height = size;
    const ctx = canvas.getContext('2d');
    ctx.clearRect(0, 0, size, size);
    ctx.save();
    ctx.globalAlpha = 1.0;
    ctx.translate(size / 2, size / 2);
    ctx.rotate(bp.rotation * Math.PI / 180.0);
    const scale = Math.min(inner / bpImg.width, inner / bpImg.height);
    const drawW = bpImg.width * scale;
    const drawH = bpImg.height * scale;
    ctx.drawImage(bpImg, -drawW / 2, -drawH / 2, drawW, drawH);
    ctx.restore();

    const bakedUrl = canvas.toDataURL('image/png');
    const bounds = [[bp.swLat, bp.swLng], [bp.neLat, bp.neLng]];
    L.imageOverlay(bakedUrl, bounds, { opacity: 1.0, interactive: false }).addTo(map);
  };
  bpImg.src = bp.b64;
});

const markersLayer = L.layerGroup().addTo(map);

function getDistanceMeters(lat1, lon1, lat2, lon2) {
  const R = 6371000;
  const dLat = (lat2 - lat1) * Math.PI / 180.0;
  const dLon = (lon2 - lon1) * Math.PI / 180.0;
  const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(lat1 * Math.PI / 180.0) * Math.cos(lat2 * Math.PI / 180.0) *
            Math.sin(dLon / 2) * Math.sin(dLon / 2);
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function selectPhoto(idx) {
  selectedIdx = idx;
  resetPhotoZoom();
  const p = photos[idx];
  mainImg.src = p.b64;
  document.getElementById('info-txt').innerText =
    `[\${p.category}] 위도: \${p.lat.toFixed(6)} | 경도: \${p.lng.toFixed(6)} | 방위각: \${p.azimuth.toFixed(1)}° | \${p.time}` + (p.memo ? ` | 메모: \${p.memo}` : '');
  renderThumbnails();
  renderMarkers();
  map.panTo([p.lat, p.lng]);
}

function renderThumbnails() {
  const box = document.getElementById('thumbs');
  box.innerHTML = '';
  photos.forEach((p, i) => {
    const im = document.createElement('img');
    im.src = p.b64;
    if (i === selectedIdx) im.className = 'active';
    im.onclick = () => selectPhoto(i);
    box.appendChild(im);
  });
}

function renderMarkers() {
  markersLayer.clearLayers();
  const order = [];
  for (let i = 0; i < photos.length; i++) {
    if (i !== selectedIdx) order.push(i);
  }
  if (selectedIdx >= 0 && selectedIdx < photos.length) {
    order.push(selectedIdx);
  }

  order.forEach((i) => {
    const p = photos[i];
    const isSel = (i === selectedIdx);
    const color = isSel ? '#2979ff' : '#f44336';
    const zIdx = isSel ? 1000 : 100;
    const htmlIcon = L.divIcon({
      className: '',
      iconSize: [28, 28],
      iconAnchor: [14, 14],
      html: `<div style="width:24px;height:24px;border-radius:50%;background:\${color}4d;border:2px solid \${color};display:flex;align-items:center;justify-content:center;transform:rotate(\${p.azimuth}deg);">
               <span style="color:\${color};font-size:14px;font-weight:bold;">▲</span>
             </div>`
    });
    const m = L.marker([p.lat, p.lng], { icon: htmlIcon, zIndexOffset: zIdx }).addTo(markersLayer);
    m.on('click', () => {
      const clickedPt = map.latLngToContainerPoint([p.lat, p.lng]);
      const nearby = [];
      for (let j = 0; j < photos.length; j++) {
        const targetPt = map.latLngToContainerPoint([photos[j].lat, photos[j].lng]);
        const pxDist = Math.hypot(clickedPt.x - targetPt.x, clickedPt.y - targetPt.y);
        if (pxDist <= 20.0) nearby.push(j);
      }
      let nextIdx = i;
      if (nearby.length > 1 && nearby.includes(selectedIdx)) {
        const pos = nearby.indexOf(selectedIdx);
        nextIdx = nearby[(pos + 1) % nearby.length];
      }
      selectPhoto(nextIdx);
    });
  });
}

if (photos.length > 0) {
  selectPhoto(selectedIdx);
}
</script>
</body>
</html>
''';

      final dir = await getTemporaryDirectory();
      final String stamp = DateTime.now()
          .toString()
          .substring(0, 16)
          .replaceAll(RegExp(r'[:\-\s]'), '');
      final File htmlFile = File('${dir.path}/GPS_Map_Viewer_$stamp.html');
      await htmlFile.writeAsString(htmlContent);

      await Share.shareXFiles(
        [XFile(htmlFile.path)],
        text: '📍 GPS 도면 & 현장 촬영 사진 웹 뷰어 파일입니다. (클릭하여 브라우저로 열기)',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('HTML 내보내기 오류: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _exportAsZipArchive() async {
    if (_visiblePhotos.isEmpty && _blueprints.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('내보낼 사진이나 도면이 없습니다.')),
      );
      return;
    }

    setState(() => _isExporting = true);
    try {
      final Archive archive = Archive();

      final List<Map<String, dynamic>> exportedMeta = [];
      for (final p in _visiblePhotos) {
        final f = File(p.path);
        if (!f.existsSync()) continue;
        final String fileName = p.path.split('/').last;
        final Uint8List bytes = await f.readAsBytes();
        archive.addFile(ArchiveFile('photos/$fileName', bytes.length, bytes));

        final mapItem = p.toMap();
        mapItem['fileName'] = fileName;
        exportedMeta.add(mapItem);
      }

      final Uint8List metaBytes =
          Uint8List.fromList(utf8.encode(jsonEncode(exportedMeta)));
      archive.addFile(
          ArchiveFile('photos_meta.json', metaBytes.length, metaBytes));

      final List<Map<String, dynamic>> exportedBps = [];
      for (final bp in _blueprints) {
        final f = File(bp.imagePath);
        if (!f.existsSync()) continue;
        final String bpName = bp.imagePath.split('/').last;
        final Uint8List bpBytes = await f.readAsBytes();
        archive.addFile(
            ArchiveFile('blueprint/$bpName', bpBytes.length, bpBytes));

        final bpMap = bp.toMap();
        bpMap['fileName'] = bpName;
        exportedBps.add(bpMap);
      }

      if (exportedBps.isNotEmpty) {
        final Uint8List cfgBytes = Uint8List.fromList(utf8.encode(jsonEncode({
          'globalShow': _bpGlobalShow,
          'blueprints': exportedBps,
        })));
        archive.addFile(
            ArchiveFile('blueprint_config.json', cfgBytes.length, cfgBytes));
      }

      final List<int>? zipData = ZipEncoder().encode(archive);
      if (zipData == null) throw Exception('ZIP 압축 실패');

      final dir = await getTemporaryDirectory();
      final String stamp = DateTime.now()
          .toString()
          .substring(0, 16)
          .replaceAll(RegExp(r'[:\-\s]'), '');
      final File zipFile = File('${dir.path}/GPS_Camera_Package_$stamp.zip');
      await zipFile.writeAsBytes(zipData);

      await Share.shareXFiles(
        [XFile(zipFile.path)],
        text: '📦 GPS 도면 & 현장 사진 원본 패키지(.zip)입니다.',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('ZIP 내보내기 오류: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _exportAsCombinedImage() async {
    if (_visiblePhotos.isEmpty || _mapCtrl == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('합성할 사진이나 지도가 준비되지 않았습니다.')),
      );
      return;
    }

    setState(() => _isExporting = true);
    try {
      final bool prevEdit = _bpEditMode;
      if (prevEdit) {
        setState(() => _bpEditMode = false);
        await _refreshAllOverlays(includeBlueprint: true);
        await Future.delayed(const Duration(milliseconds: 120));
      }

      final PhotoItem currentPhoto =
          _visiblePhotos[_selectedIdx.clamp(0, _visiblePhotos.length - 1)];
      final File mapSnapFile = await _mapCtrl!.takeSnapshot();

      if (prevEdit && mounted) {
        setState(() => _bpEditMode = true);
        await _refreshAllOverlays(includeBlueprint: true);
      }

      final Uint8List photoBytes = await File(currentPhoto.path).readAsBytes();
      final Uint8List mapBytes = await mapSnapFile.readAsBytes();

      img.Image? leftImg = img.decodeImage(photoBytes);
      img.Image? rightImg = img.decodeImage(mapBytes);

      if (leftImg == null || rightImg == null) {
        throw Exception('이미지 디코딩에 실패했습니다.');
      }

      const int targetH = 1000;
      leftImg = img.copyResize(leftImg, height: targetH);
      rightImg = img.copyResize(rightImg, height: targetH);

      final int totalW = leftImg.width + rightImg.width + 12;
      final img.Image combined = img.Image(width: totalW, height: targetH);
      img.fill(combined, color: img.ColorRgb8(20, 20, 20));

      img.compositeImage(combined, leftImg, dstX: 0, dstY: 0);
      img.compositeImage(combined, rightImg,
          dstX: leftImg.width + 12, dstY: 0);

      final List<int> outJpg = img.encodeJpg(combined, quality: 92);
      final dir = await getTemporaryDirectory();
      final String stamp = DateTime.now()
          .toString()
          .substring(0, 16)
          .replaceAll(RegExp(r'[:\-\s]'), '');
      final File outFile = File('${dir.path}/GPS_Report_$stamp.jpg');
      await outFile.writeAsBytes(outJpg);

      await Gal.putImage(outFile.path);

      await Share.shareXFiles(
        [XFile(outFile.path)],
        text:
            '🖼️ 현장 사진 & 도면 위치 합본 [카테고리: ${currentPhoto.category}] (${currentPhoto.timestamp})\n위도: ${currentPhoto.lat.toStringAsFixed(6)}, 경도: ${currentPhoto.lng.toStringAsFixed(6)}${currentPhoto.memo.trim().isNotEmpty ? "\n내용: ${currentPhoto.memo.trim()}" : ""}',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('합본 이미지 생성 오류: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Widget _fineStepBtn(String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white12,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white24),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLiveBlueprintOverlayWidget(Size mapSize) {
    final bp = _activeBp;
    final bounds = _currentMapBounds;
    if (bp == null || bounds == null || !bp.isVisible) {
      return const SizedBox.shrink();
    }

    final double rad = bp.currentRadius;
    final double dLat = rad / 111320.0;
    final double cosLat = cos(bp.centerLat * pi / 180.0).abs().clamp(0.1, 1.0);
    final double dLng = rad / (111320.0 * cosLat);

    final double swLat = bp.centerLat - dLat;
    final double neLat = bp.centerLat + dLat;
    final double swLng = bp.centerLng - dLng;
    final double neLng = bp.centerLng + dLng;

    final double latSpan =
        (bounds.northEast.latitude - bounds.southWest.latitude).abs();
    final double lngSpan =
        (bounds.northEast.longitude - bounds.southWest.longitude).abs();
    if (latSpan < 1e-9 || lngSpan < 1e-9) return const SizedBox.shrink();

    final double left =
        ((swLng - bounds.southWest.longitude) / lngSpan) * mapSize.width;
    final double right =
        ((neLng - bounds.southWest.longitude) / lngSpan) * mapSize.width;
    final double top =
        ((bounds.northEast.latitude - neLat) / latSpan) * mapSize.height;
    final double bottom =
        ((bounds.northEast.latitude - swLat) / latSpan) * mapSize.height;

    final double boxW = (right - left).abs();
    final double boxH = (bottom - top).abs();
    if (boxW < 2 || boxH < 2) return const SizedBox.shrink();

    final Widget imgWidget = bp.fastBytes != null
        ? Image.memory(
            bp.fastBytes!,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
          )
        : Image.file(
            File(bp.imagePath),
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
          );

    return Positioned(
      left: left,
      top: top,
      width: boxW,
      height: boxH,
      child: IgnorePointer(
        child: Opacity(
          opacity: bp.opacity.clamp(0.1, 1.0),
          child: Transform.rotate(
            angle: bp.rotation * (pi / 180.0),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: boxW * (40.0 / 900.0),
                vertical: boxH * (40.0 / 900.0),
              ),
              child: imgWidget,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBlueprintControlBox() {
    final bp = _activeBp;
    if (bp == null) {
      return Container(
        color: Colors.grey[900],
        alignment: Alignment.center,
        child: ElevatedButton.icon(
          onPressed: _importBlueprintFromGallery,
          icon: const Icon(Icons.add_photo_alternate),
          label: const Text('도면 추가하기'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.amber,
            foregroundColor: Colors.black,
          ),
        ),
      );
    }

    return Container(
      color: Colors.grey[900],
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 32,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  ...List.generate(_blueprints.length, (i) {
                    final item = _blueprints[i];
                    final bool isSel = i == _activeBpIdx;
                    return Container(
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(
                        color: isSel
                            ? Colors.amber.withOpacity(0.22)
                            : Colors.white10,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: isSel ? Colors.amber : Colors.white24,
                          width: isSel ? 1.5 : 1.0,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          InkWell(
                            onTap: () async {
                              setState(() {
                                item.isVisible = !item.isVisible;
                                if (item.isVisible) _bpGlobalShow = true;
                              });
                              await _persistBlueprintConfig();
                              await _refreshAllOverlays(includeBlueprint: true);
                            },
                            child: Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(
                                item.isVisible
                                    ? Icons.visibility
                                    : Icons.visibility_off,
                                size: 15,
                                color: item.isVisible
                                    ? Colors.lightGreenAccent
                                    : Colors.white38,
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: () async {
                              await _updateMapViewportInfo();
                              setState(() {
                                _activeBpIdx = i;
                                item.isVisible = true;
                                _bpGlobalShow = true;
                              });
                              await _refreshAllOverlays(includeBlueprint: true);
                            },
                            onLongPress: () async {
                              final newName = await _promptBlueprintNameDialog(
                                defaultName: item.name,
                                title: '도면 이름 변경',
                              );
                              if (newName != null && newName.isNotEmpty) {
                                setState(() => item.name = newName);
                                await _persistBlueprintConfig();
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 4),
                              child: Text(
                                item.name,
                                style: TextStyle(
                                  color: isSel ? Colors.amber : Colors.white,
                                  fontSize: 11.5,
                                  fontWeight: isSel
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: () => _deleteBlueprintAt(i),
                            child: const Padding(
                              padding: EdgeInsets.only(left: 4),
                              child: Icon(
                                Icons.close,
                                size: 14,
                                color: Colors.redAccent,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                  InkWell(
                    onTap: _importBlueprintFromGallery,
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: Colors.amber.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.amber),
                      ),
                      alignment: Alignment.center,
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add, size: 14, color: Colors.amber),
                          SizedBox(width: 2),
                          Text(
                            '도면추가',
                            style: TextStyle(
                              color: Colors.amber,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            await _updateMapViewportInfo();
                            setState(() => _bpTouchModeIsBlueprint = true);
                            await _refreshAllOverlays(includeBlueprint: true);
                          },
                          icon: const Icon(Icons.pan_tool_alt, size: 15),
                          label: const Text('도면이동',
                              style: TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _bpTouchModeIsBlueprint
                                ? Colors.amber
                                : Colors.white12,
                            foregroundColor: _bpTouchModeIsBlueprint
                                ? Colors.black
                                : Colors.white70,
                            padding: const EdgeInsets.symmetric(vertical: 6),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            setState(() => _bpTouchModeIsBlueprint = false);
                            await _persistBlueprintConfig();
                            await _refreshAllOverlays(includeBlueprint: true);
                          },
                          icon: const Icon(Icons.map_outlined, size: 15),
                          label: const Text('지도이동',
                              style: TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: !_bpTouchModeIsBlueprint
                                ? Colors.lightBlueAccent
                                : Colors.white12,
                            foregroundColor: !_bpTouchModeIsBlueprint
                                ? Colors.black
                                : Colors.white70,
                            padding: const EdgeInsets.symmetric(vertical: 6),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () async {
                    setState(() {
                      _bpEditMode = false;
                      _isSliderManipulating = false;
                    });
                    await _persistBlueprintConfig();
                    await _refreshAllOverlays(includeBlueprint: true);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('모든 도면 설정이 영구 저장되었습니다!'),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.check, size: 15),
                  label: const Text('저장',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.greenAccent[700],
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text(
                _bpTouchModeIsBlueprint
                    ? '💡 [${bp.name}] 한 손가락 이동, 두 손가락 확대·회전이 즉시 반영됩니다. (탭 길게 눌러 이름 변경)'
                    : '💡 [지도이동 켜짐] 도면은 고정된 채로 배경 지도를 이동·확대할 수 있습니다.',
                style: TextStyle(
                  color: _bpTouchModeIsBlueprint
                      ? Colors.amberAccent
                      : Colors.lightBlueAccent,
                  fontSize: 11,
                ),
              ),
            ),
            const Divider(color: Colors.white24, height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                ElevatedButton.icon(
                  onPressed: () async {
                    if (_mapCtrl == null) return;
                    final pos = await _mapCtrl!.getCameraPosition();
                    final rad60 = await _calcScreen80Radius();
                    await _updateMapViewportInfo();
                    setState(() {
                      bp.centerLat = pos.target.latitude;
                      bp.centerLng = pos.target.longitude;
                      bp.baseRadius = rad60;
                      bp.sizeSlider = 0.5;
                    });
                    if (!_useLiveActiveBpOverlay) {
                      await _syncBlueprintsToMap();
                    }
                    await _persistBlueprintConfig();
                  },
                  icon: const Icon(Icons.center_focus_strong, size: 14),
                  label:
                      const Text('화면중앙 초기화', style: TextStyle(fontSize: 11)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueGrey,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 30),
                  ),
                ),
                Row(
                  children: [
                    _fineStepBtn(
                      _nudgeStepMeters == 1.0 ? '단위: 1m' : '단위: 5m',
                      () {
                        setState(() {
                          _nudgeStepMeters =
                              (_nudgeStepMeters == 1.0) ? 5.0 : 1.0;
                        });
                      },
                    ),
                    IconButton(
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.arrow_back,
                          color: Colors.white, size: 18),
                      onPressed: () =>
                          _shiftBlueprintMeters(0, -_nudgeStepMeters),
                    ),
                    IconButton(
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.arrow_upward,
                          color: Colors.white, size: 18),
                      onPressed: () =>
                          _shiftBlueprintMeters(_nudgeStepMeters, 0),
                    ),
                    IconButton(
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.arrow_downward,
                          color: Colors.white, size: 18),
                      onPressed: () =>
                          _shiftBlueprintMeters(-_nudgeStepMeters, 0),
                    ),
                    IconButton(
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.arrow_forward,
                          color: Colors.white, size: 18),
                      onPressed: () =>
                          _shiftBlueprintMeters(0, _nudgeStepMeters),
                    ),
                  ],
                ),
              ],
            ),
            Row(
              children: [
                SizedBox(
                  width: 78,
                  child: Text(
                    '크기:${bp.currentRadius.toStringAsFixed(1)}m',
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
                _fineStepBtn('-5m', () {
                  setState(() {
                    bp.setRadiusDirectly(bp.currentRadius - 5.0);
                  });
                  if (!_useLiveActiveBpOverlay) _syncBlueprintsToMap();
                  _persistBlueprintConfig();
                }),
                _fineStepBtn('-0.5', () {
                  setState(() {
                    bp.setRadiusDirectly(bp.currentRadius - 0.5);
                  });
                  if (!_useLiveActiveBpOverlay) _syncBlueprintsToMap();
                  _persistBlueprintConfig();
                }),
                Expanded(
                  child: Slider(
                    value: bp.sizeSlider.clamp(0.0, 1.0),
                    min: 0.0,
                    max: 1.0,
                    activeColor: Colors.amber,
                    onChangeStart: (_) async {
                      if (!_bpTouchModeIsBlueprint) {
                        await _updateMapViewportInfo();
                        setState(() => _isSliderManipulating = true);
                        await _refreshAllOverlays(includeBlueprint: true);
                      }
                    },
                    onChanged: (val) {
                      setState(() => bp.sizeSlider = val);
                    },
                    onChangeEnd: (_) async {
                      if (_isSliderManipulating) {
                        setState(() => _isSliderManipulating = false);
                        await _refreshAllOverlays(includeBlueprint: true);
                      }
                      await _persistBlueprintConfig();
                    },
                  ),
                ),
                _fineStepBtn('+0.5', () {
                  setState(() {
                    bp.setRadiusDirectly(bp.currentRadius + 0.5);
                  });
                  if (!_useLiveActiveBpOverlay) _syncBlueprintsToMap();
                  _persistBlueprintConfig();
                }),
                _fineStepBtn('+5m', () {
                  setState(() {
                    bp.setRadiusDirectly(bp.currentRadius + 5.0);
                  });
                  if (!_useLiveActiveBpOverlay) _syncBlueprintsToMap();
                  _persistBlueprintConfig();
                }),
              ],
            ),
            Row(
              children: [
                SizedBox(
                  width: 78,
                  child: Text(
                    '회전:${bp.rotation.toStringAsFixed(1)}°',
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
                _fineStepBtn('-2°', () async {
                  setState(() {
                    bp.rotation = (bp.rotation - 2.0).clamp(-180.0, 180.0);
                  });
                  if (!_useLiveActiveBpOverlay) await _syncBlueprintsToMap();
                  _persistBlueprintConfig();
                }),
                _fineStepBtn('-0.2°', () async {
                  setState(() {
                    bp.rotation = (bp.rotation - 0.2).clamp(-180.0, 180.0);
                  });
                  if (!_useLiveActiveBpOverlay) await _syncBlueprintsToMap();
                  _persistBlueprintConfig();
                }),
                Expanded(
                  child: Slider(
                    value: bp.rotation.clamp(-180.0, 180.0),
                    min: -180.0,
                    max: 180.0,
                    activeColor: Colors.amber,
                    onChangeStart: (_) async {
                      if (!_bpTouchModeIsBlueprint) {
                        await _updateMapViewportInfo();
                        setState(() => _isSliderManipulating = true);
                        await _refreshAllOverlays(includeBlueprint: true);
                      }
                    },
                    onChanged: (val) {
                      setState(() => bp.rotation = val);
                    },
                    onChangeEnd: (_) async {
                      if (_isSliderManipulating) {
                        setState(() => _isSliderManipulating = false);
                        await _refreshAllOverlays(includeBlueprint: true);
                      }
                      await _persistBlueprintConfig();
                    },
                  ),
                ),
                _fineStepBtn('+0.2°', () async {
                  setState(() {
                    bp.rotation = (bp.rotation + 0.2).clamp(-180.0, 180.0);
                  });
                  if (!_useLiveActiveBpOverlay) await _syncBlueprintsToMap();
                  _persistBlueprintConfig();
                }),
                _fineStepBtn('+2°', () async {
                  setState(() {
                    bp.rotation = (bp.rotation + 2.0).clamp(-180.0, 180.0);
                  });
                  if (!_useLiveActiveBpOverlay) await _syncBlueprintsToMap();
                  _persistBlueprintConfig();
                }),
              ],
            ),
            Row(
              children: [
                SizedBox(
                  width: 78,
                  child: Text(
                    '투명도:${(bp.opacity * 100).toInt()}%',
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: bp.opacity.clamp(0.1, 1.0),
                    min: 0.1,
                    max: 1.0,
                    activeColor: Colors.amber,
                    onChangeStart: (_) async {
                      if (!_bpTouchModeIsBlueprint) {
                        await _updateMapViewportInfo();
                        setState(() => _isSliderManipulating = true);
                        await _refreshAllOverlays(includeBlueprint: true);
                      }
                    },
                    onChanged: (val) {
                      setState(() => bp.opacity = val);
                    },
                    onChangeEnd: (_) async {
                      if (_isSliderManipulating) {
                        setState(() => _isSliderManipulating = false);
                        await _refreshAllOverlays(includeBlueprint: true);
                      }
                      await _persistBlueprintConfig();
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
    final List<String> dateTabs = ['전체 보기'];
    final Set<String> days =
        widget.photos.map((p) => p.timestamp.substring(0, 10)).toSet();
    final List<String> sortedDays = days.toList()
      ..sort((a, b) => b.compareTo(a));
    dateTabs.addAll(sortedDays);

    final bool portrait =
        MediaQuery.of(context).orientation == Orientation.portrait;
    final double bottomSafe = MediaQuery.of(context).viewPadding.bottom;

    final PhotoItem? activePhoto = _visiblePhotos.isNotEmpty
        ? _visiblePhotos[_selectedIdx.clamp(0, _visiblePhotos.length - 1)]
        : null;

    final List<String> cats = _allCategories;

    final Widget leftOrTopPane = _bpEditMode
        ? _buildBlueprintControlBox()
        : (activePhoto != null
            ? Container(
                color: Colors.black,
                width: double.infinity,
                height: double.infinity,
                child: Stack(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 46),
                      child: InteractiveViewer(
                        panEnabled: true,
                        boundaryMargin: const EdgeInsets.all(20),
                        minScale: 0.5,
                        maxScale: 4.0,
                        child: Center(
                          child: Image.file(
                            File(activePhoto.path),
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 10,
                      left: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.amber, width: 1.2),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: cats.contains(activePhoto.category)
                                ? activePhoto.category
                                : '미분류',
                            isDense: true,
                            dropdownColor: Colors.grey[900],
                            icon: const Padding(
                              padding: EdgeInsets.only(left: 4),
                              child: Icon(Icons.arrow_drop_down,
                                  color: Colors.amber, size: 18),
                            ),
                            style: const TextStyle(
                              color: Colors.amber,
                              fontWeight: FontWeight.bold,
                              fontSize: 11.5,
                            ),
                            selectedItemBuilder: (context) {
                              return [
                                ...cats.map(
                                  (c) => Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      c,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                                const Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    '+ 새 카테고리 입력',
                                    style: TextStyle(
                                      color: Colors.amberAccent,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                ),
                              ];
                            },
                            items: [
                              ...cats.map(
                                (c) => DropdownMenuItem<String>(
                                  value: c,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      ConstrainedBox(
                                        constraints: const BoxConstraints(
                                            minWidth: 64, maxWidth: 115),
                                        child: Text(
                                          c,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: c == '미분류'
                                                ? Colors.white70
                                                : Colors.white,
                                            fontSize: 11.5,
                                          ),
                                        ),
                                      ),
                                      if (c != '미분류')
                                        InkWell(
                                          onTap: () {
                                            Navigator.of(context).pop();
                                            _deleteCategory(c);
                                          },
                                          child: const Padding(
                                            padding: EdgeInsets.only(
                                                left: 6, top: 2, bottom: 2),
                                            child: Icon(
                                              Icons.close,
                                              size: 14,
                                              color: Colors.redAccent,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                              const DropdownMenuItem<String>(
                                value: '__ADD_NEW__',
                                child: Text(
                                  '+ 새 카테고리 입력',
                                  style: TextStyle(
                                    color: Colors.amberAccent,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                            onChanged: (val) {
                              if (val == '__ADD_NEW__') {
                                _showAddCategoryDialog(activePhoto);
                              } else if (val != null) {
                                setState(() {
                                  activePhoto.category = val;
                                });
                                saveDefaultCategory(val);
                                _persistPhotoMetadata();
                              }
                            },
                          ),
                        ),
                      ),
                    ),
                    // 사진 우측 상단 X 삭제 버튼
                    Positioned(
                      top: 10,
                      right: 10,
                      child: InkWell(
                        onTap: () => _deletePhoto(activePhoto),
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: Colors.redAccent, width: 1.5),
                          ),
                          child: const Icon(
                            Icons.close,
                            color: Colors.redAccent,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                    // 사진 하단 내용(메모) 자유 입력칸
                    Positioned(
                      left: 10,
                      right: 10,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.grey[900],
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: Colors.amber.withOpacity(0.75),
                              width: 1.2),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.edit_note,
                                color: Colors.amber, size: 18),
                            const SizedBox(width: 6),
                            Expanded(
                              child: TextFormField(
                                key: ValueKey(activePhoto.path),
                                initialValue: activePhoto.memo,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 12.5),
                                maxLines: 1,
                                textInputAction: TextInputAction.done,
                                onTapOutside: (_) =>
                                    FocusScope.of(context).unfocus(),
                                decoration: const InputDecoration(
                                  isDense: true,
                                  contentPadding:
                                      EdgeInsets.symmetric(vertical: 7),
                                  hintText: '사진 내용을 자유롭게 입력하세요 (자동 저장)',
                                  hintStyle: TextStyle(
                                      color: Colors.white54, fontSize: 12),
                                  border: InputBorder.none,
                                ),
                                onChanged: (val) {
                                  activePhoto.memo = val;
                                  _persistPhotoMetadata();
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              )
            : const Center(
                child: Text(
                  '저장된 사진이 없습니다.',
                  style: TextStyle(color: Colors.white),
                ),
              ));

    final double initLat =
        activePhoto?.lat ?? _activeBp?.centerLat ?? 37.4984;
    final double initLng =
        activePhoto?.lng ?? _activeBp?.centerLng ?? 127.1324;

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
        : LayoutBuilder(
            builder: (context, constraints) {
              _mapWidgetSize =
                  Size(constraints.maxWidth, constraints.maxHeight);
              return Stack(
                children: [
                  NaverMap(
                    options: NaverMapViewOptions(
                      initialCameraPosition: NCameraPosition(
                        target: NLatLng(initLat, initLng),
                        zoom: 16,
                      ),
                    ),
                    onMapReady: (ctrl) async {
                      _mapCtrl = ctrl;
                      if (_bpLoadFuture != null) {
                        await _bpLoadFuture;
                      }
                      await _updateMapViewportInfo();
                      await _refreshAllOverlays(includeBlueprint: true);
                    },
                    onCameraIdle: () {
                      _updateMapViewportInfo();
                    },
                    onMapTapped: (point, latLng) async {
                      if (!_showMyLocation || _bpEditMode) return;
                      setState(() {
                        forcedUserLocation = latLng;
                      });
                      await _updateMyLocationMarkerOnly();
                      if (mounted) {
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              '📌 내 위치가 터치한 지점으로 강제 이동되었습니다. 이제 촬영하면 이 좌표로 저장됩니다!',
                            ),
                            duration: Duration(milliseconds: 1400),
                          ),
                        );
                      }
                    },
                  ),
                  if (_useLiveActiveBpOverlay)
                    _buildLiveBlueprintOverlayWidget(_mapWidgetSize),
                  if (_bpEditMode &&
                      _activeBp != null &&
                      _bpTouchModeIsBlueprint)
                    Positioned.fill(
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (event) {
                          _activePointers[event.pointer] = event.localPosition;
                        },
                        onPointerMove: _handleBlueprintPointerMove,
                        onPointerUp: (event) {
                          _activePointers.remove(event.pointer);
                          if (_activePointers.isEmpty) {
                            _persistBlueprintConfig();
                          }
                        },
                        onPointerCancel: (event) {
                          _activePointers.remove(event.pointer);
                          if (_activePointers.isEmpty) {
                            _persistBlueprintConfig();
                          }
                        },
                        child: Container(color: Colors.transparent),
                      ),
                    ),
                  // 지도 우측 상단 '내 위치 표기' 켜기/끄기 및 강제위치 복귀 버튼
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_showMyLocation && forcedUserLocation != null)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: InkWell(
                                  onTap: () async {
                                    setState(() {
                                      forcedUserLocation = null;
                                    });
                                    await _updateMyLocationMarkerOnly();
                                    if (_myCurrentPos != null) {
                                      _panMapKeepZoom(_myCurrentPos!.latitude,
                                          _myCurrentPos!.longitude);
                                    }
                                    if (mounted) {
                                      ScaffoldMessenger.of(context)
                                          .hideCurrentSnackBar();
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                          content:
                                              Text('🛰️ 실시간 GPS 위치로 복귀했습니다.'),
                                          duration:
                                              Duration(milliseconds: 1100),
                                        ),
                                      );
                                    }
                                  },
                                  borderRadius: BorderRadius.circular(8),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 7),
                                    decoration: BoxDecoration(
                                      color: Colors.black87,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                          color: Colors.lightGreenAccent,
                                          width: 1.2),
                                    ),
                                    child: const Text(
                                      'GPS 복귀',
                                      style: TextStyle(
                                        color: Colors.lightGreenAccent,
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            InkWell(
                              onTap: _toggleMyLocation,
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 7),
                                decoration: BoxDecoration(
                                  color: _showMyLocation
                                      ? Colors.amber
                                      : Colors.black87,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: _showMyLocation
                                        ? Colors.amber
                                        : Colors.white54,
                                    width: 1.2,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      _showMyLocation
                                          ? (forcedUserLocation != null
                                              ? Icons.push_pin
                                              : Icons.my_location)
                                          : Icons.location_searching,
                                      color: _showMyLocation
                                          ? Colors.black
                                          : Colors.white,
                                      size: 16,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      _showMyLocation
                                          ? (forcedUserLocation != null
                                              ? '강제위치 ON'
                                              : '내 위치 ON')
                                          : '내 위치 표기',
                                      style: TextStyle(
                                        color: _showMyLocation
                                            ? Colors.black
                                            : Colors.white,
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (_showMyLocation)
                          Container(
                            margin: const EdgeInsets.only(top: 4),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              '💡 지도/도면을 터치하면 내 위치가 강제 이동됩니다',
                              style: TextStyle(
                                color: Colors.amberAccent,
                                fontSize: 10.5,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              );
            },
          );

    const TextStyle unifiedTopTextStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.bold,
    );

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        backgroundColor: Colors.black,
        automaticallyImplyLeading: false,
        titleSpacing: 8,
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 34),
              onPressed: () => Navigator.pop(context),
            ),
            DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _dateFilter,
                isDense: true,
                dropdownColor: Colors.black87,
                style: unifiedTopTextStyle.copyWith(color: Colors.white),
                icon: const Icon(Icons.arrow_drop_down,
                    color: Colors.white, size: 16),
                items: dateTabs
                    .map(
                      (d) => DropdownMenuItem(
                        value: d,
                        child: Text(d, style: unifiedTopTextStyle),
                      ),
                    )
                    .toList(),
                onChanged: (val) {
                  if (val == null) return;
                  setState(() {
                    _dateFilter = val;
                    _selectedIdx = _visiblePhotos.isNotEmpty
                        ? _visiblePhotos.length - 1
                        : 0;
                  });
                  _refreshAllOverlays(includeBlueprint: true);
                  if (_visiblePhotos.isNotEmpty) {
                    final p = _visiblePhotos[_selectedIdx];
                    _panMapKeepZoom(p.lat, p.lng);
                  }
                },
              ),
            ),
            DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: cats.contains(_categoryFilter)
                    ? _categoryFilter
                    : '전체 카테고리',
                isDense: true,
                dropdownColor: Colors.black87,
                style: unifiedTopTextStyle.copyWith(color: Colors.amberAccent),
                icon: const Icon(Icons.arrow_drop_down,
                    color: Colors.amberAccent, size: 16),
                items: ['전체 카테고리', ...cats]
                    .map(
                      (c) => DropdownMenuItem(
                        value: c,
                        child: Text(c, style: unifiedTopTextStyle),
                      ),
                    )
                    .toList(),
                onChanged: (val) {
                  if (val == null) return;
                  setState(() {
                    _categoryFilter = val;
                    _selectedIdx = _visiblePhotos.isNotEmpty
                        ? _visiblePhotos.length - 1
                        : 0;
                  });
                  _refreshAllOverlays(includeBlueprint: true);
                  if (_visiblePhotos.isNotEmpty) {
                    final p = _visiblePhotos[_selectedIdx];
                    _panMapKeepZoom(p.lat, p.lng);
                  }
                },
              ),
            ),
            InkWell(
              onTap: _isExporting ? null : _showExportOptionsSheet,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.ios_share,
                        color: Colors.lightBlueAccent, size: 14),
                    const SizedBox(width: 2),
                    Text(
                      '내보내기',
                      style: unifiedTopTextStyle.copyWith(
                          color: Colors.lightBlueAccent),
                    ),
                  ],
                ),
              ),
            ),
            InkWell(
              onTap: _showBlueprintActionMenuDialog,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.add_photo_alternate,
                        color: Colors.amber, size: 14),
                    const SizedBox(width: 2),
                    Text(
                      '도면',
                      style: unifiedTopTextStyle.copyWith(color: Colors.amber),
                    ),
                  ],
                ),
              ),
            ),
            if (_blueprints.isNotEmpty)
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 34),
                tooltip: '도면 선택 및 켜기/끄기',
                icon: Icon(
                  _hasAnyVisibleBlueprint ? Icons.layers : Icons.layers_clear,
                  color: _hasAnyVisibleBlueprint
                      ? Colors.lightGreenAccent
                      : Colors.grey,
                  size: 19,
                ),
                onPressed: _showBlueprintLayerSelectorDialog,
              ),
          ],
        ),
      ),
      body: Stack(
        children: [
          Column(
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
                Padding(
                  padding: EdgeInsets.only(bottom: bottomSafe + 28.0),
                  child: SizedBox(
                    height: 80,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: _visiblePhotos.length,
                      itemBuilder: (context, idx) {
                        final bool selected = _selectedIdx == idx;
                        return GestureDetector(
                          onTap: () => _selectPhotoFast(idx),
                          child: Container(
                            margin: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: selected
                                    ? Colors.amber
                                    : Colors.transparent,
                                width: 3,
                              ),
                            ),
                            child: Image.file(
                              File(_visiblePhotos[idx].path),
                              width: 70,
                              height: 70,
                              cacheWidth: 160,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
            ],
          ),
          if (_isExporting)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.amber),
                    SizedBox(height: 12),
                    Text(
                      '공유 파일을 생성하는 중입니다...',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _refreshAllOverlays({bool includeBlueprint = true}) async {
    if (_mapCtrl == null) return;
    await _mapCtrl!.clearOverlays();

    if (includeBlueprint && _bpGlobalShow && _blueprints.isNotEmpty) {
      await _syncBlueprintsToMap();
    }

    final List<int> order = [];
    for (int i = 0; i < _visiblePhotos.length; i++) {
      if (i != _selectedIdx) order.add(i);
    }
    if (_selectedIdx >= 0 && _selectedIdx < _visiblePhotos.length) {
      order.add(_selectedIdx);
    }

    final List<NAddableOverlay> markerBatch = [];
    for (final int i in order) {
      final PhotoItem item = _visiblePhotos[i];
      final bool selected = i == _selectedIdx;
      try {
        final icon = await _getCachedMarkerIcon(item.azimuth, selected);
        markerBatch.add(_buildPhotoMarker(i, item, icon));
      } catch (e) {
        debugPrint('Marker build error: $e');
      }
    }

    if (markerBatch.isNotEmpty) {
      await _mapCtrl!.addOverlayAll(markerBatch.toSet());
    }

    // 내 위치 표기가 켜져 있으면 마커 유지
    if (_showMyLocation &&
        (_myCurrentPos != null || forcedUserLocation != null)) {
      await _updateMyLocationMarkerOnly();
    }
  }
}
```
