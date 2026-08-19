import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:camera/camera.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'providers/scan_provider.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 预热：在应用启动时初始化相机相关组件
  await _warmupCameraComponents();

  runApp(const MyApp());
}

/// 预热相机组件，减少首次使用时的初始化时间
Future<void> _warmupCameraComponents() async {
  try {
    // 并行预热各种组件
    await Future.wait([
      // 预热传统相机插件
      availableCameras().timeout(const Duration(seconds: 2)),

      // 预热 ML Kit 文本识别器
      Future.delayed(const Duration(milliseconds: 100), () {
        TextRecognizer().close(); // 创建并立即关闭以预热模型
      }).timeout(const Duration(seconds: 2)),

      // 预热 mobile_scanner（创建并释放控制器）
      Future.delayed(const Duration(milliseconds: 200), () {
        MobileScannerController(
          detectionSpeed: DetectionSpeed.normal,
          facing: CameraFacing.back,
        ).dispose();
      }).timeout(const Duration(seconds: 2)),
    ], eagerError: true);

    debugPrint('✅ 相机组件预热完成');
  } catch (e) {
    debugPrint('⚠️ 相机组件预热失败（可忽略）: $e');
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => ScanProvider(),
      child: MaterialApp(
        title: '流量卡扫描',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.blue,
            brightness: Brightness.light,
          ),
          useMaterial3: true,
        ),
        home: const HomeScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
