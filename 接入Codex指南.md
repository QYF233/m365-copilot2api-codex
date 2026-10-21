# 企业版 M365 Copilot → Codex CLI 接入指南

> 实测完成于 2026-10-21，环境：Windows + Codex CLI 0.163.0-alpha.11 + M365-Copilot2API v0.7.3

## 一、结论先说

| 能力 | 状态 | 说明 |
|---|---|---|
| 纯文本对话 | ✅ 可用 | 实测稳定，流式正常 |
| 12 个模型切换 | ✅ 可用 | gpt-5.2 ~ gpt-5.6、claude-sonnet、flux 生图 |
| reasoning effort 分档 | ✅ 可用 | none/minimal/low/medium/high/xhigh |
| **Codex 工具调用（读文件/改代码/跑命令）** | ✅ **可用** | 前提是 `M365_TOOL_PLANNING_MODE=router`，见第四节 |
| 企业账号授权 | ✅ 已完成 | `<你的企业账号>` |

**一句话**：可以当完整的 Codex agent 后端用——能真实读写文件、执行命令，不是只会聊天。

## 二、当前已配好的东西

| 项 | 值 |
|---|---|
| 网关 | `http://127.0.0.1:4141`（代理按端口探测自适应，见 `run-gateway.bat`） |
| 控制台密码 | `<你的控制台密码>` |
| 模型 | `gpt-6.1-sol`（上游新 tone，可在 GUI 切换） |
| API Key | 已写入用户环境变量 `M365_API_KEY` |
| NO_PROXY | 已加 `localhost,127.0.0.1` |
| Codex catalog | `~/.codex/model-catalogs/m365.json`（精简版，14 个模型含 GPT-6） |
| 原 relay 配置 | 未被删除，`python switch_profile.py custom` 可切回 |

## 三、日常使用

```bash
# 1. 起网关（每次开机/重启后都要）
双击 run-gateway.bat

# 2. 切换 Codex 默认后端
python switch_profile.py m365     # 切到 M365
python switch_profile.py custom   # 切回原 deepseek relay
python switch_profile.py status   # 看当前

# 3. 完全退出并重开 Codex 桌面 App（托盘也要退）

# 4. 命令行单次调用（不走 GUI）
codex --profile m365 exec --skip-git-repo-check "你的问题"
```

改配置后 **Codex 桌面 App 必须完全退出再开**，否则仍用旧配置。

## 四、工具调用：关键在 router 模式

### 踩坑过程

用**默认**配置启动网关（`M365_TOOL_PLANNING_MODE` 未设 → 源码里 fallback 是 `native`），
模型不会返回 `tool_calls`，而是用 markdown 代码块把"执行结果"写出来：

```json
{"finish_reason": "stop",
 "content": "Shell 命令输出：\n\n```text\nTOOL_OK\n```",
 "tool_calls": null}
```

**这是幻觉**——文件没动、命令没跑，但看起来像执行过了。非常危险。

### 根因

读源码 `internal/web/fenced_tools.go` 发现，网关把代码块转成 tool_call 的规则是：

```go
var fencedToolCall = regexp.MustCompile("(?s)```([A-Za-z0-9_-]+)\\s*\\n(.*?)\\n```")
// 仅当 info-string 是 bash/sh/shell/powershell/cmd 时才转换
```

模型输出的是 ``` `text` ```，info-string 不匹配，于是被原样当文本返回。
而 `native` 模式依赖 M365 侧的 plugin/MCP 能力，在普通企业租户里模型不会主动发起调用。

### 解决

```bat
set M365_TOOL_PLANNING_MODE=router
```

`native` 是把工具挂成 MCP（日志 `mcp_gateway=.../v1/mcp/sse`）让上游自己调，
`router` 则是让模型在文本里输出路由决策，网关再解析成标准 `tool_calls`。

源码注释说 router 是 "legacy fallback ... doubles latency and is fragile"，
但**实测 native 完全不出工具调用，router 才有效**。多一次模型调用的延迟，换来真实执行，值得。

另外 Responses 接口必须带 `tool_choice: "auto"`，否则也不会返回 `function_call`（Codex 默认会带）。

### 实测证据

**接口层**：

```json
// /v1/chat/completions
"finish_reason": "tool_calls",
"tool_calls": [{"function": {"name": "shell", "arguments": "{\"command\":\"echo TOOL_OK\"}"}}]

// /v1/responses
>>> function_call: shell {"command":"echo TOOL_OK"}
```

**端到端（Codex 真实执行）**：

```
exec
"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -Command '...'
 succeeded in 811ms:
文件创建成功：...\tooltest\tool-test.txt
读取内容：M365_TOOLCALL_OK
校验结果：正确
```

文件落盘验证：`tool-test.txt` / 21 字节 / 内容 `M365_TOOLCALL_OK` ✅

### 稳定性的真正关键（比 router 更容易被忽略）

router 只解决"能不能调工具"，**能不能稳定跑完一轮多步任务**取决于下面三件事。
缺任何一个都会表现成「Codex 里工具用不了」：

