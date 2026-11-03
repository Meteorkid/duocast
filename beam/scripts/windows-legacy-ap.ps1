# Windows Legacy AP（Wi-Fi Direct 软 AP）启动脚本
#
# 目的：在没有上游网络的情况下，让 Windows 自己广播一个 Wi-Fi 网络，
# 供 Mac 作为普通 Wi-Fi 客户端加入。这是 E0（G1a）的第一步。
#
# 状态：**未在真机验证过**。WinRT 从 PowerShell 调用有几个已知坑
# （异步操作、事件订阅、Ssid 属性类型），失败时请把完整错误贴出来。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File windows-legacy-ap.ps1 -Ssid beam-e0 -Passphrase beamtest2026
#
# 注意：
#   1. 必须先关闭「移动热点」——它与 Wi-Fi Direct 互斥，开着会让 AP 静默失败；
#   2. 口令至少 8 位，否则广告会被中止，错误信息没有意义；
#   3. 脚本会一直挂住，Ctrl+C 停止；退出时自动 Stop()，AP 随之消失
#      （Wi-Fi Direct 的 AP 生命周期绑定在 publisher 对象上）。

param(
    [string]$Ssid = "beam-e0",
    [string]$Passphrase = "beamtest2026"
)

$ErrorActionPreference = "Stop"

if ($Passphrase.Length -lt 8) {
    throw "口令至少 8 位，否则广告会被中止且错误信息不可读"
}

# 加载 WinRT 类型（PowerShell 5.1 需要显式声明 ContentType）
[Windows.Devices.WiFiDirect.WiFiDirectAdvertisementPublisher, Windows.Devices.WiFiDirect, ContentType = WindowsRuntime] | Out-Null
[Windows.Security.Credentials.PasswordCredential, Windows.Security.Credentials, ContentType = WindowsRuntime] | Out-Null
[Windows.Devices.WiFiDirect.WiFiDirectAdvertisementPublisherStatus, Windows.Devices.WiFiDirect, ContentType = WindowsRuntime] | Out-Null

Write-Host "=== 启动前检查 ===" -ForegroundColor Cyan
Get-NetAdapter -Physical | Select-Object Name, InterfaceDescription, Status | Format-Table

$publisher = New-Object Windows.Devices.WiFiDirect.WiFiDirectAdvertisementPublisher

# 没有对端协商时，必须由自己当 Group Owner
$publisher.Advertisement.IsAutonomousGroupOwnerEnabled = $true

$legacy = $publisher.Advertisement.LegacySettings
$legacy.IsEnabled = $true

$credential = New-Object Windows.Security.Credentials.PasswordCredential
$credential.Password = $Passphrase

$legacy.Ssid = $Ssid
$legacy.Passphrase = $credential

Write-Host "=== 启动 Legacy AP ===" -ForegroundColor Cyan
Write-Host "SSID: $Ssid"
Write-Host "口令: $Passphrase"

$publisher.Start()

# 轮询状态：不依赖事件订阅（PowerShell 对 WinRT 事件支持不稳）
$status = $publisher.Status
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    $status = $publisher.Status

    if ($status -ne [Windows.Devices.WiFiDirect.WiFiDirectAdvertisementPublisherStatus]::Created) {
        break
    }
}

Write-Host "状态: $status" -ForegroundColor Green

if ($status -ne [Windows.Devices.WiFiDirect.WiFiDirectAdvertisementPublisherStatus]::Started) {
    Write-Host "AP 未进入 Started 状态。排查顺序：" -ForegroundColor Yellow
    Write-Host "  1. 移动热点是否仍开着（互斥）"
    Write-Host "  2. 口令是否 ≥ 8 位"
    Write-Host "  3. 网卡是否被其他程序占用（如另一份 Wi-Fi Direct 应用）"
    Write-Host "  4. 事件里是否有 Aborted 原因：$($publisher.Status)"
    $publisher.Stop()
    exit 1
}

Write-Host ""
Write-Host "AP 已就绪。保持本窗口打开，AP 才会持续存在。" -ForegroundColor Green
Write-Host "停止：Ctrl+C（会自动 Stop）" -ForegroundColor Green
Write-Host ""

try {
    while ($true) {
        Start-Sleep -Seconds 2
    }
}
finally {
    Write-Host "正在停止 AP…" -ForegroundColor Yellow
    $publisher.Stop()
    Write-Host "已停止。" -ForegroundColor Yellow
}
