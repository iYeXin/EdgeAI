# State 缓存

长对话默认每次重新 prefill 全部历史。开启 state cache 后，native 把 KV state + token 序列写入会话目录；下次启动加载 state，只对新增 token 做增量 prefill。

## Native

```c
edge_ai_state_get_size(handle, &bytes);
edge_ai_state_save(handle, path, err, len);
edge_ai_state_load(handle, path, err, len);
edge_ai_state_clear(handle);
```

- `llama_state_save_file(ctx, path, tokens, n_tokens)` 保存完整 KV 状态和 token 序列。
- `llama_state_load_file` 要求同一模型；是否装得下按 state 实际使用的 KV cells 与当前 `n_ctx` 判断，而不是保存时的 `n_ctx`。
- `edge_ai_start_ex` 会对比新 prompt token 与已加载 state token 的公共前缀；命中则从公共前缀之后开始 decode，未命中则清 KV 全量 prefill。
- 多模态 state 额外保存 `<state>.meta`：`n_past`、图片 chunk ID 列表、纯文本 token 列表及其 **decoder position**。
- 多模态复用按 chunk 对比：
  - 图片数量/顺序/hash 必须一致；
  - 文本 token 求最长公共前缀；
  - 用缓存 position 计算公共前缀的 KV 边界，`llama_memory_seq_rm` 裁掉尾部；
  - 只 decode 新增文本 token，位置使用新 prompt 的 M-RoPE position。
- 新增图片、换图、图片顺序变化都会使图片前缀不匹配，自动回退全量 prefill。

## 会话策略

- 默认：磁盘充足时 **开启**；首次启动按剩余空间决定，可用上限默认 4 GB。
- 全局设置可调上限：`512 MB / 1 GB / 2 GB / 4 GB / 8 GB / 16 GB / 20 GB`。
- 全局设置显示当前缓存占用，支持一键清理。
- state 文件：`files/media/<session>/state.bin`。
- 只在生成完成后保存；`stateSize` 超过预算或剩余磁盘不足（state + 512 MB）则跳过。
- 保存后按 `stateUpdatedAt` LRU 淘汰，直到所有会话 state 总大小不超过预算。
- 会话记录 `statePath / stateModelPath / stateMmprojPath / stateCtx / stateBytes / stateTokens / stateUpdatedAt`；模型或 mmproj 不一致不加载，`stateCtx` 只用于展示/诊断。
- 会话参数里的系统提示词改变会删除该会话 state，强制下一轮全量 prefill。
- 编辑消息、重新生成和普通分支切换都保留当前 state，下次生成做最长公共前缀匹配；系统提示词改变才清空 state。
- 切换模型、切换会话、后台卸载模型都会清掉当前内存中的 state 标记；下次发送按需加载。

## 实测（Qwen2.5-0.5B Q6，AVD）

1. 第一轮保存 state：56 tokens，文件 **673 KB**。
2. 重启 App，加载 state：56 tokens。
3. 新 prompt 67 tokens，prefix hit **56/67**。
4. 新 turn prefill：**0.48 s**（未命中时约 **2.6 s**）。
5. generation 后再次保存 state：77 tokens。
6. 多模态（Gemma 4 12B + 单图，AVD CPU）：首次 prefill **22.4s**；保存/加载 state 后新 turn prefill **3.37s**，跳过了图片编码和公共前缀 prefill。

## 边界

- 图片集合或顺序变化时无法复用，自动回退全量 prefill。
- state 文件与模型/mmproj 强绑定；当前 n_ctx 放不下实际 KV cells 时由 native 安全拒绝。
- 保存是同步 IO，放在 worker isolate；大 state 会占用几秒。
- 不做跨设备迁移。
