# Unraider

Unraider 是一个使用 Flutter 构建的 Unraid 移动端/桌面端管理客户端。项目直接连接 Unraid WebGUI，围绕登录、服务器首页、Docker、虚拟机、共享目录、媒体相册和音乐入口提供轻量的管理与浏览体验。

当前项目仍处于功能迭代阶段。核心管理数据来自 Unraid WebGUI 页面和接口解析；共享目录、媒体浏览与备份入口使用 WebGUI 文件接口及 Android 本地媒体能力。

## 功能特性

### 服务器连接

- 支持 `http://` / `https://` 协议切换。
- 使用 Unraid WebGUI `root` 用户和密码登录。
- 登录表单提供服务器地址、用户名、密码校验和连接状态反馈。
- 支持“记住我”，Android 端通过原生 `SharedPreferences` 保存服务器地址、用户名和协议偏好。

### 服务器主页

- 展示服务器名称、版本、连接状态、CPU、内存、阵列容量和服务摘要。
- 支持服务器图标切换。
- 提供 Docker、虚拟机、共享目录等管理入口。
- 提供相册、音乐等应用入口。

### Docker 与虚拟机管理

- 通过底部导航切换 Docker、虚拟机、共享目录。
- Docker/虚拟机列表支持搜索、状态展示和快捷操作。
- 支持 Docker/虚拟机启动、停止、重启操作。
- 支持进入详情页查看分组信息和执行操作确认。

### 共享目录与媒体

- 共享列表来自 `/mnt/user` 目录读取。
- 共享详情页支持目录进入和文件预览。
- 相册、视频和备份目录选择使用 Unraid 文件接口。
- Android 端可读取本机图片/视频列表、相册分组、缩略图和分片内容，为后续备份任务提供基础能力。

### 音乐页面

- 提供音乐库、歌曲列表和播放器页面。
- 当前音乐数据为前端静态示例，用于完善媒体应用体验。

## 技术栈

- Flutter / Dart
- Material Design
- `http`：访问 Unraid WebGUI 与文件接口
- `permission_handler`：Android 媒体权限检测
- Android MethodChannel：登录偏好、相册偏好、本地媒体读取
- Flutter Widget Test：登录页基础行为测试

## 目录结构

```text
lib/
  main.dart                         应用入口、路由注册
  pages/
    login_page.dart                 WebGUI 登录和连接配置
    main_shell_page.dart            主页、底部导航、管理列表、详情入口
    album_page.dart                 相册、视频、备份设置
    music_page.dart                 音乐库和播放器 UI
    detail_page.dart                服务器详情展示
    register_page.dart              注册页 UI
  services/
    unraid_client.dart              Unraid WebGUI 访问层、HTML/接口解析和数据模型
    login_preferences.dart          登录偏好跨平台封装
    album_preferences.dart          相册备份偏好跨平台封装
    local_media_store.dart          Android 本地媒体 MethodChannel 封装
  widgets/                          通用 UI 组件
  theme/                            主题、颜色和全局样式

android/
  app/src/main/kotlin/.../MainActivity.kt
                                    Android MethodChannel 实现

html/                               原始原型页面和资料
knowledge/                          Unraid 查询资料
test/                               Widget 测试
web/                                Web 启动页、manifest 和图标
windows/ linux/ macos/ ios/         Flutter 平台工程
```

核心数据流：

```text
LoginPage
  -> UnraidWebGuiClient.checkConnection()
  -> MainShellPage
  -> UnraidWebGuiClient.fetchDashboard()
  -> UnraidDashboard / UnraidManagementItem / UnraidFileEntry
  -> 主页、Docker、虚拟机、共享、相册等页面渲染
```

文件与媒体数据流：

```text
共享详情 / 相册 / 备份目录选择
  -> UnraidWebGuiClient.fetchDirectory()
  -> SSH 原生命令列目录 / 创建目录 / 移动 / 删除 / 重命名
  -> SFTP 上传 / 下载文件
  -> UnraidFileEntry / Uint8List

Android 本机媒体
  -> LocalMediaStore
  -> MethodChannel unraider/local_media
  -> Android MediaStore
```

管理操作数据流：

```text
管理列表/详情页
  -> runManagementAction(type, id, action)
  -> Docker / VM WebGUI 管理接口
  -> 刷新 Dashboard
```

## 运行要求

