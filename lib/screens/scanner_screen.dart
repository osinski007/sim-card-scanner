import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/scan_record.dart';
import '../providers/scan_provider.dart';

/// 扫描页面
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  CameraController? _cameraController;
  TextRecognizer? _textRecognizer;
  
  bool _isProcessing = false;
  bool _hasPermission = false;
  bool _isInitialized = false;
  String? _extractedNumber;
  String? _errorMsg;
  int _frameCount = 0;
  CameraDescription? _camera;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    // 检查权限
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
      // 获取可用摄像头
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _errorMsg = '未找到摄像头');
        return;
      }

      // 使用后置摄像头
      _camera = cameras.firstWhere(
        (cam) => cam.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        _camera!,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await _cameraController!.initialize();
      
      // 初始化文字识别器
      _textRecognizer = TextRecognizer();
      
      setState(() => _isInitialized = true);
      
      // 开始图像流
      _startImageStream();
      
    } catch (e) {
      debugPrint('初始化摄像头失败: $e');
      setState(() => _errorMsg = '初始化摄像头失败: $e');
    }
  }
  
  void _startImageStream() {
    _cameraController?.startImageStream((CameraImage image) async {
      _frameCount++;
      // 每8帧处理一次
      if (_frameCount % 8 != 0) return;
      await _processImage(image);
    });
  }

  Future<void> _processImage(CameraImage image) async {
    if (_isProcessing || _textRecognizer == null || _camera == null) return;
    
    _isProcessing = true;

    try {
      // 创建 InputImage
      final inputImage = _createInputImage(image);
      if (inputImage == null) {
        _isProcessing = false;
        return;
      }

      // 识别文字
      final recognizedText = await _textRecognizer!.processImage(inputImage);
      final text = recognizedText.text;
      
      if (text.isNotEmpty) {
        debugPrint('=== 识别到的文字 ===');
        debugPrint(text);
        debugPrint('===================');
      }

      // 提取ICCID号
      String? iccid = _extractIccid(text);

      if (iccid != null && iccid != _extractedNumber) {
        debugPrint('✅ 提取到卡号: $iccid');
        setState(() {
          _extractedNumber = iccid;
        });
        HapticFeedback.mediumImpact();
      }
      
    } catch (e) {
      debugPrint('识别错误: $e');
    }

    _isProcessing = false;
  }

  /// 从识别文字中提取ICCID
  String? _extractIccid(String text) {
    if (text.isEmpty) return null;
    
    // 方法1: 直接匹配8986开头的19-20位数字
    final directMatch = RegExp(r'8986\d{15,16}').firstMatch(text);
    if (directMatch != null) {
      return directMatch.group(0);
    }
    
    // 方法2: 移除所有空白后匹配
    final noSpaceText = text.replaceAll(RegExp(r'\s'), '');
    final noSpaceMatch = RegExp(r'8986\d{15,16}').firstMatch(noSpaceText);
    if (noSpaceMatch != null) {
      return noSpaceMatch.group(0);
    }
    
    // 方法3: 提取所有数字后匹配
    final allDigits = text.replaceAll(RegExp(r'[^\d]'), '');
    if (allDigits.startsWith('8986') && allDigits.length >= 19) {
      return allDigits.substring(0, allDigits.length >= 20 ? 20 : allDigits.length);
    }
    
    // 在数字串中查找8986
    final idx = allDigits.indexOf('8986');
    if (idx >= 0 && allDigits.length - idx >= 19) {
      return allDigits.substring(idx, idx + 19);
    }
    
    // 方法4: 拼接数字块（处理分行显示）
    final digitBlocks = RegExp(r'\d{4,6}').allMatches(text).map((m) => m.group(0)!).toList();
    if (digitBlocks.isNotEmpty) {
      final joined = digitBlocks.join();
      if (joined.startsWith('8986') && joined.length >= 19) {
        return joined.substring(0, joined.length >= 20 ? 20 : joined.length);
      }
    }
    
    return null;
  }

  InputImage? _createInputImage(CameraImage image) {
    try {
      if (_camera == null) return null;
      
      final camera = _camera!;
      
      // 获取旋转角度
      final rotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation);
      if (rotation == null) return null;

      // 获取图像格式
      final format = InputImageFormatValue.fromRawValue(image.format.raw);
      if (format == null) {
        debugPrint('不支持的图像格式: ${image.format.raw}');
        return null;
      }

      debugPrint('格式: $format, 尺寸: ${image.width}x${image.height}, planes: ${image.planes.length}');

      // 只使用 NV21 格式（大多数 Android 设备）
      // 对于其他格式，直接使用 planes[0]
      final plane = image.planes[0];
      
      return InputImage.fromBytes(
        bytes: plane.bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.nv21, // 统一使用 NV21
          bytesPerRow: plane.bytesPerRow,
        ),
      );
    } catch (e) {
      debugPrint('创建 InputImage 失败: $e');
      return null;
    }
  }

  Future<void> _saveRecord() async {
    if (_extractedNumber == null) return;

    final record = ScanRecord(
      cardNumber: _extractedNumber!,
      rawText: '',
      scannedAt: DateTime.now(),
    );

    final success = await context.read<ScanProvider>().addRecord(record);
    
    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已保存: $_extractedNumber'),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ),
      );
      
      setState(() {
        _extractedNumber = null;
      });
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _textRecognizer?.close();
    super.dispose();
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
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() {
                _extractedNumber = null;
              });
            },
            tooltip: '清除识别结果',
          ),
        ],
      ),
      body: Column(
        children: [
          // 摄像头预览
          Expanded(
            flex: 3,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(_cameraController!),
                
                // 扫描框
                Center(
                  child: Container(
                    width: 300,
                    height: 80,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: _extractedNumber != null ? Colors.green : Colors.orange,
                        width: 3,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                
                // 提示文字
                Positioned(
                  bottom: 16,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _extractedNumber != null ? '已识别到卡号' : '将ICCID对准框内',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          // 识别结果
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '识别结果',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  _extractedNumber ?? '等待识别...',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: _extractedNumber != null ? Colors.green : Colors.grey,
                    fontFamily: 'monospace',
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _extractedNumber != null ? _saveRecord : null,
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
                      onPressed: () {
                        setState(() {
                          _extractedNumber = null;
                        });
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('重新扫描'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
