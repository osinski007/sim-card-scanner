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
  String? _lastRecognizedText;
  String? _extractedNumber;
  CameraDescription? _camera;
  String? _errorMsg;

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
        imageFormatGroup: ImageFormatGroup.nv21, // Android 使用 NV21 格式
      );

      await _cameraController!.initialize();
      
      // 初始化文字识别器
      _textRecognizer = TextRecognizer();
      
      setState(() => _isInitialized = true);
      
      // 开始图像流
      await _cameraController!.startImageStream(_processImage);
      
    } catch (e) {
      debugPrint('初始化摄像头失败: $e');
      setState(() => _errorMsg = '初始化摄像头失败: $e');
    }
  }

  Future<void> _processImage(CameraImage image) async {
    if (_isProcessing || _textRecognizer == null || _camera == null) return;
    
    _isProcessing = true;

    try {
      final inputImage = _convertToInputImage(image);
      if (inputImage == null) {
        _isProcessing = false;
        return;
      }

      final recognizedText = await _textRecognizer!.processImage(inputImage);
      final text = recognizedText.text;
      
      debugPrint('识别到文字: $text');

      // 提取数字（流量卡号通常是纯数字，8-20位）
      final numberMatch = RegExp(r'\d{8,20}').firstMatch(text);
      final extractedNumber = numberMatch?.group(0);

      if (extractedNumber != null && extractedNumber != _lastRecognizedText) {
        debugPrint('提取到卡号: $extractedNumber');
        setState(() {
          _lastRecognizedText = extractedNumber;
          _extractedNumber = extractedNumber;
        });
        
        // 震动反馈
        HapticFeedback.mediumImpact();
      } else if (text.isNotEmpty) {
        // 显示识别到的文字（调试用）
        debugPrint('未匹配到卡号，原文: $text');
      }
    } catch (e) {
      debugPrint('识别错误: $e');
    }

    _isProcessing = false;
  }

  InputImage? _convertToInputImage(CameraImage image) {
    try {
      if (_camera == null) return null;
      
      final camera = _camera!;
      final rotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation);
      if (rotation == null) {
        debugPrint('无效的旋转角度: ${camera.sensorOrientation}');
        return null;
      }

      // 获取图像格式
      final format = InputImageFormatValue.fromRawValue(image.format.raw);
      if (format == null) {
        debugPrint('无效的图像格式: ${image.format.raw}');
        return null;
      }

      // NV21 格式处理
      if (format == InputImageFormat.nv21) {
        return InputImage.fromBytes(
          bytes: image.planes[0].bytes,
          metadata: InputImageMetadata(
            size: Size(image.width.toDouble(), image.height.toDouble()),
            rotation: rotation,
            format: format,
            bytesPerRow: image.planes[0].bytesPerRow,
          ),
        );
      }
      
      // YUV_420_888 格式处理 (某些设备)
      if (format == InputImageFormat.yuv420) {
        final plane = image.planes[0];
        return InputImage.fromBytes(
          bytes: plane.bytes,
          metadata: InputImageMetadata(
            size: Size(image.width.toDouble(), image.height.toDouble()),
            rotation: rotation,
            format: format,
            bytesPerRow: plane.bytesPerRow,
          ),
        );
      }
      
      // 其他格式尝试
      return InputImage.fromBytes(
        bytes: image.planes[0].bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: format,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );
    } catch (e) {
      debugPrint('转换图像失败: $e');
      return null;
    }
  }

  Future<void> _saveRecord() async {
    if (_extractedNumber == null) return;

    final record = ScanRecord(
      cardNumber: _extractedNumber!,
      rawText: _lastRecognizedText ?? '',
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
      
      // 清空当前识别结果，准备下一次扫描
      setState(() {
        _extractedNumber = null;
        _lastRecognizedText = null;
      });
    }
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
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
    // 无权限
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

    // 错误状态
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

    // 加载中
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
                    width: 280,
                    height: 120,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.green, width: 3),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                
                // 提示文字
                Positioned(
                  bottom: 20,
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
                      child: const Text(
                        '将流量卡号对准框内',
                        style: TextStyle(color: Colors.white),
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
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _extractedNumber != null ? _saveRecord : null,
                    icon: const Icon(Icons.save),
                    label: const Text('保存到列表'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
