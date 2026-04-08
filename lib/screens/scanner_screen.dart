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
      final backCamera = cameras.firstWhere(
        (cam) => cam.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        backCamera,
        ResolutionPreset.veryHigh,
        enableAudio: false,
      );

      await _cameraController!.initialize();
      
      // 初始化文字识别器（使用默认设置）
      _textRecognizer = TextRecognizer();
      
      setState(() => _isInitialized = true);
      
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
      // 每5帧处理一次，避免卡顿
      if (_frameCount % 5 != 0) return;
      await _processImage(image);
    });
  }

  Future<void> _processImage(CameraImage image) async {
    if (_isProcessing || _textRecognizer == null) return;
    
    _isProcessing = true;

    try {
      // 获取相机信息
      final camera = _cameraController?.description;
      if (camera == null) {
        _isProcessing = false;
        return;
      }

      // 创建 InputImage
      final inputImage = _createInputImage(image, camera);
      if (inputImage == null) {
        debugPrint('无法创建 InputImage');
        _isProcessing = false;
        return;
      }

      // 识别文字
      final recognizedText = await _textRecognizer!.processImage(inputImage);
      final text = recognizedText.text;
      
      if (text.isNotEmpty) {
        debugPrint('=== 识别到的原始文字 ===');
        debugPrint(text);
        debugPrint('======================');
      }

      // 提取ICCID号（通常是19-20位数字，以8986开头）
      String? iccid;
      
      // 方法1: 直接匹配8986开头的连续数字
      final iccidMatch = RegExp(r'8986\d{15,16}').firstMatch(text);
      if (iccidMatch != null) {
        iccid = iccidMatch.group(0);
        debugPrint('方法1匹配到ICCID: $iccid');
      }
      
      // 方法2: 移除所有空白后匹配（处理数字分行显示的情况）
      if (iccid == null) {
        final noSpaceText = text.replaceAll(RegExp(r'\s'), '');
        debugPrint('移除空白后: $noSpaceText');
        final noSpaceMatch = RegExp(r'8986\d{15,16}').firstMatch(noSpaceText);
        if (noSpaceMatch != null) {
          iccid = noSpaceMatch.group(0);
          debugPrint('方法2匹配到ICCID: $iccid');
        }
      }
      
      // 方法3: 拼接所有数字后匹配
      if (iccid == null) {
        final allDigits = text.replaceAll(RegExp(r'[^\d]'), '');
        debugPrint('纯数字: $allDigits (长度: ${allDigits.length})');
        if (allDigits.length >= 19 && allDigits.startsWith('8986')) {
          iccid = allDigits.substring(0, allDigits.length >= 20 ? 20 : allDigits.length);
          debugPrint('方法3匹配到ICCID: $iccid');
        } else if (allDigits.length >= 19) {
          // 找8986开头的部分
          final idx = allDigits.indexOf('8986');
          if (idx >= 0 && allDigits.length - idx >= 19) {
            iccid = allDigits.substring(idx, idx + 19);
            debugPrint('方法3b匹配到ICCID: $iccid');
          }
        }
      }

      if (iccid != null && iccid != _extractedNumber) {
        debugPrint('✅ 最终提取卡号: $iccid');
        setState(() {
          _extractedNumber = iccid;
        });
        // 震动反馈
        HapticFeedback.mediumImpact();
      }
      
    } catch (e, stack) {
      debugPrint('识别错误: $e');
      debugPrint('堆栈: $stack');
    }

    _isProcessing = false;
  }

  InputImage? _createInputImage(CameraImage image, CameraDescription camera) {
    try {
      // 计算旋转角度
      final sensorOrientation = camera.sensorOrientation;
      final rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
      if (rotation == null) {
        debugPrint('无效的旋转角度: $sensorOrientation');
        return null;
      }

      // 获取图像格式
      final format = InputImageFormatValue.fromRawValue(image.format.raw);
      if (format == null) {
        debugPrint('无效的图像格式: ${image.format.raw}');
        return null;
      }
      
      debugPrint('图像格式: $format, 尺寸: ${image.width}x${image.height}, 旋转: $rotation');

      // 构建 InputImage
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
      
      // 清空当前识别结果
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
                      color: Colors.transparent,
                    ),
                  ),
                ),
                
                // 角落装饰
                Center(
                  child: SizedBox(
                    width: 300,
                    height: 80,
                    child: CustomPaint(
                      painter: _CornerPainter(
                        color: _extractedNumber != null ? Colors.green : Colors.orange,
                      ),
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

/// 角落装饰画笔
class _CornerPainter extends CustomPainter {
  final Color color;
  
  _CornerPainter({required this.color});
  
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;
    
    final cornerLength = 20.0;
    
    // 左上角
    canvas.drawLine(const Offset(0, cornerLength), Offset.zero, paint);
    canvas.drawLine(Offset.zero, Offset(cornerLength, 0), paint);
    
    // 右上角
    canvas.drawLine(Offset(size.width - cornerLength, 0), Offset(size.width, 0), paint);
    canvas.drawLine(Offset(size.width, 0), Offset(size.width, cornerLength), paint);
    
    // 左下角
    canvas.drawLine(Offset(0, size.height - cornerLength), Offset(0, size.height), paint);
    canvas.drawLine(Offset(0, size.height), Offset(cornerLength, size.height), paint);
    
    // 右下角
    canvas.drawLine(Offset(size.width - cornerLength, size.height), Offset(size.width, size.height), paint);
    canvas.drawLine(Offset(size.width, size.height - cornerLength), Offset(size.width, size.height), paint);
  }
  
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
