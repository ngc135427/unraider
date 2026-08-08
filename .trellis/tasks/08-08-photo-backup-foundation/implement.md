# 相册持久索引与文件夹映射实施计划

## 1. Baseline and contracts

- [x] 记录当前本地扫描、路径生成、待上传差集和相册状态调用链及测试覆盖。
- [x] 确认项目数据库依赖与迁移惯例，定义仓库接口、状态枚举和下游传输 lease 契约。
- [x] 为多源文件夹、同名冲突、全部/仅新增、移动媒体和旧日期目录建立 fixture。

## 2. MediaStore model

- [x] 扩展 Android MediaStore projection，返回 volume、`RELATIVE_PATH` 和完整可用媒体元数据。
- [x] 在 Dart 模型中规范化字段、路径和稳定身份，并覆盖空值、旧 Android 版本和权限异常。
- [x] 实现源文件夹选择、包含关系和多源重叠规则。

## 3. Persistent database

- [x] 新增 `SourceFolder`、`MediaAsset`、`BackupRecord`、`RemoteAsset` 和 `DiscoveryCheckpoint` schema、索引与迁移。
- [x] 实现事务化 upsert、队列 lease、受约束状态转换和分页查询。
- [x] 迁移现有相册偏好到单个默认源配置，不删除旧偏好直到新路径验证完成。

## 4. Discovery and mapping

- [x] 实现“全部”和“仅新增”基线。
- [x] 实现增量发现与周期性协调，移除日常状态判断对完整远端列表的依赖。
- [x] 实现设备/源边界、路径规范化、冲突检测和确定性远端路径解析。
- [x] 实现旧 `YYYY/MM/DD` 目录只读索引导入和导入报告。

## 5. UI integration seam

- [x] 让相册状态和待处理数量从持久仓库读取，同时保留旧页面功能开关。
- [x] 暴露下游传输和图库所需接口，不在本任务中实现真实上传或缩略图。

## Validation

- [x] 运行 `flutter analyze`、相关 Dart 单元/Widget 测试及完整 `flutter test`。
- [x] 运行 Android Gradle/Kotlin 构建及 MediaStore payload fixture 测试。
- [x] 用至少 10,000 条媒体 fixture 验证分页、索引耗时和 UI isolate 响应。
- [ ] 验证应用重启、数据库迁移失败回滚、权限撤销、媒体移动/删除和多源重叠。（除真机权限撤销、注入式数据库打开失败外均已自动化覆盖。）
- [x] 确认测试期间没有修改任何远端原始文件。

## Review and rollback gates

- [x] Schema 与状态契约评审完成后再让传输子任务依赖。
- [x] 新索引、源文件夹 UI 和旧备份导入分别受功能开关控制。
- [x] 若新仓库读取失败，旧相册视图可回退；不得自动清理旧偏好或旧远端目录。
