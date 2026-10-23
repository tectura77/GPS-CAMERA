import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
import 'dart:isolate';
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
String currentDefaultCategory = '미분류';
double? forcedUserLat;
double? forcedUserLng;
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
final Map<String, NOverlayImage> globalMarkerIconCache = {};
final Map<String, NOverlayImage> globalBpOverlayCache = {};
final Map<String, String> globalHtmlBase64Cache = {};
Future<Uint8List?> encodePhotoForHtmlFast(String path) async {
 try {
 final File origFile = File(path);
 if (!origFile.existsSync()) return null;
 final File cacheFile = File('$path.web.jpg');
 if (cacheFile.existsSync()) {
 final Uint8List cached = await cacheFile.readAsBytes();
 if (cached.isNotEmpty) return cached;
 }
 return await Isolate.run(() {
 try {
 final File f = File(path);
 final Uint8List raw = f.readAsBytesSync();
 if (raw.length <= 320 * 1024) {
 try {
 File('$path.web.jpg').writeAsBytesSync(raw);
 } catch (_) {}
 return raw;
 }
 final img.Image? decoded = img.decodeImage(raw);
 if (decoded == null) return raw;
 final img.Image resized = decoded.width > 780
 ? img.copyResize(
 decoded,
 width: 780,
 interpolation: img.Interpolation.nearest,
 )
 : decoded;
 final Uint8List jpg = Uint8List.fromList(img.encodeJpg(resized, quality: 72));
 try {
 File('$path.web.jpg').writeAsBytesSync(jpg);
 } catch (_) {}
 return jpg;
 } catch (_) {
 return null;
 }
 });
 } catch (_) {
 return null;
 }
}
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
 String? afterPath;
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
 this.afterPath,
 });
 bool get hasAfterPhoto =>
 afterPath != null &&
 afterPath!.trim().isNotEmpty &&
 File(afterPath!).existsSync();
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
 'afterPath': afterPath,
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
 afterPath: m['afterPath'] as String?,
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
 PhotoItem? _pendingAfterTarget;
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
 if (t < 0.028) {
 final double env = exp(-t * 145.0);
 final double noise = (rng.nextDouble() * 2.0 - 1.0) * 0.85;
 final double tone = sin(2.0 * pi * 1500.0 * t) * 0.6 +
 sin(2.0 * pi * 3100.0 * t) * 0.45;
 amp += (noise + tone) * env;
 }
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
 Permission.accessMediaLocation,
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
 if (decodedImg != null && _pos != null) {
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
 final double useLat = forcedUserLat ?? _pos!.latitude;
 final double useLng = forcedUserLng ?? _pos!.longitude;
 final double hAcc = forcedUserLat != null ? 1.0 : _pos!.accuracy;
 final double vAcc = hAcc * 1.5;
 final bool isAfterShot = _pendingAfterTarget != null;
 final String stamp =
 'Lat: ${useLat.toStringAsFixed(6)} (+-${hAcc.toStringAsFixed(1)}m)\n'
 'Lng: ${useLng.toStringAsFixed(6)} (+-${hAcc.toStringAsFixed(1)}m)\n'
 'Alt: ${_pos!.altitude.toStringAsFixed(1)}m (+-${vAcc.toStringAsFixed(1)}m)\n'
 'Azimuth: ${_heading.toStringAsFixed(1)} deg ($dirEn)\n'
 'Pitch: ${_tiltPitch.toStringAsFixed(1)} deg\n'
 'Time: $nowStr${isAfterShot ? " [AFTER]" : ""}';
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
 final String prefix = isAfterShot ? 'after' : 'photo';
 final String targetPath =
 '${dayDir.path}/${prefix}_${DateTime.now().millisecondsSinceEpoch}.jpg';
 await File(targetPath).writeAsBytes(jpgBytes);
 String toDmsRational(double degVal) {
 final double absVal = degVal.abs();
 final int d = absVal.floor();
 final double minFull = (absVal - d) * 60.0;
 final int m = minFull.floor();
 final int s10000 = ((minFull - m) * 60.0 * 10000.0).round();
 return '$d/1,$m/1,$s10000/10000';
 }
 final int azRational = (_heading.clamp(0.0, 360.0) * 100).round();
 final int altRational = (_pos!.altitude.abs() * 100).round();
 final exif = await Exif.fromPath(targetPath);
 await exif.writeAttributes({
 'GPSLatitude': toDmsRational(useLat),
 'GPSLatitudeRef': useLat >= 0 ? 'N' : 'S',
 'GPSLongitude': toDmsRational(useLng),
 'GPSLongitudeRef': useLng >= 0 ? 'E' : 'W',
 'GPSAltitude': '$altRational/100',
 'GPSAltitudeRef': _pos!.altitude >= 0 ? '0' : '1',
 'GPSImgDirection': '$azRational/100',
 'GPSImgDirectionRef': 'T',
 'UserComment': 'GPS:${useLat.toStringAsFixed(6)},${useLng.toStringAsFixed(6)},${_pos!.altitude.toStringAsFixed(1)},${_heading.toStringAsFixed(1)}',
 });
 await exif.close();
 await Gal.putImage(targetPath);
 encodePhotoForHtmlFast(targetPath);
 if (isAfterShot) {
 final PhotoItem targetItem = _pendingAfterTarget!;
 setState(() {
 targetItem.afterPath = targetPath;
 _pendingAfterTarget = null;
 });
 await _persistPhotos();
 if (mounted) {
 ScaffoldMessenger.of(context).showSnackBar(
 const SnackBar(
 content: Text('✅ 조치후 사진이 등록되었습니다! (조치전·조치후·지도 3등분 표시)'),
 duration: Duration(milliseconds: 1200),
 ),
 );
 await _openMapDashboard(initialPhoto: targetItem);
 }
 } else {
 final String assignedCat = currentDefaultCategory;
 setState(() {
 _photoList.add(PhotoItem(
 path: targetPath,
 lat: useLat,
 lng: useLng,
 alt: _pos!.altitude,
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
 Future<void> _openMapDashboard({PhotoItem? initialPhoto}) async {
 final dynamic res = await Navigator.push(
 context,
 MaterialPageRoute(
 builder: (_) => GalleryMapDashboard(
 photos: _photoList,
 initialSelectedPhoto: initialPhoto,
 ),
 ),
 );
 if (!mounted) return;
 if (res is PhotoItem) {
 setState(() => _pendingAfterTarget = res);
 ScaffoldMessenger.of(context).showSnackBar(
 const SnackBar(
 content: Text('📸 조치후 사진을 촬영해주세요! 촬영 즉시 3등분 화면으로 돌아갑니다.'),
 duration: Duration(seconds: 2),
 ),
 );
 } else {
 setState(() {});
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
 final double dLat = forcedUserLat ?? _pos!.latitude;
 final double dLng = forcedUserLng ?? _pos!.longitude;
 final double acc = forcedUserLat != null ? 1.0 : _pos!.accuracy;
 final String tag =
 forcedUserLat != null ? '강제위치' : '±${acc.toStringAsFixed(1)}m';
 locInfo =
 '위도: ${dLat.toStringAsFixed(6)} ($tag)\n'
 '경도: ${dLng.toStringAsFixed(6)} ($tag)\n'
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
 if (_pendingAfterTarget != null)
 Positioned(
 top: landscape ? 54 : 90,
 left: 16,
 right: 16,
 child: Container(
 padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
 decoration: BoxDecoration(
 color: Colors.green[800]!.withOpacity(0.92),
 borderRadius: BorderRadius.circular(10),
 border: Border.all(color: Colors.lightGreenAccent, width: 1.5),
 ),
 child: Row(
 children: [
 const Icon(Icons.camera_enhance, color: Colors.white, size: 18),
 const SizedBox(width: 8),
 const Expanded(
 child: Text(
 '🛠️ [조치후 사진 촬영 모드] 촬영하면 조치전·조치후·지도 3등분으로 등록됩니다',
 style: TextStyle(
 color: Colors.white,
 fontSize: 12,
 fontWeight: FontWeight.bold,
 ),
 ),
 ),
 InkWell(
 onTap: () {
 final PhotoItem prev = _pendingAfterTarget!;
 setState(() => _pendingAfterTarget = null);
 _openMapDashboard(initialPhoto: prev);
 },
 child: const Padding(
 padding: EdgeInsets.all(4),
 child: Icon(Icons.close, color: Colors.white, size: 18),
 ),
 ),
 ],
 ),
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
 child: IgnorePointer(
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
 onPressed: () => _openMapDashboard(),
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
 final PhotoItem? initialSelectedPhoto;
 const GalleryMapDashboard({
 super.key,
 required this.photos,
 this.initialSelectedPhoto,
 });
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
 String _exportStatusMsg = '공유 파일을 생성하는 중입니다...';
 Future<void>? _bpLoadFuture;
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
 _restoreCategories();
 _bpLoadFuture = _restoreBlueprintConfig();
 if (widget.initialSelectedPhoto != null) {
 final int found = _visiblePhotos.indexOf(widget.initialSelectedPhoto!);
 if (found >= 0) {
 _selectedIdx = found;
 } else if (_visiblePhotos.isNotEmpty) {
 _selectedIdx = _visiblePhotos.length - 1;
 }
 } else if (_visiblePhotos.isNotEmpty) {
 _selectedIdx = _visiblePhotos.length - 1;
 }
 _prewarmHtmlCacheSilently();
 }
 Future<void> _prewarmHtmlCacheSilently() async {
 try {
 final List<String> paths = [];
 for (final p in widget.photos) {
 if (!File('${p.path}.web.jpg').existsSync()) paths.add(p.path);
 if (p.hasAfterPhoto && !File('${p.afterPath}.web.jpg').existsSync()) {
 paths.add(p.afterPath!);
 }
 }
 for (int i = 0; i < paths.length; i += 3) {
 if (!mounted) return;
 if (_isExporting) {
 await Future.delayed(const Duration(milliseconds: 500));
 continue;
 }
 final int end = min(i + 3, paths.length);
 await Future.wait(paths.sublist(i, end).map((path) => encodePhotoForHtmlFast(path)));
 }
 } catch (_) {}
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
 static Map<String, List<int>>? _arial24GlyphMasks;
 static int _arial24LineH = 28;
 Map<String, List<int>> _getArial24GlyphMasks() {
 if (_arial24GlyphMasks != null) return _arial24GlyphMasks!;
 final Map<String, List<int>> masks = {};
 _arial24LineH = img.arial24.lineHeight > 0 ? img.arial24.lineHeight : 28;
 const String chars = '0123456789.-+():LatngAlzmuhdegTim ';
 for (int i = 0; i < chars.length; i++) {
 final int code = chars.codeUnitAt(i);
 final chObj = img.arial24.characters[code];
 if (chObj == null) continue;
 final int w = chObj.width;
 final int h = chObj.height;
 final int xOff = chObj.xOffset;
 final int yOff = chObj.yOffset;
 final int xAdv = chObj.xAdvance;
 final List<int> pts = [xAdv, w + xOff, h + yOff];
 for (int py = 0; py < h; py++) {
 for (int px = 0; px < w; px++) {
 final p = chObj.image.getPixel(px, py);
 if (p.a > 128 && p.r > 128) {
 pts.add(px + xOff);
 pts.add(py + yOff);
 }
 }
 }
 masks[chars[i]] = pts;
 }
 _arial24GlyphMasks = masks;
 return masks;
 }
 Map<String, dynamic> _extractGpsFromYellowStamp(Uint8List bytes) {
 final Map<String, dynamic> res = {};
 try {
 final img.Image? decoded = img.decodeImage(bytes);
 if (decoded == null || decoded.width < 260 || decoded.height < 180) return res;
 final int baseX = 20;
 final int baseY = max(20, decoded.height - 220);
 if (baseY + 120 >= decoded.height) return res;
 bool isYellow(int x, int y) {
 if (x < 0 || y < 0 || x >= decoded.width || y >= decoded.height) return false;
 final p = decoded.getPixel(x, y);
 return p.r > 195 && p.g > 145 && p.b < 115 && (p.r - p.b) > 100;
 }
 int yellowHits = 0;
 for (int y = baseY; y < min(decoded.height, baseY + 60); y += 2) {
 for (int x = baseX; x < min(decoded.width, baseX + 180); x += 2) {
 if (isYellow(x, y)) yellowHits++;
 }
 }
 if (yellowHits < 18) return res;
 final Map<String, List<int>> masks = _getArial24GlyphMasks();
 final int lh = _arial24LineH;
 String readLineAt(int lineIdx, String allowedChars) {
 final int ly = baseY + lineIdx * lh;
 if (ly + lh >= decoded.height) return '';
 final StringBuffer sb = StringBuffer();
 int curX = baseX;
 final int maxX = min(decoded.width - 10, baseX + 460);
 while (curX < maxX) {
 String bestCh = '';
 double bestScore = 0.58;
 int bestAdv = 8;
 for (int cIdx = 0; cIdx < allowedChars.length; cIdx++) {
 final String ch = allowedChars[cIdx];
 final List<int>? m = masks[ch];
 if (m == null || m.length <= 3) continue;
 final int totalPts = (m.length - 3) ~/ 2;
 if (totalPts == 0) continue;
 int hits = 0;
 for (int k = 3; k < m.length; k += 2) {
 if (isYellow(curX + m[k], ly + m[k + 1])) hits++;
 }
 final double ratio = hits / totalPts;
 if (ratio > bestScore || (ratio == bestScore && m.length > (masks[bestCh]?.length ?? 0))) {
 bestScore = ratio;
 bestCh = ch;
 bestAdv = m[0];
 }
 }
 if (bestCh.isNotEmpty) {
 sb.write(bestCh);
 curX += max(4, bestAdv);
 } else {
 curX += 4;
 }
 }
 return sb.toString();
 }
 final String l0 = readLineAt(0, 'Lat:0123456789.-+()m');
 final String l1 = readLineAt(1, 'Lng:0123456789.-+()m');
 final String l2 = readLineAt(2, 'Alt:0123456789.-+()m');
 final String l3 = readLineAt(3, 'Azimuth:0123456789.-deg');
 final String l5 = readLineAt(5, 'Time:0123456789-');
 final RegExp coordRe = RegExp(r'-?\d{1,3}\.\d{4,7}');
 final m0 = coordRe.firstMatch(l0);
 final m1 = coordRe.firstMatch(l1);
 if (m0 != null && m1 != null) {
 final double? la = double.tryParse(m0.group(0)!);
 final double? lo = double.tryParse(m1.group(0)!);
 if (la != null && lo != null && la.abs() <= 90 && lo.abs() <= 180) {
 res['lat'] = la;
 res['lng'] = lo;
 }
 }
 final RegExp numRe = RegExp(r'-?\d+\.\d+');
 final m2 = numRe.firstMatch(l2);
 if (m2 != null) {
 final double? al = double.tryParse(m2.group(0)!);
 if (al != null) res['alt'] = al;
 }
 final m3 = numRe.firstMatch(l3);
 if (m3 != null) {
 final double? az = double.tryParse(m3.group(0)!);
 if (az != null && az >= 0 && az <= 360) res['azimuth'] = az;
 }
 final RegExp dtRe = RegExp(r'20\d{2}-\d{2}-\d{2}\d{2}:\d{2}');
 final m5 = dtRe.firstMatch(l5);
 if (m5 != null) {
 final String rawT = m5.group(0)!;
 res['dateTime'] = '${rawT.substring(0, 10)} ${rawT.substring(10)}';
 }
 } catch (_) {}
 return res;
 }
 double? _parseRationalToken(String token) {
 final String clean = token.trim();
 if (clean.isEmpty) return null;
 if (clean.contains('/')) {
 final List<String> parts = clean.split('/');
 if (parts.length == 2) {
 final double? n = double.tryParse(parts[0].trim());
 final double? d = double.tryParse(parts[1].trim());
 if (n != null && d != null && d != 0) return n / d;
 }
 }
 return double.tryParse(clean);
 }
 double? _parseExifCoord(Object? raw, String? ref) {
 if (raw == null) return null;
 String s = raw.toString().replaceAll('[', '').replaceAll(']', '').trim();
 if (s.isEmpty) return null;
 final List<String> parts =
 s.contains(',') ? s.split(',') : s.split(RegExp(r'\s+'));
 double? deg;
 if (parts.length >= 3) {
 final double? d = _parseRationalToken(parts[0]);
 final double? m = _parseRationalToken(parts[1]);
 final double? sec = _parseRationalToken(parts[2]);
 if (d != null && m != null && sec != null) {
 deg = d.abs() + (m.abs() / 60.0) + (sec.abs() / 3600.0);
 }
 } else {
 deg = _parseRationalToken(parts[0]);
 }
 if (deg == null || deg.isNaN || deg == 0.0) return null;
 final String r = (ref ?? '').trim().toUpperCase();
 if (r == 'S' || r == 'W' || s.startsWith('-')) return -deg.abs();
 return deg.abs();
 }
 Map<String, dynamic> _parseBinaryExifFromBytes(Uint8List bytes) {
 final Map<String, dynamic> res = {};
 if (bytes.length < 14 || bytes[0] != 0xFF || bytes[1] != 0xD8) return res;
 int offset = 2;
 while (offset + 4 < bytes.length) {
 if (bytes[offset] != 0xFF) break;
 final int marker = bytes[offset + 1];
 if (marker == 0xDA || marker == 0xD9) break;
 final int segLen = (bytes[offset + 2] << 8) | bytes[offset + 3];
 if (segLen < 2 || offset + 2 + segLen > bytes.length) break;
 if (marker == 0xE1 && segLen >= 14) {
 if (bytes[offset + 4] == 0x45 &&
 bytes[offset + 5] == 0x78 &&
 bytes[offset + 6] == 0x69 &&
 bytes[offset + 7] == 0x66 &&
 bytes[offset + 8] == 0x00 &&
 bytes[offset + 9] == 0x00) {
 final int tiffStart = offset + 10;
 final int segEnd = offset + 2 + segLen;
 if (tiffStart + 8 <= segEnd) {
 final bool little =
 bytes[tiffStart] == 0x49 && bytes[tiffStart + 1] == 0x49;
 int u16(int pos) {
 if (pos + 2 > segEnd) return 0;
 return little
 ? (bytes[pos] | (bytes[pos + 1] << 8))
 : ((bytes[pos] << 8) | bytes[pos + 1]);
 }
 int u32(int pos) {
 if (pos + 4 > segEnd) return 0;
 return little
 ? (bytes[pos] |
 (bytes[pos + 1] << 8) |
 (bytes[pos + 2] << 16) |
 (bytes[pos + 3] << 24))
 : ((bytes[pos] << 24) |
 (bytes[pos + 1] << 16) |
 (bytes[pos + 2] << 8) |
 bytes[pos + 3]);
 }
 double? readRational(int pos) {
 if (pos + 8 > segEnd) return null;
 final int numVal = u32(pos);
 final int denVal = u32(pos + 4);
 if (denVal == 0) return null;
 return numVal / denVal;
 }
 String readAscii(int pos, int count) {
 if (pos < tiffStart || pos + count > segEnd) return '';
 final List<int> chars = [];
 for (int k = 0; k < count; k++) {
 final int c = bytes[pos + k];
 if (c == 0) break;
 chars.add(c);
 }
 return String.fromCharCodes(chars).trim();
 }
 final int ifd0Rel = u32(tiffStart + 4);
 final int ifd0Pos = tiffStart + ifd0Rel;
 if (ifd0Pos + 2 <= segEnd) {
 final int n0 = u16(ifd0Pos);
 int? gpsIfdRel;
 int? exifIfdRel;
 for (int i = 0; i < n0; i++) {
 final int ePos = ifd0Pos + 2 + i * 12;
 if (ePos + 12 > segEnd) break;
 final int tag = u16(ePos);
 final int cnt = u32(ePos + 4);
 final int valOff = u32(ePos + 8);
 if (tag == 0x8825) {
 gpsIfdRel = valOff;
 } else if (tag == 0x8769) {
 exifIfdRel = valOff;
 } else if (tag == 0x0132 && cnt >= 10) {
 final String dt = readAscii(tiffStart + valOff, cnt);
 if (dt.isNotEmpty) res['dateTime'] = dt;
 }
 }
 if (exifIfdRel != null) {
 final int exifPos = tiffStart + exifIfdRel;
 if (exifPos + 2 <= segEnd) {
 final int ne = u16(exifPos);
 for (int i = 0; i < ne; i++) {
 final int ePos = exifPos + 2 + i * 12;
 if (ePos + 12 > segEnd) break;
 final int tag = u16(ePos);
 final int cnt = u32(ePos + 4);
 final int valOff = u32(ePos + 8);
 if ((tag == 0x9003 || tag == 0x9004) && cnt >= 10) {
 final String dt = readAscii(tiffStart + valOff, cnt);
 if (dt.isNotEmpty) res['dateTime'] = dt;
 }
 }
 }
 }
 if (gpsIfdRel != null) {
 final int gpsPos = tiffStart + gpsIfdRel;
 if (gpsPos + 2 <= segEnd) {
 final int ng = u16(gpsPos);
 String latRef = 'N';
 String lngRef = 'E';
 int altRef = 0;
 double? latAbs;
 double? lngAbs;
 double? altVal;
 double? azVal;
 for (int i = 0; i < ng; i++) {
 final int ePos = gpsPos + 2 + i * 12;
 if (ePos + 12 > segEnd) break;
 final int tag = u16(ePos);
 final int cnt = u32(ePos + 4);
 final int valOff = u32(ePos + 8);
 if (tag == 0x0001) {
 final int c = bytes[ePos + 8];
 if (c == 0x53 || c == 0x73) latRef = 'S';
 } else if (tag == 0x0003) {
 final int c = bytes[ePos + 8];
 if (c == 0x57 || c == 0x77) lngRef = 'W';
 } else if (tag == 0x0005) {
 altRef = bytes[ePos + 8];
 } else if (tag == 0x0002 && cnt >= 3) {
 final int rPos = tiffStart + valOff;
 final double? d = readRational(rPos);
 final double? m = readRational(rPos + 8);
 final double? s = readRational(rPos + 16);
 if (d != null && m != null && s != null) {
 latAbs = d + (m / 60.0) + (s / 3600.0);
 }
 } else if (tag == 0x0004 && cnt >= 3) {
 final int rPos = tiffStart + valOff;
 final double? d = readRational(rPos);
 final double? m = readRational(rPos + 8);
 final double? s = readRational(rPos + 16);
 if (d != null && m != null && s != null) {
 lngAbs = d + (m / 60.0) + (s / 3600.0);
 }
 } else if (tag == 0x0006 && cnt >= 1) {
 altVal = readRational(tiffStart + valOff);
 } else if (tag == 0x0011 && cnt >= 1) {
 azVal = readRational(tiffStart + valOff);
 }
 }
 if (latAbs != null &&
 lngAbs != null &&
 (latAbs > 0.0001 || lngAbs > 0.0001)) {
 res['lat'] = (latRef == 'S') ? -latAbs : latAbs;
 res['lng'] = (lngRef == 'W') ? -lngAbs : lngAbs;
 }
 if (altVal != null) {
 res['alt'] = (altRef == 1) ? -altVal.abs() : altVal;
 }
 if (azVal != null && !azVal.isNaN) {
 res['azimuth'] = (azVal % 360 + 360) % 360;
 }
 }
 }
 }
 }
 }
 }
 offset += 2 + segLen;
 }
 return res;
 }
 Future<Map<String, dynamic>> _extractPhotoMetaFromPath(String path,
 {bool allowYellowOcr = true}) async {
 final Map<String, dynamic> out = {};
 Uint8List? rawBytes;
 try {
 rawBytes = await File(path).readAsBytes();
 out.addAll(_parseBinaryExifFromBytes(rawBytes));
 } catch (_) {}
 try {
 final Exif exif = await Exif.fromPath(path);
 try {
 final dynamic latLong = await exif.getLatLong();
 if (latLong != null && (out['lat'] == null || out['lng'] == null)) {
 double? la;
 double? lo;
 try {
 la = (latLong.latitude as num?)?.toDouble();
 lo = (latLong.longitude as num?)?.toDouble();
 } catch (_) {}
 if (la == null || lo == null) {
 final RegExp numRe = RegExp(r'-?\d+\.\d+');
 final List<RegExpMatch> m =
 numRe.allMatches(latLong.toString()).toList();
 if (m.length >= 2) {
 la = double.tryParse(m[0].group(0)!);
 lo = double.tryParse(m[1].group(0)!);
 }
 }
 if (la != null && lo != null && (la.abs() > 0.0001 || lo.abs() > 0.0001)) {
 out['lat'] = la;
 out['lng'] = lo;
 }
 }
 } catch (_) {}
 final Map<String, Object>? attrs = await exif.getAttributes();
 if (attrs != null) {
 if (out['lat'] == null || out['lng'] == null) {
 final double? la = _parseExifCoord(
 attrs['GPSLatitude'], attrs['GPSLatitudeRef']?.toString());
 final double? lo = _parseExifCoord(
 attrs['GPSLongitude'], attrs['GPSLongitudeRef']?.toString());
 if (la != null && lo != null && (la.abs() > 0.0001 || lo.abs() > 0.0001)) {
 out['lat'] = la;
 out['lng'] = lo;
 }
 }
 if (out['lat'] == null && attrs['UserComment'] != null) {
 final String uc = attrs['UserComment'].toString();
 if (uc.startsWith('GPS:')) {
 final List<String> sp = uc.substring(4).split(',');
 if (sp.length >= 2) {
 final double? la = double.tryParse(sp[0]);
 final double? lo = double.tryParse(sp[1]);
 if (la != null && lo != null) {
 out['lat'] = la;
 out['lng'] = lo;
 }
 }
 }
 }
 if (out['alt'] == null && attrs['GPSAltitude'] != null) {
 final double? a = _parseRationalToken(attrs['GPSAltitude'].toString());
 if (a != null) out['alt'] = a;
 }
 if (out['azimuth'] == null && attrs['GPSImgDirection'] != null) {
 final double? az =
 _parseRationalToken(attrs['GPSImgDirection'].toString());
 if (az != null && !az.isNaN) out['azimuth'] = (az % 360 + 360) % 360;
 }
 if (out['dateTime'] == null) {
 final String? rawDt =
 (attrs['DateTimeOriginal'] ?? attrs['DateTime'])?.toString();
 if (rawDt != null && rawDt.trim().isNotEmpty) {
 out['dateTime'] = rawDt.trim();
 }
 }
 }
 if (out['dateTime'] == null) {
 try {
 final DateTime? origDt = await exif.getOriginalDate();
 if (origDt != null) out['dateTime'] = origDt.toString();
 } catch (_) {}
 }
 await exif.close();
 } catch (_) {}
 if (allowYellowOcr &&
 (out['lat'] == null || out['lng'] == null) &&
 rawBytes != null) {
 final Map<String, dynamic> yellow = _extractGpsFromYellowStamp(rawBytes);
 if (yellow['lat'] != null && yellow['lng'] != null) {
 out.addAll(yellow);
 }
 }
 return out;
 }
 List<String> _listGalleryFilePathsFast(String docDirPath) {
 final List<String> out = [];
 final List<String> roots = [
 docDirPath,
 '/storage/emulated/0/DCIM/Camera',
 '/storage/emulated/0/Pictures',
 '/storage/emulated/0/Pictures/KakaoTalk',
 '/storage/emulated/0/DCIM',
 '/storage/emulated/0/Download',
 ];
 final Set<String> seen = {};
 void scanDir(Directory d, int depth) {
 if (depth > 2) return;
 try {
 if (!d.existsSync()) return;
 final List<FileSystemEntity> list = d.listSync(followLinks: false);
 for (final e in list) {
 if (e is File) {
 final String p = e.path;
 final String low = p.toLowerCase();
 if (!low.endsWith('.jpg') && !low.endsWith('.jpeg')) continue;
 final String fn = p.split('/').last;
 if (fn.startsWith('imported_') ||
 fn.startsWith('bp_saved_') ||
 low.endsWith('.web.jpg')) {
 continue;
 }
 if (seen.add(p)) out.add(p);
 } else if (e is Directory && depth < 2) {
 final String subName = e.path.split('/').last;
 if (!subName.startsWith('.')) scanDir(e, depth + 1);
 }
 }
 } catch (_) {}
 }
 for (final r in roots) {
 scanDir(Directory(r), 0);
 }
 return out;
 }
 Future<Map<String, dynamic>> _fastPinpointOriginalGps(
 XFile picked, String? rawDateTime, List<String> allGalleryPaths) async {
 final String pickedName = picked.name;
 int pickedSize = 0;
 try {
 pickedSize = await File(picked.path).length();
 } catch (_) {}
 String? digits14;
 if (rawDateTime != null) {
 final String d = rawDateTime.replaceAll(RegExp(r'[^0-9]'), '');
 if (d.length >= 14) digits14 = d.substring(0, 14);
 }
 if (digits14 == null) {
 final RegExp fnRe = RegExp(r'(20\d{6})[_\-]?(\d{6})');
 final m = fnRe.firstMatch(pickedName);
 if (m != null) digits14 = '${m.group(1)}${m.group(2)}';
 }
 for (final String p in allGalleryPaths) {
 if (p.split('/').last == pickedName) {
 final m = await _extractPhotoMetaFromPath(p, allowYellowOcr: false);
 if (m['lat'] != null && m['lng'] != null) return m;
 }
 }
 if (digits14 != null) {
 final String ymd = digits14.substring(0, 8);
 final String hms = digits14.substring(8, 14);
 final int targetSec = (int.tryParse(hms.substring(0, 2)) ?? 0) * 3600 +
 (int.tryParse(hms.substring(2, 4)) ?? 0) * 60 +
 (int.tryParse(hms.substring(4, 6)) ?? 0);
 for (int tol = 0; tol <= 5; tol++) {
 for (final String p in allGalleryPaths) {
 final String fn = p.split('/').last;
 if (!fn.contains(ymd)) continue;
 final RegExp re = RegExp(ymd + r'[_\-]?(\d{6})');
 final m = re.firstMatch(fn);
 if (m != null) {
 final String fHms = m.group(1)!;
 final int fSec = (int.tryParse(fHms.substring(0, 2)) ?? 0) * 3600 +
 (int.tryParse(fHms.substring(2, 4)) ?? 0) * 60 +
 (int.tryParse(fHms.substring(4, 6)) ?? 0);
 if ((fSec - targetSec).abs() == tol) {
 final meta = await _extractPhotoMetaFromPath(p, allowYellowOcr: false);
 if (meta['lat'] != null && meta['lng'] != null) return meta;
 }
 }
 }
 }
 }
 if (pickedSize > 0) {
 int checked = 0;
 for (final String p in allGalleryPaths) {
 if (checked++ > 3500) break;
 try {
 final int len = File(p).lengthSync();
 if (len == pickedSize) {
 final meta = await _extractPhotoMetaFromPath(p, allowYellowOcr: false);
 if (meta['lat'] != null && meta['lng'] != null) return meta;
 }
 } catch (_) {}
 }
 }
 return {};
 }
 Future<void> _importPhotosFromGallery() async {
 try {
 await [
 Permission.photos,
 Permission.storage,
 Permission.accessMediaLocation,
 ].request();
 final ImagePicker picker = ImagePicker();
 final List<XFile> pickedFiles = await picker.pickMultiImage(
 requestFullMetadata: true,
 );
 if (pickedFiles.isEmpty) return;
 setState(() {
 _isExporting = true;
 _exportStatusMsg = '사진 위치정보를 분석하여 불러오는 중...';
 });
 final Directory docDir = await getApplicationDocumentsDirectory();
 final List<String> galleryPaths = _listGalleryFilePathsFast(docDir.path);
 int addedCount = 0;
 int exifGpsCount = 0;
 double defaultLat = forcedUserLat ?? _myCurrentPos?.latitude ?? 37.4984;
 double defaultLng = forcedUserLng ?? _myCurrentPos?.longitude ?? 127.1324;
 if (_mapCtrl != null && forcedUserLat == null) {
 try {
 final camPos = await _mapCtrl!.getCameraPosition();
 defaultLat = camPos.target.latitude;
 defaultLng = camPos.target.longitude;
 } catch (_) {}
 }
 for (int i = 0; i < pickedFiles.length; i++) {
 final XFile picked = pickedFiles[i];
 Map<String, dynamic> meta = await _extractPhotoMetaFromPath(picked.path);
 if (meta['lat'] == null || meta['lng'] == null) {
 final Map<String, dynamic> recovered = await _fastPinpointOriginalGps(
 picked, meta['dateTime'] as String?, galleryPaths);
 if (recovered['lat'] != null && recovered['lng'] != null) {
 meta = {...meta, ...recovered};
 }
 }
 final double? lat = meta['lat'] as double?;
 final double? lng = meta['lng'] as double?;
 final double alt = (meta['alt'] as double?) ?? 0.0;
 final double azimuth = (meta['azimuth'] as double?) ?? -1.0;
 String? timeStr;
 final String? rawDt = meta['dateTime'] as String?;
 if (rawDt != null && rawDt.length >= 16) {
 final String sub = rawDt.substring(0, 16);
 timeStr = sub.replaceFirst(':', '-').replaceFirst(':', '-');
 }
 if (timeStr == null || timeStr.length < 10) {
 try {
 final DateTime modDt = await File(picked.path).lastModified();
 timeStr = modDt.toString().substring(0, 16);
 } catch (_) {
 timeStr = DateTime.now().toString().substring(0, 16);
 }
 }
 final bool hasValidExifGps =
 lat != null && lng != null && (lat.abs() > 0.0001 || lng.abs() > 0.0001);
 final double finalLat = hasValidExifGps ? lat : defaultLat;
 final double finalLng = hasValidExifGps ? lng : defaultLng;
 if (hasValidExifGps) exifGpsCount++;
 final String folderDate = timeStr.substring(0, 10);
 final Directory dayDir = Directory('${docDir.path}/$folderDate');
 if (!await dayDir.exists()) {
 await dayDir.create(recursive: true);
 }
 final int nowMs = DateTime.now().millisecondsSinceEpoch + i;
 final String targetPath = '${dayDir.path}/imported_$nowMs.jpg';
 await File(picked.path).copy(targetPath);
 encodePhotoForHtmlFast(targetPath);
 widget.photos.add(PhotoItem(
 path: targetPath,
 lat: finalLat,
 lng: finalLng,
 alt: alt,
 acc: 1.0,
 azimuth: azimuth,
 pitch: 0.0,
 timestamp: timeStr,
 category: currentDefaultCategory,
 ));
 addedCount++;
 }
 if (addedCount > 0) {
 await _persistPhotoMetadata();
 setState(() {
 _dateFilter = '전체 보기';
 _categoryFilter = '전체 카테고리';
 _selectedIdx = _visiblePhotos.isNotEmpty ? _visiblePhotos.length - 1 : 0;
 });
 await _refreshAllOverlays(includeBlueprint: true);
 if (_visiblePhotos.isNotEmpty) {
 final PhotoItem lastAdded = _visiblePhotos[_selectedIdx];
 _panMapKeepZoom(lastAdded.lat, lastAdded.lng);
 if (mounted) {
 ScaffoldMessenger.of(context).showSnackBar(
 SnackBar(
 content: Text(
 '📍 사진 ${addedCount}장 첨부 완료! (원본 위치 확인: ${exifGpsCount}장)',
 ),
 duration: const Duration(seconds: 2),
 ),
 );
 }
 }
 }
 } catch (e) {
 if (mounted) {
 ScaffoldMessenger.of(context).showSnackBar(
 SnackBar(content: Text('사진 불러오기 오류: $e')),
 );
 }
 } finally {
 if (mounted) setState(() => _isExporting = false);
 }
 }
 Future<void> _showAfterPhotoActionSheet(PhotoItem targetPhoto) async {
 await showModalBottomSheet(
 context: context,
 backgroundColor: Colors.grey[900],
 shape: const RoundedRectangleBorder(
 borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
 ),
 builder: (ctx) {
 return SafeArea(
 child: Padding(
 padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
 child: Column(
 mainAxisSize: MainAxisSize.min,
 crossAxisAlignment: CrossAxisAlignment.start,
 children: [
 const Padding(
 padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
 child: Text(
 '🛠️ 조치후 사진 등록 · 관리 (조치전 · 조치후 · 지도 3등분)',
 style: TextStyle(
 color: Colors.lightGreenAccent,
 fontSize: 15.5,
 fontWeight: FontWeight.bold,
 ),
 ),
 ),
 const Divider(color: Colors.white24),
 ListTile(
 leading: const Icon(Icons.camera_alt, color: Colors.amber),
 title: const Text(
 '① 카메라로 조치후 사진 바로 촬영하기',
 style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
 ),
 subtitle: const Text(
 '카메라 화면으로 전환하여 촬영 후 자동으로 3등분 화면으로 돌아옵니다',
 style: TextStyle(color: Colors.white70, fontSize: 12),
 ),
 onTap: () {
 Navigator.pop(ctx);
 Navigator.pop(context, targetPhoto);
 },
 ),
 ListTile(
 leading: const Icon(Icons.photo_library, color: Colors.lightBlueAccent),
 title: const Text(
 '② 갤러리에서 조치후 사진 선택하기',
 style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
 ),
 subtitle: const Text(
 '이미 찍어둔 조치완료 사진을 앨범에서 골라 기존 사진과 지도 사이에 넣습니다',
 style: TextStyle(color: Colors.white70, fontSize: 12),
 ),
 onTap: () async {
 Navigator.pop(ctx);
 try {
 final ImagePicker picker = ImagePicker();
 final XFile? picked = await picker.pickImage(
 source: ImageSource.gallery,
 );
 if (picked == null) return;
 final Directory docDir = await getApplicationDocumentsDirectory();
 final String folderDate = targetPhoto.timestamp.length >= 10
 ? targetPhoto.timestamp.substring(0, 10)
 : DateTime.now().toString().substring(0, 10);
 final Directory dayDir = Directory('${docDir.path}/$folderDate');
 if (!await dayDir.exists()) {
 await dayDir.create(recursive: true);
 }
 final String destPath =
 '${dayDir.path}/after_imp_${DateTime.now().millisecondsSinceEpoch}.jpg';
 await File(picked.path).copy(destPath);
 encodePhotoForHtmlFast(destPath);
 setState(() {
 targetPhoto.afterPath = destPath;
 });
 await _persistPhotoMetadata();
 if (mounted) {
 ScaffoldMessenger.of(context).showSnackBar(
 const SnackBar(
 content: Text('✅ 조치후 사진이 등록되어 3등분 화면으로 전환되었습니다!'),
 duration: Duration(milliseconds: 1400),
 ),
 );
 }
 } catch (e) {
 if (mounted) {
 ScaffoldMessenger.of(context).showSnackBar(
 SnackBar(content: Text('조치후 사진 첨부 오류: $e')),
 );
 }
 }
 },
 ),
 if (targetPhoto.hasAfterPhoto)
 ListTile(
 leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
 title: const Text(
 '③ 조치후 사진만 삭제 (기본 2등분으로 복귀)',
 style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
 ),
 onTap: () async {
 Navigator.pop(ctx);
 final String? oldAfter = targetPhoto.afterPath;
 setState(() {
 targetPhoto.afterPath = null;
 });
 if (oldAfter != null) {
 try {
 final f = File(oldAfter);
 if (await f.exists()) await f.delete();
 final wf = File('$oldAfter.web.jpg');
 if (await wf.exists()) await wf.delete();
 } catch (_) {}
 }
 await _persistPhotoMetadata();
 },
 ),
 ],
 ),
 ),
 );
 },
 );
 }
 Future<void> _deletePhoto(PhotoItem targetPhoto) async {
 try {
 final file = File(targetPhoto.path);
 if (await file.exists()) await file.delete();
 final webCache = File('${targetPhoto.path}.web.jpg');
 if (await webCache.exists()) await webCache.delete();
 if (targetPhoto.afterPath != null && targetPhoto.afterPath!.isNotEmpty) {
 final af = File(targetPhoto.afterPath!);
 if (await af.exists()) await af.delete();
 final awf = File('${targetPhoto.afterPath!}.web.jpg');
 if (await awf.exists()) await awf.delete();
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
 Offset? _tapDownPos;
 int _tapDownMs = 0;
 Future<void> _updateMyLocationMarkerOnly() async {
 if (_mapCtrl == null || !_showMyLocation) return;
 final double? lat = forcedUserLat ?? _myCurrentPos?.latitude;
 final double? lng = forcedUserLng ?? _myCurrentPos?.longitude;
 if (lat == null || lng == null) return;
 try {
 final icon = await _getMyLocationIcon();
 final myMarker = NMarker(
 id: 'my_current_location_marker',
 position: NLatLng(lat, lng),
 icon: icon,
 );
 await _mapCtrl!.addOverlay(myMarker);
 } catch (e) {
 debugPrint('My location marker error: $e');
 }
 }
 Future<void> _toggleMyLocation() async {
 if (_showMyLocation) {
 await _myLocStreamSub?.cancel();
 _myLocStreamSub = null;
 setState(() {
 _showMyLocation = false;
 forcedUserLat = null;
 forcedUserLng = null;
 });
 await _refreshAllOverlays(includeBlueprint: true);
 return;
 }
 setState(() => _showMyLocation = true);
 try {
 final pos = await Geolocator.getLastKnownPosition() ??
 await Geolocator.getCurrentPosition(
 locationSettings:
 const LocationSettings(accuracy: LocationAccuracy.high),
 );
 if (!mounted || !_showMyLocation) return;
 setState(() => _myCurrentPos = pos);
 _panMapKeepZoom(pos.latitude, pos.longitude);
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
 final bool noDir = azimuth < 0;
 final int degStep =
 noDir ? -1 : (((azimuth % 360 + 360) % 360) / 5).round() * 5 % 360;
 final String key =
 noDir ? '${selected ? "sel" : "unsel"}_circle' : '${selected ? "sel" : "unsel"}_$degStep';
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
 color: c.withOpacity(0.35),
 shape: BoxShape.circle,
 border: Border.all(color: c, width: 2.2),
 ),
 ),
 noDir
 ? Container(
 width: 11,
 height: 11,
 decoration: BoxDecoration(
 color: c,
 shape: BoxShape.circle,
 ),
 )
 : Transform.rotate(
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
 padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
 child: SingleChildScrollView(
 child: Column(
 mainAxisSize: MainAxisSize.min,
 crossAxisAlignment: CrossAxisAlignment.start,
 children: [
 const Padding(
 padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
 child: Text(
 '📤 내보내기 및 📥 공유파일(HTML·ZIP) 불러오기',
 style: TextStyle(
 color: Colors.amber,
 fontSize: 16,
 fontWeight: FontWeight.bold,
 ),
 ),
 ),
 const Divider(color: Colors.white24),
 ListTile(
 dense: true,
 leading:
 const Icon(Icons.flash_on, color: Colors.lightBlueAccent),
 title: const Text(
 '① 웹 뷰어 파일(.html) 초고속 내보내기',
 style: TextStyle(
 color: Colors.white, fontWeight: FontWeight.bold),
 ),
 subtitle: Text(
 '멀티코어 병렬 압축 (${_visiblePhotos.length}장) + 조치전·조치후 3등분 + 도면 데이터 포함',
 style:
 const TextStyle(color: Colors.white70, fontSize: 11.5),
 ),
 onTap: () {
 Navigator.pop(ctx);
 _exportAsHtmlViewer();
 },
 ),
 ListTile(
 dense: true,
 leading:
 const Icon(Icons.folder_zip, color: Colors.amberAccent),
 title: const Text(
 '② 프로젝트 압축파일(.zip)로 내보내기',
 style: TextStyle(
 color: Colors.white, fontWeight: FontWeight.bold),
 ),
 subtitle: const Text(
 '원본 사진·조치후 사진들과 도면 설정 데이터를 통째로 묶어 전달',
 style: TextStyle(color: Colors.white70, fontSize: 11.5),
 ),
 onTap: () {
 Navigator.pop(ctx);
 _exportAsZipArchive();
 },
 ),
 ListTile(
 dense: true,
 leading: const Icon(Icons.burst_mode,
 color: Colors.lightGreenAccent),
 title: const Text(
 '③ [사진 + 도면 지도] 합본 이미지(.jpg) 공유',
 style: TextStyle(
 color: Colors.white, fontWeight: FontWeight.bold),
 ),
 subtitle: const Text(
 '조치후 사진이 있으면 [조치전 + 조치후 + 도면 지도] 3등분 합본으로 즉시 공유',
 style: TextStyle(color: Colors.white70, fontSize: 11.5),
 ),
 onTap: () {
 Navigator.pop(ctx);
 _exportAsCombinedImage();
 },
 ),
 const Divider(color: Colors.white24),
 ListTile(
 dense: true,
 leading: const Icon(Icons.file_download,
 color: Colors.greenAccent),
 title: const Text(
 '④ 받은 HTML(웹 뷰어) · ZIP 업로드해서 보기',
 style: TextStyle(
 color: Colors.greenAccent, fontWeight: FontWeight.bold),
 ),
 subtitle: const Text(
 '공유받은 .html 또는 .zip 파일을 앱에 업로드하여 사진·조치후·도면을 그대로 복원',
 style: TextStyle(color: Colors.white70, fontSize: 11.5),
 ),
 onTap: () {
 Navigator.pop(ctx);
 _showImportProjectDialog();
 },
 ),
 ],
 ),
 ),
 ),
 );
 },
 );
 }
 Future<String?> _getPhotoDataUriFast(String path) async {
 if (globalHtmlBase64Cache.containsKey(path)) {
 return globalHtmlBase64Cache[path];
 }
 final Uint8List? jpgBytes = await encodePhotoForHtmlFast(path);
 if (jpgBytes == null || jpgBytes.isEmpty) return null;
 final String uri = 'data:image/jpeg;base64,${base64Encode(jpgBytes)}';
 globalHtmlBase64Cache[path] = uri;
 return uri;
 }
 Future<void> _exportAsHtmlViewer() async {
 final List<BlueprintItem> allBps = _blueprints.toList();
 if (_visiblePhotos.isEmpty && allBps.isEmpty) {
 ScaffoldMessenger.of(context).showSnackBar(
 const SnackBar(content: Text('내보낼 사진이나 도면이 없습니다.')),
 );
 return;
 }
 final int totalPhotos = _visiblePhotos.length;
 setState(() {
 _isExporting = true;
 _exportStatusMsg = '⚡ HTML 고속 생성 중... (0 / $totalPhotos장)';
 });
 try {
 final List<Map<String, dynamic>?> results =
 List<Map<String, dynamic>?>.filled(totalPhotos, null);
 const int batchSize = 6;
 for (int start = 0; start < totalPhotos; start += batchSize) {
 final int end = min(start + batchSize, totalPhotos);
 await Future.wait(List.generate(end - start, (offset) async {
 final int idx = start + offset;
 final PhotoItem p = _visiblePhotos[idx];
 final String? mainUri = await _getPhotoDataUriFast(p.path);
 if (mainUri == null) return;
 String afterUri = '';
 if (p.hasAfterPhoto) {
 afterUri = (await _getPhotoDataUriFast(p.afterPath!)) ?? '';
 }
 results[idx] = {
 'b64': mainUri,
 'afterB64': afterUri,
 'lat': p.lat,
 'lng': p.lng,
 'alt': p.alt,
 'acc': p.acc,
 'azimuth': p.azimuth,
 'pitch': p.pitch,
 'time': p.timestamp,
 'category': p.category,
 'memo': p.memo,
 };
 }));
 if (mounted) {
 setState(() {
 _exportStatusMsg = '⚡ HTML 고속 생성 중... ($end / $totalPhotos장)';
 });
 }
 }
 final List<Map<String, dynamic>> encodedPhotos =
 results.whereType<Map<String, dynamic>>().toList();
 final List<Map<String, dynamic>> bpJsonList = [];
 for (final bp in allBps) {
 if (!File(bp.imagePath).existsSync()) continue;
 final Uint8List bpBytes =
 bp.fastBytes ?? await File(bp.imagePath).readAsBytes();
 final String mime = bp.fastBytes != null
 ? 'image/png'
 : (bp.imagePath.toLowerCase().endsWith('.png')
 ? 'image/png'
 : 'image/jpeg');
 final double rad = bp.currentRadius;
 final double dLat = rad / 111320.0;
 final double cosLat =
 cos(bp.centerLat * pi / 180.0).abs().clamp(0.1, 1.0);
 final double dLng = rad / (111320.0 * cosLat);
 bpJsonList.add({
 'id': bp.id,
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
 'origOpacity': bp.opacity,
 'baseRadius': bp.baseRadius,
 'sizeSlider': bp.sizeSlider,
 'isVisible': _bpGlobalShow && bp.isVisible,
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
 header { padding: 8px 12px; background: #000; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #333; flex-wrap: wrap; gap: 6px; }
 .hdr-left { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
 .app-copy-btn { background: #00e676; color: #000; border: none; border-radius: 6px; padding: 5px 10px; font-size: 11.5px; font-weight: bold; cursor: pointer; }
 .main-wrap { flex: 1; display: flex; flex-direction: row; overflow: hidden; gap: 3px; background: #222; }
 @media (max-width: 768px) { .main-wrap { flex-direction: column; } }
 .img-pane { flex: 1; background: #000; display: flex; align-items: center; justify-content: center; overflow: hidden; position: relative; touch-action: none; }
 .img-pane img { max-width: 100%; max-height: 100%; object-fit: contain; transform-origin: center center; user-select: none; -webkit-user-drag: none; }
 .pane-badge { position: absolute; top: 8px; left: 8px; background: rgba(0,0,0,0.75); color: #ffc107; border: 1px solid #ffc107; font-size: 11px; font-weight: bold; padding: 3px 8px; border-radius: 6px; z-index: 10; pointer-events: none; }
 .pane-badge.after { color: #00e676; border-color: #00e676; }
 .zoom-hint { position: absolute; bottom: 8px; right: 10px; background: rgba(0,0,0,0.6); color: #ddd; font-size: 10.5px; padding: 2px 7px; border-radius: 10px; pointer-events: none; }
 #map-pane { flex: 1; position: relative; }
 #thumbs { height: 82px; background: #000; display: flex; overflow-x: auto; padding: 4px; border-top: 1px solid #333; }
 .thumb-wrap { position: relative; margin-right: 6px; flex-shrink: 0; }
 .thumb-wrap img { width: 70px; height: 70px; object-fit: cover; border: 3px solid transparent; cursor: pointer; display: block; }
 .thumb-wrap img.active { border-color: #ffc107; }
 .thumb-tag { position: absolute; bottom: 3px; right: 3px; background: #00c853; color: #fff; font-size: 9px; font-weight: bold; padding: 1px 4px; border-radius: 4px; pointer-events: none; }
</style>
</head>
<body>
<header>
 <div class="hdr-left">
 <strong>📍 날짜: $_dateFilter | 분류: $_categoryFilter</strong>
 <button class="app-copy-btn" onclick="copyProjectForApp()">📲 앱에 업로드용 데이터 복사</button>
 </div>
 <span id="info-txt" style="font-size:12px; color:#ffc107;"></span>
</header>
<div class="main-wrap">
 <div id="photo-pane" class="img-pane">
 <div id="before-badge" class="pane-badge" style="display:none;">조치전 사진</div>
 <img id="main-photo" src="" alt="현장 사진"/>
 <div class="zoom-hint">두 손가락 확대/이동 · 더블터치 초기화</div>
 </div>
 <div id="after-pane" class="img-pane" style="display:none;">
 <div class="pane-badge after">조치후 사진</div>
 <img id="after-photo" src="" alt="조치후 사진"/>
 <div class="zoom-hint">조치후 완료 사진</div>
 </div>
 <div id="map-pane"></div>
</div>
<div id="thumbs"></div>
<script>
const photos = $photosJs;
const bps = $bpsJs;
let selectedIdx = 0;
function copyProjectForApp() {
 const payload = 'GPS_CAMERA_HTML_V2:' + JSON.stringify({ photos: photos, bps: bps });
 const ta = document.createElement('textarea');
 ta.value = payload;
 ta.style.position = 'fixed';
 ta.style.left = '-9999px';
 document.body.appendChild(ta);
 ta.focus();
 ta.select();
 let ok = false;
 try { ok = document.execCommand('copy'); } catch (e) {}
 document.body.removeChild(ta);
 if (navigator.clipboard && navigator.clipboard.writeText) {
 navigator.clipboard.writeText(payload).catch(() => {});
 }
 alert('✅ 사진(' + photos.length + '장)과 도면(' + bps.length + '개) 데이터가 복사되었습니다!\n\n이제 [GPS 카메라 앱]을 열고 상단 [공유] ➔ [④ 받은 HTML·ZIP 업로드해서 보기]를 누르면 도면과 사진이 앱에 그대로 등록됩니다.');
}
function bindPinchZoom(paneEl, imgEl) {
 let scale = 1.0, tx = 0, ty = 0;
 let sDist = 0, sScale = 1.0, dragging = false, sx = 0, sy = 0, lastTap = 0;
 function apply() { imgEl.style.transform = `translate(\${tx}px, \${ty}px) scale(\${scale})`; }
 function reset() { scale = 1.0; tx = 0; ty = 0; apply(); }
 paneEl.addEventListener('touchstart', (e) => {
 if (e.touches.length === 2) {
 dragging = false;
 sDist = Math.hypot(e.touches[0].clientX - e.touches[1].clientX, e.touches[0].clientY - e.touches[1].clientY);
 sScale = scale;
 } else if (e.touches.length === 1) {
 const now = Date.now();
 if (now - lastTap < 300) {
 scale = scale > 1.2 ? 1.0 : 2.5; tx = 0; ty = 0; apply(); lastTap = 0; return;
 }
 lastTap = now;
 if (scale > 1.02) { dragging = true; sx = e.touches[0].clientX - tx; sy = e.touches[0].clientY - ty; }
 }
 }, { passive: false });
 paneEl.addEventListener('touchmove', (e) => {
 e.preventDefault();
 if (e.touches.length === 2 && sDist > 0) {
 const d = Math.hypot(e.touches[0].clientX - e.touches[1].clientX, e.touches[0].clientY - e.touches[1].clientY);
 scale = Math.min(5.0, Math.max(1.0, sScale * (d / sDist)));
 if (scale <= 1.02) { tx = 0; ty = 0; }
 apply();
 } else if (e.touches.length === 1 && dragging && scale > 1.02) {
 tx = e.touches[0].clientX - sx; ty = e.touches[0].clientY - sy; apply();
 }
 }, { passive: false });
 paneEl.addEventListener('touchend', (e) => {
 if (e.touches.length < 2) sDist = 0;
 if (e.touches.length === 0) dragging = false;
 });
 paneEl.addEventListener('wheel', (e) => {
 e.preventDefault();
 scale = Math.min(5.0, Math.max(1.0, scale + (e.deltaY < 0 ? 0.2 : -0.2)));
 if (scale <= 1.02) { tx = 0; ty = 0; }
 apply();
 }, { passive: false });
 return reset;
}
const resetMainZoom = bindPinchZoom(document.getElementById('photo-pane'), document.getElementById('main-photo'));
const resetAfterZoom = bindPinchZoom(document.getElementById('after-pane'), document.getElementById('after-photo'));
const initLat = photos.length > 0 ? photos[0].lat : (bps.length > 0 ? bps[0].lat : 37.4984);
const initLng = photos.length > 0 ? photos[0].lng : (bps.length > 0 ? bps[0].lng : 127.1324);
const map = L.map('map-pane', { maxZoom: 22 }).setView([initLat, initLng], ${currentMapZoom.toStringAsFixed(1)});
L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
 maxNativeZoom: 19,
 maxZoom: 22,
 attribution: '© OpenStreetMap'
}).addTo(map);
bps.forEach((bp) => {
 if (bp.isVisible === false) return;
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
function selectPhoto(idx) {
 selectedIdx = idx;
 resetMainZoom();
 resetAfterZoom();
 const p = photos[idx];
 document.getElementById('main-photo').src = p.b64;
 const afterPane = document.getElementById('after-pane');
 const beforeBadge = document.getElementById('before-badge');
 if (p.afterB64 && p.afterB64.length > 10) {
 document.getElementById('after-photo').src = p.afterB64;
 afterPane.style.display = 'flex';
 beforeBadge.style.display = 'block';
 } else {
 afterPane.style.display = 'none';
 beforeBadge.style.display = 'none';
 }
 setTimeout(() => { map.invalidateSize(); }, 60);
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
 const wrap = document.createElement('div');
 wrap.className = 'thumb-wrap';
 const im = document.createElement('img');
 im.src = p.b64;
 if (i === selectedIdx) im.className = 'active';
 im.onclick = () => selectPhoto(i);
 wrap.appendChild(im);
 if (p.afterB64 && p.afterB64.length > 10) {
 const tag = document.createElement('span');
 tag.className = 'thumb-tag';
 tag.innerText = '조치후';
 wrap.appendChild(tag);
 }
 box.appendChild(wrap);
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
 const noDir = p.azimuth < 0;
 const htmlIcon = L.divIcon({
 className: '',
 iconSize: [28, 28],
 iconAnchor: [14, 14],
 html: `<div style="width:24px;height:24px;border-radius:50%;background:\${color}4d;border:2px solid \${color};display:flex;align-items:center;justify-content:center;\${noDir ? '' : 'transform:rotate(' + p.azimuth + 'deg);'}">
 <span style="color:\${color};font-size:\${noDir ? '12px' : '14px'};font-weight:bold;">\${noDir ? '●' : '▲'}</span>
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
 selectPhoto(0);
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
 text: '📍 GPS 도면 & 현장 촬영 사진 웹 뷰어(.html)입니다. (브라우저에서 열거나 GPS 카메라 앱에 그대로 업로드할 수 있습니다)',
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
 Future<void> _showImportProjectDialog() async {
 String? clipboardPayload;
 try {
 final ClipboardData? cdata = await Clipboard.getData('text/plain');
 final String? txt = cdata?.text?.trim();
 if (txt != null &&
 (txt.startsWith('GPS_CAMERA_HTML_V2:') ||
 (txt.contains('const photos =') && txt.contains('const bps =')))) {
 clipboardPayload = txt;
 }
 } catch (_) {}
 final List<File> foundFiles = [];
 final Set<String> seenPaths = {};
 final List<String> scanDirs = [
 '/storage/emulated/0/Download',
 '/storage/emulated/0/Download/KakaoTalk',
 '/storage/emulated/0/KakaoTalkDownload',
 '/storage/emulated/0/Documents',
 ];
 try {
 final Directory tmp = await getTemporaryDirectory();
 scanDirs.add(tmp.path);
 } catch (_) {}
 void scanForImportFiles(Directory d, int depth) {
 if (depth > 2) return;
 try {
 if (!d.existsSync()) return;
 for (final FileSystemEntity e in d.listSync(followLinks: false)) {
 if (e is File) {
 final String low = e.path.toLowerCase();
 if ((low.endsWith('.html') || low.endsWith('.htm') || low.endsWith('.zip')) &&
 seenPaths.add(e.path)) {
 foundFiles.add(e);
 }
 } else if (e is Directory && depth < 2) {
 final String sub = e.path.split('/').last;
 if (!sub.startsWith('.')) scanForImportFiles(e, depth + 1);
 }
 }
 } catch (_) {}
 }
 for (final String dPath in scanDirs) {
 scanForImportFiles(Directory(dPath), 0);
 }
 foundFiles.sort((a, b) {
 try {
 return b.lastModifiedSync().compareTo(a.lastModifiedSync());
 } catch (_) {
 return 0;
 }
 });
 bool replaceExisting = false;
 if (!mounted) return;
 await showDialog(
 context: context,
 builder: (ctx) {
 return StatefulBuilder(
 builder: (ctx, setDialogState) {
 return Dialog(
 backgroundColor: Colors.grey[900],
 insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
 shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
 Icon(Icons.file_download, color: Colors.greenAccent, size: 20),
 SizedBox(width: 6),
 Text(
 'HTML · ZIP 프로젝트 업로드 (사진+도면)',
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
 child: const Icon(Icons.close, color: Colors.white54, size: 18),
 ),
 ],
 ),
 const SizedBox(height: 8),
 Container(
 padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
 decoration: BoxDecoration(
 color: Colors.white10,
 borderRadius: BorderRadius.circular(8),
 ),
 child: Row(
 children: [
 Checkbox(
 value: replaceExisting,
 activeColor: Colors.amber,
 checkColor: Colors.black,
 visualDensity: VisualDensity.compact,
 onChanged: (v) {
 setDialogState(() => replaceExisting = v ?? false);
 },
 ),
 const Expanded(
 child: Text(
 '기존 사진/도면을 비우고 업로드한 파일만 단독으로 보기',
 style: TextStyle(color: Colors.white, fontSize: 11.5),
 ),
 ),
 ],
 ),
 ),
 if (clipboardPayload != null) ...[
 const SizedBox(height: 10),
 ElevatedButton.icon(
 onPressed: () {
 Navigator.pop(ctx);
 _importProjectFromHtmlOrPayload(
 clipboardPayload!,
 replaceExisting: replaceExisting,
 );
 },
 icon: const Icon(Icons.content_paste_go, size: 18),
 label: const Text(
 '📋 방금 웹 뷰어(.html)에서 복사한 데이터 즉시 업로드!',
 style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
 ),
 style: ElevatedButton.styleFrom(
 backgroundColor: Colors.greenAccent[400],
 foregroundColor: Colors.black,
 padding: const EdgeInsets.symmetric(vertical: 11),
 ),
 ),
 ],
 const SizedBox(height: 10),
 ElevatedButton.icon(
 onPressed: () async {
 try {
 const MethodChannel ch = MethodChannel('gps_camera/shutter');
 final String? pickedContent =
 await ch.invokeMethod<String>('pickHtmlOrZipFile');
 if (pickedContent != null && pickedContent.isNotEmpty) {
 if (ctx.mounted) Navigator.pop(ctx);
 await _importProjectFromHtmlOrPayload(
 pickedContent,
 replaceExisting: replaceExisting,
 );
 return;
 }
 } catch (_) {
 if (mounted) {
 ScaffoldMessenger.of(context).showSnackBar(
 const SnackBar(
 content: Text(
 '💡 카카오톡 등에서 받은 HTML을 브라우저로 연 뒤 상단 초록색 [📲 앱에 업로드용 데이터 복사] 버튼을 누르면 즉시 업로드됩니다!',
 ),
 duration: Duration(seconds: 3),
 ),
 );
 }
 }
 },
 icon: const Icon(Icons.folder_open, size: 17),
 label: const Text(
 '📂 휴대폰 파일 탐색기에서 .html 파일 직접 선택',
 style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
 ),
 style: ElevatedButton.styleFrom(
 backgroundColor: Colors.lightBlueAccent,
 foregroundColor: Colors.black,
 padding: const EdgeInsets.symmetric(vertical: 10),
 ),
 ),
 const SizedBox(height: 10),
 const Text(
 '📥 다운로드 / 카카오톡 폴더에서 발견된 파일 (터치하여 업로드):',
 style: TextStyle(color: Colors.white70, fontSize: 11.5),
 ),
 const SizedBox(height: 6),
 ConstrainedBox(
 constraints: const BoxConstraints(maxHeight: 200),
 child: foundFiles.isEmpty
 ? Container(
 padding: const EdgeInsets.all(12),
 decoration: BoxDecoration(
 color: Colors.black45,
 borderRadius: BorderRadius.circular(8),
 border: Border.all(color: Colors.white24),
 ),
 child: const Text(
 '다운로드 폴더에 표시 가능한 .html 파일이 없거나 Android 보안 정책으로 숨겨져 있습니다.\n\n👉 받은 .html 파일을 열어 상단의 초록색 [📲 앱에 업로드용 데이터 복사] 버튼을 누른 뒤 이 창을 다시 열면 1초 만에 사진과 도면이 모두 업로드됩니다!',
 style: TextStyle(color: Colors.amberAccent, fontSize: 11.5),
 ),
 )
 : ListView.builder(
 shrinkWrap: true,
 itemCount: foundFiles.length,
 itemBuilder: (_, i) {
 final File f = foundFiles[i];
 final String fname = f.path.split('/').last;
 final bool isZip = fname.toLowerCase().endsWith('.zip');
 return Card(
 color: Colors.white10,
 margin: const EdgeInsets.only(bottom: 6),
 child: ListTile(
 dense: true,
 leading: Icon(
 isZip ? Icons.folder_zip : Icons.public,
 color: isZip ? Colors.amberAccent : Colors.lightBlueAccent,
 size: 20,
 ),
 title: Text(
 fname,
 style: const TextStyle(
 color: Colors.white,
 fontSize: 12,
 fontWeight: FontWeight.bold,
 ),
 ),
 subtitle: Text(
 f.parent.path.replaceFirst('/storage/emulated/0/', ''),
 style: const TextStyle(color: Colors.white54, fontSize: 10.5),
 ),
 onTap: () async {
 Navigator.pop(ctx);
 if (isZip) {
 await _importFromZipFile(f, replaceExisting: replaceExisting);
 } else {
 final String content = await f.readAsString();
 await _importProjectFromHtmlOrPayload(
 content,
 replaceExisting: replaceExisting,
 );
 }
 },
 ),
 );
 },
 ),
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
 Uint8List? _decodeDataUriBytes(String dataUri) {
 try {
 final int commaIdx = dataUri.indexOf(',');
 final String b64 = commaIdx >= 0 ? dataUri.substring(commaIdx + 1) : dataUri;
 return base64Decode(b64.trim());
 } catch (_) {
 return null;
 }
 }
 Future<void> _importProjectFromHtmlOrPayload(
 String rawText, {
 bool replaceExisting = false,
 }) async {
 setState(() {
 _isExporting = true;
 _exportStatusMsg = '📥 HTML 파일에서 사진과 도면을 복원하는 중...';
 });
 try {
 List<dynamic> photosRaw = [];
 List<dynamic> bpsRaw = [];
 if (rawText.startsWith('GPS_CAMERA_HTML_V2:')) {
 final Map<String, dynamic> decoded =
 jsonDecode(rawText.substring('GPS_CAMERA_HTML_V2:'.length))
 as Map<String, dynamic>;
 photosRaw = (decoded['photos'] as List<dynamic>?) ?? [];
 bpsRaw = (decoded['bps'] as List<dynamic>?) ?? [];
 } else {
 final int pMarker = rawText.indexOf('const photos =');
 final int bMarker = rawText.indexOf('const bps =');
 if (pMarker >= 0 && bMarker > pMarker) {
 final int pStart = rawText.indexOf('[', pMarker);
 final int pEnd = rawText.lastIndexOf('];', bMarker);
 if (pStart >= 0 && pEnd > pStart) {
 photosRaw = jsonDecode(rawText.substring(pStart, pEnd + 1)) as List<dynamic>;
 }
 }
 if (bMarker >= 0) {
 final int bStart = rawText.indexOf('[', bMarker);
 final int afterBps = rawText.indexOf('let selectedIdx', bMarker);
 final int searchUntil = afterBps > bStart ? afterBps : rawText.length;
 final int bEnd = rawText.lastIndexOf('];', searchUntil);
 if (bStart >= 0 && bEnd > bStart) {
 bpsRaw = jsonDecode(rawText.substring(bStart, bEnd + 1)) as List<dynamic>;
 }
 }
 }
 if (photosRaw.isEmpty && bpsRaw.isEmpty) {
 throw Exception('유효한 GPS 카메라 HTML 데이터가 아닙니다.');
 }
 final Directory docDir = await getApplicationDocumentsDirectory();
 if (replaceExisting) {
 widget.photos.clear();
 _blueprints.clear();
 }
 int importedPhotos = 0;
 final int baseMs = DateTime.now().millisecondsSinceEpoch;
 for (int i = 0; i < photosRaw.length; i++) {
 final Map<String, dynamic> m = photosRaw[i] as Map<String, dynamic>;
 final String? b64 = m['b64'] as String?;
 if (b64 == null || b64.isEmpty) continue;
 final Uint8List? jpgBytes = _decodeDataUriBytes(b64);
 if (jpgBytes == null || jpgBytes.isEmpty) continue;
 final String timeStr = (m['time'] as String?) ??
 DateTime.now().toString().substring(0, 16);
 final String folderDate = timeStr.length >= 10
 ? timeStr.substring(0, 10)
 : DateTime.now().toString().substring(0, 10);
 final Directory dayDir = Directory('${docDir.path}/$folderDate');
 if (!await dayDir.exists()) {
 await dayDir.create(recursive: true);
 }
 final String targetPath = '${dayDir.path}/html_imp_${baseMs}_$i.jpg';
 await File(targetPath).writeAsBytes(jpgBytes);
 await File('$targetPath.web.jpg').writeAsBytes(jpgBytes);
 globalHtmlBase64Cache[targetPath] = b64;
 String? afterPath;
 final String? afterB64 = m['afterB64'] as String?;
 if (afterB64 != null && afterB64.length > 10) {
 final Uint8List? afterBytes = _decodeDataUriBytes(afterB64);
 if (afterBytes != null && afterBytes.isNotEmpty) {
 afterPath = '${dayDir.path}/html_after_${baseMs}_$i.jpg';
 await File(afterPath).writeAsBytes(afterBytes);
 await File('$afterPath.web.jpg').writeAsBytes(afterBytes);
 globalHtmlBase64Cache[afterPath] = afterB64;
 }
 }
 final String cat = (m['category'] as String?)?.trim().isNotEmpty == true
 ? (m['category'] as String).trim()
 : '미분류';
 if (cat != '미분류') {
 _customCategories.add(cat);
 }
 widget.photos.add(PhotoItem(
 path: targetPath,
 lat: (m['lat'] as num?)?.toDouble() ?? 37.4984,
 lng: (m['lng'] as num?)?.toDouble() ?? 127.1324,
 alt: (m['alt'] as num?)?.toDouble() ?? 0.0,
 acc: (m['acc'] as num?)?.toDouble() ?? 1.0,
 azimuth: (m['azimuth'] as num?)?.toDouble() ?? -1.0,
 pitch: (m['pitch'] as num?)?.toDouble() ?? 0.0,
 timestamp: timeStr,
 category: cat,
 memo: (m['memo'] as String?) ?? '',
 afterPath: afterPath,
 ));
 importedPhotos++;
 }
 int importedBps = 0;
 for (int i = 0; i < bpsRaw.length; i++) {
 final Map<String, dynamic> bm = bpsRaw[i] as Map<String, dynamic>;
 final String? b64 = bm['b64'] as String?;
 if (b64 == null || b64.isEmpty) continue;
 final Uint8List? bpBytes = _decodeDataUriBytes(b64);
 if (bpBytes == null || bpBytes.isEmpty) continue;
 final String ext = b64.contains('image/png') ? 'png' : 'jpg';
 final int bpMs = baseMs + i;
 final String destPath = '${docDir.path}/bp_saved_$bpMs.$ext';
 await File(destPath).writeAsBytes(bpBytes);
 final double cLat = (bm['lat'] as num?)?.toDouble() ?? 37.4984;
 final double cLng = (bm['lng'] as num?)?.toDouble() ?? 127.1324;
 double baseRad = (bm['baseRadius'] as num?)?.toDouble() ?? 0.0;
 double sizeSl = (bm['sizeSlider'] as num?)?.toDouble() ?? 0.5;
 if (baseRad <= 0.1) {
 final double? swLat = (bm['swLat'] as num?)?.toDouble();
 final double? neLat = (bm['neLat'] as num?)?.toDouble();
 if (swLat != null && neLat != null) {
 baseRad = (((neLat - swLat).abs() / 2.0) * 111320.0).clamp(5.0, 5000.0);
 sizeSl = 0.5;
 } else {
 baseRad = 200.0;
 }
 }
 final BlueprintItem newBp = BlueprintItem(
 id: 'bp_$bpMs',
 name: (bm['name'] as String?) ?? '복원 도면 ${i + 1}',
 imagePath: destPath,
 centerLat: cLat,
 centerLng: cLng,
 baseRadius: baseRad,
 sizeSlider: sizeSl.clamp(0.0, 1.0),
 rotation: ((bm['rotation'] as num?)?.toDouble() ?? 0.0).clamp(-180.0, 180.0),
 opacity: ((bm['origOpacity'] as num?)?.toDouble() ?? 0.6).clamp(0.1, 1.0),
 isVisible: (bm['isVisible'] as bool?) ?? true,
 );
 await _prepareFastBlueprintBytes(newBp);
 _blueprints.add(newBp);
 importedBps++;
 }
 await _persistCategories();
 await _persistPhotoMetadata();
 if (importedBps > 0) {
 _bpGlobalShow = true;
 _activeBpIdx = _blueprints.length - 1;
 await _persistBlueprintConfig();
 }
 setState(() {
 _dateFilter = '전체 보기';
 _categoryFilter = '전체 카테고리';
 _selectedIdx = _visiblePhotos.isNotEmpty ? _visiblePhotos.length - 1 : 0;
 });
 await _refreshAllOverlays(includeBlueprint: true);
 if (_visiblePhotos.isNotEmpty) {
 final PhotoItem last = _visiblePhotos[_selectedIdx];
 _panMapKeepZoom(last.lat, last.lng);
 } else if (_blueprints.isNotEmpty) {
 final BlueprintItem lastBp = _blueprints.last;
 _panMapKeepZoom(lastBp.centerLat, lastBp.centerLng);
 }
 if (mounted) {
 ScaffoldMessenger.of(context).showSnackBar(
 SnackBar(
 content: Text(
 '🎉 업로드 완료! 사진 ${importedPhotos}장 + 도면 ${importedBps}개가 지도에 복원되었습니다.',
 ),
 duration: const Duration(seconds: 3),
 ),
 );
 }
 } catch (e) {
 if (mounted) {
 ScaffoldMessenger.of(context).showSnackBar(
 SnackBar(content: Text('HTML 업로드 오류: $e')),
 );
 }
 } finally {
 if (mounted) setState(() => _isExporting = false);
 }
 }
 Future<void> _importFromZipFile(File zipFile, {bool replaceExisting = false}) async {
 setState(() {
 _isExporting = true;
 _exportStatusMsg = '📦 ZIP 패키지에서 사진과 도면을 복원하는 중...';
 });
 try {
 final Uint8List zipBytes = await zipFile.readAsBytes();
 final Archive archive = ZipDecoder().decodeBytes(zipBytes);
 final Directory docDir = await getApplicationDocumentsDirectory();
 if (replaceExisting) {
 widget.photos.clear();
 _blueprints.clear();
 }
 final Map<String, Uint8List> fileMap = {};
 for (final ArchiveFile af in archive) {
 if (af.isFile && af.content != null) {
 fileMap[af.name] = Uint8List.fromList(af.content as List<int>);
 }
 }
 final int baseMs = DateTime.now().millisecondsSinceEpoch;
 int importedPhotos = 0;
 if (fileMap.containsKey('photos_meta.json')) {
 final List<dynamic> metaList =
 jsonDecode(utf8.decode(fileMap['photos_meta.json']!)) as List<dynamic>;
 for (int i = 0; i < metaList.length; i++) {
 final Map<String, dynamic> m = metaList[i] as Map<String, dynamic>;
 final String fn = (m['fileName'] as String?) ?? '';
 final Uint8List? pBytes = fileMap['photos/$fn'];
 if (pBytes == null) continue;
 final String timeStr = (m['time'] as String?) ??
 DateTime.now().toString().substring(0, 16);
 final String folderDate = timeStr.length >= 10
 ? timeStr.substring(0, 10)
 : DateTime.now().toString().substring(0, 10);
 final Directory dayDir = Directory('${docDir.path}/$folderDate');
 if (!await dayDir.exists()) await dayDir.create(recursive: true);
 final String destPath = '${dayDir.path}/zip_imp_${baseMs}_$i.jpg';
 await File(destPath).writeAsBytes(pBytes);
 encodePhotoForHtmlFast(destPath);
 String? afterDest;
 final String? afterFn = m['afterFileName'] as String?;
 if (afterFn != null && fileMap.containsKey('photos/$afterFn')) {
 afterDest = '${dayDir.path}/zip_after_${baseMs}_$i.jpg';
 await File(afterDest).writeAsBytes(fileMap['photos/$afterFn']!);
 encodePhotoForHtmlFast(afterDest);
 }
 final String cat = (m['category'] as String?) ?? '미분류';
 if (cat != '미분류') _customCategories.add(cat);
 widget.photos.add(PhotoItem(
 path: destPath,
 lat: (m['latitude'] as num?)?.toDouble() ?? 37.4984,
 lng: (m['longitude'] as num?)?.toDouble() ?? 127.1324,
 alt: (m['altitude'] as num?)?.toDouble() ?? 0.0,
 acc: (m['accuracy'] as num?)?.toDouble() ?? 1.0,
 azimuth: (m['azimuth'] as num?)?.toDouble() ?? -1.0,
 pitch: (m['pitch'] as num?)?.toDouble() ?? 0.0,
 timestamp: timeStr,
 category: cat,
 memo: (m['memo'] as String?) ?? '',
 afterPath: afterDest,
 ));
 importedPhotos++;
 }
 }
 int importedBps = 0;
 if (fileMap.containsKey('blueprint_config.json')) {
 final Map<String, dynamic> bpCfg =
 jsonDecode(utf8.decode(fileMap['blueprint_config.json']!))
 as Map<String, dynamic>;
 final List<dynamic> bpList = (bpCfg['blueprints'] as List<dynamic>?) ?? [];
 for (int i = 0; i < bpList.length; i++) {
 final Map<String, dynamic> bm = bpList[i] as Map<String, dynamic>;
 final String fn = (bm['fileName'] as String?) ?? '';
 final Uint8List? bBytes = fileMap['blueprint/$fn'];
 if (bBytes == null) continue;
 final String ext = fn.split('.').last;
 final int bpMs = baseMs + i;
 final String destPath = '${docDir.path}/bp_saved_$bpMs.$ext';
 await File(destPath).writeAsBytes(bBytes);
 bm['imagePath'] = destPath;
 final BlueprintItem newBp = BlueprintItem.fromMap(bm, i);
 await _prepareFastBlueprintBytes(newBp);
 _blueprints.add(newBp);
 importedBps++;
 }
 }
 await _persistCategories();
 await _persistPhotoMetadata();
 if (importedBps > 0) {
 _bpGlobalShow = true;
 _activeBpIdx = _blueprints.length - 1;
 await _persistBlueprintConfig();
 }
 setState(() {
 _dateFilter = '전체 보기';
 _categoryFilter = '전체 카테고리';
 _selectedIdx = _visiblePhotos.isNotEmpty ? _visiblePhotos.length - 1 : 0;
 });
 await _refreshAllOverlays(includeBlueprint: true);
 if (mounted) {
 ScaffoldMessenger.of(context).showSnackBar(
 SnackBar(
 content: Text(
 '🎉 ZIP 업로드 완료! 사진 ${importedPhotos}장 + 도면 ${importedBps}개가 복원되었습니다.',
 ),
 ),
 );
 }
 } catch (e) {
 if (mounted) {
 ScaffoldMessenger.of(context).showSnackBar(
 SnackBar(content: Text('ZIP 업로드 오류: $e')),
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
 setState(() {
 _isExporting = true;
 _exportStatusMsg = '📦 ZIP 압축 파일을 생성하는 중...';
 });
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
 if (p.hasAfterPhoto) {
 final File af = File(p.afterPath!);
 final String afterFileName = p.afterPath!.split('/').last;
 final Uint8List aBytes = await af.readAsBytes();
 archive.addFile(
 ArchiveFile('photos/$afterFileName', aBytes.length, aBytes));
 mapItem['afterFileName'] = afterFileName;
 }
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
 setState(() {
 _isExporting = true;
 _exportStatusMsg = '🖼️ 합본 이미지를 생성하는 중...';
 });
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
 img.Image? midImg;
 if (currentPhoto.hasAfterPhoto) {
 final Uint8List afterBytes =
 await File(currentPhoto.afterPath!).readAsBytes();
 final img.Image? decodedAfter = img.decodeImage(afterBytes);
 if (decodedAfter != null) {
 midImg = img.copyResize(decodedAfter, height: targetH);
 }
 }
 final int gap = 12;
 final int totalW = leftImg.width +
 (midImg != null ? midImg.width + gap : 0) +
 rightImg.width +
 gap;
 final img.Image combined = img.Image(width: totalW, height: targetH);
 img.fill(combined, color: img.ColorRgb8(20, 20, 20));
 int curX = 0;
 img.compositeImage(combined, leftImg, dstX: curX, dstY: 0);
 curX += leftImg.width + gap;
 if (midImg != null) {
 img.compositeImage(combined, midImg, dstX: curX, dstY: 0);
 curX += midImg.width + gap;
 }
 img.compositeImage(combined, rightImg, dstX: curX, dstY: 0);
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
 '🖼️ 현장 사진${midImg != null ? "(조치전·조치후)" : ""} & 도면 위치 합본 [카테고리: ${currentPhoto.category}] (${currentPhoto.timestamp})\n위도: ${currentPhoto.lat.toStringAsFixed(6)}, 경도: ${currentPhoto.lng.toStringAsFixed(6)}${currentPhoto.memo.trim().isNotEmpty ? "\n내용: ${currentPhoto.memo.trim()}" : ""}',
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
 final bool isThreeSplit =
 !_bpEditMode && activePhoto != null && activePhoto.hasAfterPhoto;
 Widget buildMemoField(PhotoItem photo) {
 return Container(
 padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
 decoration: BoxDecoration(
 color: Colors.grey[900],
 borderRadius: BorderRadius.circular(8),
 border: Border.all(
 color: Colors.amber.withOpacity(0.75),
 width: 1.2,
 ),
 ),
 child: Row(
 children: [
 const Icon(Icons.edit_note, color: Colors.amber, size: 18),
 const SizedBox(width: 6),
 Expanded(
 child: TextFormField(
 key: ValueKey(photo.path),
 initialValue: photo.memo,
 style: const TextStyle(color: Colors.white, fontSize: 12.5),
 maxLines: 1,
 textInputAction: TextInputAction.done,
 onTapOutside: (_) => FocusScope.of(context).unfocus(),
 decoration: const InputDecoration(
 isDense: true,
 contentPadding: EdgeInsets.symmetric(vertical: 7),
 hintText: '사진 내용을 자유롭게 입력하세요 (자동 저장)',
 hintStyle: TextStyle(color: Colors.white54, fontSize: 12),
 border: InputBorder.none,
 ),
 onChanged: (val) {
 photo.memo = val;
 _persistPhotoMetadata();
 },
 ),
 ),
 ],
 ),
 );
 }
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
 padding: EdgeInsets.only(bottom: isThreeSplit ? 0 : 46),
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
 top: 8,
 left: 8,
 child: Row(
 mainAxisSize: MainAxisSize.min,
 children: [
 if (isThreeSplit)
 Container(
 margin: const EdgeInsets.only(right: 6),
 padding: const EdgeInsets.symmetric(
 horizontal: 7, vertical: 5),
 decoration: BoxDecoration(
 color: Colors.orange[800],
 borderRadius: BorderRadius.circular(6),
 ),
 child: const Text(
 '조치전',
 style: TextStyle(
 color: Colors.white,
 fontSize: 11,
 fontWeight: FontWeight.bold,
 ),
 ),
 ),
 Container(
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
 ],
 ),
 ),
 Positioned(
 top: 8,
 right: 8,
 child: Row(
 mainAxisSize: MainAxisSize.min,
 children: [
 if (!isThreeSplit)
 Padding(
 padding: const EdgeInsets.only(right: 6),
 child: InkWell(
 onTap: () => _showAfterPhotoActionSheet(activePhoto),
 borderRadius: BorderRadius.circular(8),
 child: Container(
 padding: const EdgeInsets.symmetric(
 horizontal: 9, vertical: 6),
 decoration: BoxDecoration(
 color: Colors.green[800]!.withOpacity(0.9),
 borderRadius: BorderRadius.circular(8),
 border: Border.all(
 color: Colors.lightGreenAccent, width: 1.3),
 ),
 child: const Row(
 mainAxisSize: MainAxisSize.min,
 children: [
 Icon(Icons.add_a_photo,
 color: Colors.lightGreenAccent, size: 14),
 SizedBox(width: 4),
 Text(
 '조치후 촬영',
 style: TextStyle(
 color: Colors.white,
 fontSize: 11.5,
 fontWeight: FontWeight.bold,
 ),
 ),
 ],
 ),
 ),
 ),
 ),
 InkWell(
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
 size: 19,
 ),
 ),
 ),
 ],
 ),
 ),
 if (!isThreeSplit)
 Positioned(
 left: 10,
 right: 10,
 bottom: 4,
 child: buildMemoField(activePhoto),
 ),
 ],
 ),
 )
 : Center(
 child: Column(
 mainAxisSize: MainAxisSize.min,
 children: [
 const Text(
 '저장된 사진이 없습니다.',
 style: TextStyle(color: Colors.white70, fontSize: 13),
 ),
 const SizedBox(height: 10),
 ElevatedButton.icon(
 onPressed: _isExporting ? null : _importPhotosFromGallery,
 icon: const Icon(Icons.photo_library, size: 17),
 label: const Text(
 '갤러리에서 기존 사진 불러오기',
 style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
 ),
 style: ElevatedButton.styleFrom(
 backgroundColor: Colors.amber,
 foregroundColor: Colors.black,
 ),
 ),
 const SizedBox(height: 8),
 ElevatedButton.icon(
 onPressed: _isExporting ? null : _showImportProjectDialog,
 icon: const Icon(Icons.file_download, size: 17),
 label: const Text(
 '공유받은 HTML · ZIP 업로드 (사진+도면)',
 style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
 ),
 style: ElevatedButton.styleFrom(
 backgroundColor: Colors.greenAccent[400],
 foregroundColor: Colors.black,
 ),
 ),
 ],
 ),
 ));
 final Widget afterPhotoPane = (activePhoto != null && isThreeSplit)
 ? Container(
 color: Colors.black,
 width: double.infinity,
 height: double.infinity,
 child: Stack(
 children: [
 Padding(
 padding: const EdgeInsets.only(bottom: 42),
 child: InteractiveViewer(
 panEnabled: true,
 boundaryMargin: const EdgeInsets.all(20),
 minScale: 0.5,
 maxScale: 4.0,
 child: Center(
 child: Image.file(
 File(activePhoto.afterPath!),
 fit: BoxFit.contain,
 gaplessPlayback: true,
 ),
 ),
 ),
 ),
 Positioned(
 top: 8,
 left: 8,
 child: Container(
 padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
 decoration: BoxDecoration(
 color: Colors.green[800]!.withOpacity(0.92),
 borderRadius: BorderRadius.circular(6),
 border: Border.all(color: Colors.lightGreenAccent, width: 1.2),
 ),
 child: const Row(
 mainAxisSize: MainAxisSize.min,
 children: [
 Icon(Icons.check_circle, color: Colors.lightGreenAccent, size: 13),
 SizedBox(width: 4),
 Text(
 '조치후 완료',
 style: TextStyle(
 color: Colors.white,
 fontSize: 11,
 fontWeight: FontWeight.bold,
 ),
 ),
 ],
 ),
 ),
 ),
 Positioned(
 top: 8,
 right: 8,
 child: InkWell(
 onTap: () => _showAfterPhotoActionSheet(activePhoto),
 borderRadius: BorderRadius.circular(8),
 child: Container(
 padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
 decoration: BoxDecoration(
 color: Colors.black87,
 borderRadius: BorderRadius.circular(8),
 border: Border.all(color: Colors.lightGreenAccent, width: 1.2),
 ),
 child: const Row(
 mainAxisSize: MainAxisSize.min,
 children: [
 Icon(Icons.cameraswitch, color: Colors.lightGreenAccent, size: 14),
 SizedBox(width: 4),
 Text(
 '조치후 재촬영/관리',
 style: TextStyle(
 color: Colors.lightGreenAccent,
 fontSize: 11,
 fontWeight: FontWeight.bold,
 ),
 ),
 ],
 ),
 ),
 ),
 ),
 Positioned(
 left: 10,
 right: 10,
 bottom: 2,
 child: buildMemoField(activePhoto),
 ),
 ],
 ),
 )
 : const SizedBox.shrink();
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
 Listener(
 behavior: HitTestBehavior.translucent,
 onPointerDown: (e) {
 _tapDownPos = e.localPosition;
 _tapDownMs = DateTime.now().millisecondsSinceEpoch;
 },
 onPointerUp: (e) async {
 if (!_showMyLocation || _bpEditMode || _mapCtrl == null) {
 return;
 }
 final Offset? down = _tapDownPos;
 if (down == null) return;
 if (DateTime.now().millisecondsSinceEpoch - _tapDownMs <
 260 &&
 (e.localPosition - down).distance < 10.0 &&
 _mapWidgetSize.width > 10 &&
 _mapWidgetSize.height > 10) {
 final bounds = _currentMapBounds ??
 await _mapCtrl!.getContentBounds();
 final double tLat = bounds.northEast.latitude -
 (e.localPosition.dy / _mapWidgetSize.height) *
 (bounds.northEast.latitude -
 bounds.southWest.latitude);
 final double tLng = bounds.southWest.longitude +
 (e.localPosition.dx / _mapWidgetSize.width) *
 (bounds.northEast.longitude -
 bounds.southWest.longitude);
 setState(() {
 forcedUserLat = tLat;
 forcedUserLng = tLng;
 });
 await _updateMyLocationMarkerOnly();
 if (mounted) {
 ScaffoldMessenger.of(context).showSnackBar(
 const SnackBar(
 content: Text(
 '내 위치가 강제 이동되었습니다. 촬영 시 이 좌표가 기록됩니다.'),
 duration: Duration(milliseconds: 1200),
 ),
 );
 }
 }
 },
 child: NaverMap(
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
 ),
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
 Positioned(
 top: 10,
 right: 10,
 child: Row(
 mainAxisSize: MainAxisSize.min,
 children: [
 if (activePhoto != null) ...[
 InkWell(
 onTap: () {
 _panMapKeepZoom(activePhoto.lat, activePhoto.lng);
 },
 borderRadius: BorderRadius.circular(8),
 child: Container(
 padding: const EdgeInsets.symmetric(
 horizontal: 9, vertical: 7),
 decoration: BoxDecoration(
 color: Colors.black87,
 borderRadius: BorderRadius.circular(8),
 border: Border.all(
 color: Colors.lightGreenAccent,
 width: 1.2,
 ),
 ),
 child: const Row(
 mainAxisSize: MainAxisSize.min,
 children: [
 Icon(
 Icons.place,
 color: Colors.lightGreenAccent,
 size: 15,
 ),
 SizedBox(width: 3),
 Text(
 '사진위치 이동',
 style: TextStyle(
 color: Colors.white,
 fontSize: 11,
 fontWeight: FontWeight.bold,
 ),
 ),
 ],
 ),
 ),
 ),
 const SizedBox(width: 6),
 ],
 InkWell(
 onTap: _toggleMyLocation,
 borderRadius: BorderRadius.circular(8),
 child: Container(
 padding: const EdgeInsets.symmetric(
 horizontal: 10, vertical: 7),
 decoration: BoxDecoration(
 color:
 _showMyLocation ? Colors.amber : Colors.black87,
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
 ? Icons.my_location
 : Icons.location_searching,
 color: _showMyLocation
 ? Colors.black
 : Colors.white,
 size: 16,
 ),
 const SizedBox(width: 4),
 Text(
 _showMyLocation
 ? (forcedUserLat != null
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
 ),
 ],
 );
 },
 );
 const TextStyle unifiedTopTextStyle = TextStyle(
 fontSize: 11,
 fontWeight: FontWeight.bold,
 );
 return Scaffold(
 backgroundColor: Colors.black,
 resizeToAvoidBottomInset: false,
 appBar: AppBar(
 backgroundColor: Colors.black,
 automaticallyImplyLeading: false,
 titleSpacing: 4,
 toolbarHeight: 48,
 title: Row(
 children: [
 IconButton(
 icon: const Icon(Icons.arrow_back, color: Colors.white, size: 19),
 padding: EdgeInsets.zero,
 constraints: const BoxConstraints(minWidth: 26, minHeight: 34),
 onPressed: () => Navigator.pop(context),
 ),
 const SizedBox(width: 2),
 Container(
 padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
 decoration: BoxDecoration(
 color: Colors.white10,
 borderRadius: BorderRadius.circular(6),
 ),
 child: DropdownButtonHideUnderline(
 child: DropdownButton<String>(
 value: _dateFilter,
 isDense: true,
 dropdownColor: Colors.grey[900],
 style: unifiedTopTextStyle.copyWith(color: Colors.white),
 icon: const Icon(Icons.arrow_drop_down,
 color: Colors.white70, size: 15),
 selectedItemBuilder: (context) {
 return dateTabs.map((d) {
 final String shortLabel =
 (d == '전체 보기') ? '전체날짜' : (d.length >= 10 ? d.substring(5) : d);
 return Align(
 alignment: Alignment.centerLeft,
 child: Text(shortLabel, style: unifiedTopTextStyle),
 );
 }).toList();
 },
 items: dateTabs
 .map(
 (d) => DropdownMenuItem(
 value: d,
 child: Text(
 d == '전체 보기' ? '전체 날짜 보기' : d,
 style: unifiedTopTextStyle,
 ),
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
 ),
 const SizedBox(width: 4),
 Flexible(
 child: Container(
 padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
 decoration: BoxDecoration(
 color: Colors.white10,
 borderRadius: BorderRadius.circular(6),
 ),
 child: DropdownButtonHideUnderline(
 child: DropdownButton<String>(
 value: cats.contains(_categoryFilter)
 ? _categoryFilter
 : '전체 카테고리',
 isDense: true,
 isExpanded: true,
 dropdownColor: Colors.grey[900],
 style: unifiedTopTextStyle.copyWith(color: Colors.amberAccent),
 icon: const Icon(Icons.arrow_drop_down,
 color: Colors.amberAccent, size: 15),
 selectedItemBuilder: (context) {
 return ['전체 카테고리', ...cats].map((c) {
 final String shortCat = (c == '전체 카테고리') ? '전체분류' : c;
 return Align(
 alignment: Alignment.centerLeft,
 child: Text(
 shortCat,
 overflow: TextOverflow.ellipsis,
 style: unifiedTopTextStyle.copyWith(color: Colors.amberAccent),
 ),
 );
 }).toList();
 },
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
 ),
 ),
 const SizedBox(width: 4),
 InkWell(
 onTap: _isExporting ? null : _importPhotosFromGallery,
 borderRadius: BorderRadius.circular(6),
 child: Container(
 padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
 decoration: BoxDecoration(
 color: Colors.lightGreenAccent.withOpacity(0.12),
 borderRadius: BorderRadius.circular(6),
 border: Border.all(color: Colors.lightGreenAccent.withOpacity(0.6)),
 ),
 child: Row(
 mainAxisSize: MainAxisSize.min,
 children: [
 const Icon(Icons.add_a_photo,
 color: Colors.lightGreenAccent, size: 13),
 const SizedBox(width: 3),
 Text(
 '사진',
 style: unifiedTopTextStyle.copyWith(
 color: Colors.lightGreenAccent),
 ),
 ],
 ),
 ),
 ),
 const SizedBox(width: 4),
 InkWell(
 onTap: _isExporting ? null : _showExportOptionsSheet,
 borderRadius: BorderRadius.circular(6),
 child: Container(
 padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
 decoration: BoxDecoration(
 color: Colors.lightBlueAccent.withOpacity(0.12),
 borderRadius: BorderRadius.circular(6),
 border: Border.all(color: Colors.lightBlueAccent.withOpacity(0.6)),
 ),
 child: Row(
 mainAxisSize: MainAxisSize.min,
 children: [
 const Icon(Icons.ios_share,
 color: Colors.lightBlueAccent, size: 13),
 const SizedBox(width: 2),
 Text(
 '공유',
 style: unifiedTopTextStyle.copyWith(
 color: Colors.lightBlueAccent),
 ),
 ],
 ),
 ),
 ),
 const SizedBox(width: 4),
 InkWell(
 onTap: _showBlueprintActionMenuDialog,
 borderRadius: BorderRadius.circular(6),
 child: Container(
 padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
 decoration: BoxDecoration(
 color: Colors.amber.withOpacity(0.14),
 borderRadius: BorderRadius.circular(6),
 border: Border.all(color: Colors.amber.withOpacity(0.7)),
 ),
 child: Row(
 mainAxisSize: MainAxisSize.min,
 children: [
 const Icon(Icons.map, color: Colors.amber, size: 13),
 const SizedBox(width: 2),
 Text(
 '도면',
 style: unifiedTopTextStyle.copyWith(color: Colors.amber),
 ),
 ],
 ),
 ),
 ),
 if (_blueprints.isNotEmpty) ...[
 const SizedBox(width: 3),
 InkWell(
 onTap: _showBlueprintLayerSelectorDialog,
 borderRadius: BorderRadius.circular(6),
 child: Container(
 padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
 decoration: BoxDecoration(
 color: Colors.white10,
 borderRadius: BorderRadius.circular(6),
 border: Border.all(
 color: _hasAnyVisibleBlueprint
 ? Colors.lightGreenAccent
 : Colors.white38,
 ),
 ),
 child: Icon(
 _hasAnyVisibleBlueprint ? Icons.layers : Icons.layers_clear,
 color: _hasAnyVisibleBlueprint
 ? Colors.lightGreenAccent
 : Colors.grey,
 size: 15,
 ),
 ),
 ),
 ],
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
 children: isThreeSplit
 ? [
 Expanded(flex: 1, child: leftOrTopPane),
 const SizedBox(height: 3),
 Expanded(flex: 1, child: afterPhotoPane),
 const SizedBox(height: 3),
 Expanded(flex: 1, child: mapPane),
 ]
 : [
 Expanded(flex: 5, child: leftOrTopPane),
 const SizedBox(height: 4),
 Expanded(flex: 5, child: mapPane),
 ],
 )
 : Row(
 children: isThreeSplit
 ? [
 Expanded(flex: 1, child: leftOrTopPane),
 const SizedBox(width: 3),
 Expanded(flex: 1, child: afterPhotoPane),
 const SizedBox(width: 3),
 Expanded(flex: 1, child: mapPane),
 ]
 : [
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
 final PhotoItem thumbItem = _visiblePhotos[idx];
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
 child: Stack(
 children: [
 Image.file(
 File(thumbItem.path),
 width: 70,
 height: 70,
 cacheWidth: 160,
 fit: BoxFit.cover,
 gaplessPlayback: true,
 ),
 if (thumbItem.hasAfterPhoto)
 Positioned(
 right: 2,
 bottom: 2,
 child: Container(
 padding: const EdgeInsets.symmetric(
 horizontal: 4, vertical: 1),
 decoration: BoxDecoration(
 color: Colors.green[800],
 borderRadius: BorderRadius.circular(4),
 ),
 child: const Text(
 '조치후',
 style: TextStyle(
 color: Colors.white,
 fontSize: 8.5,
 fontWeight: FontWeight.bold,
 ),
 ),
 ),
 ),
 ],
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
 child: Center(
 child: Column(
 mainAxisSize: MainAxisSize.min,
 children: [
 const CircularProgressIndicator(color: Colors.amber),
 const SizedBox(height: 12),
 Text(
 _exportStatusMsg,
 style: const TextStyle(
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
 if (_showMyLocation && _myCurrentPos != null) {
 await _updateMyLocationMarkerOnly();
 }
 }
}
