# Edge AI SDK

两层封装：

- **Native**：`native/include/edge_ai.h`，稳定 C ABI v2，负责模型、backend、内存预算、Jinja chat template、tokenizer、采样、停止条件。
- **Dart**：`app/lib/engine/edge_ai.dart`，负责 isolate 生命周期、类型化配置/事件、请求超时、worker 崩溃处理。

App 的 UI 只依赖 Dart SDK，不再手写 ChatML，也不直接碰 FFI。

## Native ABI v2

```c
edge_ai_create_ex(&config, &handle, err, err_len);
edge_ai_prepare_chat(handle, messages, n, max_output, enable_thinking, prompt, cap, &plan);
edge_ai_start_ex(handle, prompt, &gen_params, err, err_len);
edge_ai_next_ex(handle, out, cap, &out_len, &stop_reason, err, err_len);
edge_ai_cancel(handle);
edge_ai_get_model_info(handle, &info);
edge_ai_get_stats(handle, &stats);
edge_ai_unload(handle);
edge_ai_destroy(handle);
```

### 配置（`edge_ai_config`）

| 字段 | 作用 |
| --- | --- |
| `backend` | AUTO / VULKAN / CPU |
| `n_gpu_layers` | -1 自动；CPU 强制 0 |
| `n_ctx` | 0 = 按内存预算自动 |
| `n_batch` / `n_ubatch` | prefill 批次 |
| `n_threads` | CPU 线程数 |
| `flash_attn` | -1 auto / 0 off / 1 on |
| `use_mmap` / `use_mlock` | 加载方式 |
| `allow_cpu_fallback` | Vulkan 加载失败时回退 CPU |
| `strict_memory` | 1 = 超预算直接失败，不自动降 ctx |
| `kv_type_k` / `kv_type_v` | 0 = f16，或 ggml_type |
| `memory_budget_bytes` | 0 = 用系统可用内存 |
| `memory_reserve_bytes` | 给系统/应用预留，0 = 默认 768 MB 或 total/16 |
| `min_ctx` / `max_ctx` | ctx 边界，最终还会被模型 `n_ctx_train` 截断 |

### 自动上下文

`edge_ai_create_ex` 在模型加载后计算：

```
kv_per_token = n_layer * n_head_kv * head_dim * (bytes_k + bytes_v)
usable       = budget - model_bytes - reserve
recommended  = clamp(usable / kv_per_token, min_ctx, min(max_ctx, n_ctx_train))
```

- `n_ctx=0` 时使用 `recommended`；显式 `n_ctx` 超预算会被降到 `recommended`（除非 `strict_memory=1`）。
- context 创建失败会按 1/2 递减重试；仍失败且允许回退时，重新以 CPU 加载。
- 实际值通过 `edge_ai_get_model_info` 返回，包括 model/KV/RSS/系统内存/budget。
- KV 估算包含 K 和 V；不区分 SWA 层，偏保守。

Qwen3-1.7B Q6_K：`kv_per_token = 114688 B`（约 112 KB）。12 GB AVD 实测可到 **32768**（模型训练上限），KV 3584 MB，RSS 约 5.4 GB，budget 9.3 GB。ctx 4096 时 RSS 约 2.3 GB、decode 12.5 tok/s；ctx 32768 时 RSS 5.4 GB、decode 5.7 tok/s（emulator CPU），容量和速度需要按业务权衡。

真机 vivo V2458A：Vulkan + 32768 ctx，358 tokens 长生成 22.91 tok/s，prefill 1.31 s，8.4 W / 0.36 J/tok，RSS 约 5.85 GB。

内存预算本身还能支持更大的 ctx（约 70k），但超过 `n_ctx_train` 会退化质量，SDK 默认用 `min(max_ctx, n_ctx_train)` 截断。

### 通用 chat template

`edge_ai_prepare_chat` 使用 llama.cpp 的 `common_chat_templates`（Jinja），从 GGUF 读模板：

- 支持 system/user/assistant 多轮、`enable_thinking=false`、模型的 generation prompt。
- 返回精确 prompt token 数和格式化后的 prompt。
- 上下文不足时只裁剪**较早的非 system 消息**，保留 system 和最后一条 user；绝不为了腾 max_output 空间丢弃当前问题。
- `max_output_tokens` 会按剩余 ctx 自动缩小。
- 模板失败返回 `EDGE_AI_ERR_UNSUPPORTED`，不会静默拼错。

### 多模态图片输入（ABI v3）

- `edge_ai_load_mmproj(handle, path)` 在模型加载后挂载视觉投影；`edge_ai_has_vision` 查询能力。
- `edge_ai_chat_message_v3` 增加 `image_path`；native 在用户内容前插入 `mtmd_default_marker()`，再用 `mtmd_tokenize_from_parts` 生成 text/image chunks。
- `edge_ai_prepare_chat_v3` 用 placeholder 图片做精确 token 预算（图片 token 也计入 ctx）。
- `edge_ai_start_chat_v3` 用真实图片做 `mtmd_helper_eval_chunks` 预填充，之后 `next_ex` 流式解码。
- 支持 Gemma 4 / Qwen-VL 等带 mmproj 的模型；App 通过 `image_picker` 选图，复制到会话媒体目录后传入路径。

AVD 实测（Gemma 4 12B QAT Q4_0 + BF16 mmproj，CPU）：图片 130 image tokens，prompt 164，ctx 3584，prefill 23.6 s，3.67 tok/s，正确识别 1969 年登月报纸。

### 生成控制

`edge_ai_gen_params` 暴露：

- `max_tokens`
- `temperature` / `top_p` / `top_k` / `min_p`
- `repeat_penalty` / `frequency_penalty` / `presence_penalty`
- `repeat_last_n`
- `seed`
- `ignore_eos`
- `stop_sequences`（最多 512 字节/条，native 做 holdback，不会把停止串泄漏到输出）

