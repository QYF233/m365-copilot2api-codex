@echo off
chcp 65001 >nul
cd /d "%~dp0"

REM ============================================
REM  M365 Copilot -> OpenAI 兼容网关（给 Codex 用）
REM  用法：双击本文件，或命令行 run-gateway.bat
REM ============================================

REM 管理员密码：优先用已设置的环境变量，否则用下面的默认值（请改成你自己的）
if "%M365_ADMIN_PASSWORD%"=="" set M365_ADMIN_PASSWORD=ChangeMe-Str0ng-Passw0rd

REM 只监听本机；要内网访问改 0.0.0.0:4141，并务必加 TLS 反代
set M365_LISTEN=127.0.0.1:4141

REM ---------- 核心 1：工具调用模式（必设）----------
REM 默认 native 模式下 M365 不会真正调用工具，只会写个 ```text 代码块
REM 假装执行（幻觉）。只有 router 会返回真正的 tool_calls。
REM 代价：每次请求多一轮模型调用，延迟翻倍。
set M365_TOOL_PLANNING_MODE=router

REM ---------- 核心 2：失败后快速恢复 ----------
REM 上游抖动一次账号就进冷却。默认冷却太长，客户端重试窗口撑不过去。
set M365_RATE_LIMIT_COOLDOWN_SECONDS=8
set M365_ENABLE_SYDNEY_RECONNECT=true

REM ---------- 代理：先探测端口再启用 ----------
REM 国内直连 substrate.office.com 的 WebSocket 容易超时，有代理更稳。
REM 但端口不存在时硬配会导致全部请求失败，所以先探测。
set PROXY_PORT=7479
netstat -ano | findstr /C:"127.0.0.1:%PROXY_PORT% " | findstr LISTENING >nul 2>&1
if not errorlevel 1 (
  set M365_PROXY_POOL=http://127.0.0.1:%PROXY_PORT%
  echo [代理] 检测到 127.0.0.1:%PROXY_PORT%，已启用
) else (
  echo [代理] 未检测到 127.0.0.1:%PROXY_PORT%，走直连，靠客户端重试兜底
)

echo.
echo 控制台:   http://127.0.0.1:4141
echo 工具模式: %M365_TOOL_PLANNING_MODE%
echo 按 Ctrl+C 停止服务
echo.

m365-copilot2api.exe
pause
