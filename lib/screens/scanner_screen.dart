import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
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
  String _debugInfo = '';
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
      
      setState(() {
        _isInitialized = true;
        _debugInfo = '相机已初始化: ${_camera!.name}\n'
            '传感器角度: ${_camera!.sensorOrientation}°\n'
            '分辨率: ${_cameraController!.value.previewSize}';
      });
      
      // 开始图像流
      _startImageStream();
      
    } catch (e, stack) {
      debugPrint('初始化摄像头失败: $e');
      debugPrint('堆栈: $stack');
      setState(() => _errorMsg = '初始化摄像头失败: $e');
    }
  }
  
  void _startImageStream() {
    _cameraController?.startImageStream((CameraImage image) async {
      _frameCount++;
      // 每10帧处理一次，避免卡顿
      if (_frameCount % 10 != 0) return;
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
        debugPrint('无法创建 InputImage');
        _isProcessing = false;
        return;
      }

      // 识别文字
      final recognizedText = await _textRecognizer!.processImage(inputImage);
      final text = recognizedText.text;
      
      // 更新调试信息
      if (text.isNotEmpty) {
        debugPrint('=== 识别到的文字 ===');
        debugPrint(text);
        debugPrint('==================');
        
        // 保存一张调试图片（仅在调试模式）
        // await _saveDebugImage(image);
      }

      // 提取ICCID号
      String? iccid = _extractIccid(text);

      if (iccid != null && iccid != _extractedNumber) {
        debugPrint('✅ 提取到卡号: $iccid');
        setState(() {
          _extractedNumber = iccid;
        });
        HapticFeedback.mediumImpact();
      } else if (text.isNotEmpty) {
        // 显示识别到但未匹配的文字
        debugPrint('⚠️ 识别到文字但未匹配到ICCID');
      }
      
    } catch (e, stack) {
      debugPrint('识别错误: $e');
      debugPrint('堆栈: $stack');
      setState(() {
        _debugInfo = '识别错误: $e';
      });
    }

    _isProcessing = false;
  }

  /// 从识别文字中提取ICCID
  String? _extractIccid(String text) {
    if (text.isEmpty) return null;
    
    debugPrint('开始提取ICCID，原文长度: ${text.length}');
    
    // 方法1: 直接匹配8986开头的19-20位连续数字
    final directMatch = RegExp(r'8986\d{15,16}').firstMatch(text);
    if (directMatch != null) {
      debugPrint('方法1匹配到ICCID: ${directMatch.group(0)}');
      return directMatch.group(0);
    }
    
    // 方法2: 移除所有空白后匹配（处理数字分行显示的情况）
    final noSpaceText = text.replaceAll(RegExp(r'\s'), '');
    debugPrint('移除空白后: $noSpaceText');
    final noSpaceMatch = RegExp(r'8986\d{15,16}').firstMatch(noSpaceText);
    if (noSpaceMatch != null) {
      debugPrint('方法2匹配到ICCID: ${noSpaceMatch.group(0)}');
      return noSpaceMatch.group(0);
    }
    
    // 方法3: 提取所有数字后匹配
    final allDigits = text.replaceAll(RegExp(r'[^\d]'), '');
    debugPrint('纯数字: $allDigits (长度: ${allDigits.length})');
    
    // 如果数字串以8986开头
    if (allDigits.startsWith('8986') && allDigits.length >= 19) {
      final result = allDigits.substring(0, allDigits.length >= 20 ? 20 : allDigits.length);
      debugPrint('方法3匹配到ICCID: $result');
      return result;
    }
    
    // 在数字串中查找8986开头的部分
    final idx = allDigits.indexOf('8986');
    if (idx >= 0 && allDigits.length - idx >= 19) {
      final result = allDigits.substring(idx, idx + 19);
      debugPrint('方法3b匹配到ICCID: $result');
      return result;
    }
    
    // 方法4: 拼接所有连续5位数字块（处理像 89860 62232 00099 4174 这种情况）
    final digitBlocks = RegExp(r'\d{4,6}').allMatches(text).map((m) => m.group(0)!).toList();
    if (digitBlocks.isNotEmpty) {
      final joined = digitBlocks.join();
      debugPrint('拼接数字块: $joined');
      if (joined.startsWith('8986') && joined.length >= 19) {
        final result = joined.substring(0, joined.length >= 20 ? 20 : joined.length);
        debugPrint('方法4匹配到ICCID: $result');
        return result;
      }
    }
    
    debugPrint('未找到有效ICCID');
    return null;
  }

  InputImage? _createInputImage(CameraImage image) {
    try {
      if (_camera == null) return null;
      
      final camera = _camera!;
      final rotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation);
      if (rotation == null) {
        debugPrint('无效的旋转角度: ${camera.sensorOrientation}');
        return null;
      }

      final format = InputImageFormatValue.fromRawValue(image.format.raw);
      if (format == null) {
        debugPrint('无效的图像格式: ${image.format.raw}');
        return null;
      }
      
      debugPrint('图像: ${image.width}x${image.height}, 格式: $format, 旋转: $rotation, planes: ${image.planes.length}');
      for (var i = 0; i < image.planes.length; i++) {
        debugPrint('  Plane[$i]: ${image.planes[i].bytesPerRow} bytes/row, ${image.planes[i].bytes.length} total');
      }

      // 根据不同格式处理
      switch (format) {
        case InputImageFormat.nv21:
          // NV21 格式
          return InputImage.fromBytes(
            bytes: image.planes[0].bytes,
            metadata: InputImageMetadata(
              size: Size(image.width.toDouble(), image.height.toDouble()),
              rotation: rotation,
              format: format,
              bytesPerRow: image.planes[0].bytesPerRow,
            ),
          );
          
        case InputImageFormat.yuv420:
          // YUV_420_888 格式 - 需要拼接所有平面
          final allBytes = _concatenatePlanes(image);
          if (allBytes == null) return null;
          
          return InputImage.fromBytes(
            bytes: allBytes,
            metadata: InputImageMetadata(
              size: Size(image.width.toDouble(), image.height.toDouble()),
              rotation: rotation,
              format: format,
              bytesPerRow: image.planes[0].bytesPerRow,
            ),
          );
          
        case InputImageFormat.bgra8888:
          // BGRA 8888 格式
          return InputImage.fromBytes(
            bytes: image.planes[0].bytes,
            metadata: InputImageMetadata(
              size: Size(image.width.toDouble(), image.height.toDouble()),
              rotation: rotation,
              format: format,
              bytesPerRow: image.planes[0].bytesPerRow,
            ),
          );
          
        default:
          // 其他格式尝试使用第一个平面
          debugPrint('使用默认格式处理: $format');
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
    } catch (e, stack) {
      debugPrint('创建 InputImage 失败: $e');
      debugPrint('堆栈: $stack');
      return null;
    }
  }
  
  /// 拼接 YUV420 的所有平面
  Uint8List? _concatenatePlanes(CameraImage image) {
    try {
      final int width = image.width;
      final int height = image.height;
      
      // YUV420 总大小 = Y + U + V = width * height * 1.5
      final int ySize = width * height;
      final int uvSize = ySize ~/ 2;
      final int totalSize = ySize + uvSize;
      
      final bytes = Uint8List(totalSize);
      
      // Y 平面
      int offset = 0;
      final yPlane = image.planes[0];
      for (int i = 0; i < height; i++) {
        bytes.setRange(
          offset,
          offset + width,
          yPlane.bytes,
          yPlane.bytesPerRow * i,
        );
        offset += width;
      }
      
      // U 平面
      final uPlane = image.planes[1];
      final uvRowStride = uPlane.bytesPerRow;
      final uvPixelStride = uPlane.bytesPerPixel ?? 1;
      for (int i = 0; i < height ~/ 2; i++) {
        for (int j = 0; j < width ~/ 2; j++) {
          bytes[offset++] = uPlane.bytes[uvRowStride * i + uvPixelStride * j];
        }
      }
      
      // V 平面
      final vPlane = image.planes[2];
      final vRowStride = vPlane.bytesPerRow;
      final vPixelStride = vPlane.bytesPerPixel ?? 1;
      for (int i = 0; i < height ~/ 2; i++) {
        for (int j = 0; j < width ~/ 2; j++) {
          bytes[offset++] = vPlane.bytes[vRowStride * i + vPixelStride * j];
        }
      }
      
      return bytes;
    } catch (e) {
      debugPrint('拼接YUV420失败: $e');
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
            children: const [
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
                _debugInfo = '';
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
                
                // 调试信息（长按显示）
                if (_debugInfo.isNotEmpty)
                  Positioned(
                    top: 8,
                    left: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _debugInfo,
                        style: const TextStyle(color: Colors.white, fontSize: 10),
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
                          _debugInfo = '';
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
