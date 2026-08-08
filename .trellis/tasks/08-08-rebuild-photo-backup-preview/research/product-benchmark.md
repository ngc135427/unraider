# 相册产品能力对标

调研日期：2026-08-08

## 结论摘要

成熟相册产品通常把系统拆成三层：

1. **原始媒体层**：保存不被破坏、可直接恢复的照片和视频。
2. **索引与任务层**：持久化记录媒体身份、元数据、备份状态及后台任务。
3. **派生媒体层**：独立保存小缩略图、大预览图、视频封面和兼容转码。

Unraider 当前主要直接操作第一层，并在打开相册时临时构建部分第二、三层信息。要改善速度与体验，必须把索引和派生媒体变成持久化的一等能力。

## 产品矩阵

| 能力 | Immich | MT Photos | Synology Photos | 飞牛相册 | Nextcloud + Memories / Les Pas | 对 Unraider 的启示 |
|---|---|---|---|---|---|---|
| 手机后台备份 | 选择相册、Wi-Fi、充电、延迟、后台任务 | 后台备份、位置和命名规则 | 后台自动备份、Focused Backup | 全部/新增、节能、流量、不熄屏备份 | Nextcloud 自动上传；Les Pas 每媒体文件夹设置 | 必须脱离页面生命周期，建立可恢复队列 |
| 防重复 | 上传前内容校验和 | MD5 重复检查 | 已备份状态与图库索引 | 跳过已备份照片 | 文件索引/服务端版本信息 | 首次内容指纹 + 日常稳定身份/大小/时间组合 |
| 目录与相册 | 设备相册逻辑同步；Folder View；Storage Template | 文件夹视图、现有目录图库、丰富目录规则 | 文件夹/时间线；物理目录与逻辑相册并存 | 目录偏好、同步创建手机相册 | Nextcloud 文件夹；Les Pas 每媒体目录备份 | 物理文件夹和逻辑相册必须分开建模 |
| 现有图库 | External Libraries，定时扫描 | 挂载任意已有文件夹，不移动原件 | NAS 指定照片目录 | NAS 相册扫描与 Google Photos 导入 | 直接使用 Nextcloud 文件树 | 需要“导入/索引已有目录”，但不能每次全盘扫描 |
| 缩略图 | Thumbhash、小缩略图、大预览图 | 独立缩略图和预览视频缓存 | 服务端/客户端 Image Assistant 生成预览 | 服务端相册预览与 AI 任务 | Nextcloud previews；Memories 优化时间线 | 原图、网格缩略图、详情预览必须分离 |
| 视频 | 后台转码、Range/兼容版本、硬件加速 | 预览视频及转码 | 兼容预览、质量优先/速度优先 | 视频预览、增强识别 | Memories 按需转码和硬件加速 | MVP 先做封面 + Range；兼容转码后置 |
| 大图库 | 数据库、分页、后台 jobs/workers | 数据库、图库扫描、独立缓存 | 连续加载、索引、离线缓存 | 扫描/任务状态、后台索引 | Memories 针对百万级图库优化 | UI 只能消费分页索引，不能直接递归文件树 |
| 搜索整理 | 人物、语义、OCR、路径、标签、地点、相似重复 | 人物、地点、场景、类型、标签、评分、MD5 | 人物、对象、地点、标签、器材、条件相册 | 人物、AI 搜图、智能分类、视频增强 | Recognize/Face Recognition、地图、标签 | MVP 先做元数据筛选；AI 保留可插拔扩展 |
| 手机空间 | Free Up Space，带复核和保留条件 | 下载/备份管理 | 按日期/大小/文件夹释放空间 | 备份后节省空间 | Remote Album 等 | 必须基于“远端已验证”状态，不能只看上传请求成功 |
| 多用户/分享 | 用户、伙伴共享、相册、公开链接 | 多用户、图库权限、分享 | 私人/共享空间、权限、密码/过期链接 | 设备用户共享、查看/添加权限 | Nextcloud 用户、协作相册、公开分享 | 与备份引擎解耦，后续复用 Unraider 账户能力 |
| 数据可移植性 | 原件保留，但上传库依赖数据库管理；外部图库更开放 | 原目录不移动；数据库和缓存可重建 | 文件仍在 NAS，部分相册/人物数据在数据库 | 原件在 NAS，应用元数据另存 | Memories 强调现有文件树和 EXIF | 原件必须普通可读；派生数据可删除重建 |

