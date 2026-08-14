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

class _ScannerScreenState extends State<ScannerScreen> with WidgetsBindingObserver {
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

  // 绑定模式状态
  _BindStep _bindStep = _BindStep.device;
  String? _bindingDeviceCode;

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
      // 提前创建识别器，与摄像头初始化并行加载 ML Kit 模型
      _textRecognizer = TextRecognizer();
      _qrScanner = BarcodeScanner(formats: [BarcodeFormat.qrCode]);
      _barcodeScanner = BarcodeScanner(formats: [BarcodeFormat.all]);

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

      // 焦点/曝光设置不阻塞初始化
      try {
        _cameraController!.setFocusMode(FocusMode.auto);
        _cameraController!.setExposureMode(ExposureMode.auto);
      } catch (_) {}

      setState(() => _isInitialized = true);
      _startStreamIfNeeded();
    } catch (e) {
      debugPrint('初始化摄像头失败: $e');
      setState(() => _errorMsg = '初始化摄像头失败: $e');
    }
  }

  /// 切换扫描模式
  void _onModeChanged(ScanMode mode) {
    if (mode == _currentMode) return;
    _stopStream();
    setState(() {
      _currentMode = mode;
      _extractedNumber = null;
      _recognizedText = null;
      if (mode != ScanMode.bind) {
        _bindingDeviceCode = null;
        _bindStep = _BindStep.device;
      }
    });
    _startStreamIfNeeded();
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
  }

  /// 处理实时帧，识别二维码/条形码
  Future<void> _processCameraFrame(CameraImage cameraImage) async {
    if (_isProcessing) return;
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
          final value = barcodes.where((b) => b.rawValue != null && b.rawValue!.isNotEmpty).map((b) => b.rawValue!).firstOrNull;
          if (value == null) return;
          debugPrint('✅ 识别到设备码: $value');
          _stopStream();
          if (!mounted) return;
          setState(() {
            _bindingDeviceCode = value;
            _bindStep = _BindStep.card;
            _extractedNumber = null;
            _recognizedText = null;
          });
          HapticFeedback.mediumImpact();
          return;
        }
        // 阶段2：识别流量卡条形码
        if (_extractedNumber != null) return;
        final barcodes = await _barcodeScanner?.processImage(inputImage);
        if (barcodes == null || barcodes.isEmpty) return;
        for (final barcode in barcodes) {
          final value = barcode.rawValue;
          if (value == null || value.isEmpty) continue;
          debugPrint('✅ 识别到卡号: $value');
          _stopStream();
          if (!mounted) return;
          setState(() {
            _extractedNumber = value;
            _recognizedText = value;
          });
          HapticFeedback.mediumImpact();
          break;
        }
        return;
      }

      if (_extractedNumber != null) return;
      final scanner = _currentMode == ScanMode.qr ? _qrScanner : _barcodeScanner;
      if (scanner == null) return;

      final barcodes = await scanner.processImage(inputImage);
      if (barcodes.isEmpty) return;

      for (final barcode in barcodes) {
        final value = barcode.rawValue;
        if (value == null || value.isEmpty) continue;

        debugPrint('✅ 识别到条码: $value');
        _stopStream();
        if (!mounted) return;
        setState(() {
          _extractedNumber = value;
          _recognizedText = value;
        });
        HapticFeedback.mediumImpact();
        break;
      }
    } catch (e) {
      // 单帧处理失败忽略，继续下一帧
    } finally {
      _isProcessing = false;
    }
  }

  /// 将相机帧转换为 ML Kit InputImage
  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final camera = _cameraController?.description;
    if (camera == null) return null;

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

    final bytes = _concatenatePlanes(image.planes);
    final size = Size(image.width.toDouble(), image.height.toDouble());
    final format = Platform.isAndroid
        ? InputImageFormat.nv21
        : InputImageFormat.bgra8888;

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: size,
        rotation: imageRotation,
        format: format,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  Uint8List _concatenatePlanes(List<Plane> planes) {
    final WriteBuffer allBytes = WriteBuffer();
    for (final plane in planes) {
      allBytes.putUint8List(plane.bytes);
    }
    return allBytes.done().buffer.asUint8List();
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
        await Future.delayed(const Duration(milliseconds: 100));
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
    setState(() {
      _extractedNumber = null;
      _recognizedText = null;
      if (_currentMode == ScanMode.bind) {
        _bindingDeviceCode = null;
        _bindStep = _BindStep.device;
      }
    });
    _startStreamIfNeeded();
  }

  /// 绑定模式：设备已识别，继续扫描流量卡
  void _proceedToCard() {
    _startStreamIfNeeded();
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
                  CameraPreview(_cameraController!),
                  Center(
                    child: _buildScanOverlay(),
                  ),
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

  /// 扫码取景框，随模式变化
  Widget _buildScanOverlay() {
    final double width;
    final double height;
    switch (_currentMode) {
      case ScanMode.iccid:
        width = 300;
        height = 80;
        break;
      case ScanMode.qr:
        width = 240;
        height = 240;
        break;
      case ScanMode.barcode:
        width = 320;
        height = 120;
        break;
      case ScanMode.bind:
        if (_bindStep == _BindStep.device) {
          width = 240;
          height = 240;
        } else {
          width = 320;
          height = 120;
        }
        break;
    }

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white, width: 2),
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }

  /// 底部提示文字
  String _getScanHint() {
    switch (_currentMode) {
      case ScanMode.iccid:
        return '将ICCID对准框内，点击拍照按钮';
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
          const SizedBox(height: 12),
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

    // 第2步：等待扫描流量卡条形码
    if (_extractedNumber == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('设备绑定', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          _buildBindValueRow('设备码', _bindingDeviceCode!),
          const SizedBox(height: 12),
          _buildStepIndicator(activeStep: 2),
          const SizedBox(height: 12),
          Text(
            '第2步/共2步：请扫描流量卡条形码',
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey.shade700),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _proceedToCard,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('下一步'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    backgroundColor: Colors.blue,
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
      );
    }

    // 完成：确认绑定
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('设备绑定', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        _buildBindValueRow('设备码', _bindingDeviceCode!),
        const SizedBox(height: 4),
        _buildBindValueRow('流量卡', _extractedNumber!, highlight: true),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
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
            const SizedBox(width: 12),
            ElevatedButton.icon(
              onPressed: _resetResult,
              icon: const Icon(Icons.refresh),
              label: const Text('重新开始'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              ),
            ),
          ],
        ),
      ],
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

  /// 绑定面板中的键值行
  Widget _buildBindValueRow(String label, String value, {bool highlight = false}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
        ],
      ),
    );
  }
}
