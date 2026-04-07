# 编译指南

## 方式一： GitHub Actions 自动编译（推荐）

### 步骤

1. **创建 GitHub 仓库**
   - 登录 github.com
   - 点击右上角 "+" → "New repository"
   - 名称填 `sim-card-scanner`
   - 设为 Public 或 Private

2. **上传代码**
   ```bash
   cd ~/projects/sim_card_scanner
   
   git init
   git add .
   git commit -m "Initial commit"
   git branch -M main
   git remote add origin https://github.com/你的用户名/sim-card-scanner.git
   git push -u origin main
   ```

3. **等待编译完成**
   - 打开你的仓库页面
   - 点击 "Actions" 标签
   - 等待编译完成（约5-10分钟）

4. **下载 APK**
   - 编译成功后，点击右侧 "Releases"
   - 下载 `sim-scanner-main.apk`
   - 或者从 Actions 页面下载 artifacts

## 方式二： 本地编译

### 前提条件

- Flutter SDK 3.x
- Android Studio / JDK 17
- 已配置 Android SDK

### 编译步骤

```bash
cd ~/projects/sim_card_scanner

# 安装依赖
flutter pub get

# 编译 APK
flutter build apk --release

# APK 位置
# build/app/outputs/flutter-apk/app-release.apk
```

### 安装到手机

```bash
# 通过 adb 安装
adb install build/app/outputs/flutter-apk/app-release.apk

# 或直接复制到手机
cp build/app/outputs/flutter-apk/app-release.apk ~/Desktop/
```

## 常见问题

### Q: 编译报错 "Could not find an option named 'android:name'"
确保使用 Flutter 3.x 和 Gradle 7.x

### Q: 权限问题
确保 AndroidManifest.xml 中声明了相机和存储权限

### Q: 找不到 Flutter SDK
```bash
# 添加到 ~/.bashrc 或 ~/.zshrc
export PATH="$PATH:/path/to/flutter/bin"
```