## 分产品观察

### Immich

值得借鉴：

- 选择设备相册备份，并把手机相册映射为服务端逻辑相册。
- 上传前使用内容校验和防重复；同步语义明确为手机到服务端单向。
- 后台任务支持 Wi-Fi、充电和延迟策略。
- 上传后触发元数据提取、三档缩略图、视频转码、智能搜索和人脸任务。
- API worker 与后台 microservices worker 分离；并发可独立配置。
- 网格显示本地/已同步状态；释放空间前提供扫描和复核。
- Folder View、External Libraries、Storage Template 和 XMP sidecar 兼顾已有目录与元数据可移植性。

不直接照搬：

- Immich 是完整服务端产品，依赖数据库与作业队列；Unraider 的基础能力仍应允许直接访问普通 NAS 目录。
- Immich 上传库默认并不等同于保留 Android 真实目录；Unraider 明确要求保留源相对路径。

官方资料：

- https://docs.immich.app/features/mobile-backup/
- https://docs.immich.app/features/mobile-app/
- https://docs.immich.app/features/folder-view/
- https://docs.immich.app/features/libraries/
- https://docs.immich.app/administration/jobs-workers/
- https://docs.immich.app/administration/system-settings/
- https://docs.immich.app/features/searching/
- https://docs.immich.app/features/duplicates-utility/

### MT Photos

值得借鉴：

- 时间线与文件夹视图并存，图库可以直接索引已有文件夹而不移动原件。
- 手机备份支持目标位置、目录生成规则、按拍摄日期重命名和后台运行。
- 原件、数据库、缩略图/预览视频缓存分目录保存。
- 基于路径、mtime 的常规图库扫描与显式检查模式分开。
- 支持 Live Photos、RAW、人物、地点、场景、类型、标签、备注、评分、重复检查、分享与多用户。
- 缩略图目录使用标记文件避免被再次扫描，体现“派生媒体不可进入原件索引”的边界。

不直接照搬：

- 定时全图库扫描适合服务端挂载目录，但不适合作为手机端每次确认备份状态的机制。
- AI、转码和完整多用户图库属于可选服务端能力，不应阻塞基础备份 MVP。

官方资料：

- https://mtmt.tech/docs/start/introduction/
- https://mtmt.tech/docs/guide/gallery_manage/
- https://mtmt.tech/docs/start/faq/
- https://mtmt.tech/docs/advanced/upgrade/

### Synology Photos

值得借鉴：

- 文件夹视图、时间线、物理文件夹、虚拟相册和条件相册并存。
- 移动端支持后台备份、Focused Backup、自定义目标、离线浏览和释放空间。
- 相册可以引用同一原件而不复制；私人空间和共享空间边界清晰。
- 预览生成可从 NAS 卸载到客户端 Image Assistant，说明派生任务可以按能力放在不同节点。
- 支持人物、对象、地点、标签、评分、相机参数筛选，以及密码/到期时间分享。

不直接照搬：

- 群晖功能与 DSM、特定硬件型号深度绑定；Unraider 必须保持渠道与 NAS 品牌无关。

官方资料：

- https://www.synology.com/en-global/dsm/feature/photos
- https://www.synology.com/en-global/dsm/7.4/software_spec/synology_photos

### 飞牛相册

值得借鉴：

