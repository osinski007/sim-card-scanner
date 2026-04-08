import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/scan_record.dart';
import '../providers/scan_provider.dart';

/// 扫描页面 - 拍照识别模式
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> with WidgetsBindingObserver {
  CameraController? _cameraController;
  TextRecognizer? _textRecognizer;
  
  bool _hasPermission = false;
  bool _isInitialized = false;
  bool _isProcessing = false;
  String? _extractedNumber;
  String? _errorMsg;
  String? _recognizedText;

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
        // 应用进入后台或屏幕熄灭，释放相机资源
        if (_cameraController != null && _isInitialized) {
          debugPrint('释放相机资源');
          _cameraController?.dispose();
          _cameraController = null;
          setState(() {
            _isInitialized = false;
          });
        }
        break;
      case AppLifecycleState.resumed:
        // 应用恢复，重新初始化相机
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
    _cameraController?.dispose();
    _textRecognizer?.close();
    super.dispose();
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
        ResolutionPreset.veryHigh,  // 使用最高分辨率
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,  // 指定JPEG格式
      );

      await _cameraController!.initialize();
      
      // 设置自动对焦
      await _cameraController!.setFocusMode(FocusMode.auto);
      // 设置自动曝光
      await _cameraController!.setExposureMode(ExposureMode.auto);
      
      _textRecognizer = TextRecognizer();
      
      setState(() => _isInitialized = true);
    } catch (e) {
      debugPrint('初始化摄像头失败: $e');
      setState(() => _errorMsg = '初始化摄像头失败: $e');
    }
  }

  Future<void> _takePictureAndRecognize() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    if (_isProcessing) return;

    setState(() {
      _isProcessing = true;
      _extractedNumber = null;
      _recognizedText = null;
    });

    try {
      // 拍照前先锁定对焦和曝光，确保图像清晰
      try {
        await _cameraController!.setFocusMode(FocusMode.locked);
        await _cameraController!.setExposureMode(ExposureMode.locked);
        // 等待100ms让相机稳定
        await Future.delayed(const Duration(milliseconds: 100));
      } catch (_) {
        // 某些设备不支持锁定，忽略错误
      }
      
      // 拍照
      final image = await _cameraController!.takePicture();
      
      // 拍照后恢复自动对焦和曝光
      try {
        await _cameraController!.setFocusMode(FocusMode.auto);
        await _cameraController!.setExposureMode(ExposureMode.auto);
      } catch (_) {}
      
      final file = File(image.path);
      
      // 使用 ML Kit 识别图片
      final inputImage = InputImage.fromFile(file);
      final recognizedText = await _textRecognizer!.processImage(inputImage);
      final text = recognizedText.text;
      
      debugPrint('=== 识别到的文字 ===');
      debugPrint(text);
      debugPrint('===================');
      
      _recognizedText = text;
      
      // 删除临时图片
      try {
        await file.delete();
      } catch (_) {}
      
      // 恢复自动对焦和自动曝光，为下次拍照做准备
      try {
        await _cameraController!.setFocusMode(FocusMode.auto);
        await _cameraController!.setExposureMode(ExposureMode.auto);
      } catch (_) {}

      // 提取 ICCID
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
  
  /// 点击对焦
  Future<void> _onTapDown(TapDownDetails details) async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    
    try {
      // 获取点击位置
      final RenderBox box = context.findRenderObject() as RenderBox;
      final localPosition = box.globalToLocal(details.globalPosition);
      
      // 计算相对位置
      final size = MediaQuery.of(context).size;
      final x = localPosition.dx / size.width;
      final y = localPosition.dy / size.height;
      
      // 设置对焦点
      await _cameraController!.setFocusPoint(Offset(x, y));
      await _cameraController!.setExposurePoint(Offset(x, y));
      
      debugPrint('对焦到: ($x, $y)');
      
      // 短暂震动反馈
      HapticFeedback.lightImpact();
    } catch (e) {
      debugPrint('对焦失败: $e');
    }
  }

  Future<void> _saveRecord() async {
    if (_extractedNumber == null) return;

    // 检查是否已存在相同卡号
    final provider = context.read<ScanProvider>();
    final exists = provider.records.any((r) => r.cardNumber == _extractedNumber);
    
    if (exists) {
      // 卡号已存在，显示提示
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
        ),
      );
      
      setState(() {
        _extractedNumber = null;
        _recognizedText = null;
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
      ),
      body: Column(
        children: [
          // 摄像头预览
          Expanded(
            flex: 3,
            child: GestureDetector(
              onTapDown: _onTapDown,
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
                        color: Colors.white,
                        width: 2,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                
                // 提示文字
                const Positioned(
                  bottom: 16,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Text(
                      '将ICCID对准框内，点击拍照按钮',
                      style: TextStyle(
                        color: Colors.white,
                        backgroundColor: Colors.black54,
                      ),
                    ),
                  ),
                ),
                
                // 处理中遮罩
                if (_isProcessing)
                  Container(
                    color: Colors.black54,
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: Colors.white),
                          SizedBox(height: 16),
                          Text(
                            '正在识别...',
                            style: TextStyle(color: Colors.white),
                          ),
                        ],
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
                  _extractedNumber ?? '点击下方按钮拍照识别',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: _extractedNumber != null ? Colors.green : Colors.grey,
                    fontFamily: 'monospace',
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 16),
                
                // 拍照按钮
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
                ),
                
                // 保存按钮（识别成功后显示）
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
                        onPressed: () {
                          setState(() {
                            _extractedNumber = null;
                            _recognizedText = null;
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}
