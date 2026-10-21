# M365 Copilot 授权回调一键提交
# 用法：
#   1. 授权弹窗跳到"错误的页面"后，点地址栏，Ctrl+A / Ctrl+C 复制完整 URL
#   2. 双击 submit-auth.bat（或运行本脚本）
#   3. 脚本自动读取剪贴板并提交给网关
#
# 也可手动传参： powershell -File submit-auth.ps1 "https://login.microsoftonline.com/...?code=..."

param(
    [string]$CallbackUrl
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

# 1) 取 URL：优先用参数，其次读剪贴板
if (-not $CallbackUrl) {
    try { $CallbackUrl = Get-Clipboard -Raw } catch {
        Write-Host "[x] 读剪贴板失败，请把 URL 作为参数传入" -ForegroundColor Red
        exit 1
    }
}

if (-not $CallbackUrl -or $CallbackUrl.Trim().Length -eq 0) {
    Write-Host "[x] 剪贴板是空的。请先在错误页地址栏 Ctrl+A / Ctrl+C 复制完整 URL" -ForegroundColor Red
    exit 1
}

$CallbackUrl = $CallbackUrl.Trim()

# 2) 安全检查：必须是 OAuth 回调内容
if ($CallbackUrl -match 'AADSTS|error=') {
    Write-Host "[!] 这个 URL 里没有 code，而是包含错误信息：" -ForegroundColor Yellow
    Write-Host "    $CallbackUrl" -ForegroundColor Yellow
    Write-Host "    说明微软直接拒绝了授权（常见原因：租户策略拦截 / 需要管理员同意 / 账号无 M365 Copilot 许可）" -ForegroundColor Yellow
    exit 2
}

if ($CallbackUrl -notmatch 'code=') {
    Write-Host "[!] 这个 URL 里没有 code= 参数，可能复制的不是授权回调页" -ForegroundColor Yellow
    Write-Host "    内容：$CallbackUrl" -ForegroundColor Yellow
    exit 2
}

Write-Host "[*] 待提交 URL 长度: $($CallbackUrl.Length)" -ForegroundColor Cyan

# 3) 登录控制台拿会话
try {
    $session = $null
    Invoke-RestMethod -Method Post -Uri "$base/api/admin/login" `
        -ContentType 'application/json' `
        -Body (@{ password = $pw } | ConvertTo-Json) `
        -SessionVariable session | Out-Null
    Write-Host "[+] 控制台登录成功" -ForegroundColor Green
} catch {
    Write-Host "[x] 控制台登录失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "    确认网关在 $base 运行，且密码与脚本内一致" -ForegroundColor Red
    exit 1
}

# 4) 提交回调
try {
    if ($CallbackUrl -like 'http*') {
        $uri = "$base/api/auth/callback?url=$([uri]::EscapeDataString($CallbackUrl))"
    } else {
        $uri = "$base/api/auth/callback?" + $CallbackUrl.TrimStart('?')
    }

    $resp = Invoke-RestMethod -Uri $uri -WebSession $session
    Write-Host "[OK] 授权成功，账号已添加" -ForegroundColor Green
    $resp | ConvertTo-Json -Depth 6
} catch {
    Write-Host "[x] 提交失败：$($_.Exception.Message)" -ForegroundColor Red
    $detail = $_.ErrorDetails.Message
    if ($detail) { Write-Host "    服务端返回：$detail" -ForegroundColor Red }
    Write-Host ""
    Write-Host "常见原因：" -ForegroundColor Yellow
    Write-Host "  - state 已失效：授权码只能用一次，且 10 分钟内有效。请回控制台重新点「开始授权」再走一遍" -ForegroundColor Yellow
    Write-Host "  - 租户未授权该应用：需要管理员同意" -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "下一步：回控制台 http://127.0.0.1:4141 的「API Key」页创建密钥" -ForegroundColor Cyan