`edge_ai_next_ex` 返回 `stop_reason`：eos / max_tokens / stop_sequence / cancelled / error。

### 错误码

`edge_ai_status`：invalid_argument、not_loaded、busy、out_of_memory、context_overflow、backend、cancelled、io、unsupported、buffer_too_small、internal。

每次调用带 `err` 缓冲区；Dart 映射为 `EdgeAiException(code, message)`。

## Dart SDK

```dart
final engine = await EdgeAiEngine.spawn();

final info = await engine.load(const EngineConfig(
  modelPath: '/path/model.gguf',
  backend: ComputeBackend.auto,
  threads: 4,
  contextSize: 0,             // 自动
  maxContext: 8192,
  memoryBudgetBytes: null,   // 自动
  allowCpuFallback: true,
));

final plan = await engine.estimate(ChatRequest(
  messages: [
    const ChatTurn('system', 'You are a concise assistant.'),
    const ChatTurn('user', 'Explain Vulkan in one sentence.'),
  ],
  params: const GenerationParams(maxTokens: 128),
));

engine.events.listen((event) {
  switch (event) {
    case PlanReady():      // promptTokens / droppedMessages / maxOutputTokens
    case TokenReceived():  // 流式文本
    case GenerationFinished(): // tokens、prefill/decode、tok/s、stopReason
    case EngineFailure():  // code/message，fatal=true 需要重新 spawn
    default:
  }
});

await engine.generate(ChatRequest(
  messages: [...],
  params: const GenerationParams(
    maxTokens: 256,
    temperature: 0.7,
    stopSequences: ['</answer>'],
  ),
  enableThinking: false,
));

await engine.cancel();
await engine.unload();
await engine.dispose();
```

### 资源控制

- `EngineConfig.contextSize=0`：native 按预算自动选择。
- `memoryBudgetBytes`：业务层可传设备允许的上限（例如 AVD/真机实测可用内存的 70%）。
- `EngineInfo`：`modelBytes`、`kvBytesPerToken`、`kvBytes`、`budgetBytes`、`availRamBytes`、`rssBytes`、`recommendedCtx`、`nCtx`。
- `DeviceMemory.read()`：Android `ActivityManager.MemoryInfo`，供业务层计算预算。
- `ContextPlan`：精确 token 数、裁剪条数、调整后的 max output、fits。
- `strictMemory=true`：预算不足时报错，而不是悄悄降 ctx。

### 调度器与防 OOM

`InferenceScheduler` 是单模型常驻调度器：

- `maxContext` 默认 **32768**，尽量保留长上下文；`contextSize=0` 时由 native 按预算自动选。
- 预留 `headroom = max(1 GiB, total RAM * 10%)`；加载前检查 `model_file + headroom <= budget`。
- `memoryBudgetBytes` 默认取当前 `MemAvailable`；native 以 `budget - model - reserve` 推导 ctx，并拒绝 model 本身都放不下的加载。
- 加载完成后再校验 `modelBytes + kvBytes + headroom <= budget`，不满足则立即卸载并抛 `ResourceExhaustedException`，不会带着超额内存继续跑。
- 同一时刻最多一个 handle；切换模型先 unload，等待 250 ms 再加载。
- 生成中不卸载；后台切换、`onTrimMemory`、空闲 10 分钟会 unload；生成结束再执行延迟卸载。
- 15 s watchdog：可用内存低于 headroom 只告警，低于 `max(512 MiB, headroom/2)` 才强制释放。
- App 按 Home 后实测：模型立即释放，PSS 5.7 GB → **196 MB**；回前台首次发送自动重载，23.1 tok/s。
- 这里保证的是“调度器不会主动把进程推到 OOM”；Android 系统仍可能因全局内存压力杀进程，所以后台卸载是硬策略。

### 健壮性

- 所有 native 调用校验 handle/状态/struct size；生成中禁止 reload/unload。
- `std::mutex` 串行化 native 操作；`cancel` 用 atomic，可从其他线程调用。
- Worker isolate `onError`/`onExit` 会失败所有 pending 请求并发出 `EngineFailure(fatal: true)`。
- 重新 load 会先销毁旧 handle，避免重复模型内存。
- App 侧显示实际 backend（Vulkan 失败回退 CPU 时不会误标）。
- 首轮 128 token dummy prefill 预热 Vulkan pipeline，加载时间多约 1 s。

## 构建与验证

```bat
scripts\build_all.bat                    :: arm64 native + APK
scripts\build_native_android_x86_64.bat  :: AVD x86_64
```

AVD（12 GB）：

```text
MemTotal 12246848 kB
ctx 32768, KV 3584 MB, RSS 5434 MB, budget 9.3 GB
Context used 57 / 32768 (exact tokenizer)
```

Native smoke：

```bat
adb push build\native-android-x86_64\out\libedge_ai.so /data/local/tmp/edgeai/
adb push build\native-android-x86_64\out\edge_ai_smoke /data/local/tmp/edgeai/
adb shell "cd /data/local/tmp/edgeai && LD_LIBRARY_PATH=. ./edge_ai_smoke ./model.gguf cpu 0"
```

## 已知边界

- `edge_ai_prepare_chat` 依赖 GGUF 自带 chat template；没有模板的模型返回 unsupported。
- KV 估算按全量 n_ctx 计算，SWA 模型会偏保守。
- 加载进度还没有回调到 Dart（native 有 progress 日志）。
- 模型选择、聊天持久化仍属于 App 层，不在 SDK 内。
- 32k ctx 在 12 GB AVD 可分配，但 emulator CPU decode 会明显变慢；真机建议按场景选择 4k/8k/16k。
