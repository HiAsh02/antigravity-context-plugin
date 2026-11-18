---
name: context
description: Inspect current session context window usage, remaining token capacity, token breakdown (base system prompt vs. conversation growth, cached vs. uncached), and turn-by-turn history. Triggered when the user runs /context or asks about remaining context window or token usage.
---

# Context Window Monitor (`/context`)

当用户触发 `/context` 或询问当前会话（Session）的上下文窗口占用、剩余 Token 容量及消耗拆解时，执行以下步骤：

## 1. 获取当前会话的上下文统计数据

立即运行统计脚本，传入当前会话上下文中 `<user_information>` 提供的 `<Artifact Directory Path>\.system_generated\logs\transcript.jsonl`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.gemini\config\plugins\context\skills\context\scripts\get-context-usage.ps1" -TranscriptPath "<Artifact Directory Path>\.system_generated\logs\transcript.jsonl"
```

- 如果不知道当前 `<Artifact Directory Path>`，可省略 `-TranscriptPath` 参数，脚本会自动定位最近更新的 `transcript.jsonl`。
- 如果无法执行命令行工具，则使用 `read_file` 读取 `<Artifact Directory Path>\.system_generated\logs\transcript.jsonl` 的尾部记录，手动提取第一条与最后一条 `"type":"PLANNER_RESPONSE"` 的 `input_tokens`、`cache_read_tokens` 和 `output_tokens` 进行计算（默认窗口上限为 1M = `1,048,576` tokens）。

## 2. 格式化输出结果

拿到脚本返回的 JSON 数据后，**不要输出多余寒暄**，直接以清晰、紧凑的中文 Markdown 展示以下内容：

1. **进度条概览**：
   使用 20 格字符进度条（实心块 `█` 与空心块 `░`，按 `used_percent / 5` 四舍五入计算实心格数，至少占用 > 0% 时可按实际比例或展示 `█`/`░`），直观呈现：
   - 已用百分比（`used_percent%`）
   - 已用 Token / 总容量（`active_context_tokens / 1,048,576 tokens`）
   - 剩余可用 Token（`remaining_tokens tokens`，剩余 `remaining_percent%`）

2. **上下文结构拆解表**：
   | 指标 | 数值 | 说明 |
   | :--- | :--- | :--- |
   | 当前上下文总占用 | `<active_context_tokens>` tokens (`<used_percent>%`) | 最新一次调用（Step `<latest_step>`）的完整上下文大小 |
   | 剩余可用窗口 | `<remaining_tokens>` tokens (`<remaining_percent>%`) | 按 `1,048,576` tokens (1M) 上限计算 |
   | 基础系统开销（首轮基准） | `<initial_context_tokens>` tokens | System Prompt、Rules、MCP 工具定义与 Skills 摘要 |
   | 会话累计增量 | `<session_growth_tokens>` tokens | 历史对话、文件读取及工具返回带来的增量 |
   | 最新轮次缓存命中率 | `<latest_cache_hit_rate>%` | 缓存读取 `<latest_cache_read_tokens>` / 新增输入 `<latest_input_tokens>` |
   | 本会话累计统计 | `<user_turns>` 轮提问 / `<planner_steps>` 次模型调用 | 累计输出 `<cumulative_output_tokens>` tokens（若 `compaction_count > 0` 则注明已压缩 `<compaction_count>` 次） |

3. **最近步数趋势**：
   用简短列表或小表格展示 `recent_steps` 中最近几步的 `step_index`、`active_tokens`（以及 `cache_read_tokens` + `input_tokens` 构成与 `output_tokens`）。

4. **容量提醒**：
   - 若 `used_percent` 超过 `60%`，在末尾提醒用户可以使用 `/compact` 命令压缩历史上下文以释放容量。
