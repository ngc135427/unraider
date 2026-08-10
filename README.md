# Unraider

Unraider 是一个使用 Flutter 构建的 Unraid 移动端/桌面端管理客户端。项目直接连接 Unraid WebGUI，提供服务器状态查看、Docker 与虚拟机控制、共享目录管理、远程媒体预览、Android 相册备份和音乐播放等功能。

当前项目仍处于功能迭代阶段。核心管理数据来自 Unraid WebGUI 页面和接口解析；文件与媒体传输可使用 FileBrowser Quantum WebDAV、Android SMB 或 SSH/SFTP，并按可用性自动回退。

## 功能特性

### 服务器连接

- 支持 `http://` / `https://` 协议切换。
- 使用 Unraid WebGUI `root` 用户和密码登录。
- 登录表单提供服务器地址、用户名、密码校验和连接状态反馈。
- 支持“记住我”，Android 端通过原生 `SharedPreferences` 保存服务器地址、用户名、密码和协议偏好。

### 服务器主页

- 展示服务器名称、版本、连接状态、CPU、内存、阵列容量、服务摘要和通知数量。
- 支持服务器图标切换。
- 支持刷新服务器数据，以及关机、重启操作确认。
- 提供 Docker、虚拟机、共享目录等管理入口。
- 提供相册、音乐和远程预览配置入口。

### Docker 与虚拟机管理

- 通过底部导航切换 Docker、虚拟机、共享目录。
- Docker/虚拟机列表支持搜索、状态展示和快捷操作。
- 支持 Docker/虚拟机启动、停止、重启操作。
- 支持进入详情页查看分组信息和执行操作确认。

### 共享目录与媒体

- 共享列表来自 `/mnt/user` 目录读取。
- 共享详情页支持目录进入、返回上级、搜索、排序和刷新。
- 支持新建文件夹、新建空文件、重命名和删除文件或目录。
- 支持图片、视频、音频、PDF 和常见文本文件预览。
- 图片预览支持同目录翻页、缩放和流式缓存。
- 视频预览支持同目录视频翻页、HTTP Range 直连或渐进式缓存、播放/暂停、进度拖动、时长显示和从头播放。
- PDF 预览使用内置 PDF.js 与 WebView 离线打开。
- 可独立配置 FileBrowser Quantum WebDAV 根地址、Unraid 路径映射和 API Token；远程预览优先使用 WebDAV，失败时回退到 SMB/SFTP。

### 相册与备份

- Android 端通过 MediaStore 读取本机照片和视频，按日期分组展示，并支持本机/云端时间线、缩略图、全屏预览和视频播放。
- 支持选择一个或多个本机媒体目录作为备份源，远端路径按设备、来源和原始相对目录组织。
- 首次备份可选择“全部现有媒体”或“仅备份之后新增”，后续按持久化 SQLite 索引执行增量扫描。
- 支持立即同步、暂停、继续和取消；上传任务记录完成、失败、重试、校验和中断恢复状态。
- 上传优先使用 WebDAV，并自动回退到 Android SMB 或 SFTP；可配置同一目标的并发数。
- Android WorkManager 支持周期后台备份和前台集中备份，可限制仅 Wi-Fi 或仅充电时运行，并在通知中展示进度。
- 云端相册支持分页加载和旧版日期目录备份识别。
- 管理页支持按文件名、目录和媒体类型搜索，创建逻辑相册、按 SHA-256 复核精确重复项，以及在远端原件完成大小校验后释放本机空间。

### 音乐页面

- 扫描 Unraid 远程音乐库并展示专辑、歌曲列表和播放器页面。
- 支持 WebDAV 或分片读取的远程音频播放、缓存回退、后台播放通知、迷你播放器和播放队列。
- 支持内嵌歌词与同目录歌词文件解析。

## 技术栈

