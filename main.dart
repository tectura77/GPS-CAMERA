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
import 'package:share_plus/share_plus.dart';
import 'package:archive/archive.dart';

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

  double _currentZoom = 1.0;
  double _baseScaleZoom = 1.0;
  double _hwMinZoom = 1.0;
  double _hwMaxZoom = 2.0;
  int _activeCamIdx = 0;
  List<int> _backCameraIndices = [];

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
      locInfo =
          '위도: ${_pos!.latitude.toStringAsFixed(6)} (±${acc.toStringAsFixed(1)}m)\n'
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
                aspectRatio: ratio,
                child: CameraPreview(_camController!),
              ),
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
            bottom: 145,
            left: 20,
            child: Container(
              padding: const EdgeInsets.all(8),
              color: Colors.black45,
              child: Text(
                '$locInfo\n방위각: ${_heading.toStringAsFixed(1)}° ($dirKr)\n'
                '피치각: ${_tiltPitch.toStringAsFixed(1)}° | 배율: ${_currentZoom.toStringAsFixed(1)}x\n'
                '시간: ${DateTime.now().toString().substring(0, 16)}',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
          Positioned(
            bottom: 92,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [0.6, 1.0, 2.0].map((z) {
                final bool selected = (_currentZoom - z).abs() < 0.15;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
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
          Positioned(
            bottom: 25,
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
                child:
                    const Icon(Icons.camera_alt, color: Colors.black, size: 30),
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

  String? _bpPath;
  double? _bpLat;
  double? _bpLng;
  double _bpBaseRadius = 200.0;
  double _bpSizeSlider = 0.5;
  double _bpRotation = 0.0;
  double _bpOpacity = 0.5;
  bool _bpShow = true;
  bool _bpEditMode = false;

  NOverlayImage? _bpCachedOverlayImg;
  bool _isRenderingBp = false;
  bool _pendingBpRender = false;
  bool _isExporting = false;

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

  Future<void> _restoreBlueprintConfig() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final cfgFile = File('${dir.path}/blueprint_config.json');
      if (!await cfgFile.exists()) return;

      final Map<String, dynamic> data =
          jsonDecode(await cfgFile.readAsString());
      final String? savedPath = data['imagePath'] as String?;

      if (savedPath != null && File(savedPath).existsSync()) {
        if (mounted) {
          await precacheImage(FileImage(File(savedPath)), context);
        }
        setState(() {
          _bpPath = savedPath;
          _bpLat = (data['centerLat'] as num?)?.toDouble();
          _bpLng = (data['centerLng'] as num?)?.toDouble();
          _bpBaseRadius = (data['baseRadius'] as num?)?.toDouble() ?? 200.0;
          _bpSizeSlider =
              ((data['sizeSlider'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0);
          _bpRotation = ((data['rotation'] as num?)?.toDouble() ?? 0.0)
              .clamp(-180.0, 180.0);
          _bpOpacity =
              ((data['opacity'] as num?)?.toDouble() ?? 0.5).clamp(0.1, 1.0);
          _bpShow = data['isVisible'] as bool? ?? true;
        });
      }
    } catch (e) {
      debugPrint('Blueprint restore error: $e');
    }
  }

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
      final double heightMeters = Geolocator.distanceBetween(
        bounds.southWest.latitude,
        bounds.southWest.longitude,
        bounds.northEast.latitude,
        bounds.southWest.longitude,
      );
      final double minSpan = min(widthMeters, heightMeters);
      return (minSpan * 0.44).clamp(30.0, 1500.0);
    } catch (_) {
      return 200.0;
    }
  }

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

      final double screen80Rad = await _calcScreen80Radius();

      setState(() {
        _bpPath = destPath;
        _bpLat = centerLat;
        _bpLng = centerLng;
        _bpBaseRadius = screen80Rad;
        _bpSizeSlider = 0.5;
        _bpOpacity = 0.5;
        _bpRotation = 0.0;
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
                  padding: const EdgeInsets.all(16),
                  child: Image.file(
                    File(_bpPath!),
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
            size: const Size(360, 360),
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

  // 📤 내보내기 메뉴 팝업 (3가지 방식 중 선택)
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
                  subtitle: const Text(
                    '상대방이 앱 없이도 PC·폰 인터넷 창에서 도면+사진+지도를 클릭하며 볼 수 있는 단일 파일',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
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
                    '원본 사진들과 맞춘 도면 이미지·좌표 설정 데이터를 통째로 묶어 동료나 PC로 전달',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _exportAsZipArchive();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.Burst_mode,
                      color: Colors.lightGreenAccent),
                  title: const Text(
                    '③ [사진 + 도면 지도] 합본 이미지(.jpg) 공유',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text(
                    '현재 선택된 사진과 도면이 얹어진 지도를 1장의 이미지로 합쳐 카톡 등으로 즉시 공유',
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

  // 방식 1: 단독 실행 가능한 대화형 웹 뷰어(.html) 생성 및 공유
  Future<void> _exportAsHtmlViewer() async {
    if (_visiblePhotos.isEmpty && _bpPath == null) {
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
        });
      }

      Map<String, dynamic>? bpJson;
      if (_bpPath != null &&
          File(_bpPath!).existsSync() &&
          _bpLat != null &&
          _bpLng != null) {
        final bpBytes = await File(_bpPath!).readAsBytes();
        final String ext = _bpPath!.split('.').last.toLowerCase();
        final String mime = ext == 'png' ? 'image/png' : 'image/jpeg';
        final double rad = _currentBpRadius;
        final double dLat = rad / 111320.0;
        final double cosLat = cos(_bpLat! * pi / 180.0).abs().clamp(0.1, 1.0);
        final double dLng = rad / (111320.0 * cosLat);

        bpJson = {
          'b64': 'data:$mime;base64,${base64Encode(bpBytes)}',
          'lat': _bpLat,
          'lng': _bpLng,
          'swLat': _bpLat! - dLat,
          'swLng': _bpLng! - dLng,
          'neLat': _bpLat! + dLat,
          'neLng': _bpLng! + dLng,
          'rotation': _bpRotation,
          'opacity': _bpOpacity,
        };
      }

      final String photosJs = jsonEncode(encodedPhotos);
      final String bpJs = jsonEncode(bpJson);

      final String htmlContent = '''
<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>GPS 도면 & 현장 사진 대시보드</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"/>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<style>
  body, html { margin: 0; padding: 0; height: 100%; background: #111; color: #fff; font-family: sans-serif; display: flex; flex-direction: column; }
  header { padding: 10px 16px; background: #000; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #333; }
  .main-wrap { flex: 1; display: flex; flex-direction: row; overflow: hidden; }
  @media (max-width: 768px) { .main-wrap { flex-direction: column; } }
  #photo-pane { flex: 1; background: #000; display: flex; align-items: center; justify-content: center; overflow: hidden; position: relative; }
  #photo-pane img { max-width: 100%; max-height: 100%; object-fit: contain; transition: transform 0.15s ease; cursor: zoom-in; }
  #map-pane { flex: 1; position: relative; }
  #thumbs { height: 82px; background: #000; display: flex; overflow-x: auto; padding: 4px; border-top: 1px solid #333; }
  #thumbs img { width: 70px; height: 70px; object-fit: cover; margin-right: 6px; border: 3px solid transparent; cursor: pointer; }
  #thumbs img.active { border-color: #ffc107; }
</style>
</head>
<body>
<header>
  <strong>📍 GPS 도면 & 현장 사진 뷰어 (${_dateFilter})</strong>
  <span id="info-txt" style="font-size:13px; color:#ffc107;"></span>
</header>
<div class="main-wrap">
  <div id="photo-pane"><img id="main-photo" src="" alt="현장 사진"/></div>
  <div id="map-pane"></div>
</div>
<div id="thumbs"></div>
<script>
const photos = $photosJs;
const bp = $bpJs;
let selectedIdx = photos.length > 0 ? photos.length - 1 : 0;
let zoomed = false;

const mainImg = document.getElementById('main-photo');
mainImg.onclick = () => {
  zoomed = !zoomed;
  mainImg.style.transform = zoomed ? 'scale(2.2)' : 'scale(1.0)';
  mainImg.style.cursor = zoomed ? 'zoom-out' : 'zoom-in';
};

const initLat = photos.length > 0 ? photos[selectedIdx].lat : (bp ? bp.lat : 37.4984);
const initLng = photos.length > 0 ? photos[selectedIdx].lng : (bp ? bp.lng : 127.1324);

const map = L.map('map-pane').setView([initLat, initLng], 17);
L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
  maxZoom: 20,
  attribution: '© OpenStreetMap'
}).addTo(map);

if (bp) {
  const bounds = [[bp.swLat, bp.swLng], [bp.neLat, bp.neLng]];
  const overlay = L.imageOverlay(bp.b64, bounds, { opacity: bp.opacity }).addTo(map);
  const el = overlay.getElement();
  if (el) {
    el.style.transformOrigin = 'center center';
  }
}

const markersLayer = L.layerGroup().addTo(map);

function selectPhoto(idx) {
  selectedIdx = idx;
  zoomed = false;
  mainImg.style.transform = 'scale(1.0)';
  const p = photos[idx];
  mainImg.src = p.b64;
  document.getElementById('info-txt').innerText =
    `위도: \${p.lat.toFixed(6)} | 경도: \${p.lng.toFixed(6)} | 방위각: \${p.azimuth.toFixed(1)}° | \${p.time}`;
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
  photos.forEach((p, i) => {
    const isSel = (i === selectedIdx);
    const color = isSel ? '#2979ff' : '#f44336';
    const zIdx = isSel ? 1000 : 100;
    const htmlIcon = L.divIcon({
      className: '',
      iconSize: [28, 28],
      iconAnchor: [14, 14],
      html: `<div style="width:24px;height:24px;border-radius:50%;background:\${color}44;border:2px solid \${color};display:flex;align-items:center;justify-content:center;transform:rotate(\${p.azimuth}deg);">
               <span style="color:\${color};font-size:14px;font-weight:bold;">▲</span>
             </div>`
    });
    const m = L.marker([p.lat, p.lng], { icon: htmlIcon, zIndexOffset: zIdx }).addTo(markersLayer);
    m.on('click', () => selectPhoto(i));
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

  // 방식 2: 원본 사진 + 도면 + 설정 데이터를 ZIP 압축파일로 묶어 내보내기
  Future<void> _exportAsZipArchive() async {
    if (_visiblePhotos.isEmpty && _bpPath == null) {
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

      if (_bpPath != null && File(_bpPath!).existsSync()) {
        final String bpName = _bpPath!.split('/').last;
        final Uint8List bpBytes = await File(_bpPath!).readAsBytes();
        archive.addFile(ArchiveFile('blueprint/$bpName', bpBytes.length, bpBytes));

        final Map<String, dynamic> bpCfg = {
          'fileName': bpName,
          'centerLat': _bpLat,
          'centerLng': _bpLng,
          'baseRadius': _bpBaseRadius,
          'sizeSlider': _bpSizeSlider,
          'rotation': _bpRotation,
          'opacity': _bpOpacity,
          'isVisible': _bpShow,
        };
        final Uint8List cfgBytes =
            Uint8List.fromList(utf8.encode(jsonEncode(bpCfg)));
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

  // 방식 3: [왼쪽 촬영 사진 + 오른쪽 도면 지도] 반반 합본 이미지(.jpg) 생성 및 공유
  Future<void> _exportAsCombinedImage() async {
    if (_visiblePhotos.isEmpty || _mapCtrl == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('합성할 사진이나 지도가 준비되지 않았습니다.')),
      );
      return;
    }

    setState(() => _isExporting = true);
    try {
      final PhotoItem currentPhoto =
          _visiblePhotos[_selectedIdx.clamp(0, _visiblePhotos.length - 1)];
      final File mapSnapFile = await _mapCtrl!.takeSnapshot();

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
            '🖼️ 현장 사진 & 도면 위치 합본 (${currentPhoto.timestamp})\n위도: ${currentPhoto.lat.toStringAsFixed(6)}, 경도: ${currentPhoto.lng.toStringAsFixed(6)}',
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
                    final rad80 = await _calcScreen80Radius();
                    setState(() {
                      _bpLat = pos.target.latitude;
                      _bpLng = pos.target.longitude;
                      _bpBaseRadius = rad80;
                      _bpSizeSlider = 0.5;
                    });
                    await _renderBlueprintOnMap(rebuildBitmap: false);
                    await _persistBlueprintConfig();
                  },
                  icon: const Icon(Icons.center_focus_strong, size: 15),
                  label: const Text('화면 중앙·80%크기 초기화',
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
    final List<String> sortedDays = days.toList()
      ..sort((a, b) => b.compareTo(a));
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
                    child:
                        Image.file(File(activePhoto.path), fit: BoxFit.contain),
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
            fontSize: 15,
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
          // 📤 내보내기 버튼 (클릭 시 3가지 방식 선택 창 오픈)
          TextButton.icon(
            onPressed: _isExporting ? null : _showExportOptionsSheet,
            icon: const Icon(Icons.ios_share,
                color: Colors.lightBlueAccent, size: 18),
            label: const Text(
              '내보내기',
              style: TextStyle(color: Colors.lightBlueAccent, fontSize: 12),
            ),
          ),
          TextButton.icon(
            onPressed: _importBlueprintFromGallery,
            icon: const Icon(Icons.add_photo_alternate,
                color: Colors.amber, size: 18),
            label: const Text(
              '도면',
              style: TextStyle(color: Colors.amber, fontSize: 12),
            ),
          ),
          if (_bpPath != null) ...[
            IconButton(
              icon: Icon(
                _bpShow ? Icons.layers : Icons.layers_clear,
                color: _bpShow ? Colors.lightGreenAccent : Colors.grey,
                size: 20,
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
              padding: const EdgeInsets.only(right: 6),
              child: ElevatedButton(
                onPressed: () async {
                  await _persistBlueprintConfig();
                  setState(() => _bpEditMode = !_bpEditMode);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      _bpEditMode ? Colors.amber : Colors.blueAccent,
                  foregroundColor: _bpEditMode ? Colors.black : Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: Text(
                  _bpEditMode ? '고정저장' : '도면정렬',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ),
          ],
        ],
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
                              color:
                                  selected ? Colors.amber : Colors.transparent,
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
