import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/device_binding.dart';
import '../models/scan_record.dart';
import '../providers/scan_provider.dart';
import '../services/database_service.dart';

/// 扫描模式
enum ScanMode { iccid, qr, barcode, bind }

/// 绑定流程步骤
enum _BindStep { device, card }

/// 扫描页面 - ICCID 拍照识别 + 二维码/条形码实时扫描 + 设备-卡绑定
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key, this.onViewRecords});

  /// 跳转到历史记录页的回调
  final VoidCallback? onViewRecords;

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  CameraController? _cameraController;
  TextRecognizer? _textRecognizer;
  BarcodeScanner? _qrScanner;
  BarcodeScanner? _barcodeScanner;

  ScanMode _currentMode = ScanMode.iccid;

  bool _hasPermission = false;
  bool _isInitialized = false;
  bool _isProcessing = false;
  bool _isStreaming = false;
  String? _extractedNumber;
  String? _errorMsg;
  String? _recognizedText;

  // 帧处理节流：跳过部分帧以提高识别成功率
  int _frameCount = 0;
  static const int _frameSkip = 2; // 每3帧处理1帧

  // 绑定模式状态
  _BindStep _bindStep = _BindStep.device;
  String? _bindingDeviceCode;

  // 绑定流程中的重复提示（设备已存在 / 流量卡已存在）
  String? _bindWarning;

  // 连续帧确认状态，用于降低二维码/条形码误识别
  String? _pendingValue;
  int _pendingCount = 0;
  static const int _requiredFrames = 3; // 提高到3帧确认，降低误识

  // 取景框扫描线动画，让扫描区域看起来是实时动态的
  late final AnimationController _scanLineController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('App生命周期状态变化: $state');

    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
        if (_cameraController != null && _isInitialized) {
          debugPrint('释放相机资源');
          _stopStream();
          _cameraController?.dispose();
          _cameraController = null;
          setState(() {
            _isInitialized = false;
            _isStreaming = false;
          });
        }
        break;
      case AppLifecycleState.resumed:
        debugPrint('重新初始化相机');
        if (!_isInitialized) {
          _initCamera();
        }
        break;
      default:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanLineController.dispose();
    _stopStream();
    _cameraController?.dispose();
    _textRecognizer?.close();
    _qrScanner?.close();
    _barcodeScanner?.close();
    super.dispose();
  }

  Future<void> _initCamera() async {
    var status = await Permission.camera.status;
    if (!status.isGranted) {
      status = await Permission.camera.request();
    }

    if (!status.isGranted) {
      setState(() {
        _hasPermission = false;
        _errorMsg = '需要相机权限才能扫描';
      });
      return;
    }

    setState(() => _hasPermission = true);

    try {
      // ML Kit 识别器按需创建一次（构造函数很轻量，模型在首次识别时才加载）
      _textRecognizer ??= TextRecognizer();

      // 二维码扫描器 - 支持常见二维码格式
      _qrScanner ??= BarcodeScanner(
        formats: [
          BarcodeFormat.qrCode,
          BarcodeFormat.dataMatrix,
          BarcodeFormat.aztec, // 支持更多二维码类型
        ],
      );

      // 条形码扫描器 - 明确指定常见条形码格式，提高识别准确率
      _barcodeScanner ??= BarcodeScanner(
        formats: [
          // 一维条形码
          BarcodeFormat.code128,    // 最常见的条形码格式
          BarcodeFormat.code39,     // 字母数字条形码
          BarcodeFormat.code93,     // Code39的改进版
          BarcodeFormat.ean13,      // 商品条码
          BarcodeFormat.ean8,       // 短商品条码
          BarcodeFormat.upca,       // UPC-A
          BarcodeFormat.upce,       // UPC-E
          // 二维条形码
          BarcodeFormat.pdf417,
          BarcodeFormat.dataMatrix,
          // 其他格式
          BarcodeFormat.codabar,
          BarcodeFormat.itf,
        ],
      );

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _errorMsg = '未找到摄像头');
        return;
      }

      final backCamera = cameras.firstWhere(
        (cam) => cam.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
        // 优化识别性能和图像质量
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21 // Android使用NV21格式
            : ImageFormatGroup.bgra8888, // iOS使用BGRA8888
      );

      // 建立 camera2 预览会话（首次打开较慢，属相机系统固有开销）
      await _cameraController!.initialize();

      // 立即标记初始化完成并显示画面，
      // 焦点/曝光设置异步执行，不再阻塞“正在初始化”的等待时间
      setState(() => _isInitialized = true);
      _startStreamIfNeeded();
      _applyFocusSettings();
    } catch (e) {
      debugPrint('初始化摄像头失败: $e');
      setState(() => _errorMsg = '初始化摄像头失败: $e');
    }
  }

  /// 应用焦点/曝光设置（异步执行，不阻塞相机初始化）
  ///
  /// 优化点：
  /// 1. 使用连续自动对焦模式，确保近距离物体也能清晰
  /// 2. 设置合适的曝光点，避免过暗或过亮
  /// 3. 增加重试机制提高成功率
  Future<void> _applyFocusSettings() async {
    final cam = _cameraController;
    if (cam == null || !cam.value.isInitialized) return;

    // 重试几次以确保设置成功
    for (int i = 0; i < 3; i++) {
      try {
        await Future.delayed(Duration(milliseconds: 100 * i));

        // FocusMode.auto 在 Android 上对应 CONTROL_AF_MODE_CONTINUOUS_PICTURE，
        // 即持续自动对焦，对近距离/屏幕上的二维码、条形码识别至关重要，
        // 避免长时间对不上焦导致一直识别失败。
        await cam.setFocusMode(FocusMode.auto);
        await cam.setExposureMode(ExposureMode.auto);

        // 设置中心对焦点和测光点
        await cam.setFocusPoint(const Offset(0.5, 0.5));
        await cam.setExposurePoint(const Offset(0.5, 0.5));

        // 尝试设置更高的帧率以提高识别响应速度
        try {
          await cam.setFlashMode(FlashMode.off);
        } catch (_) {}

        debugPrint('对焦设置应用成功');
        break;
      } catch (e) {
        debugPrint('对焦设置尝试 $i 失败: $e');
        if (i == 2) {
          // 最后一次尝试失败，但不阻塞初始化
          debugPrint('对焦设置最终失败，但相机仍可使用');
        }
      }
    }
  }

  /// 切换扫描模式
  void _onModeChanged(ScanMode mode) {
    if (mode == _currentMode) return;
    _stopStream();
    _clearPendingScan();
    setState(() {
      _currentMode = mode;
      _extractedNumber = null;
      _recognizedText = null;
      _bindWarning = null;
      if (mode != ScanMode.bind) {
        _bindingDeviceCode = null;
        _bindStep = _BindStep.device;
      }
    });
    _startStreamIfNeeded();
    _focusAtCenter();
  }

  void _stopStream() {
    if (_isStreaming && _cameraController != null) {
      try {
        _cameraController!.stopImageStream();
      } catch (e) {
        debugPrint('停止图像流失败: $e');
      }
      _isStreaming = false;
    }
  }

  /// 二维码/条形码/绑定模式启动实时扫描
  void _startStreamIfNeeded() {
    if (_currentMode == ScanMode.iccid) return;
    if (!_isInitialized || _cameraController == null) return;
    if (_isStreaming) return;
    if (_currentMode == ScanMode.bind &&
        _bindingDeviceCode != null &&
        _extractedNumber != null) {
      return;
    }
    if (_currentMode != ScanMode.bind && _extractedNumber != null) return;

    try {
      _cameraController!.startImageStream(_processCameraFrame);
      _isStreaming = true;
    } catch (e) {
      debugPrint('启动图像流失败: $e');
    }

    // 启动图像流后重新触发一次中心对焦，让镜头尽快对准画面中心区域
    _focusAtCenter();
  }

  /// 处理实时帧，识别二维码/条形码
  Future<void> _processCameraFrame(CameraImage cameraImage) async {
    if (_isProcessing) return;

    // 帧节流：每N帧处理一次，避免过度处理导致的性能问题
    _frameCount++;
    if (_frameCount % (_frameSkip + 1) != 0) {
      return;
    }

    _isProcessing = true;

    try {
      final inputImage = _inputImageFromCameraImage(cameraImage);
      if (inputImage == null) return;

      // 绑定模式：先扫设备二维码，再扫流量卡条形码
      if (_currentMode == ScanMode.bind) {
        if (_bindingDeviceCode == null) {
          // 阶段1：识别设备二维码
          if (_bindStep != _BindStep.device) return;
          final barcodes = await _qrScanner?.processImage(inputImage);
          if (barcodes == null || barcodes.isEmpty) return;
          final value = barcodes
              .where((b) => b.rawValue != null && b.rawValue!.isNotEmpty)
              .map((b) => b.rawValue!)
              .firstOrNull;
          if (value == null) return;
          // 连续帧确认，避免误识别
          if (!_confirmStableValue(value)) return;
          debugPrint('✅ 识别到设备码: $value');
          // 不停止图像流，识别后自动切换为扫描流量卡条形码；
          // 保留已识别的流量卡号（设备码重扫场景下不删除条形码结果）
          if (!mounted) return;
          final existing = await context.read<ScanProvider>().findBindingByDeviceCode(value);
          if (!mounted) return;
          setState(() {
            _bindingDeviceCode = value;
            _bindStep = _BindStep.card;
            _bindWarning = existing != null ? '当前设备已存在：已绑定流量卡 ${existing.cardNumber}' : null;
          });
          if (existing != null) {
            _showBindWarning('当前设备已存在：已绑定流量卡 ${existing.cardNumber}');
          }
          HapticFeedback.mediumImpact();
          return;
        }
        // 阶段2：识别流量卡条形码
        if (_extractedNumber != null) return;
        final barcodes = await _barcodeScanner?.processImage(inputImage);
        if (barcodes == null || barcodes.isEmpty) return;
        String? value;
        for (final barcode in barcodes) {
          final v = barcode.rawValue;
          if (v == null || v.isEmpty) continue;
          // 用户尚未更换码时，设备二维码可能仍被识别，跳过与设备码相同的结果
          if (_bindingDeviceCode != null && v == _bindingDeviceCode) continue;
          value = v;
          break;
        }
        if (value == null) return;
        // 连续帧确认，降低误识别
        if (!_confirmStableValue(value)) return;
        debugPrint('✅ 识别到卡号: $value');
        _stopStream();
        if (!mounted) return;
        final existing = await context.read<ScanProvider>().findBindingByCardNumber(value);
        if (!mounted) return;
        setState(() {
          _extractedNumber = value;
          _recognizedText = value;
          _bindWarning = existing != null ? '该流量卡已存在：已绑定设备 ${existing.deviceCode}' : null;
        });
        if (existing != null) {
          _showBindWarning('该流量卡已存在：已绑定设备 ${existing.deviceCode}');
        }
        HapticFeedback.mediumImpact();
        return;
      }

      if (_extractedNumber != null) return;
      final scanner = _currentMode == ScanMode.qr ? _qrScanner : _barcodeScanner;
      if (scanner == null) return;

      final barcodes = await scanner.processImage(inputImage);
      if (barcodes.isEmpty) return;

      String? value;
      for (final barcode in barcodes) {
        final v = barcode.rawValue;
        if (v == null || v.isEmpty) continue;
        value = v;
        break;
      }
      if (value == null) return;
      // 连续帧确认，降低误识别
      if (!_confirmStableValue(value)) return;

      debugPrint('✅ 识别到条码: $value');
      _stopStream();
      if (!mounted) return;
      setState(() {
        _extractedNumber = value;
        _recognizedText = value;
      });
      HapticFeedback.mediumImpact();
    } catch (e) {
      // 单帧处理失败忽略，继续下一帧
    } finally {
      _isProcessing = false;
    }
  }

  /// 连续帧确认：同一值需连续识别 N 次才返回 true，降低误识别率
  bool _confirmStableValue(String value) {
    if (_pendingValue == value) {
      _pendingCount++;
    } else {
      _pendingValue = value;
      _pendingCount = 1;
    }
    if (_pendingCount >= _requiredFrames) {
      _pendingValue = null;
      _pendingCount = 0;
      return true;
    }
    return false;
  }

  void _clearPendingScan() {
    _pendingValue = null;
    _pendingCount = 0;
    _frameCount = 0;
  }

  /// 弹出绑定重复提示
  void _showBindWarning(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.orange.shade700,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 将相机帧转换为 ML Kit InputImage
  ///
  /// 优化点：
  /// 1. 添加图像有效性检查，避免处理损坏数据
  /// 2. 优化 NV21 转换逻辑，确保数据格式正确
  /// 3. 添加更详细的错误日志便于调试
  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final camera = _cameraController?.description;
    if (camera == null) {
      debugPrint('相机描述不可用');
      return null;
    }

    // 验证图像尺寸
    if (image.width <= 0 || image.height <= 0) {
      debugPrint('无效的图像尺寸: ${image.width}x${image.height}');
      return null;
    }

    InputImageRotation imageRotation;
    switch (camera.sensorOrientation) {
      case 90:
        imageRotation = InputImageRotation.rotation90deg;
        break;
      case 180:
        imageRotation = InputImageRotation.rotation180deg;
        break;
      case 270:
        imageRotation = InputImageRotation.rotation270deg;
        break;
      default:
        imageRotation = InputImageRotation.rotation0deg;
    }

    final size = Size(image.width.toDouble(), image.height.toDouble());

    if (Platform.isAndroid) {
      final nv21 = _convertToNv21(image);
      if (nv21 == null) {
        debugPrint('NV21转换失败');
        return null;
      }

      // 验证转换后的数据大小
      final expectedSize = image.width * image.height * 3 ~/ 2;
      if (nv21.length != expectedSize) {
        debugPrint('NV21数据大小不匹配: 期望=$expectedSize, 实际=${nv21.length}');
        return null;
      }

      return InputImage.fromBytes(
        bytes: nv21,
        metadata: InputImageMetadata(
          size: size,
          rotation: imageRotation,
          format: InputImageFormat.nv21,
          bytesPerRow: image.width,
        ),
      );
    }

    // iOS: BGRA8888 直接拼接各平面
    try {
      final bgra = _concatenatePlanes(image.planes);
      final expectedSize = image.width * image.height * 4;
      if (bgra.length != expectedSize) {
        debugPrint('BGRA数据大小不匹配: 期望=$expectedSize, 实际=${bgra.length}');
        return null;
      }

      return InputImage.fromBytes(
        bytes: bgra,
        metadata: InputImageMetadata(
          size: size,
          rotation: imageRotation,
          format: InputImageFormat.bgra8888,
          bytesPerRow: image.planes.first.bytesPerRow,
        ),
      );
    } catch (e) {
      debugPrint('iOS图像转换失败: $e');
      return null;
    }
  }

  Uint8List _concatenatePlanes(List<Plane> planes) {
    final WriteBuffer allBytes = WriteBuffer();
    for (final plane in planes) {
      allBytes.putUint8List(plane.bytes);
    }
    return allBytes.done().buffer.asUint8List();
  }

  /// 将 CameraImage 转换为无行填充的标准 NV21 字节流（Y 平面 + VU 交错）。
  ///
  /// 优化后的转换逻辑，处理两种常见布局：
  /// - Y 平面存在行填充（bytesPerRow > width）时逐行去除填充；
  /// - UV 为分离平面（pixelStride=1）时按 NV21 顺序交错 V、U；
  /// - UV 已交错（pixelStride=2）时直接拷贝。
  ///
  /// 增加了边界检查和错误处理，避免数组越界。
  Uint8List? _convertToNv21(CameraImage image) {
    try {
      final width = image.width;
      final height = image.height;
      if (width <= 0 || height <= 0 || image.planes.length < 3) {
        debugPrint('无效的图像参数: width=$width, height=$height, planes=${image.planes.length}');
        return null;
      }

      final yPlane = image.planes[0];
      final yRowStride = yPlane.bytesPerRow;
      final out = Uint8List(width * height * 3 ~/ 2);
      var outPos = 0;

      // 拷贝 Y 平面，处理行填充
      if (yRowStride == width) {
        // 无行填充，直接拷贝
        if (yPlane.bytes.length >= width * height) {
          out.setRange(0, width * height, yPlane.bytes, 0);
          outPos = width * height;
        } else {
          debugPrint('Y平面数据不足: 需要${width * height}, 实际${yPlane.bytes.length}');
          return null;
        }
      } else {
        // 有行填充，逐行拷贝并去除填充
        for (var row = 0; row < height; row++) {
          final start = row * yRowStride;
          if (start + width > yPlane.bytes.length) {
            debugPrint('Y平面行数据越界: row=$row, start=$start, width=$width, total=${yPlane.bytes.length}');
            return null;
          }
          out.setRange(outPos, outPos + width, yPlane.bytes, start);
          outPos += width;
        }
      }

      final uPlane = image.planes[1];
      final vPlane = image.planes[2];
      final uRowStride = uPlane.bytesPerRow;
      final vRowStride = vPlane.bytesPerRow;
      final uPixelStride = uPlane.bytesPerPixel ?? 1;
      final vPixelStride = vPlane.bytesPerPixel ?? 1;
      final uvWidth = width ~/ 2;
      final uvHeight = height ~/ 2;
      final uvBytes = uvWidth * uvHeight * 2;

      // 验证UV平面数据大小
      if (uPlane.bytes.length < uvBytes / 2 || vPlane.bytes.length < uvBytes / 2) {
        debugPrint('UV平面数据不足');
        return null;
      }

      // 若 UV 已是 NV21 交错布局（pixelStride=2），直接拷贝
      if (uPixelStride == 2 && vPixelStride == 2) {
        if (outPos + uvBytes <= out.length) {
          final uvData = uPlane.bytes.length >= uvBytes ? uPlane.bytes : vPlane.bytes;
          if (uvData.length >= uvBytes) {
            out.setRange(outPos, outPos + uvBytes, uvData, 0);
            return out;
          } else {
            debugPrint('交错UV数据不足: 需要$uvBytes, 实际${uvData.length}');
          }
        } else {
          debugPrint('输出缓冲区溢出');
        }
      }

      // 分离平面：逐像素交错 V、U
      for (var row = 0; row < uvHeight; row++) {
        for (var col = 0; col < uvWidth; col++) {
          final uIndex = row * uRowStride + col * uPixelStride;
          final vIndex = row * vRowStride + col * vPixelStride;

          if (uIndex >= uPlane.bytes.length || vIndex >= vPlane.bytes.length) {
            debugPrint('UV索引越界: uIndex=$uIndex(${uPlane.bytes.length}), vIndex=$vIndex(${vPlane.bytes.length})');
            continue;
          }
          if (outPos + 1 >= out.length) {
            debugPrint('输出缓冲区溢出: outPos=$outPos, length=${out.length}');
            return out;
          }

          out[outPos++] = vPlane.bytes[vIndex];
          out[outPos++] = uPlane.bytes[uIndex];
        }
      }
      return out;
    } catch (e, stackTrace) {
      debugPrint('NV21 转换异常: $e\n$stackTrace');
      return null;
    }
  }

  /// 将对焦/测光点置于画面中央并触发一次对焦
  Future<void> _focusAtCenter() async {
    final cam = _cameraController;
    if (cam == null || !cam.value.isInitialized) return;
    try {
      await cam.setFocusPoint(const Offset(0.5, 0.5));
      await cam.setExposurePoint(const Offset(0.5, 0.5));
    } catch (_) {}
  }

  /// ICCID 模式：拍照并识别
  Future<void> _takePictureAndRecognize() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    if (_isProcessing) return;

    setState(() {
      _isProcessing = true;
      _extractedNumber = null;
      _recognizedText = null;
    });

    try {
      try {
        // setFocusMode(locked) 会触发一次对焦扫描，等待足够时间让镜头稳定
        await _cameraController!.setFocusMode(FocusMode.locked);
        await _cameraController!.setExposureMode(ExposureMode.locked);
        await Future.delayed(const Duration(milliseconds: 400));
      } catch (_) {}

      final image = await _cameraController!.takePicture();

      try {
        await _cameraController!.setFocusMode(FocusMode.auto);
        await _cameraController!.setExposureMode(ExposureMode.auto);
      } catch (_) {}

      final file = File(image.path);
      final inputImage = InputImage.fromFile(file);
      final recognizedText = await _textRecognizer!.processImage(inputImage);
      final text = recognizedText.text;

      debugPrint('=== 识别到的文字 ===');
      debugPrint(text);

      _recognizedText = text;

      try {
        await file.delete();
      } catch (_) {}

      final iccid = _extractIccid(text);

      if (iccid != null) {
        debugPrint('✅ 提取到卡号: $iccid');
        setState(() {
          _extractedNumber = iccid;
        });
        HapticFeedback.mediumImpact();
      } else {
        setState(() {
          _extractedNumber = null;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('未识别到有效卡号，请重新拍照'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('识别错误: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('识别失败: $e')),
        );
      }
    }

    setState(() {
      _isProcessing = false;
    });
  }

  String? _extractIccid(String text) {
    if (text.isEmpty) return null;

    // 方法1: 直接匹配
    final directMatch = RegExp(r'8986\d{15,16}').firstMatch(text);
    if (directMatch != null) return directMatch.group(0);

    // 方法2: 移除空白后匹配
    final noSpaceText = text.replaceAll(RegExp(r'\s'), '');
    final noSpaceMatch = RegExp(r'8986\d{15,16}').firstMatch(noSpaceText);
    if (noSpaceMatch != null) return noSpaceMatch.group(0);

    // 方法3: 提取所有数字后匹配
    final allDigits = text.replaceAll(RegExp(r'[^\d]'), '');
    if (allDigits.startsWith('8986') && allDigits.length >= 19) {
      return allDigits.substring(0, allDigits.length >= 20 ? 20 : allDigits.length);
    }

    final idx = allDigits.indexOf('8986');
    if (idx >= 0 && allDigits.length - idx >= 19) {
      return allDigits.substring(idx, idx + 19);
    }

    // 方法4: 拼接数字块
    final digitBlocks = RegExp(r'\d{4,6}').allMatches(text).map((m) => m.group(0)!).toList();
    if (digitBlocks.isNotEmpty) {
      final joined = digitBlocks.join();
      if (joined.startsWith('8986') && joined.length >= 19) {
        return joined.substring(0, joined.length >= 20 ? 20 : joined.length);
      }
    }

    return null;
  }

  Future<void> _onTapDown(TapDownDetails details) async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;

    try {
      final RenderBox box = context.findRenderObject() as RenderBox;
      final localPosition = box.globalToLocal(details.globalPosition);
      final size = MediaQuery.of(context).size;
      final x = localPosition.dx / size.width;
      final y = localPosition.dy / size.height;

      await _cameraController!.setFocusPoint(Offset(x, y));
      await _cameraController!.setExposurePoint(Offset(x, y));
      HapticFeedback.lightImpact();
    } catch (e) {
      debugPrint('对焦失败: $e');
    }
  }

  /// 清除当前结果并继续扫描
  void _resetResult() {
    _clearPendingScan();
    setState(() {
      _extractedNumber = null;
      _recognizedText = null;
      _bindWarning = null;
      if (_currentMode == ScanMode.bind) {
        _bindingDeviceCode = null;
        _bindStep = _BindStep.device;
      }
    });
    _startStreamIfNeeded();
    _focusAtCenter();
  }

  /// 绑定模式：仅重新扫描设备二维码。
  /// 保留已识别的流量卡号，重扫成功后直接回到确认页，不跳回第1步丢失条形码。
  void _rescanDeviceCode() {
    _stopStream();
    _clearPendingScan();
    setState(() {
      _bindingDeviceCode = null;
      _bindWarning = null;
      _bindStep = _BindStep.device;
    });
    _startStreamIfNeeded();
    _focusAtCenter();
  }

  /// 绑定模式：仅重新扫描流量卡条形码（不影响已识别的设备码）
  void _rescanCardNumber() {
    _stopStream();
    _clearPendingScan();
    setState(() {
      _extractedNumber = null;
      _recognizedText = null;
      _bindWarning = null;
    });
    _startStreamIfNeeded();
    _focusAtCenter();
  }

  /// 绑定模式：确认绑定设备与流量卡
  Future<void> _confirmBinding() async {
    if (_bindingDeviceCode == null || _extractedNumber == null) return;

    final provider = context.read<ScanProvider>();
    final binding = DeviceBinding(
      deviceCode: _bindingDeviceCode!,
      cardNumber: _extractedNumber!,
      boundAt: DateTime.now(),
    );

    final result = await provider.addBinding(binding);

    if (!mounted) return;

    switch (result) {
      case BindingResult.success:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('绑定成功'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: '查看记录',
              textColor: Colors.white,
              onPressed: () => widget.onViewRecords?.call(),
            ),
          ),
        );
        _resetResult();
        break;
      case BindingResult.updated:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('该设备已更新绑定（替换旧卡）'),
            backgroundColor: Colors.blue,
            behavior: SnackBarBehavior.floating,
          ),
        );
        _resetResult();
        break;
      case BindingResult.cardTaken:
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('绑定失败'),
            content: Text('流量卡 $_extractedNumber 已被其他设备绑定。\n如需更换请先在"记录-设备绑定"中解绑。'),
            actions: [
              TextButton(
                child: const Text('确定'),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        );
        break;
    }
  }

  Future<void> _saveRecord() async {
    if (_extractedNumber == null) return;

    final provider = context.read<ScanProvider>();
    final exists = provider.records.any((r) => r.cardNumber == _extractedNumber);

    if (exists) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('卡号已存在'),
            content: Text('卡号 $_extractedNumber 已在记录中，无需重复保存。'),
            actions: [
              TextButton(
                child: const Text('确定'),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        );
      }
      return;
    }

    final record = ScanRecord(
      cardNumber: _extractedNumber!,
      rawText: _recognizedText ?? '',
      scannedAt: DateTime.now(),
    );

    final success = await provider.addRecord(record);

    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已保存: $_extractedNumber'),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: '查看记录',
            textColor: Colors.white,
            onPressed: () => widget.onViewRecords?.call(),
          ),
        ),
      );

      _resetResult();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasPermission) {
      return Scaffold(
        appBar: AppBar(title: const Text('扫描')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.camera_alt, size: 64, color: Colors.grey),
              const SizedBox(height: 16),
              Text(_errorMsg ?? '需要相机权限'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => openAppSettings(),
                child: const Text('打开设置'),
              ),
            ],
          ),
        ),
      );
    }

    if (_errorMsg != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('扫描')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                Text(_errorMsg!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _errorMsg = null;
                      _isInitialized = false;
                    });
                    _initCamera();
                  },
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (!_isInitialized || _cameraController == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('扫描')),
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('正在初始化摄像头...'),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('扫描流量卡'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '查看记录',
            onPressed: () => widget.onViewRecords?.call(),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SegmentedButton<ScanMode>(
              segments: const [
                ButtonSegment(
                  value: ScanMode.iccid,
                  icon: Icon(Icons.sim_card),
                  label: Text('ICCID'),
                ),
                ButtonSegment(
                  value: ScanMode.qr,
                  icon: Icon(Icons.qr_code),
                  label: Text('二维码'),
                ),
                ButtonSegment(
                  value: ScanMode.barcode,
                  icon: Icon(Icons.barcode_reader),
                  label: Text('条形码'),
                ),
                ButtonSegment(
                  value: ScanMode.bind,
                  icon: Icon(Icons.link),
                  label: Text('绑定'),
                ),
              ],
              selected: {_currentMode},
              onSelectionChanged: (selection) {
                _onModeChanged(selection.first);
              },
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: GestureDetector(
              onTapDown: _onTapDown,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildCameraPreview(),
                  _buildScanOverlay(),
                  Positioned(
                    bottom: 16,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Text(
                        _getScanHint(),
                        style: const TextStyle(
                          color: Colors.white,
                          backgroundColor: Colors.black54,
                        ),
                      ),
                    ),
                  ),
                  if (_isProcessing && _currentMode == ScanMode.iccid)
                    Container(
                      color: Colors.black54,
                      child: const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: Colors.white),
                            SizedBox(height: 16),
                            Text('正在识别...', style: TextStyle(color: Colors.white)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              boxShadow: [
                BoxShadow(
                  color: Colors.black12,
                  blurRadius: 10,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: _currentMode == ScanMode.bind
                ? _buildBindPanel()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('识别结果', style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          _extractedNumber ?? _getResultHint(),
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: _extractedNumber != null ? Colors.green : Colors.grey,
                            fontFamily: 'monospace',
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (_currentMode == ScanMode.iccid)
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _isProcessing ? null : _takePictureAndRecognize,
                            icon: const Icon(Icons.camera_alt),
                            label: Text(_isProcessing ? '识别中...' : '拍照识别'),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              backgroundColor: Colors.blue,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        )
                      else
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: null,
                            icon: const Icon(Icons.radar),
                            label: Text(_isStreaming ? '扫描中...' : '扫描已暂停'),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              backgroundColor: Colors.blueGrey.shade200,
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: Colors.blueGrey.shade200,
                              disabledForegroundColor: Colors.white,
                            ),
                          ),
                        ),
                      if (_extractedNumber != null) ...[
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: _saveRecord,
                                icon: const Icon(Icons.save),
                                label: const Text('保存'),
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  backgroundColor: Colors.green,
                                  foregroundColor: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            ElevatedButton.icon(
                              onPressed: _resetResult,
                              icon: const Icon(Icons.refresh),
                              label: const Text('重新扫描'),
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// 相机预览：按镜头真实宽高比以 cover 方式铺满预览区域，且不做缩放变换。
  ///
  /// CameraPreview 内部按当前屏幕方向计算渲染宽高比（竖屏下为 1/aspectRatio），
  /// 这里用相同公式算出能铺满区域的尺寸，再通过纯布局 + 裁剪呈现：
  /// - 不拉伸变形（之前外层误用 AspectRatio(aspectRatio) 把画面压扁了）；
  /// - 不使用 FittedBox/Transform 缩放（部分 Android 设备上相机纹理在变换
  ///   缩放下无法渲染，预览变成灰白色）。
  Widget _buildCameraPreview() {
    final cam = _cameraController;
    if (cam == null || !cam.value.isInitialized) {
      return const SizedBox.shrink();
    }

    final DeviceOrientation orientation = cam.value.previewPauseOrientation ??
        cam.value.lockedCaptureOrientation ??
        cam.value.deviceOrientation;
    final bool landscape = orientation == DeviceOrientation.landscapeLeft ||
        orientation == DeviceOrientation.landscapeRight;
    // 与 CameraPreview 内部一致的渲染宽高比（宽/高）
    final double renderAspect =
        landscape ? cam.value.aspectRatio : 1 / cam.value.aspectRatio;

    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxW = constraints.maxWidth;
        final double maxH = constraints.maxHeight;

        double w;
        double h;
        if (maxW / maxH < renderAspect) {
          // 预览区域比画面更“瘦高”：以高度铺满，两侧溢出后裁剪
          h = maxH;
          w = h * renderAspect;
        } else {
          w = maxW;
          h = w / renderAspect;
        }

        return ClipRect(
          child: Center(
            child: SizedBox(
              width: w,
              height: h,
              child: CameraPreview(cam),
            ),
          ),
        );
      },
    );
  }

  Widget _buildScanOverlay() {
    final double width;
    final double height;
    switch (_currentMode) {
      case ScanMode.iccid:
        width = 360;
        height = 130;
        break;
      case ScanMode.qr:
        width = 300;
        height = 300;
        break;
      case ScanMode.barcode:
        width = 400;
        height = 170;
        break;
      case ScanMode.bind:
        if (_bindStep == _BindStep.device) {
          width = 300;
          height = 300;
        } else {
          width = 400;
          height = 170;
        }
        break;
    }

    final bool showScanLine = _isStreaming && _currentMode != ScanMode.iccid;
    final Color dimColor = Colors.black.withValues(alpha: 0.35);

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;
        final left = (maxW - width) / 2;
        final top = (maxH - height) / 2;
        final right = left + width;
        final bottom = top + height;

        return Stack(
          children: [
            // 取景框四周压暗，突出识别区域
            Positioned(
              left: 0, top: 0, right: 0, height: top,
              child: ColoredBox(color: dimColor),
            ),
            Positioned(
              left: 0, top: bottom, right: 0, height: maxH - bottom,
              child: ColoredBox(color: dimColor),
            ),
            Positioned(
              left: 0, top: top, width: left, height: height,
              child: ColoredBox(color: dimColor),
            ),
            Positioned(
              left: right, top: top, width: maxW - right, height: height,
              child: ColoredBox(color: dimColor),
            ),
            // 取景框
            Positioned(
              left: left,
              top: top,
              width: width,
              height: height,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 2),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            // 动态扫描线（仅在实时扫描时显示）
            if (showScanLine)
              Positioned(
                left: left + 4,
                top: top,
                width: width - 8,
                height: height,
                child: ClipRect(
                  child: AnimatedBuilder(
                    animation: _scanLineController,
                    builder: (context, child) {
                      return Stack(
                        children: [
                          Positioned(
                            top: (height - 8) * _scanLineController.value,
                            left: 0,
                            right: 0,
                            child: Container(
                              height: 2,
                              decoration: const BoxDecoration(
                                color: Colors.greenAccent,
                                boxShadow: [
                                  BoxShadow(color: Colors.greenAccent, blurRadius: 8),
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 底部提示文字
  String _getScanHint() {
    switch (_currentMode) {
      case ScanMode.iccid:
        return '将ICCID对准框内，保持约10~20cm距离，点击拍照';
      case ScanMode.qr:
        return '将二维码对准框内，自动识别';
      case ScanMode.barcode:
        return '将条形码对准框内，自动识别';
      case ScanMode.bind:
        return _bindStep == _BindStep.device
            ? '第1步/共2步：请扫描设备二维码'
            : '第2步/共2步：请扫描流量卡条形码';
    }
  }

  String _getResultHint() {
    switch (_currentMode) {
      case ScanMode.iccid:
        return '点击下方按钮拍照识别';
      case ScanMode.qr:
        return '将二维码对准框内，自动识别';
      case ScanMode.barcode:
        return '将条形码对准框内，自动识别';
      case ScanMode.bind:
        return '请先扫描设备二维码';
    }
  }

  /// 绑定模式操作面板
  Widget _buildBindPanel() {
    final theme = Theme.of(context);

    // 第1步：等待扫描设备二维码
    if (_bindingDeviceCode == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('设备绑定', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          _buildBindWarning(),
          // 重扫设备时保留已识别的流量卡，不丢失条形码结果
          if (_extractedNumber != null) ...[
            _buildBindValueRow('流量卡(保留)', _extractedNumber!, highlight: true),
            const SizedBox(height: 8),
          ],
          _buildStepIndicator(activeStep: 1),
          const SizedBox(height: 12),
          Text(
            '第1步/共2步：请扫描设备二维码',
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey.shade700),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: null,
              icon: const Icon(Icons.radar),
              label: Text(_isStreaming ? '扫描中...' : '扫描已暂停'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                backgroundColor: Colors.blueGrey.shade200,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.blueGrey.shade200,
                disabledForegroundColor: Colors.white,
              ),
            ),
          ),
        ],
      );
    }

    // 第2步：自动扫描流量卡条形码（设备码已识别，无需点击下一步）
    if (_extractedNumber == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('设备绑定', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          _buildBindWarning(),
          _buildBindValueRow(
            '设备码',
            _bindingDeviceCode!,
            onRescan: _rescanDeviceCode,
            rescanTooltip: '重新扫描设备二维码',
          ),
          const SizedBox(height: 12),
          _buildStepIndicator(activeStep: 2),
          const SizedBox(height: 12),
          Text(
            '第2步/共2步：正在扫描流量卡条形码...',
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey.shade700),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: null,
              icon: const Icon(Icons.radar),
              label: Text(_isStreaming ? '扫描中...' : '扫描已暂停'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                backgroundColor: Colors.blueGrey.shade200,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.blueGrey.shade200,
                disabledForegroundColor: Colors.white,
              ),
            ),
          ),
        ],
      );
    }

    // 完成：确认绑定，设备码/卡号均可单独重扫
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('设备绑定', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        _buildBindWarning(),
        _buildBindValueRow(
          '设备码',
          _bindingDeviceCode!,
          onRescan: _rescanDeviceCode,
          rescanTooltip: '重新扫描设备二维码',
        ),
        const SizedBox(height: 4),
        _buildBindValueRow(
          '流量卡',
          _extractedNumber!,
          highlight: true,
          onRescan: _rescanCardNumber,
          rescanTooltip: '重新扫描流量卡条形码',
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _confirmBinding,
            icon: const Icon(Icons.link),
            label: const Text('确认绑定'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  /// 绑定重复提示横幅（设备已存在 / 流量卡已存在）
  Widget _buildBindWarning() {
    final warning = _bindWarning;
    if (warning == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: Colors.orange.shade700),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              warning,
              style: TextStyle(color: Colors.orange.shade900, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  /// 绑定步骤指示器
  Widget _buildStepIndicator({required int activeStep}) {    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildStepDot(1, activeStep >= 1),
        const SizedBox(width: 8),
        const Icon(Icons.arrow_forward, size: 16, color: Colors.grey),
        const SizedBox(width: 8),
        _buildStepDot(2, activeStep >= 2),
      ],
    );
  }

  Widget _buildStepDot(int number, bool active) {
    return CircleAvatar(
      radius: 12,
      backgroundColor: active ? Colors.blue : Colors.grey.shade300,
      child: Text(
        '$number',
        style: TextStyle(
          color: active ? Colors.white : Colors.grey.shade600,
          fontSize: 12,
        ),
      ),
    );
  }

  /// 绑定面板中的键值行（可带单独重扫按钮）
  Widget _buildBindValueRow(
    String label,
    String value, {
    bool highlight = false,
    VoidCallback? onRescan,
    String? rescanTooltip,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: highlight ? Colors.green.shade50 : Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Text(label, style: TextStyle(color: Colors.grey.shade600)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
                color: highlight ? Colors.green.shade700 : Colors.black87,
              ),
            ),
          ),
          if (onRescan != null) ...[
            const SizedBox(width: 4),
            IconButton(
              tooltip: rescanTooltip ?? '重新扫描',
              icon: const Icon(Icons.refresh, size: 20),
              color: Colors.blueGrey,
              visualDensity: VisualDensity.compact,
              onPressed: onRescan,
            ),
          ],
        ],
      ),
    );
  }
}