| 参数 | 不设的后果 | 设为 |
|---|---|---|
| `M365_RATE_LIMIT_COOLDOWN_SECONDS` | 上游抖一次，账号进长冷却，Codex 的默认 3 次重试（约 3 秒）全部撞在冷却期 | `8` |
| Codex 侧 `request_max_retries` / `stream_max_retries` | 默认 3 次，撑不过 8 秒冷却 | `10` |

> ⚠️ **别照抄网上的 `M365_SESSION_CACHE=false`**。这个变量是**文件路径**
> （`session_resolver.go:85`，为空时默认 `sessions.json`），不是布尔开关。
> 设成 `false` 不会关缓存，只会在工作目录生成一个名为 `false` 的垃圾文件。
> WS 连接池的复用**没有环境变量能关闭**——遇到 `reused=true (pooled)` 只能重启网关清池，
> 或者靠客户端重试兜底。

**日志判据**（`run-gateway.bat` 会把输出打到 `gateway.log`）：

```
# 正常：两轮都有 router 返回，第二轮带上工具结果
stage=router_start prompt_len=22968
stage=router_return elapsed_ms=7889 err=false

# 故障：router 轮 5ms 就超时（说明复用了死连接）
stage=router_return elapsed_ms=5 err=true
[tool-router] failed ... WS_READ_TIMEOUT
[account-route] resolve failed ... upstream http 503
```

### 实测证据（2026-10-21 复测）

工具链完整跑通，含「执行 → 读回 → 校验」多轮循环：

```
exec
"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -Command
  "Set-Content -LiteralPath '.\tool-a.txt' -Value 'AAA' -NoNewline; Get-Content -LiteralPath '.\tool-a.txt' -Raw"
 succeeded in 880ms:
AAA
已创建文件 `tool-a.txt`，并读取确认其内容为：AAA
```

另一次在冷启动抖动中 **重试 7 次后自动恢复**，正确列出目录下 3 个 txt 文件
（`tool-a.txt` / `tool-stream.txt` / `tool-test.txt`，与实际文件一致）。
说明「冷却 8 秒 + 重试 10 次」这套组合能自愈。

落盘验证：`tool-a.txt` 真实存在，内容 `AAA` ✅

### router 是同步调用，流式非流式都走它

`internal/web/server.go` 里条件是：

```go
if planningMode == "router" && body.Stream && len(toolMaps) > 0 && fmt.Sprint(body.ToolChoice) != "none" {
```

所以 stream / 非流式都会先跑一次 router。实测两种模式都返回 `function_call`。
但它**要求 `tool_choice` 不是 `none`**——桌面 App 若在纯聊天模式（不带 tools）不会触发，
表现为模型说「我无法控制浏览器」这类话，那不是故障。

### 已知残留问题

- **延迟偏高**：router 模式每个工具轮次多一次模型调用，实测单轮 4~12 秒。
- **上游抖动**：直连微软 WS 成功率约 70~80%。有代理时更稳。抖动已靠重试自愈，但一次失败会让当前请求多等 5~10 秒。
- **同一个 tool 可能被合并**：模型倾向于把多步操作写进一个 shell 命令里一次完成（如上例创建+读取合一），
  这其实是好事，能减少轮次。

## 五、五个踩过的坑（都已在脚本里规避）

### 1. Edge 报「URL 包含你的密码」

Edg 的 Defender SmartScreen 把带 `code=` 的 nativeclient 回调判为钓鱼页，提示**不要复制 URL**。
但流程恰恰需要复制。**解决：用 Chrome**（`open-auth.bat`），Chrome 没有这个拦截。

`code` 的安全性：一次性 + 10 分钟过期 + 绑定 PKCE verifier，只发到 `127.0.0.1:4141`，不出本机。

### 2. 「这不是正确的页面，已进入错误的页面」

`redirect_uri` 是 `https://login.microsoftonline.com/common/oauth2/nativeclient`，
**这不是真实网页**，认证后必然跳到这里报错。code 就在地址栏里。

备选：Edge DevTools → Network → 勾 Preserve log → 找 `nativeclient?code=` → Copy link address。

### 3. `[profiles.xxx]` 已被 Codex 废弃

旧写法会让 Codex **整个 config.toml 加载失败**：

```
Error loading config.toml: --profile `m365` cannot be used while config.toml
contains legacy `[profiles.m365]` config
```

新写法：独立文件 `~/.codex/m365.config.toml`（本目录脚本已按此配置）。

### 4. 完整 catalog 会让请求直接失败

把网关 `/v1/models` 的**全部字段**塞进 catalog，Codex 会读到
`tool_mode` / `use_responses_lite` / `experimental_supported_tools` 等实验字段，
导致请求里 `tools` 从 10 个变成 1 个，上游直接 `response.failed` / `ws dial` 失败。

**解决：精简 catalog**（`fetch_models.py`），只留纯描述字段，`experimental_supported_tools` 置空，
并补上 Codex 强校验的 `base_instructions` / `model_messages`。

