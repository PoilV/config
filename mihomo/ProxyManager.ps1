param([switch]$AutoTun)

# ============================================================================
# 检查是否以管理员身份运行
# ============================================================================
function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ==================== 用户配置（按需修改） ====================
# 启动前根据实际情况改这里即可
$workDir   = "$env:USERPROFILE\.config\mihomo"       # Mihomo 工作目录
$configUrl = "https://raw.githubusercontent.com/PoilV/config/refs/heads/main/mihomo/config.yaml"  # 远程配置地址
$configPath = Join-Path $workDir "config.yaml"        # 本地配置路径（自动拼接）

# ==================== 系统常量（一般无需修改） ====================
$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"

# 代理环境变量列表（增删改只在这一处）
$ProxyEnvVarNames = @(
    'http_proxy','https_proxy','socks_proxy','all_proxy','no_proxy'
)

# 启动时清理残留的代理环境变量（用户级 + 进程级）
$ProxyEnvVarNames | ForEach-Object {
    Remove-ItemProperty -Path 'HKCU:\Environment' -Name $_ -ErrorAction SilentlyContinue
    Remove-Item "Env:$_" -ErrorAction SilentlyContinue
}

# ============================================================================
# 从配置文件中读取所有端口配置
# port / socks-port / mixed-port / redir-port / tproxy-port
# ============================================================================
function Get-AllProxyPorts {
    $result = @{ http=$null; socks=$null; mixed=$null }
    if (-not (Test-Path $configPath)) { return $result }
    $text = Get-Content $configPath -Raw

    if ($text -match '(?m)^port:\s*(\d+)')        { $result.http   = [int]$matches[1] }
    if ($text -match '(?m)^socks-port:\s*(\d+)')  { $result.socks  = [int]$matches[1] }
    if ($text -match '(?m)^mixed-port:\s*(\d+)')  { $result.mixed  = [int]$matches[1] }

    return $result
}

# ============================================================================
# 设置用户级环境变量（User 作用域）
# 开启系统代理时调用
# ============================================================================
function Set-UserEnvVars {
    $ports = Get-AllProxyPorts
    $addr = '127.0.0.1'
    $envReg = 'HKCU:\Environment'

    # HTTP 端口：port > mixed-port，都没有就不设
    $httpPort = $ports.http ?? $ports.mixed
    # SOCKS 端口：socks-port > mixed-port，都没有就不设
    $socksPort = $ports.socks ?? $ports.mixed

    Write-Host "设置用户级环境变量..." -ForegroundColor Cyan

    if ($httpPort) {
        $httpVal = "http://${addr}:${httpPort}"
        Set-ItemProperty -Path $envReg -Name 'http_proxy'  -Value $httpVal -Type ExpandString
        Set-ItemProperty -Path $envReg -Name 'https_proxy' -Value $httpVal -Type ExpandString
        $env:http_proxy  = $httpVal
        $env:https_proxy = $httpVal
        Write-Host "   http_proxy  = $httpVal" -ForegroundColor Gray
        Write-Host "   https_proxy = $httpVal" -ForegroundColor Gray
    }

    if ($socksPort) {
        $val = "socks5://${addr}:${socksPort}"
        Set-ItemProperty -Path $envReg -Name 'socks_proxy' -Value $val -Type ExpandString
        $env:socks_proxy = $val
        Write-Host "   socks_proxy = $val" -ForegroundColor Gray
    }

    # all_proxy 优先 socks，兜底 http
    if ($socksPort) {
        $val = "socks5://${addr}:${socksPort}"
        Set-ItemProperty -Path $envReg -Name 'all_proxy' -Value $val -Type ExpandString
        $env:all_proxy = $val
        Write-Host "   all_proxy   = $val" -ForegroundColor Gray
    } elseif ($httpPort) {
        $val = "http://${addr}:${httpPort}"
        Set-ItemProperty -Path $envReg -Name 'all_proxy' -Value $val -Type ExpandString
        $env:all_proxy = $val
        Write-Host "   all_proxy   = $val" -ForegroundColor Gray
    }

    $noProxyVal = 'localhost;127.*;192.168.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;<local>'
    Set-ItemProperty -Path $envReg -Name 'no_proxy' -Value $noProxyVal -Type ExpandString
    $env:no_proxy = $noProxyVal
}

