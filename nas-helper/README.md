# Unraider Album Helper

可选的 Unraid 端相册加速服务。它在 NAS 本地建立可重建索引，批量生成图片缩略图、视频封面和 SHA-256 完整性数据；停止或删除助手不会影响任何原始媒体，也不会阻塞 Unraider 的纯客户端备份流程。

## 快速部署

1. 复制 `docker-compose.example.yml` 为 `docker-compose.yml`。
2. 设置一个至少 16 字符的随机 `UNRAIDER_HELPER_TOKEN`。
3. 按实际共享目录修改媒体卷和 `UNRAIDER_ROOTS_JSON`。
4. 确保 `PUID`/`PGID` 对媒体目录具有读取权限，并能在根目录创建 `.unraider/`。
5. 运行 `docker compose up -d --build`。

每个根目录需要同时配置容器路径与 Unraid 逻辑路径：

```json
[
  {
    "id": "photos",
    "path": "/media/photos",
    "remotePrefix": "/mnt/user/photos"
  }
]
```

助手只在 `path` 下读取原件；所有派生图片写入该根目录的 `.unraider/thumbnails/` 或 `.unraider/video-posters/`。SQLite 作业与索引保存在 `/data`，可删除后重建。

默认 `UNRAIDER_CORS_ORIGIN=*`，便于 Flutter Web 从局域网访问 API；如果只从固定 Web 站点使用，可改为该站点的 Origin。媒体根的容器路径和 Unraid 逻辑路径均不得彼此嵌套，以避免同一原件重复入库。

## API

- `GET /healthz`：无需鉴权的存活探针。
- `GET /api/v1/capabilities`：版本、能力与媒体根协商。
- `GET /api/v1/assets?limit=100&cursor=...&prefix=/mnt/user/photos`：稳定游标分页索引。
- `POST /api/v1/jobs`：提交 `scan`、`previews`、`integrity` 或 `rebuild` 作业。
- `GET /api/v1/jobs/{id}`：查询进度和逐批结果。
- `POST /api/v1/jobs/{id}/retry`：重试完成、失败或取消的作业。
- `POST /api/v1/jobs/{id}/cancel`：请求取消排队或运行中的作业。

除 `/healthz` 外，所有请求必须包含：

```text
Authorization: Bearer <UNRAIDER_HELPER_TOKEN>
```

提交作业时可带 `Idempotency-Key`。相同键的重复请求返回同一作业，不会重复占用队列或生成冲突文件。

```bash
curl -X POST http://unraid:9487/api/v1/jobs \
  -H "Authorization: Bearer $UNRAIDER_HELPER_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: first-library-rebuild" \
  -d '{"type":"rebuild","payload":{"rootId":"photos"}}'
```

服务默认使用 HTTP，适合可信局域网。跨不可信网络访问时应通过反向代理启用 HTTPS，并限制防火墙来源。

## 本地测试

项目只依赖 Python 标准库；缩略图和视频封面运行时需要 `ffmpeg`。

```bash
cd nas-helper
python -m unittest discover -s tests -v
```