### 5. 连接池复用失效连接（这是「工具调不了」最常见的真凶）

直连微软会 `WS_READ_TIMEOUT`，随后账号被标记冷却：

```
ws read before completion: read tcp 10.0.0.150:5242->40.99.46.226:443: i/o timeout
[account-route] resolve failed requested="" err=upstream http 503
```

日志里 `reused=true (pooled)` 说明连接池复用了已断的 WebSocket——
**注意耗时只有 5ms 就报超时，这不可能是真实网络超时，是死连接**。

**解决**——连接池本身关不掉（没有对应环境变量），所以只能从两头夹：

```bat
REM 网关侧：让失败后能快速恢复
set M365_RATE_LIMIT_COOLDOWN_SECONDS=8
set M365_ENABLE_SYDNEY_RECONNECT=true
```

```toml
# Codex 侧：把重试窗口拉到能覆盖冷却期
request_max_retries = 10
stream_max_retries = 10
```

遇到 `reused=true (pooled)` 连续失败时，**重启网关**是唯一能立刻清池的办法。

代理是加分项不是必需项：有代理更稳（`run-gateway.bat` 会自动探测端口），
没有代理靠重试也能跑通，只是失败一次要多等 5~10 秒。

## 六、文件说明

| 文件 | 用途 |
|---|---|
| `m365-copilot2api.exe` | 网关主程序 v0.7.3 |
| `run-gateway.bat` | 起网关（含密码、代理池） |
| `open-auth.bat` | 用 Chrome 打开授权页 |
| `submit-auth.bat` | 从剪贴板提交回调 URL |
| `switch_profile.py` | 在 m365 / custom 之间切 Codex 默认后端 |
| `fetch_models.py` | 重新生成精简版 Codex catalog |
| `~/.codex/m365.config.toml` | Codex 的 m365 profile |
| `~/.codex/model-catalogs/m365.json` | 14 个模型的元数据 |

## 七、环境变量速查

| 变量 | 默认 | 说明 |
|---|---|---|
| `M365_LISTEN` | `127.0.0.1:4141` | 监听地址 |
| `M365_ADMIN_PASSWORD` | 无（不设会拒绝启动） | 控制台密码 |
| `M365_PROXY_POOL` | 空 | 代理池，有代理更稳（bat 会自动探测 7479） |
| `M365_TOOL_PLANNING_MODE` | `native` | **必须设 `router`**，否则工具调用变成幻觉 |
| `M365_SESSION_CACHE` | `sessions.json` | 会话缓存**文件路径**（不是开关，别设 `false`） |
| `M365_SESSION_TTL_MINUTES` | `120` | 会话绑定有效期 |
| `M365_RATE_LIMIT_COOLDOWN_SECONDS` | 较长 | 设 `8`，让 Codex 重试能救回来 |
| `M365_ENABLE_SYDNEY_RECONNECT` | — | `true`，断了自动重连 |
| `M365_CONTEXT_WINDOW` | `128000` | 上下文窗口 |
| `M365_MAX_OUTPUT_TOKENS` | `16384` | 最大输出 |
| `M365_AUTO_CLEANUP_MAX_AGE_HOURS` | `2` | 云端对话闲置回收 |
| `M365_ACCOUNT_DEFAULT_CONCURRENCY` | `8` | 每账号并发 |

## 八、排错表

| 现象 | 原因 | 处理 |
|---|---|---|
| `401 valid API key required` | `M365_API_KEY` 没设或不对 | 检查用户环境变量，重开终端 |
| `all accounts cooling down` / `upstream http 503` | WS 超时后账号冷却 | 确认缓存已关（见第五节第 5 条），重启网关 |
| `Reconnecting... N/M` 后仍失败 | 重试次数不够撑过冷却 | Codex 侧设 `stream_max_retries = 10` |
| `Error loading config.toml: legacy [profiles.x]` | 用了旧 profile 写法 | 改独立文件 `~/.codex/m365.config.toml` |
| `failed to parse model_catalog_json ... missing field` | catalog 字段不全 | 跑 `fetch_models.py` 重新生成 |
| `tools=1` 且请求立即失败 | catalog 含实验字段 | 同上，用精简版 |
| Stream disconnected / Reconnecting | WebSocket 被试 | 确认 `supports_websockets = false` |
| 模型说「无法控制浏览器/没有工具」 | 该会话没带 tools（纯聊天模式），或模型选了 NO_TOOL_NEEDED | 换成文件/命令类任务复测 |

## 九、风险

1. **非官方逆向**，违反微软 ToS，可能封**租户**账号。企业账号上这是真实合规风险，先确认公司 IT 政策。
2. 许可证 AGPL-3.0 + **禁止商业 API 中继**，内部自用可以，对外售卖不行。
3. 输出受 M365 内容过滤约束。
4. 云端对话会累积，别关 `M365_AUTO_CLEANUP`，否则可能触发风控。