# ============================================================================
# 删除用户级环境变量
# 关闭系统代理时调用
# ============================================================================
function Remove-UserEnvVars {
    Write-Host "清除用户级环境变量..." -ForegroundColor Yellow

    $ProxyEnvVarNames | ForEach-Object {
        Remove-ItemProperty -Path 'HKCU:\Environment' -Name $_ -ErrorAction SilentlyContinue
    }

    # 当前进程也立即清除
    $ProxyEnvVarNames | ForEach-Object { Remove-Item "Env:$_" -ErrorAction SilentlyContinue }

    Write-Host "   已清除所有代理环境变量" -ForegroundColor Green
}

$WinInetType = $null

# ============================================================================
# 可执行文件查找 — 优先 PATH，其次工作目录
# ============================================================================
function Get-MihomoExePath {
    $exe = Get-Command mihomo* -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) { return $exe.Source }

    $exe = Get-ChildItem $workDir -Filter "*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) { return $exe.FullName }

    return $null
}

# ============================================================================
# 获取进程名（不含扩展名）
# ============================================================================
function Get-MihomoProcessName {
    $exePath = Get-MihomoExePath
    if ($exePath) { return [IO.Path]::GetFileNameWithoutExtension($exePath) }
    return $null
}

# ============================================================================
# 获取正在运行的 Mihomo 进程
# ============================================================================
function Get-MihomoProcess {
    $name = Get-MihomoProcessName
    if ($name) { return Get-Process -Name $name -ErrorAction SilentlyContinue }
    return $null
}

# ============================================================================
# 检测配置文件中是否包含 tun: 字段
# ============================================================================
function Test-ConfigHasTun {
    if (Test-Path $configPath) {
        return (Get-Content $configPath -Raw) -match '(?m)^tun:'
    }
    return $false
}

# ============================================================================
# 下载远程配置文件
# ============================================================================
function Update-Config {
    Write-Host "正在下载配置文件..." -ForegroundColor Cyan
    curl.exe -L $configUrl -o $configPath -s
    if (Test-Path $configPath) {
        Write-Host "配置文件下载成功" -ForegroundColor Green
        return $true
    }
    Write-Host "配置文件下载失败" -ForegroundColor Red
    return $false
}

