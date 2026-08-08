# 相册持久索引与文件夹映射设计

## Scope

本子任务只建立 Android 媒体发现、SQLite 持久模型、文件夹映射、增量协调和旧备份导入契约。网络 I/O、缩略图生成和系统后台调度由后续子任务实现。

## Data flow

```text
MediaStore query/checkpoint
  → normalize MediaAsset
  → resolve SourceFolder membership
  → calculate destination relative path
  → transactionally upsert asset + BackupRecord
  → expose queued work and paginated gallery queries
```

## Persistent entities

- `SourceFolder`: Android volume、规范化相对路径、显示名、目标 ID、远端根目录、媒体策略、约束和初始模式。
- `MediaAsset`: volume + MediaStore ID 主身份，路径/大小/时间指纹作为恢复辅助；保存展示、排序和预览所需媒体元数据。
- `BackupRecord`: 资产 + 目标唯一键、解析后的远端路径、状态、进度、重试、远端版本和派生媒体状态。
- `RemoteAsset`: 规范化远端路径、版本键、时间线字段、来源与预览位置。
- `DiscoveryCheckpoint`: 按 volume/source 保存扫描水位、最近协调时间和模式版本。

数据库写入通过事务保持“发现资产、解析目标、创建队列记录”的原子性。Flutter UI 只消费仓库分页结果和状态流，不直接递归文件系统。

## Folder mapping

推荐布局：`<目标根>/<设备稳定目录>/<源文件夹显示目录>/<源内相对路径>/<文件名>`。

- 设备目录使用用户可读名称加稳定短 ID，设备改名不改变已解析路径。
- 源文件夹保存 volume 与规范化根路径；相对路径只允许落在该根下，拒绝 `..` 等逃逸片段。
- 原文件名默认保留；同一目标路径出现不同本地身份时进入 `remote-conflict`，由确定性重命名或用户决策解决，不静默覆盖。
- 本地移动产生新候选路径，但不自动删除或移动旧远端文件；备份不是双向同步。

## Incremental discovery

- 初次“全部”模式记录基线后排队现有媒体；“仅新增”记录基线但不排队已有媒体。
- 日常使用 MediaStore 时间/ID 水位发现候选，再按身份与版本字段协调新增、修改、移动和消失。
- 周期性轻量协调修复漏报；完整重建必须是显式维护操作。
- 发现阶段只创建持久任务，不执行网络传输。

## Downstream contracts

- 队列领取必须是事务化 lease，防止多个 worker 同时处理一条记录。
- 状态转换至少支持 `discovered → queued → uploading → verifying → completed`，以及 `failed`、`paused`、`missing-local`、`remote-conflict`。
- 传输子任务通过仓库获取本地 URI、目标和已解析远端路径，并通过受约束方法写入进度/结果。
- 图库子任务通过 `RemoteAsset` 的稳定分页、时间排序、文件夹前缀和版本键查询。

## Compatibility and rollback

- 旧 `YYYY/MM/DD` 文件只导入索引，不移动原件；无法可靠匹配本地资产时标记为 `imported-existing`。
- Schema 迁移必须版本化并具备测试 fixture；开发期保留降级/重建路径。
- 新索引使用功能开关；回滚时旧相册页面仍可读取原文件，新数据库可丢弃重建，但不得修改远端原件。
