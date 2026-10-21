# 用 Chrome 打开 M365 授权页（绕过 Edge SmartScreen 的"URL 包含密码"警告）
#
# 原因：Edge 会把带 code= 的 nativeclient 回调判定为钓鱼页并警告"不要复制 URL"，
#       而该流程恰恰需要复制 URL。Chrome 没有这个拦截。
#
# 用法：双击 open-auth.bat

param(
    [switch]$NoBrowser   # 仅调试用：不启动浏览器，只打印 URL
)

$ErrorActionPreference = 'Stop'
$base = 'http://127.0.0.1:4141'
# 控制台密码：优先读环境变量，避免明文写进脚本
$pw   = $env:M365_ADMIN_PASSWORD
if (-not $pw) {
    Write-Host '[x] 未设置环境变量 M365_ADMIN_PASSWORD' -ForegroundColor Red
    Write-Host '    先执行：' $env:M365_ADMIN_PASSWORD = '你的控制台密码' -ForegroundColor Yellow
    exit 1
}

$chromeCandidates = @(
    'C:\Program Files\Google\Chrome\Application\chrome.exe',
    'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
)
$chrome = $chromeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $chrome) {
    Write-Host "[x] 没找到 Chrome，请改用 Firefox，或按文档里的 DevTools 方案" -ForegroundColor Red
    exit 1
}

# 1) 登录控制台
try {
    $session = $null
    Invoke-RestMethod -Method Post -Uri "$base/api/admin/login" `
        -ContentType 'application/json' `
        -Body (@{ password = $pw } | ConvertTo-Json) `
        -SessionVariable session | Out-Null
} catch {
    Write-Host "[x] 控制台登录失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "    先确认网关在运行：双击 run-gateway.bat" -ForegroundColor Red
    exit 1
}

# 2) 取新的授权 URL（会作废之前未使用的 state）
$r = Invoke-RestMethod -Uri "$base/api/auth/start" -WebSession $session

if (-not $r.url) {
    Write-Host "[x] 网关没有返回授权 URL：$($r | ConvertTo-Json -Compress)" -ForegroundColor Red
    exit 1
}

Write-Host "[+] 已生成新的授权 URL，state=$($r.state)" -ForegroundColor Green

# 3) 用 Chrome 打开（独立窗口，不复用你日常的 Edge 会话）
if ($NoBrowser) {
    Write-Host "[dry-run] 授权 URL：" -ForegroundColor Yellow
    Write-Host $r.url -ForegroundColor Yellow
    Write-Host "[dry-run] 不启动浏览器" -ForegroundColor Yellow
    exit 0
}

Start-Process -FilePath $chrome -ArgumentList @("`"$($r.url)`"")

Write-Host ""
Write-Host "Chrome 已打开微软登录页。接下来：" -ForegroundColor Cyan
Write-Host "  1. 用企业账号登录（含 MFA）" -ForegroundColor Cyan
Write-Host "  2. 登录后会跳到 login.microsoftonline.com/common/oauth2/nativeclient?code=..." -ForegroundColor Cyan
Write-Host "  3. 页面内容为空或报错都正常，点地址栏 Ctrl+A Ctrl+C 复制整条 URL" -ForegroundColor Cyan
Write-Host "  4. 回来双击 submit-auth.bat 提交" -ForegroundColor Cyan
Write-Host ""
Write-Host "注意：state=$($r.state) 只能用一次，约 10 分钟内有效。" -ForegroundColor Yellow
Write-Host "如果中途失败，重新运行本脚本，不要复用旧 URL。" -ForegroundColor Yellow