- “备份全部”和“仅备份新增”是清晰的首次导入策略。
- 备份状态明确区分扫描、正在备份、成功/部分失败、暂停/失败，并给出电量、Wi-Fi、连接、容量和权限原因。
- 不熄屏备份用于大批量首次导入；普通后台备份用于日常增量。
- 可按拍摄日期重命名，并同步创建手机相册。
- 人物、自然语言搜图、智能分类和视频增强识别均作为独立后台任务。
- Google Photos 导入恢复原件、收藏、相册、描述和位置，体现迁移能力的重要性。

不直接照搬：

- AI 模型需要 NAS 算力和大量额外空间，应作为可选助手能力。

官方资料：

- https://help.fnnas.com/articles/v1/photo/photo-backup
- https://help.fnnas.com/articles/v1/photo/photo-ai
- https://help.fnnas.com/articles/v1/photo/photo-share
- https://help.fnnas.com/articles/v1/photo/import-google-photos

### Nextcloud + Memories / Les Pas

值得借鉴：

- Nextcloud Android 可监控多个本地目录，并提供命名、目录排序、Wi-Fi 和排除子目录等策略。
- Memories 保留现有文件系统结构，提供高性能时间线、相册、共享、地图、元数据编辑和按需视频转码。
- Les Pas 允许每个手机媒体文件夹独立设置备份，并提供 Remote Album 与双向相册管理。
- Nextcloud 可挂载 SMB、SFTP、WebDAV、S3 等外部存储，说明“统一照片 API + 多后端”是一条成熟路线。

不直接照搬：

- Nextcloud 平台较重；Unraider 不应强制用户部署完整协作云。
- 双向同步与单向备份要严格分开，避免远端删除传播到手机。

官方资料：

- https://nextcloud.com/features/
- https://memories.gallery/
- https://github.com/scubajeff/lespas
- https://docs.nextcloud.com/server/latest/admin_manual/configuration_files/external_storage_configuration_gui.html

## 建议功能分级

### MVP：可靠备份与可用预览

- 多源文件夹选择、源相对路径保留、设备命名空间。
- 首次“全部备份”和日常“仅新增/变化”模式。
- 持久化资产与任务索引、应用重启续跑、错误队列。
- SMB/WebDAV 原生流式上传、连接复用、受控并发、`.part` + 原子重命名。
- 大小/mtime 校验；可选内容 hash；同名冲突不覆盖。
- Wi-Fi、充电、电量、前台集中备份、暂停/继续/取消。
- 上传时生成图片缩略图和视频封面；远端 sidecar + 本地磁盘缓存。
- 时间线与文件夹视图、照片/视频筛选、可见区域懒加载。
- 本地/待备份/上传中/已验证/失败状态标识和实时吞吐。

### Phase 2：照片管理完整性

- 逻辑相册及手机相册映射，不移动或复制原件。
- 收藏、归档、标签、描述、评分和基础 EXIF 筛选。
- 已有远端目录的可恢复增量索引。
- 精确重复检查、备份后安全释放手机空间、离线最近浏览。
- HEIC/RAW/Live Photo 基础预览兼容。
- 分享给 Unraider 内其他用户或生成受控链接。

### Phase 3：可选 NAS 智能助手

- 多级缩略图、大预览图、历史图库批量派生。
- 视频兼容转码、硬件加速和自适应播放。
- 人脸识别、地点聚类、场景/对象识别、OCR、自然语言搜索。
- 相似照片检测、智能堆叠、回忆和“那年今日”。
- 多用户共享空间、协作相册、迁移导入工具。

## 反向需求：明确避免

- 不把双向删除同步包装成“备份”。
- 不用全盘远端扫描作为每次上传成功的确认方式。
- 不让网格读取完整原图。
- 不让缩略图、转码文件进入原始图库扫描。
- 不因数据库或缓存损坏而无法找回原始媒体。
- 不让 AI/转码任务占满资源而拖慢备份和浏览主路径。