# ============================================================================
# 启动 Mihomo
#   -TunMode：启动前校验配置文件包含 tun: 字段
# ============================================================================
function Start-Mihomo {
    param([switch]$TunMode)

    $proc = Get-MihomoProcess
    if ($proc) {
        Write-Host "Mihomo 已在运行 (PID: $($proc.Id))" -ForegroundColor Yellow
        return $true
    }

    $exePath = Get-MihomoExePath
    if (-not $exePath) {
        Write-Host "错误: 找不到 Mihomo 可执行文件" -ForegroundColor Red
        return $false
    }

    if (-not (Test-Path $workDir)) {
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    }

    if (-not (Update-Config)) { return $false }

    # TUN 模式：校验配置文件
    if ($TunMode -and -not (Test-ConfigHasTun)) {
        Write-Host "配置文件中无 tun: 字段，无法启动 TUN 模式" -ForegroundColor Red
        return $false
    }

    $modeLabel = if ($TunMode) { "TUN 模式" } else { "普通模式" }
    Write-Host "启动 Mihomo ($modeLabel)..." -ForegroundColor Cyan

    try {
        $arguments = "-d `"$workDir`" -f `"$configPath`""
        Start-Process -FilePath $exePath -ArgumentList $arguments -WindowStyle Hidden -WorkingDirectory $workDir

        # 轮询等待进程启动（最长 5 秒）
        $timeout = 5
        $elapsed = 0
        while ($elapsed -lt $timeout) {
            Start-Sleep -Milliseconds 500
            $elapsed += 0.5
            if (Get-MihomoProcess) {
                Write-Host "Mihomo 已启动 (PID: $((Get-MihomoProcess).Id))" -ForegroundColor Green
                return $true
            }
        }
        Write-Host "启动超时，请检查配置或路径" -ForegroundColor Red
        return $false
    } catch {
        Write-Host "启动失败: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# ============================================================================
# 停止 Mihomo
# ============================================================================
function Stop-Mihomo {
    $proc = Get-MihomoProcess
    if ($proc) {
        try {
            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            Write-Host "Mihomo 已停止" -ForegroundColor Green
            return $true
        } catch {
            Write-Host "停止失败: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }
    Write-Host "Mihomo 未运行" -ForegroundColor Yellow
    return $true
}

# ============================================================================
# WinInet API — 刷新系统代理使注册表修改立即生效
# ============================================================================
function Initialize-WinInet {
    if (-not $WinInetType) {
        try {
            $signature = @'
[DllImport("wininet.dll", SetLastError = true)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@
            $typeName = "WinInet$(Get-Random)"
            $script:WinInetType = Add-Type -MemberDefinition $signature -Name $typeName -Namespace WinInetInterop -PassThru
        } catch {
            Write-Host "警告: 初始化 WinInet 失败: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Update-System {
    Initialize-WinInet
    if ($WinInetType) {
        try {
            $WinInetType::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
            $WinInetType::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
            return $true
        } catch {
            Write-Host "警告: 刷新代理设置失败: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    return $false
}

# ============================================================================
# 设置系统代理（注册表 + WinInet 刷新）
# ============================================================================
function Set-Proxy {
    param([bool]$Enable)

    try {
        Set-ItemProperty -Path $regPath -Name ProxyEnable -Value ([int]$Enable) -ErrorAction Stop
        if ($Enable) {
            $ports = Get-AllProxyPorts
            $httpPort = $ports.http ?? $ports.mixed

            if (-not $httpPort) {
                Write-Host "⚠️ 配置文件中未找到 HTTP 代理端口，跳过系统代理设置" -ForegroundColor Yellow
                Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0 -ErrorAction Stop
            } else {
                $proxyAddr = "127.0.0.1:${httpPort}"
                Set-ItemProperty -Path $regPath -Name ProxyServer -Value $proxyAddr -ErrorAction Stop
                Write-Host "系统代理: $proxyAddr" -ForegroundColor Gray
            }
        }
    } catch {
        Write-Host "警告: 注册表设置失败: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Update-System | Out-Null
}

# ============================================================================
# UWP 应用代理 — 为所有 UWP 应用添加/清除回环豁免
# ============================================================================
function Enable-UwpProxy {
    Write-Host "正在为所有 UWP 应用开启代理..." -ForegroundColor Green
    $packages = Get-AppxPackage
    foreach ($pkg in $packages) {
        $name = $pkg.PackageFamilyName
        try {
            CheckNetIsolation LoopbackExempt -a -n="$name" | Out-Null
            Write-Host "  已添加: $name" -ForegroundColor Gray
        } catch {
            Write-Host "  失败: $name" -ForegroundColor Red
        }
    }
    Write-Host "操作完成。所有 UWP 应用已开启代理。" -ForegroundColor Green
}

function Disable-UwpProxy {
    Write-Host "正在关闭所有 UWP 应用的代理..." -ForegroundColor Yellow
    try {
        CheckNetIsolation LoopbackExempt -c
        Write-Host "操作完成。已清除所有 UWP 应用的代理豁免。" -ForegroundColor Green
    } catch {
        Write-Host "清除失败，请确认已以管理员身份运行。" -ForegroundColor Red
    }
}

# ============================================================================
# 显示菜单
# ============================================================================
function Show-Menu {
    Clear-Host
    $proc  = Get-MihomoProcess
    $proxyOn = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).ProxyEnable -eq 1

    Write-Host "========== 代理管理工具 ==========" -ForegroundColor Cyan
    $serviceStatus = if ($proc) { "运行中 (PID: $($proc.Id))" } else { "未运行" }
    $serviceColor  = if ($proc) { "Green" } else { "Red" }
    Write-Host "Mihomo 服务: $serviceStatus" -ForegroundColor $serviceColor
    $proxyStatus = if ($proxyOn) { "已开启" } else { "已关闭" }
    $proxyColor  = if ($proxyOn) { "Green" } else { "Yellow" }
    Write-Host "系统代理: $proxyStatus" -ForegroundColor $proxyColor
    Write-Host "------------------------------------------"
    Write-Host " [1] 启动 Mihomo + 开启系统代理"
    Write-Host " [2] 停止 Mihomo + 关闭系统代理"
    Write-Host " [3] 切换系统代理状态"
    Write-Host " [4] 启动 Mihomo (TUN 模式)"
    Write-Host " [5] UWP 应用开启代理"
    Write-Host " [6] UWP 应用关闭代理"
    Write-Host " [7] 退出"
    Write-Host "------------------------------------------"
}

# ============================================================================
# 主程序循环
# ============================================================================
try {
    # 自动 TUN 模式（由提权后的进程触发）
    if ($AutoTun) {
        if (-not (Test-IsAdmin)) {
            Write-Host "错误：TUN 模式需要管理员权限" -ForegroundColor Red
            Read-Host "按回车键退出..."
            exit
        }
        $ok = Start-Mihomo -TunMode
        if ($ok) { Write-Host "✅ TUN 模式已启动" -ForegroundColor Green }
        else      { Write-Host "⚠️ 启动失败" -ForegroundColor Yellow }
        Start-Sleep -Seconds 2
    }

    while ($true) {
        Show-Menu
        $choice = Read-Host "请选择操作"

        switch ($choice) {
            "1" {
                $ok = Start-Mihomo
                Set-Proxy $true
                Set-UserEnvVars
                if ($ok) { Write-Host "✅ 已启动 + 系统代理已开启 + 环境变量已设置" -ForegroundColor Green }
                else      { Write-Host "⚠️ 操作可能未完全成功" -ForegroundColor Yellow }
                Start-Sleep -Seconds 1
            }
            "2" {
                $ok = Stop-Mihomo
                Set-Proxy $false
                Remove-UserEnvVars
                if ($ok) { Write-Host "✅ 已停止 + 系统代理已关闭 + 环境变量已清除" -ForegroundColor Green }
                else      { Write-Host "⚠️ 操作可能未完全成功" -ForegroundColor Yellow }
                Start-Sleep -Seconds 1
            }
            "3" {
                $currentOn = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).ProxyEnable -eq 1
                Set-Proxy (-not $currentOn)
                $text = if (-not $currentOn) { "开启" } else { "关闭" }
                Write-Host "✅ 系统代理已$text" -ForegroundColor Green
                Start-Sleep -Seconds 1
            }
            "4" {
                if (-not (Test-IsAdmin)) {
                    Write-Host "TUN 模式需要管理员权限，正在提权..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                    Start-Process pwsh.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -AutoTun" -Verb RunAs
                    exit
                }
                $ok = Start-Mihomo -TunMode
                # TUN 模式下无需系统代理和环境变量，清理上次残留
                Set-Proxy $false
                Remove-UserEnvVars
                if ($ok) { Write-Host "✅ TUN 模式已启动（已清理环境变量和系统代理）" -ForegroundColor Green }
                else      { Write-Host "⚠️ 启动失败" -ForegroundColor Yellow }
                Start-Sleep -Seconds 1
            }
            "5" {
                Enable-UwpProxy
                Start-Sleep -Seconds 1
            }
            "6" {
                Disable-UwpProxy
                Start-Sleep -Seconds 1
            }
            "7" {
                Write-Host "再见！" -ForegroundColor Cyan
                exit
            }
            default {
                Write-Host "❌ 无效输入，请输入 1-7" -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
} catch {
    Write-Host "发生错误: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "按回车键退出..."
}
