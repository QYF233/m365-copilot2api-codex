# M365 Copilot → Codex 接入脚本

把**企业版 M365 Copilot** 当成 Codex 的模型后端使用。本仓库只放配置、脚本和踩坑记录，
不含网关本体（用上游 [`HEXUXIU/M365-Copilot2API`](https://github.com/HEXUXIU/M365-Copilot2API) 的 release 二进制）。

> 非官方逆向，违反微软 ToS，**可能封租户账号**。企业环境请先确认 IT 政策。仅供内部自用。

## 为什么是 M365-Copilot2API

Codex 强制走 Responses API。其他把消费版 Copilot 包成接口的项目只实现了
`/v1/chat/completions`，接上去工具调用会崩。这个项目原生实现 `/v1/responses`，
且直连 M365 ChatHub WebSocket，不是浏览器自动化。

## 前置条件

| 项 | 要求 |
|---|---|
| 账号 | 企业租户下有 **M365 Copilot 授权**（个人账号不行） |
| 系统 | Windows（脚本是 bat + PowerShell；网关本体跨平台） |
| 客户端 | Codex CLI / 桌面 App ≥ 0.163 |
| 网络 | 能访问 `substrate.office.com`，直连不稳时建议挂代理 |

## 快速开始

### 1. 下载网关二进制

去 [releases](https://github.com/HEXUXIU/M365-Copilot2API/releases) 拿对应平台的包，
放到本目录，命名保持 `m365-copilot2api.exe`。

### 2. 起网关

```bat
set M365_ADMIN_PASSWORD=你的强密码
run-gateway.bat
```

网关拒用弱密码（`admin123` 之类会直接退出）。

### 3. 授权企业账号

```bat
open-auth.bat     :: 用 Chrome 打开授权页
submit-auth.bat   :: 授权后从剪贴板提交回调 URL
```

- **必须用 Chrome**。Edge 的 SmartScreen 会把带 `code=` 的回调判为钓鱼页并警告
  「不要复制该 URL」，而流程恰恰需要复制。
- 授权后浏览器显示「这不是正确的页面」是**正常的**——`redirect_uri` 指向
  `login.microsoftonline.com/common/oauth2/nativeclient`，这是桌面客户端的假回调，
  不是真实网页。`code` 就在地址栏里。
- `code` 一次性、约 10 分钟过期、绑定 PKCE verifier，只发往 `127.0.0.1:4141`，不出本机。
  **但仍不要贴到任何公开地方。**

### 4. 创建 API Key

浏览器打开 `http://127.0.0.1:4141`，用第 2 步的密码登录，「API Key」页新建一个。

```bat
setx M365_API_KEY "m365_xxxxx"
```

> key 在网关侧是哈希存储，**明文只在创建时显示一次**，忘了只能重建。

### 5. 配置 Codex

`~/.codex/config.toml`：

```toml
model = "gpt-5.6-reasoning"
model_provider = "m365"

[model_providers.m365]
name = "M365 Copilot"
base_url = "http://127.0.0.1:4141/v1"
env_key = "M365_API_KEY"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false      # 不关会卡 Reconnecting
request_max_retries = 10         # 默认 3 撑不过账号冷却
stream_max_retries = 10
stream_idle_timeout_ms = 300000
```

模型元数据用 `fetch_models.py` 生成精简版 catalog：

```bash
python fetch_models.py <你的 API Key>
```

**不要**把网关 `/v1/models` 的全部字段直接塞进 catalog——里面的
`tool_mode` / `use_responses_lite` / `experimental_supported_tools` 会让 Codex
把工具数从 10 削到 1，请求直接 `response.failed`。

### 6. 验证

```bash
codex exec --skip-git-repo-check "创建 test.txt 写入 hello，然后读回确认"
```

看到 `exec` 片段 + `succeeded in xxx ms` 才是真的调用了工具。

## 三个必须知道的关键点

### 一、`M365_TOOL_PLANNING_MODE=router`（否则工具调用是幻觉）

默认值 `native` 会把工具挂成 MCP 让上游自己调，普通企业租户下模型**不发起调用**，
而是写一个 ` ```text ` 代码块把"执行结果"编出来：

```json
{"finish_reason": "stop",
 "content": "Shell 命令输出：\n\n```text\nTOOL_OK\n```",
 "tool_calls": null}
```

文件没动、命令没跑，但看起来执行过了。**这是最危险的状态。**

`router` 模式让模型输出路由决策，网关解析成标准 `tool_calls`。
源码注释称它是 "legacy fallback, fragile"，但实测是唯一可用路径。

### 二、别设 `M365_SESSION_CACHE=false`

这个变量是**文件路径**，不是布尔开关（`session_resolver.go:85`，为空时默认
`sessions.json`）。设成 `false` 不会关闭缓存，只会在工作目录生成一个叫 `false` 的垃圾文件。

WS 连接池的复用**没有环境变量能关**。遇到日志里 `reused=true (pooled)` 然后
`5ms 内 WS_READ_TIMEOUT`（死连接，不是真超时），只能重启网关清池。

### 三、稳定性靠"冷却缩短 + 客户端重试"

上游抖一次，账号会被标记失败，之后全部 `upstream http 503`。
默认冷却期内客户端的 3 次重试根本撑不过去。所以：

- 网关：`M365_RATE_LIMIT_COOLDOWN_SECONDS=8`
- Codex：`request_max_retries = 10`

实测冷启动抖动下重试 7 次后自动恢复。

## 文件说明

| 文件 | 用途 |
|---|---|
| `run-gateway.bat` | 起网关（router 模式 + 冷却 8s + 代理端口自适应探测） |
| `open-auth.bat` / `.ps1` | 用 Chrome 打开授权页，绕开 Edge 钓鱼警告 |
| `submit-auth.bat` / `.ps1` | 从剪贴板取回调 URL 提交给网关 |
| `switch_profile.py` | 在 M365 和原后端之间切 Codex 默认 provider |
| `fetch_models.py` | 生成精简版 Codex 模型 catalog |
| `接入Codex指南.md` | 完整踩坑记录与排错表 |

## 已知限制

| 限制 | 说明 |
|---|---|
| 延迟 | router 每轮多一次模型调用，单轮 4~12 秒 |
| 稳定性 | 直连微软 WS 成功率约 70~80%，有代理更稳 |
| 工具合并 | 模型倾向把多步操作合成一个 shell 命令，反而省轮次 |
| 内容过滤 | 输出受 M365 自身过滤约束，无法绕过 |
| 无浏览器控制 | Codex 的 browser 能力走另一套 MCP，与此无关 |

## License

脚本部分随本仓库；网关本体是 AGPL-3.0 且**禁止商业 API 中继**，
内部自用可以，对外售卖不行。
