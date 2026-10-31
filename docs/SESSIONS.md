# 会话管理

`app/lib/session/session_store.dart`

## 数据结构

会话是**扁平树**：所有消息放在一个列表里，用 `parentId` 指向父节点，用 `activeLeafId` 表示当前分支的叶子。

```json
{
  "version": 2,
  "id": "epoch-random",
  "title": "用户第一条消息的前 32 个字符",
  "modelPath": "/data/.../models/qwen.gguf",
  "activeLeafId": "169...-5",
  "messages": [
    {
      "id": "169...-0",
      "parentId": null,
      "role": "user",
      "text": "Hello",
      "imagePaths": [],
      "stats": {},
      "createdAt": "..."
    },
    {
      "id": "169...-1",
      "parentId": "169...-0",
      "role": "assistant",
      "text": "Hi",
      "stats": {"tok_s": "22.9"}
    },
    {
      "id": "169...-2",
      "parentId": "169...-0",
      "role": "assistant",
      "text": "Hello!",
      "stats": {}
    }
  ]
}
```

- 编辑用户消息：在同一个 `parentId` 下新建 user 节点，并新建 assistant 子节点。
- 重新生成：在同一个 user 节点下新建 assistant 兄弟节点。
- 切换分支：把 `activeLeafId` 指向目标分支的最新叶子，不删除其他分支。
- 旧版 `version: 1` 的线性 `messages` 会在加载时自动迁移成一条链。

## 存储

- 根目录：Android `getExternalFilesDir(null)`，即 `.../files`。
- 会话：`sessions/<id>.json`，一个会话一个文件。
- 索引：`sessions.json` 存 `activeId`、缓存和显示策略。
- 图片：`media/<session>/<timestamp>.jpg`。
- 写入使用 `.tmp` + rename 原子替换；损坏的单个会话文件会被跳过。

## State 缓存与分支

- 每个会话只保留**一份**当前 KV state，不为每个分支单独缓存。
- 切换到其他分支时保留当前 native state；下一次生成由 native 做公共前缀匹配，只 prefill 新增 token，生成后再覆盖这份 state。
- 系统提示词改变会删除该会话 state；模型/mmproj/ctx 改变会拒绝加载旧 state。
- 详细机制见 [STATE_CACHE.md](STATE_CACHE.md)。

## 行为

- 启动时恢复 `activeId` 对应会话；不存在则取最近更新会话，再没有就新建。
- 新建、切换、删除会话；删除会同时删媒体目录。
- 标题取当前分支的第一条用户消息。
- 用户消息/分支节点发送后立即落盘；生成完成后再更新助手节点和统计。
- App 进入后台时保存当前会话。
- 每个会话保存 `modelPath`，并绑定当前模型。

## 限制

- 尚未做搜索、导出、跨设备同步。
- 生成中被系统强杀时，最后一条助手消息可能不完整。
- 图片路径依赖 App 私有外部目录；清理 App 数据会一并删除。