- Flutter / Dart
- Material Design
- `dartssh2`：SSH/SFTP 目录浏览、文件传输与管理操作
- `http`：访问 Unraid WebGUI、WebDAV 与文件接口
- `just_audio` / `just_audio_background`：音乐播放与后台播放通知
- `video_player` / `wakelock_plus`：本机与远程视频播放、播放期间亮屏
- `webview_flutter`：PDF.js 阅读器承载
- `path_provider`：媒体与 PDF 临时缓存目录
- `permission_handler`：Android 媒体权限检测
- `sqflite`：相册媒体、备份队列和管理索引持久化
- Android MethodChannel：登录/相册/WebDAV 偏好、本地媒体读取、SMB 传输与后台任务
- Android WorkManager、OkHttp、SMBJ：后台媒体发现、前台通知、WebDAV/SMB 上传与下载
- Flutter Widget Test 与单元测试：页面行为、解析、传输、缓存、歌词和相册备份覆盖

## 目录结构

```text
lib/
  main.dart                         应用入口、路由注册
  pages/
    login_page.dart                 WebGUI 登录和连接配置
    main_shell_page.dart            主页状态、底部导航和服务器操作
    management_page.dart            Docker、虚拟机和共享列表
    management_detail_page.dart     管理详情、文件操作和媒体预览
    album_page.dart                 本机/云端相册、同步、管理和设置
    album_widgets.dart              相册时间线、备份状态和管理组件
    music_page.dart                 音乐库和播放器 UI
    video_stream_settings_page.dart FileBrowser Quantum WebDAV 配置
    detail_page.dart                服务器详情展示
    register_page.dart              注册页 UI
  services/
    unraid_client.dart              Unraid WebGUI 访问层、HTML/接口解析和数据模型
    unraid_client_ssh.dart          SSH 命令构建、目录解析和文件传输辅助
    media_cache.dart                图片、视频、PDF 等媒体临时缓存与渐进式下载
    remote_video_stream.dart        WebDAV 视频直连和缓存回退
    music_player_service.dart       音乐播放队列、后台播放和当前曲目状态
    streaming_audio_source.dart     远程音频分片读取
    lyrics_service.dart             LRC/文本歌词发现与解析
    embedded_lyrics.dart            音频文件内嵌歌词解析
    login_preferences.dart          登录偏好跨平台封装
    album_preferences.dart          相册备份偏好跨平台封装
    album_backup_repository.dart    相册与备份 SQLite 持久化索引
    album_backup_discovery.dart     本机媒体增量发现
    album_transfer_engine.dart      前台并发上传、状态与重试
    album_background_service.dart   Android 后台备份通道
    album_management_service.dart   搜索、逻辑相册、重复项和空间释放
    album_preview_cache.dart        相册缩略图与预览缓存
    local_media_store.dart          Android 本地媒体 MethodChannel 封装
  widgets/                          通用 UI 组件
  theme/                            主题、颜色和全局样式

android/
  app/src/main/kotlin/.../MainActivity.kt
                                    Android MethodChannel、MediaStore、SMB/WebDAV 实现
  app/src/main/kotlin/.../AlbumBackgroundWorker.kt
                                    WorkManager 相册发现和后台上传

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
共享详情 / 相册 / 音乐
  -> UnraidWebGuiClient.fetchDirectory()
  -> SSH 原生命令列目录 / 创建目录 / 删除 / 重命名
  -> WebDAV HTTP Range / Android SMB / SFTP 自动回退
  -> UnraidFileEntry / Uint8List

Android 本机媒体
  -> LocalMediaStore
  -> MethodChannel unraider/local_media
  -> Android MediaStore

相册增量备份
  -> AlbumBackupDiscovery / AlbumBackupRepository
  -> AlbumTransferEngine 或 Android WorkManager
  -> WebDAV -> SMB -> SFTP
  -> 远端大小校验与持久化状态更新
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
- 使用共享目录浏览或 SFTP 回退时，Unraid 需要启用 SSH 服务
- 使用 WebDAV 预览和传输时，需要可访问的 FileBrowser Quantum 数据源及 API Token

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

版本号来自 `pubspec.yaml` 的 `version: 0.0.1+1`，也可以在发布命令里显式指定：

```bash
flutter build <platform> --release --build-name 0.0.1 --build-number 1
```

Flutter 官方构建命令默认把产物写入 `build/`，不会自动写入 `dist/`。如果需要 GitHub Release 那样的统一资产列表，可以在构建后手动从 `build/` 复制或压缩到 `dist/`。

### Android 安装包

仓库的 Android Gradle 配置已启用 `armeabi-v7a`、`arm64-v8a`、`x86_64` ABI 拆分，并生成 universal APK。

```bash
flutter build apk --release --split-per-abi --build-name 0.0.1 --build-number 1
```

| Android 架构 | 适用设备 | 产物 |
|--------------|----------|------|
| `armeabi-v7a` | 32 位 ARM Android 设备 | `build/app/outputs/flutter-apk/unraider-armeabi-v7a-release.apk` |
| `arm64-v8a` | 主流 64 位 ARM Android 手机、平板 | `build/app/outputs/flutter-apk/unraider-arm64-v8a-release.apk` |
| `x86_64` | Android 模拟器、部分 ChromeOS / x86_64 设备 | `build/app/outputs/flutter-apk/unraider-x86_64-release.apk` |
| universal | 包含所有 Android ABI 的通用包 | `build/app/outputs/flutter-apk/unraider-release.apk` |

如果只需要某一个架构，可以使用 `--target-platform`：

```bash
flutter build apk --release --target-platform android-arm64 --build-name 0.0.1 --build-number 1
flutter build apk --release --target-platform android-arm --build-name 0.0.1 --build-number 1
flutter build apk --release --target-platform android-x64 --build-name 0.0.1 --build-number 1
```

发布到 Google Play 或支持 AAB 的渠道时使用 App Bundle：

```bash
flutter build appbundle --release --target-platform android-arm,android-arm64,android-x64 --build-name 0.0.1 --build-number 1
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
flutter build windows --release --build-name 0.0.1 --build-number 1
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
flutter build linux --release --target-platform linux-x64 --build-name 0.0.1 --build-number 1
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
flutter build macos --release --build-name 0.0.1 --build-number 1
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
6. 创建 `v0.0.1` 版本标签，并上传发布包和校验文件。

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

