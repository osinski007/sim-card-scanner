import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:camera/camera.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
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
/// 使用 mobile_scanner 提供高性能条码识别
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key, this.onViewRecords});

  /// 跳转到历史记录页的回调
  final VoidCallback? onViewRecords;

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  // ICCID 模式使用传统相机
  CameraController? _cameraController;
  TextRecognizer? _textRecognizer;

  // 二维码/条形码模式使用 mobile_scanner
  MobileScannerController? _scannerController;

  ScanMode _currentMode = ScanMode.iccid;

  bool _hasPermission = false;
  bool _isInitialized = false;
  bool _isProcessing = false;
  String? _extractedNumber;
  String? _errorMsg;
  String? _recognizedText;

  // 绑定模式状态
  _BindStep _bindStep = _BindStep.device;
  String? _bindingDeviceCode;

  // 绑定流程中的重复提示（设备已存在 / 流量卡已存在）
  String? _bindWarning;

  // 连续帧确认状态，用于降低条形码误识别（二维码不需要）
  String? _pendingValue;
  int _pendingCount = 0;

  // 缩放和对焦控制
  double _zoomScale = 0.0;
  double _minZoomScale = 0.0;
  double _maxZoomScale = 0.0;
  bool _isAutoZooming = false;
  Offset? _focusPoint;

  // 取景框扫描线动画
  late final AnimationController _scanLineController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat(reverse: true);

  // 扫描统计
  int _scanCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 预热：在后台初始化文本识别器，不阻塞 UI
    _initTextRecognizer();

    _initCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('App生命周期状态变化: $state');

    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
        _releaseResources();
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
    _releaseResources();
    _textRecognizer?.close();
    super.dispose();
  }

  void _releaseResources() {
    if (_currentMode == ScanMode.iccid) {
      _cameraController?.dispose();
      _cameraController = null;
    } else {
      _scannerController?.dispose();
      _scannerController = null;
    }
    setState(() {
      _isInitialized = false;
    });
  }

  Future<void> _initCamera() async {
    final startTime = DateTime.now();
    debugPrint('🚀 开始初始化相机');

    // 并行执行权限检查和文本识别器初始化
    final results = await Future.wait([
      _checkCameraPermission(),
      _initTextRecognizer(),
    ]);

    if (!(results[0] as bool)) {
      setState(() {
        _hasPermission = false;
        _errorMsg = '需要相机权限才能扫描';
      });
      return;
    }

    setState(() => _hasPermission = true);

    try {
      if (_currentMode == ScanMode.iccid) {
        await _initTraditionalCamera();
      } else {
        await _initScanner();
      }

      final elapsed = DateTime.now().difference(startTime).inMilliseconds;
      debugPrint('✅ 相机初始化完成: ${elapsed}ms');

      setState(() => _isInitialized = true);
    } catch (e) {
      final elapsed = DateTime.now().difference(startTime).inMilliseconds;
      debugPrint('❌ 初始化摄像头失败 (${elapsed}ms): $e');
      setState(() => _errorMsg = '初始化摄像头失败: $e');
    }
  }

  /// 检查相机权限（优化版本）
  Future<bool> _checkCameraPermission() async {
    final permStart = DateTime.now();
    var status = await Permission.camera.status;
    if (!status.isGranted) {
      status = await Permission.camera.request();
    }
    debugPrint('📋 权限检查: ${DateTime.now().difference(permStart).inMilliseconds}ms');
    return status.isGranted;
  }

  /// 异步初始化文本识别器（避免阻塞）
  Future<void> _initTextRecognizer() async {
    if (_textRecognizer != null) return; // 已初始化

    final mlStart = DateTime.now();
    try {
      _textRecognizer = TextRecognizer();
      // 预热 ML Kit（可选：处理空白图片让模型提前加载）
      debugPrint('🤖 ML Kit 初始化: ${DateTime.now().difference(mlStart).inMilliseconds}ms');
    } catch (e) {
      debugPrint('⚠️ ML Kit 初始化失败: $e');
    }
  }

  /// 初始化传统相机（用于 ICCID 文字识别）
  Future<void> _initTraditionalCamera() async {
    final camStart = DateTime.now();

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
      ResolutionPreset.medium,
      enableAudio: false,
    );

    await _cameraController!.initialize();

    debugPrint('📷 传统相机初始化: ${DateTime.now().difference(camStart).inMilliseconds}ms');

    // 异步设置对焦，不阻塞初始化
    _applyFocusSettings();
  }

  /// 初始化 mobile_scanner（用于二维码/条形码）
  Future<void> _initScanner() async {
    final scanStart = DateTime.now();

    _scannerController = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal, // 使用 normal 而不是 noDuplicates 提高响应速度
      facing: CameraFacing.back,
      torchEnabled: false,
      // 性能优化设置
      returnImage: false, // 不返回图像数据，提高性能
      // 支持所有常见条形码格式
      formats: [
        BarcodeFormat.qrCode,
        BarcodeFormat.dataMatrix,
        BarcodeFormat.aztec,
        BarcodeFormat.code128,
        BarcodeFormat.code39,
        BarcodeFormat.code93,
        BarcodeFormat.ean13,
        BarcodeFormat.ean8,
        BarcodeFormat.pdf417,
        BarcodeFormat.codabar,
        BarcodeFormat.itf,
      ],
    );

    debugPrint('📱 mobile_scanner 初始化: ${DateTime.now().difference(scanStart).inMilliseconds}ms');

    // mobile_scanner 4.0.1: zoomScaleState 范围 0.0-1.0
    _minZoomScale = 0.0;
    _maxZoomScale = 1.0;
    _zoomScale = _scannerController!.zoomScaleState.value;
    debugPrint('🔍 缩放范围: $_minZoomScale - $_maxZoomScale, 当前: $_zoomScale');

    // 监听扫码结果
    _scannerController!.barcodes.listen(
      _handleBarcodeResult,
      onError: (error) {
        debugPrint('扫码错误: $error');
      },
    );
  }

  /// 处理扫码结果
  void _handleBarcodeResult(BarcodeCapture capture) {
    if (_isProcessing) return;
    if (_extractedNumber != null && _currentMode != ScanMode.bind) return;

    final barcode = capture.barcodes.first;
    final rawValue = barcode.rawValue;
    if (rawValue == null || rawValue.isEmpty) return;

    debugPrint('📱 检测到条码: $rawValue (${barcode.format})');

    // 自动放大和对焦到检测到的条形码区域
    _autoZoomAndFocus(capture, barcode);

    // 绑定模式的特殊处理
    if (_currentMode == ScanMode.bind) {
      if (_bindingDeviceCode == null) {
        // 阶段1：识别设备二维码
        if (_bindStep != _BindStep.device) return;

        // 只接受二维码格式作为设备码
        if (barcode.format != BarcodeFormat.qrCode &&
            barcode.format != BarcodeFormat.dataMatrix) {
          return;
        }

        if (!_confirmStableValue(rawValue, isQrCode: true)) {
          debugPrint('设备码确认中...');
          return;
        }

        debugPrint('✅ 识别到设备码: $rawValue');
        _handleDeviceCodeRecognized(rawValue);
        return;
      }

      // 阶段2：识别流量卡条形码
      if (_extractedNumber != null) return;

      // 跳过与设备码相同的结果
      if (rawValue == _bindingDeviceCode) return;

      if (!_confirmStableValue(rawValue)) {
        debugPrint('卡号确认中... ($_pendingCount/2)');
        return;
      }

      debugPrint('✅ 识别到卡号: $rawValue');
      _handleCardNumberRecognized(rawValue);
      return;
    }

    // 普通模式：二维码/条形码识别
    if (_currentMode == ScanMode.qr) {
      // 二维码模式：只接受二维码格式
      if (barcode.format != BarcodeFormat.qrCode &&
          barcode.format != BarcodeFormat.dataMatrix &&
          barcode.format != BarcodeFormat.aztec) {
        return;
      }
    } else if (_currentMode == ScanMode.barcode) {
      // 条形码模式：排除纯二维码格式
      if (barcode.format == BarcodeFormat.qrCode) {
        // 如果检测到二维码而不是条形码，提示用户
        debugPrint('检测到二维码，请使用条形码模式');
        return;
      }
    }

    final isQr = _currentMode == ScanMode.qr ||
        barcode.format == BarcodeFormat.qrCode ||
        barcode.format == BarcodeFormat.dataMatrix ||
        barcode.format == BarcodeFormat.aztec;

    if (!_confirmStableValue(rawValue, isQrCode: isQr)) {
      debugPrint('条码确认中... ($_pendingCount/2)');
      return;
    }

    debugPrint('✅ 识别成功: $rawValue');
    _scanCount++;

    if (!mounted) return;
    setState(() {
      _extractedNumber = rawValue;
      _recognizedText = rawValue;
    });

    HapticFeedback.mediumImpact();
  }

  /// 自动放大和对焦到检测到的条形码
  void _autoZoomAndFocus(BarcodeCapture capture, Barcode barcode) {
    if (_isAutoZooming || _maxZoomScale == 0) return;

    final corners = barcode.corners;
    if (corners.isEmpty) return;

    double centerX = 0;
    double centerY = 0;
    for (final corner in corners) {
      centerX += corner.dx;
      centerY += corner.dy;
    }
    centerX /= corners.length;
    centerY /= corners.length;

    final normalizedX = centerX / capture.size.width;
    final normalizedY = centerY / capture.size.height;

    debugPrint('🎯 条形码位置: ($normalizedX, $normalizedY)');

    // mobile_scanner 4.0.1: zoomScaleState 范围 0.0-1.0，当前缩放低于 0.7 时自动放大
    _zoomScale = _scannerController!.zoomScaleState.value;
    if (_zoomScale < _maxZoomScale * 0.7) {
      _isAutoZooming = true;

      final targetZoom = _zoomScale + (_maxZoomScale - _zoomScale) * 0.3;
      _smoothZoomTo(targetZoom);

      Future.delayed(const Duration(milliseconds: 1500), () {
        _isAutoZooming = false;
      });
    }
  }

  /// 平滑缩放到指定级别
  Future<void> _smoothZoomTo(double targetZoom) async {
    if (_scannerController == null) return;

    final steps = 10;
    final stepSize = (targetZoom - _zoomScale) / steps;

    for (int i = 0; i < steps; i++) {
      final newZoom = _zoomScale + stepSize * (i + 1);
      final clampedZoom = newZoom.clamp(_minZoomScale, _maxZoomScale);

      try {
        await _scannerController!.setZoomScale(clampedZoom);
        setState(() {
          _zoomScale = clampedZoom;
        });
        await Future.delayed(const Duration(milliseconds: 50));
      } catch (e) {
        debugPrint('缩放失败: $e');
        break;
      }
    }
  }

  /// 处理设备码识别
  Future<void> _handleDeviceCodeRecognized(String deviceCode) async {
    if (!mounted) return;
    final existing = await context.read<ScanProvider>().findBindingByDeviceCode(deviceCode);
    if (!mounted) return;

    setState(() {
      _bindingDeviceCode = deviceCode;
      _bindStep = _BindStep.card;
      _bindWarning = existing != null ? '当前设备已存在：已绑定流量卡 ${existing.cardNumber}' : null;
    });

    if (existing != null) {
      _showBindWarning('当前设备已存在：已绑定流量卡 ${existing.cardNumber}');
    }

    HapticFeedback.mediumImpact();
  }

  /// 处理卡号识别
  Future<void> _handleCardNumberRecognized(String cardNumber) async {
    if (!mounted) return;
    final existing = await context.read<ScanProvider>().findBindingByCardNumber(cardNumber);
    if (!mounted) return;

    // 暂停扫描
    _scannerController?.stop();

    setState(() {
      _extractedNumber = cardNumber;
      _recognizedText = cardNumber;
      _bindWarning = existing != null ? '该流量卡已存在：已绑定设备 ${existing.deviceCode}' : null;
    });

    if (existing != null) {
      _showBindWarning('该流量卡已存在：已绑定设备 ${existing.deviceCode}');
    }

    HapticFeedback.mediumImpact();
  }

  /// 连续帧确认：同一值需连续识别 N 次才返回 true
  /// QR码/二维码直接通过（误识别率低），条形码需要连续2帧确认
  bool _confirmStableValue(String value, {bool isQrCode = false}) {
    if (isQrCode) return true;
    if (_pendingValue == value) {
      _pendingCount++;
    } else {
      _pendingValue = value;
      _pendingCount = 1;
    }
    if (_pendingCount >= 2) {
      _pendingValue = null;
      _pendingCount = 0;
      return true;
    }
    return false;
  }

  void _clearPendingScan() {
    _pendingValue = null;
    _pendingCount = 0;
    _scanCount = 0;
  }

  /// 切换扫描模式
  void _onModeChanged(ScanMode mode) {
    if (mode == _currentMode) return;

    // 释放当前资源
    _releaseResources();
    _clearPendingScan();

    setState(() {
      _currentMode = mode;
      _extractedNumber = null;
      _recognizedText = null;
      _bindWarning = null;
      _isInitialized = false;
      if (mode != ScanMode.bind) {
        _bindingDeviceCode = null;
        _bindStep = _BindStep.device;
      }
    });

    // 重新初始化
    _initCamera();
  }

  /// 应用焦点/曝光设置
  Future<void> _applyFocusSettings() async {
    final cam = _cameraController;
    if (cam == null || !cam.value.isInitialized) return;

    try {
      await cam.setFocusMode(FocusMode.auto);
      await cam.setExposureMode(ExposureMode.auto);
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

  /// 清除当前结果并继续扫描
  void _resetResult() {
    _clearPendingScan();
    setState(() {
      _extractedNumber = null;
      _recognizedText = null;
      _bindWarning = null;
      _zoomScale = 0.0;
      _isAutoZooming = false;
      if (_currentMode == ScanMode.bind) {
        _bindingDeviceCode = null;
        _bindStep = _BindStep.device;
        // 重新启动扫描
        _scannerController?.start();
      } else {
        _scannerController?.start();
      }
    });
  }

  /// 绑定模式：仅重新扫描设备二维码
  void _rescanDeviceCode() {
    _clearPendingScan();
    _scannerController?.start();
    setState(() {
      _bindingDeviceCode = null;
      _bindWarning = null;
      _bindStep = _BindStep.device;
    });
  }

  /// 绑定模式：仅重新扫描流量卡条形码
  void _rescanCardNumber() {
    _clearPendingScan();
    _scannerController?.start();
    setState(() {
      _extractedNumber = null;
      _recognizedText = null;
      _bindWarning = null;
    });
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

    if (!_isInitialized) {
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
            child: Stack(
              fit: StackFit.expand,
              children: [
                _currentMode == ScanMode.iccid
                    ? _buildCameraPreview()
                    : _buildScannerPreview(),
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
                : _buildNormalPanel(),
          ),
        ],
      ),
    );
  }

  /// 传统相机预览（ICCID 模式）
  Widget _buildCameraPreview() {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return const SizedBox.shrink();
    }
    return CameraPreview(_cameraController!);
  }

  /// mobile_scanner 预览（二维码/条形码模式）
  Widget _buildScannerPreview() {
    return Stack(
      children: [
        MobileScanner(
          controller: _scannerController!,
          onDetect: _handleBarcodeResult,
          overlay: _buildScanOverlay(),
        ),

        // 缩放控制按钮
        if (_maxZoomScale > 0)
          Positioned(
            right: 16,
            top: 100,
            child: Column(
              children: [
                // 放大按钮
                FloatingActionButton.small(
                  heroTag: 'zoom_in',
                  backgroundColor: Colors.white.withOpacity(0.8),
                  onPressed: _zoomScale < _maxZoomScale ? () => _zoomIn() : null,
                  child: const Icon(Icons.zoom_in, color: Colors.black87),
                ),
                const SizedBox(height: 8),

                // 缩放指示器
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${(_zoomScale * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                // 缩小按钮
                FloatingActionButton.small(
                  heroTag: 'zoom_out',
                  backgroundColor: Colors.white.withOpacity(0.8),
                  onPressed: _zoomScale > _minZoomScale ? () => _zoomOut() : null,
                  child: const Icon(Icons.zoom_out, color: Colors.black87),
                ),
                const SizedBox(height: 8),

                // 重置缩放按钮
                FloatingActionButton.small(
                  heroTag: 'zoom_reset',
                  backgroundColor: Colors.blue.withOpacity(0.8),
                  onPressed: () => _resetZoom(),
                  child: const Icon(Icons.center_focus_strong, color: Colors.white, size: 16),
                ),
              ],
            ),
          ),

        // 自动缩放提示
        if (_isAutoZooming)
          Positioned(
            left: 16,
            top: 100,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.8),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                  SizedBox(width: 8),
                  Text(
                    '自动对焦中...',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// 底部提示文字
  String _getScanHint() {
    switch (_currentMode) {
      case ScanMode.iccid:
        return '将ICCID对准框内，保持约10~20cm距离，点击拍照';
      case ScanMode.qr:
        return '将二维码对准框内，自动识别和放大';
      case ScanMode.barcode:
        return '将条形码对准框内，自动识别和放大';
      case ScanMode.bind:
        return _bindStep == _BindStep.device
            ? '第1步/共2步：请扫描设备二维码'
            : '第2步/共2步：请扫描流量卡条形码';
    }
  }

  Widget _buildNormalPanel() {
    return Column(
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
              label: Text(_extractedNumber != null ? '识别成功' : '扫描中...'),
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
    );
  }

  String _getResultHint() {
    switch (_currentMode) {
      case ScanMode.iccid:
        return '点击下方按钮拍照识别';
      case ScanMode.qr:
        return '将二维码对准框内，自动识别和放大';
      case ScanMode.barcode:
        return '将条形码对准框内，自动识别和放大';
      case ScanMode.bind:
        return '请先扫描设备二维码';
    }
  }

  /// 扫描区域叠加层
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

    final bool showScanLine = _currentMode != ScanMode.iccid;
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
            // 取景框四周压暗
            Positioned(left: 0, top: 0, right: 0, height: top, child: ColoredBox(color: dimColor)),
            Positioned(left: 0, top: bottom, right: 0, height: maxH - bottom, child: ColoredBox(color: dimColor)),
            Positioned(left: 0, top: top, width: left, height: height, child: ColoredBox(color: dimColor)),
            Positioned(left: right, top: top, width: maxW - right, height: height, child: ColoredBox(color: dimColor)),
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
            // 动态扫描线
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
              label: const Text('扫描中...'),
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

    // 第2步：自动扫描流量卡条形码
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
              label: const Text('扫描中...'),
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

    // 完成：确认绑定
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

  /// 绑定重复提示横幅
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
  Widget _buildStepIndicator({required int activeStep}) {
    return Row(
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

  /// 放大
  Future<void> _zoomIn() async {
    if (_scannerController == null || _isAutoZooming) return;

    final newZoom = (_zoomScale + 0.1).clamp(_minZoomScale, _maxZoomScale);
    try {
      await _scannerController!.setZoomScale(newZoom);
      setState(() {
        _zoomScale = newZoom;
      });
      HapticFeedback.lightImpact();
    } catch (e) {
      debugPrint('放大失败: $e');
    }
  }

  /// 缩小
  Future<void> _zoomOut() async {
    if (_scannerController == null || _isAutoZooming) return;

    final newZoom = (_zoomScale - 0.1).clamp(_minZoomScale, _maxZoomScale);
    try {
      await _scannerController!.setZoomScale(newZoom);
      setState(() {
        _zoomScale = newZoom;
      });
      HapticFeedback.lightImpact();
    } catch (e) {
      debugPrint('缩小失败: $e');
    }
  }

  /// 重置缩放
  Future<void> _resetZoom() async {
    if (_scannerController == null) return;

    try {
      await _scannerController!.setZoomScale(_minZoomScale);
      setState(() {
        _zoomScale = _minZoomScale;
        _isAutoZooming = false;
      });
      HapticFeedback.mediumImpact();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('缩放已重置'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      debugPrint('重置缩放失败: $e');
    }
  }
}