- Flutter SDK，Dart SDK `>=3.4.0 <4.0.0`
- Android Studio 或 Android SDK，构建 Android 时需要
- Visual Studio C++ Desktop workload，构建 Windows 时需要
- Linux 构建机需要 GTK 3 开发依赖
- macOS 构建机需要 Xcode
- 可访问的 Unraid 服务器
- 已启用 Unraid WebGUI，并允许当前客户端访问
- Unraid `root` 用户密码

## 本地开发

```bash
flutter pub get
flutter run
```

指定平台运行：

```bash
flutter run -d windows
flutter run -d chrome
flutter run -d android
```

如果缺少平台目录，可以重新生成 Flutter 平台工程：

```bash
flutter create --platforms=android,ios,web,windows,linux,macos --project-name unraider --no-pub .
```

## 自构建与安装包发布

发布前建议先统一版本号并通过质量检查：

```bash
flutter clean
flutter pub get
flutter analyze
flutter test
```

版本号来自 `pubspec.yaml` 的 `version: 1.0.0+1`，也可以在发布命令里显式指定：

```bash
flutter build <platform> --release --build-name 1.0.0 --build-number 1
```

Flutter 官方构建命令默认把产物写入 `build/`，不会自动写入 `dist/`。如果需要 GitHub Release 那样的统一资产列表，可以在构建后手动从 `build/` 复制或压缩到 `dist/`。

### Android 安装包

仓库的 Android Gradle 配置已启用 `armeabi-v7a`、`arm64-v8a`、`x86_64` ABI 拆分，并生成 universal APK。

```bash
flutter build apk --release --split-per-abi --build-name 1.0.0 --build-number 1
```

| Android 架构 | 适用设备 | 产物 |
|--------------|----------|------|
| `armeabi-v7a` | 32 位 ARM Android 设备 | `build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk` |
| `arm64-v8a` | 主流 64 位 ARM Android 手机、平板 | `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` |
| `x86_64` | Android 模拟器、部分 ChromeOS / x86_64 设备 | `build/app/outputs/flutter-apk/app-x86_64-release.apk` |
| universal | 包含所有 Android ABI 的通用包 | `build/app/outputs/flutter-apk/app-release.apk` |

如果只需要某一个架构，可以使用 `--target-platform`：

```bash
flutter build apk --release --target-platform android-arm64 --build-name 1.0.0 --build-number 1
flutter build apk --release --target-platform android-arm --build-name 1.0.0 --build-number 1
flutter build apk --release --target-platform android-x64 --build-name 1.0.0 --build-number 1
```

发布到 Google Play 或支持 AAB 的渠道时使用 App Bundle：

```bash
flutter build appbundle --release --target-platform android-arm,android-arm64,android-x64 --build-name 1.0.0 --build-number 1
```

产物位置：

```text
build/app/outputs/bundle/release/app-release.aab
```

### 桌面端安装包

当前仓库已包含 `windows/`、`linux/` 和 `macos/` 平台目录。Windows 可以在当前 Windows 构建机上发布；Linux 和 macOS 需要切换到对应宿主系统或 CI runner 构建。

桌面端发布时要打包整个 release bundle 目录，不能只分发可执行文件；Flutter 运行库、插件 DLL / so / dylib 和资源文件都在 bundle 内。

#### Windows x64 / Arm64

```powershell
flutter build windows --release --build-name 1.0.0 --build-number 1
```

| 桌面架构 | 构建环境 | 产物目录 | 发布包 |
|----------|----------|----------|--------|
| `windows-x64` | Windows + Visual Studio C++ Desktop workload | `build/windows/x64/runner/Release/` | 手动压缩整个 `Release/` 目录 |
| `windows-arm64` | Windows on Arm64 + Visual Studio C++ Desktop workload | `build/windows/arm64/runner/Release/` | 手动压缩整个 `Release/` 目录 |

Windows CMake 还提供 `package_release` 目标，可将 release 目录压缩到 `dist/`：

```powershell
cmake --build build/windows/x64 --config Release --target package_release
```

#### Linux

```bash
flutter build linux --release --target-platform linux-x64 --build-name 1.0.0 --build-number 1
```

Linux 交叉编译需要目标架构 sysroot；没有 sysroot 时建议在对应架构的 Linux 构建机上打包。

