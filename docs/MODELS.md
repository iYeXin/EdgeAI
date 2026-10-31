# 模型管理 / Hub

代码：

- `app/lib/models/hub.dart`：HuggingFace / ModelScope 统一 provider
- `app/lib/models/model_manager.dart`：本地扫描、下载、删除
- `app/lib/models/model_manager_sheet.dart`：本地/下载 UI

## Hub API

### ModelScope（默认，国内直连）

| 功能 | 端点 |
| --- | --- |
| 搜索 | `GET https://modelscope.cn/openapi/v1/models?PageSize=20&PageNumber=1&search=<query>` |
| 文件列表 | `GET https://modelscope.cn/api/v1/models/<repo>/repo/files?Recursive=true&Revision=master` |
| 下载 | `GET https://modelscope.cn/models/<repo>/resolve/master/<path>` |
| Token | `Authorization: Bearer <token>`（预留给 gated/私有模型） |

搜索参数是小写 `search`；大写的 `Name/Search` 会被忽略。

### HuggingFace（默认走 hf-mirror.com）

| 功能 | 端点 |
| --- | --- |
| 搜索 | `GET https://hf-mirror.com/api/models?search=<q>&filter=gguf&limit=20&sort=downloads&direction=-1` |
| 文件列表 | `GET https://hf-mirror.com/api/models/<repo>?blobs=true` |
| 下载 | `GET https://hf-mirror.com/<repo>/resolve/main/<path>?download=true` |

`HuggingFaceProvider(mirror: false)` 可切回 `huggingface.co`。

## 本地目录

```text
files/models/
  ModelScope/
    Qwen/Qwen2.5-0.5B-Instruct-GGUF/
      qwen2.5-0.5b-instruct-q6_k.gguf
  HuggingFace/
    unsloth/gemma-4-12b-it-GGUF/
      gemma-4-12b-it-Q4_K_M.gguf
      mmproj-gemma-4-12b-it-BF16.gguf
```

- 扫描递归，同一目录下 `mmproj-*` 自动配给该目录的 GGUF。
- 模型条目显示大小和“视觉”标记。
- 删除当前加载模型被禁用，避免运行中删文件。

## 下载

- 先写 `<file>.part`，完成后 rename；中断可保留 `.part`。
- 支持 `Range: bytes=<n>-` 续传；服务器返回 200 时自动从头覆盖。
- 按文件大小校验完整性；不完整会报错并保留 `.part`。
- 下载前用 `StatFs` 检查剩余空间，要求文件大小 + 256 MB 余量。
- 下载后按 Hub 提供的 SHA256 校验（ModelScope `Sha256` / HF LFS `oid`），失败删除文件。
- 支持分片 GGUF：点击任意 `-00001-of-0000N.gguf` 会自动下载同前缀全部 shard。
- 下载 GGUF 主文件时，如果同仓库有 `mmproj`，自动追加下载第一个 mmproj。
- 进度通过 `DownloadJob` 回调到 UI；支持取消当前下载，同一时间只允许一个下载队列。

## 已验证

- ModelScope 搜索 `gemma gguf` / `qwen2.5 0.5b gguf`。
- 文件列表（GGUF 量化、大小）。
- 实际下载 `Qwen/Qwen2.5-0.5B-Instruct-GGUF` 的 Q6_K（约 635 MB），自动切换到该模型并加载。
- HF 镜像搜索 `gemma gguf`。
- 发布版 AndroidManifest 已加 `INTERNET` 权限（此前 release 包只有 debug manifest 有，导致 `Failed host lookup`）。

## 边界

- Token 字段已预留，但 UI 还没有配置入口。
- 模型下载完成会切换当前会话模型；历史消息里的图片不会因为切到纯文本模型而删除，下一次带图发送会提示无视觉投影。
- GGUF 只做文件级校验，不做模型结构/chat template 预检；加载失败由调度器报错。
- 不支持断点续传的服务器会从头下载，但仍使用 `.part` 保护目标文件。
