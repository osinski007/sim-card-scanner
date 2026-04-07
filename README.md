# 📱 流量卡扫描工具

[![Flutter](https://img.shields.io/badge/Flutter-3.22-blue)](https://flutter.dev)

[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

[![Platform](https://img.shields.io/badge/Platform-Android%20%20iOS-green)](https://flutter.dev)

一款基于 Flutter 的流量卡编号扫描工具，支持离线文字识别、批量扫描、本地存储。

## ✨ 功能特性

- 📷 **实时扫描** - 打开摄像头实时识别卡号
- 🔢 **离线识别** - 使用 Google ML Kit，无需网络
- 💾 **本地存储** - SQLite 数据库，支持离线查看
- 📋 **历史记录** - 查看所有扫描记录
- 📤 **导出分享** - 支持导出为文本或CSV
- ✏ **批量累计** - 多次扫描结果累积保存

## 📦 截图预览
```
┌─────────────────────┐
│   📷 扫描流量卡      │
│  ┌───────────────┐  │
│  │               │  │
│  │   [摄像头预览]   │  │
│  │   自动识别卡号  │  │
│  │               │  │
│  └───────────────┘  │
│                     │
│  识别结果: 8901234567 │
│  [ ✅ 添加到列表 ]   │
├─────────────────────┤
│  📋 已扫描 (15)       │
│  ─────────────────  │
│  8901234567  15:30   │
│  8901234568  15:31   │
│  8901234569  15:32   │
│                     │
│  [📤 导出] [🗑️清空] │
└─────────────────────┘
```

## 🚀 开始使用

### 方式一： 自己编译（推荐）

1. 安装 Flutter SDK
   ```bash
   # Windows/Mac/Linux
   git clone https://github.com/flutter/flutter.git -b stable
   export PATH="$PATH:`pwd`/flutter/bin"
   flutter doctor
   ```

2. 克隆项目并编译
   ```bash
   cd ~/projects
   git clone <your-repo-url> sim_card_scanner
   cd sim_card_scanner
   flutter pub get
   flutter run
   ```

3. 编译 APK
   ```bash
   # Android
   flutter build apk --release
   
   # iOS (需要 Mac)
   flutter build ios --release
   ```

### 方式二: 使用 GitHub Actions 自动编译

1. Fork 本项目到你的 GitHub
2. 在 GitHub Actions 中配置 secrets:
   - `KEYSTORE_PASSWORD`: Android 签名密钥密码
   - `KEYSTORE_ALIAS`: 密钥别名(可选)
3. Push 代码触发自动编译
4. 从 Releases 下载 APK

## 📋 项目结构
```
sim_card_scanner/
├── android/                # Android 配置
│   └── app/src/main/
│       └── AndroidManifest.xml
├── lib/
│   ├── main.dart           # 应用入口
│   ├── models/
│   │   └── scan_record.dart # 数据模型
│   ├── providers/
│   │   └── scan_provider.dart # 状态管理
│   ├── screens/
│   │   ├── home_screen.dart # 主页面
│   │   ├── scanner_screen.dart # 扫描页
│   │   └── history_screen.dart # 历史记录页
│   └── services/
│       └── database_service.dart # 数据库服务
├── pubspec.yaml            # 依赖配置
└── README.md
```

## 🛠️ 技术栈
- **Flutter** - 跨平台 UI 框架
- **Google ML Kit** - 文字识别(离线)
- **SQLite** - 本地数据库
- **Provider** - 状态管理
- **Camera** - 摄像头访问

- **Share Plus** - 分享功能

## 📝 待开发功能
- [ ] 条码/二维码扫描
- [ ] 云端同步
- [ ] 自定义识别区域
- [ ] 多语言支持
- [ ] 暗黑模式

- [ ] 批量导出为 Excel

## 📄 许可证
MIT License

## 🤝 贡献
欢迎提交 Issue 和 Pull Request!