| 桌面架构 | 推荐构建环境 | 构建命令 | 产物目录 |
|----------|--------------|----------|----------|
| `linux-x64` | x64 Linux | `flutter build linux --release --target-platform linux-x64` | `build/linux/x64/release/bundle/` |
| `linux-arm64` | arm64 Linux，或带 arm64 sysroot 的 Linux | `flutter build linux --release --target-platform linux-arm64 --target-sysroot <arm64-sysroot>` | `build/linux/arm64/release/bundle/` |
| `linux-riscv64` | riscv64 Linux，或带 riscv64 sysroot 的 Linux | `flutter build linux --release --target-platform linux-riscv64 --target-sysroot <riscv64-sysroot>` | `build/linux/riscv64/release/bundle/` |

#### macOS

macOS 需要在 macOS 构建机上构建和签名：

```bash
flutter build macos --release --build-name 1.0.0 --build-number 1
```

| 桌面架构 | 推荐构建环境 | 产物 | 发布包 |
|----------|--------------|------|--------|
| `macos-x64` | Intel macOS 构建机，或在 Xcode 中显式配置 x86_64 | `build/macos/Build/Products/Release/unraider.app` | 手动压缩 `.app` |
| `macos-arm64` | Apple Silicon macOS 构建机，或在 Xcode 中显式配置 arm64 | `build/macos/Build/Products/Release/unraider.app` | 手动压缩 `.app` |
| `macos-universal` | macOS + Xcode universal archive/signing 配置 | `build/macos/Build/Products/Release/unraider.app` | 手动压缩 `.app` |

### Web

```bash
flutter build web --release
```

产物位置：

```text
build/web/
```

Web 端受浏览器跨域和 Unraid WebGUI 会话策略影响，真实环境下可能需要同源部署或反向代理。

### 发布归档清单

1. 确认 `flutter analyze` 和 `flutter test` 通过。
2. 按目标平台和架构运行 Flutter 官方构建命令，产物默认生成在 `build/` 下。
3. 在真实设备或虚拟机上验证安装包可启动：Android 使用 `adb install`，Windows 运行 `unraider.exe`，Linux 运行 `unraider`，macOS 启动 `.app`。
4. 如果要发布到 GitHub Release 或自有下载页，再把需要上传的产物从 `build/` 复制或压缩到 `dist/`。
5. 为发布包生成 SHA256 校验值。
6. 创建 `v1.0.0` 这类版本标签，并上传发布包和校验文件。

Windows PowerShell 生成校验文件：

```powershell
Get-ChildItem dist -File | Where-Object Name -ne 'SHA256SUMS.txt' | ForEach-Object { "$((Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash)  $($_.Name)" } | Set-Content dist\SHA256SUMS.txt
```

Linux 生成校验文件：

```bash
cd dist
rm -f SHA256SUMS.txt
sha256sum * > SHA256SUMS.txt
```

macOS 生成校验文件：

```bash
cd dist
rm -f SHA256SUMS.txt
shasum -a 256 * > SHA256SUMS.txt
```

## 测试与质量检查

运行全部测试：

```bash
flutter test
```

运行静态分析：

```bash
flutter analyze
```

格式化代码：

```bash
dart format lib test
```

当前测试覆盖：

- 登录页基础渲染。
- 已保存登录信息恢复。

## API 与权限说明

- 登录、Dashboard、Docker、虚拟机、共享列表等管理数据来自 Unraid WebGUI。
- Docker/虚拟机操作通过 WebGUI 管理接口执行。
- 文件列表、创建目录、移动、删除和重命名通过 SSH 执行原生命令；上传和下载通过标准 SFTP 执行。
- SSH/SFTP 默认复用登录主机、用户名和密码，并优先从 WebUI/API 配置读取 SSH 端口，读取失败时回退到 22。
- Android 相册页会请求图片/视频权限，并通过 MediaStore 读取本机媒体。
- 登录页只采集服务器地址、用户名和密码。

## 安全说明

- Unraid `root` 密码属于敏感凭据，请避免提交到仓库、截图或公开日志。
- Android 端“记住我”当前使用 `SharedPreferences` 保存偏好，适合本地开发和个人设备使用；如面向生产发布，建议改为平台安全存储。
- 关机/重启等系统电源入口需要谨慎暴露，发布前建议加入更明确的确认与权限边界。

## 路线图

- 将 Android 本机媒体备份从 UI/能力层推进到真实上传任务。
- 将音乐页面接入真实媒体库。
- 补充 Web/桌面端偏好持久化能力。
- 完善桌面端和 Android 端自动化发布流水线与签名配置。

## License

本项目使用 AGPL-3.0，见 [LICENSE](LICENSE)。