- 登录页渲染、表单校验和已保存登录信息恢复。
- 音乐播放器路由、播放控制组件和窄屏布局。
- SSH 目录列表、媒体扫描、路径规范化和 WebGUI 数据解析。
- WebDAV 配置、文件传输选择、Range 读取和媒体缓存策略。
- 音乐歌词候选路径、LRC/纯文本歌词和 MP3、FLAC、Ogg、MP4 内嵌歌词解析。
- Android MediaStore 数据边界、备份路径映射和旧偏好迁移。
- 相册 SQLite 索引、增量发现、任务状态、失败重试、中断恢复和旧备份识别。
- 相册预览缓存、逻辑相册、搜索、精确重复项和空间释放候选筛选。

## API 与权限说明

- 登录、Dashboard、Docker、虚拟机、共享列表等管理数据来自 Unraid WebGUI。
- Docker/虚拟机操作通过 WebGUI 管理接口执行。
- 文件列表、新建目录/文件、删除和重命名通过 SSH 执行；远程内容读取和媒体上传按 WebDAV、Android SMB、SFTP 的可用性选择传输方式。
- SSH/SFTP 默认复用登录主机、用户名和密码，并优先从 WebUI/API 配置读取 SSH 端口，读取失败时使用 22。
- Android 相册页通过 MediaStore 读取本机媒体，并按系统版本请求图片、视频或外部存储读取权限。
- Android 后台相册备份使用 WorkManager 和前台数据同步通知，可按网络、充电、电量和存储状态约束运行。
- 音乐后台播放使用媒体播放前台服务和通知；视频播放期间使用唤醒锁保持屏幕点亮。
- FileBrowser Quantum WebDAV 配置独立保存根地址、Unraid 路径前缀和 API Token。

## 路线图

- 扩展逻辑相册的查看、重命名、移除项目和元数据管理能力。
- 补充 iOS、Web 和桌面端相册索引、偏好持久化与备份能力。
- 补充共享目录、远程媒体预览和 Android 后台任务的集成测试。
- 完善桌面端和 Android 端自动化发布流水线与签名配置。

## License

本项目使用 AGPL-3.0，见 [LICENSE](LICENSE)。
