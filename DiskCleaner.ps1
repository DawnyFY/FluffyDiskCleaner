#Requires -Version 5.1
<#
--------------------------------------------------------------------------
  便携式 C 盘清理工具  (DiskCleaner)
--------------------------------------------------------------------------
  功能：
    * 打开即自动扫描可清理项目并显示大小
    * 可自由勾选要删除的内容（分低/中/高三个风险等级）
    * 永久删除（不经过回收站），真正释放磁盘空间
    * 可开启「启动时自动清理」，下次打开按上次勾选自动执行
  环境：
    Windows 10 / 11 自带 PowerShell 5.1 + WinForms，无需安装任何依赖
  便携性：
    所有路径均基于环境变量，整个文件夹可直接拷贝到其他电脑使用
--------------------------------------------------------------------------
#>
[CmdletBinding()]
param(
    [switch]$Console,   # 控制台模式（不显示界面，适合测试或计划任务）
    [switch]$Auto,      # 控制台模式下直接按配置清理，不询问
    [switch]$SelfTest,  # 自检模式：验证删除引擎与安全校验，不触碰任何真实数据
    [string]$RenderTo,  # 渲染自检：把界面渲染成 PNG 后退出，用于校验视觉样式
    [int]$BenchPaint = 0, # 性能测量：连续重绘 N 帧并报告耗时
    [string]$SnapTo,    # 走真实启动流程后把窗口存成 PNG，用于排查渲染问题
    [string]$Config     # 指定配置文件路径
)

$ErrorActionPreference = 'SilentlyContinue'
# 自检 / 控制台 / 渲染 / 性能模式下让错误显式暴露，避免静默失败掩盖问题
if ($SelfTest -or $Console -or $RenderTo -or $BenchPaint -or $SnapTo) { $ErrorActionPreference = 'Continue' }

$script:AppName  = 'C 盘清理工具'
$script:Version  = '1.3.0'
$script:IsAdmin  = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:Abort    = $false
$script:Cleaning = $false
$script:Entries  = New-Object System.Collections.ArrayList
$script:DisclaimerAccepted = $false   # 是否已同意免责声明，未同意前不进入主界面

# ======================= 基础工具函数 =======================

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1073741824) { return ('{0:N2} GB' -f ($Bytes / 1073741824)) }
    if ($Bytes -ge 1048576)    { return ('{0:N1} MB' -f ($Bytes / 1048576)) }
    if ($Bytes -ge 1024)       { return ('{0:N0} KB' -f ($Bytes / 1024)) }
    return ('{0:N0} B' -f $Bytes)
}

function Get-ScriptDir {
    if ($PSScriptRoot) { return $PSScriptRoot }
    if ($PSCommandPath) { return (Split-Path -Parent $PSCommandPath) }
    return (Get-Location).Path
}

function Get-ConfigPath {
    param([string]$Override)
    if ($Override) { return $Override }
    $dir = Get-ScriptDir
    try {
        $probe = Join-Path $dir ('.wtest_' + [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($probe, 'x')
        [System.IO.File]::Delete($probe)
        return (Join-Path $dir 'cleaner.config.json')
    } catch {
        $alt = Join-Path $env:LOCALAPPDATA 'CDiskCleaner'
        if (-not (Test-Path -LiteralPath $alt)) { New-Item -ItemType Directory -Path $alt -Force | Out-Null }
        return (Join-Path $alt 'cleaner.config.json')
    }
}

function Load-Config {
    param([string]$Path)
    $cfg = [PSCustomObject]@{ Selected = @{} ; AutoClean = $false ; LastRun = '' ; DisclaimerAccepted = $false }
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        try {
            $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
            $obj = $raw | ConvertFrom-Json
            if ($obj) {
                if ($obj.AutoClean -ne $null) { $cfg.AutoClean = [bool]$obj.AutoClean }
                if ($obj.DisclaimerAccepted -ne $null) { $cfg.DisclaimerAccepted = [bool]$obj.DisclaimerAccepted }
                if ($obj.LastRun) { $cfg.LastRun = [string]$obj.LastRun }
                if ($obj.Selected) {
                    $map = @{}
                    $obj.Selected.PSObject.Properties | ForEach-Object { $map[$_.Name] = [bool]$_.Value }
                    $cfg.Selected = $map
                }
            }
        } catch { }
    }
    return $cfg
}

function Save-Config {
    param([string]$Path)
    try {
        $map = @{}
        foreach ($e in $script:Entries) { $map[$e.Id] = [bool]$e.Selected }
        $obj = [PSCustomObject]@{
            AutoClean = [bool]$script:AutoClean
            DisclaimerAccepted = [bool]$script:DisclaimerAccepted
            LastRun   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Selected  = $map
        }
        $json = $obj | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding $true))
    } catch { }
}

# ======================= 安全校验 =======================

$script:ProtectedExact = @(
    ($env:SystemDrive + '\'),
    $env:SystemRoot,
    (Join-Path $env:SystemRoot 'System32'),
    (Join-Path $env:SystemRoot 'SysWOW64'),
    (Join-Path $env:SystemRoot 'WinSxS'),
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    $env:ProgramData,
    $env:USERPROFILE,
    $env:LOCALAPPDATA,
    $env:APPDATA,
    (Join-Path $env:USERPROFILE 'Desktop'),
    (Join-Path $env:USERPROFILE 'Documents'),
    (Join-Path $env:USERPROFILE 'Downloads'),
    (Join-Path $env:USERPROFILE 'Pictures'),
    (Join-Path $env:USERPROFILE 'Videos'),
    (Join-Path $env:USERPROFILE 'Music'),
    (Join-Path $env:USERPROFILE 'OneDrive'),
    'C:\Users',
    'C:\Windows'
)

function Test-SafePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $false }

    # 不能是磁盘根目录
    if ($full -match '^[A-Za-z]:\\?$') { return $false }

    $trim = $full.TrimEnd('\')
    foreach ($p in $script:ProtectedExact) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($trim -ieq $p.TrimEnd('\')) { return $false }
    }

    # 不能是本程序所在目录
    $selfDir = (Get-ScriptDir).TrimEnd('\')
    if ($trim -ieq $selfDir) { return $false }

    # 长度下限，避免误伤
    if ($trim.Length -lt 6) { return $false }

    return $true
}

function Get-PathSize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [double]0 }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return [double]0 }
    if (-not $item.PSIsContainer) { return [double]$item.Length }
    $s = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
          Measure-Object -Property Length -Sum).Sum
    if ($null -eq $s) { return [double]0 }
    return [double]$s
}

function Expand-Targets {
    param($Targets)
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Targets) { return $out }
    foreach ($t in $Targets) {
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        $expanded = [System.Environment]::ExpandEnvironmentVariables($t)
        if ($expanded -match '[\*\?]') {
            $hits = Get-ChildItem -Path $expanded -Force -ErrorAction SilentlyContinue
            foreach ($h in $hits) { [void]$out.Add($h.FullName) }
        } else {
            if (Test-Path -LiteralPath $expanded) { [void]$out.Add($expanded) }
        }
    }
    return $out
}

function Clear-ReadOnlyRecursive {
    param([string]$Path)
    Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            if ($_.Attributes -band ([System.IO.FileAttributes]::ReadOnly -bor [System.IO.FileAttributes]::System -bor [System.IO.FileAttributes]::Hidden)) {
                $_.Attributes = [System.IO.FileAttributes]::Normal
            }
        } catch { }
    }
    try { (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue).Attributes = [System.IO.FileAttributes]::Normal } catch { }
}

function Remove-PathPermanent {
    param([string]$Path, [switch]$KeepRoot)
    if (-not (Test-SafePath $Path)) { return @{ Ok = $false; Msg = '安全校验未通过，已跳过' } }
    if (-not (Test-Path -LiteralPath $Path)) { return @{ Ok = $true; Msg = '不存在' } }

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return @{ Ok = $true; Msg = '不存在' } }
    $isDir = $item.PSIsContainer
    $failed = New-Object System.Collections.ArrayList

    if ($isDir -and $KeepRoot) {
        # 只清空目录内容，保留目录本身
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $child = $_
            try {
                if ($child.PSIsContainer) { [System.IO.Directory]::Delete($child.FullName, $true) }
                else { [System.IO.File]::Delete($child.FullName) }
            } catch { [void]$failed.Add($child.FullName) }
        }
    } elseif ($isDir) {
        try { [System.IO.Directory]::Delete($Path, $true) } catch { [void]$failed.Add($Path) }
    } else {
        try { [System.IO.File]::Delete($Path) } catch { [void]$failed.Add($Path) }
    }

    # 只读 / 隐藏 / 系统属性会导致删除失败，清掉属性后重试
    if ($failed.Count -gt 0) {
        foreach ($f in $failed) {
            if (-not (Test-Path -LiteralPath $f)) { continue }
            try { Clear-ReadOnlyRecursive -Path $f } catch { }
            try {
                $it = Get-Item -LiteralPath $f -Force -ErrorAction Stop
                if ($it.PSIsContainer) { [System.IO.Directory]::Delete($f, $true) }
                else { [System.IO.File]::Delete($f) }
            } catch { }
        }
    }

    # 复核结果
    $remain = 0
    if (Test-Path -LiteralPath $Path) {
        if ($KeepRoot -and $isDir) {
            $remain = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue).Count
        } else {
            $remain = 1
        }
    }

    if ($remain -eq 0) { return @{ Ok = $true; Msg = '已删除' } }
    return @{ Ok = $false; Msg = ('仍有 ' + $remain + ' 项未能删除，可能被程序占用') }
}

# ======================= 清理项目目录 =======================

function New-Entry {
    param(
        [string]$Id, [string]$Name, [string]$Desc, [string]$Kind,
        [string[]]$Targets, [string]$Risk, [bool]$Default, [bool]$NeedAdmin
    )
    [PSCustomObject]@{
        Id       = $Id
        Name     = $Name
        Desc     = $Desc
        Kind     = $Kind
        Targets  = $Targets
        Risk     = $Risk
        NeedAdmin = $NeedAdmin
        Size     = [double]0
        Selected = $Default
    }
}

function Get-Catalog {
    $la  = $env:LOCALAPPDATA
    $ad  = $env:APPDATA
    $win = $env:SystemRoot
    $pd  = $env:ProgramData
    $up  = $env:USERPROFILE
    $sd  = $env:SystemDrive

    $list = New-Object System.Collections.ArrayList

    # ---------- 低风险 ----------
    [void]$list.Add((New-Entry 'UserTemp' '用户临时文件' '%TEMP% 中当前用户的临时文件，程序运行留下的垃圾' 'DirContent' @($env:TEMP) '低' $true $false))
    [void]$list.Add((New-Entry 'SystemTemp' '系统临时文件' 'Windows\Temp 系统级临时文件' 'DirContent' @("$win\Temp") '低' $true $true))
    [void]$list.Add((New-Entry 'RecycleBin' '回收站' '清空回收站。注意确认里面没有你还想保留的东西' 'RecycleBin' @() '低' $true $false))
    [void]$list.Add((New-Entry 'ThumbCache' '缩略图 / 图标缓存' '资源管理器的缩略图缓存，删除后浏览图片时自动重建' 'FileGlob' @("$la\Microsoft\Windows\Explorer\thumbcache_*.db", "$la\Microsoft\Windows\Explorer\iconcache_*.db") '低' $true $false))
    [void]$list.Add((New-Entry 'CrashDumps' '崩溃转储文件' '程序崩溃生成的 .dmp 转储，用于排查问题' 'DirContent' @("$la\CrashDumps") '低' $true $false))
    [void]$list.Add((New-Entry 'Wer' 'Windows 错误报告' '系统错误报告缓存' 'DirContent' @("$la\Microsoft\Windows\WER", "$pd\Microsoft\Windows\WER") '低' $true $true))
    [void]$list.Add((New-Entry 'BrowserCache' '浏览器缓存' 'Edge / Chrome 网页缓存、代码缓存，删除后首次打开网页略慢' 'DirContent' @(
        "$la\Microsoft\Edge\User Data\*\Cache",
        "$la\Microsoft\Edge\User Data\*\Code Cache",
        "$la\Microsoft\Edge\User Data\*\GPUCache",
        "$la\Microsoft\Edge\User Data\*\Service Worker\CacheStorage",
        "$la\Google\Chrome\User Data\*\Cache",
        "$la\Google\Chrome\User Data\*\Code Cache",
        "$la\Google\Chrome\User Data\*\GPUCache",
        "$la\Google\Chrome\User Data\*\Service Worker\CacheStorage"
    ) '低' $true $false))
    [void]$list.Add((New-Entry 'DevCache' '开发工具缓存' 'pip / npm / yarn / NuGet / Go / Cargo / Gradle 等包管理器下载缓存' 'DirContent' @(
        "$la\pip\Cache", "$la\npm-cache", "$ad\npm-cache", "$la\Yarn\Cache", "$la\Yarn\Berry\cache",
        "$la\NuGet\v3-cache", "$la\NuGet\plugins-cache", "$la\go-build", "$up\.cache", "$up\.cargo\registry\cache",
        "$up\.gradle\wrapper\dists", "$up\.gradle\daemon"
    ) '低' $true $false))
    [void]$list.Add((New-Entry 'INetCache' '系统网络缓存' 'WinINet / IE 模式网络缓存目录' 'DirContent' @("$la\Microsoft\Windows\INetCache") '低' $true $false))
    [void]$list.Add((New-Entry 'GpuShaderCache' '显卡着色器缓存' 'DirectX 与 AMD / Intel 显卡的着色器缓存，删除后游戏首次加载略慢' 'DirContent' @(
        "$la\D3DSCache", "$la\Microsoft\DirectX Shader Cache",
        "$la\AMD\DxCache", "$la\AMD\GLCache", "$la\Intel\ShaderCache"
    ) '低' $true $false))
    [void]$list.Add((New-Entry 'BrowserGpuCache' '浏览器 GPU 着色器缓存' 'Edge / Chrome 的 GPU 着色器缓存，与网页缓存分开存放' 'DirContent' @(
        "$la\Microsoft\Edge\User Data\ShaderCache",
        "$la\Microsoft\Edge\User Data\GrShaderCache",
        "$la\Microsoft\Edge\User Data\GraphiteDawnCache",
        "$la\Google\Chrome\User Data\ShaderCache",
        "$la\Google\Chrome\User Data\GrShaderCache",
        "$la\Google\Chrome\User Data\GraphiteDawnCache"
    ) '低' $true $false))
    [void]$list.Add((New-Entry 'WebView2Cache' 'WebView2 应用缓存' 'Office / Teams 等内嵌浏览器组件的网页缓存，删除后首次加载略慢' 'DirContent' @(
        "$la\Microsoft\EdgeWebView\User Data\*\EBWebView\*\Cache",
        "$la\Microsoft\EdgeWebView\User Data\*\EBWebView\*\Code Cache",
        "$la\Microsoft\EdgeWebView\User Data\*\EBWebView\*\GPUCache"
    ) '低' $true $false))
    [void]$list.Add((New-Entry 'VSCodeCache' 'VS Code 缓存' 'CachedData、GPU 缓存与启动日志，删除后首次启动略慢' 'DirContent' @(
        "$ad\Code\Cache", "$ad\Code\CachedData", "$ad\Code\GPUCache",
        "$ad\Code\Code Cache", "$ad\Code\logs"
    ) '低' $true $false))
    [void]$list.Add((New-Entry 'BrowserCrashReport' '浏览器崩溃报告' 'Edge / Chrome 崩溃后留下的报告文件' 'DirContent' @(
        "$la\Microsoft\Edge\User Data\Crashpad\reports",
        "$la\Google\Chrome\User Data\Crashpad\reports"
    ) '低' $true $false))
    [void]$list.Add((New-Entry 'RdpCache' '远程桌面缓存' '远程桌面连接的位图缓存，删除后首次连接略慢' 'DirContent' @("$la\Microsoft\Terminal Server Client\Cache") '低' $true $false))

    # ---------- 中风险 ----------
    [void]$list.Add((New-Entry 'MavenGradle' 'Maven / Gradle 本地仓库' 'Java 依赖本地仓库，删除后下次构建会重新下载（可能很久）' 'DirContent' @("$up\.m2\repository", "$up\.gradle\caches") '中' $false $false))
    [void]$list.Add((New-Entry 'WinUpdate' 'Windows 更新缓存' '已下载的更新安装包，不影响已经装好的更新' 'DirContent' @("$win\SoftwareDistribution\Download") '中' $false $true))
    [void]$list.Add((New-Entry 'DeliveryOpt' '更新传递优化缓存' 'Windows 更新的 P2P 分发缓存' 'DirContent' @(
        "$win\SoftwareDistribution\DeliveryOptimization",
        "$win\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization"
    ) '中' $false $true))
    [void]$list.Add((New-Entry 'Prefetch' '预读取文件 (Prefetch)' '程序启动加速缓存，删除后前几次启动会略慢' 'DirContent' @("$win\Prefetch") '中' $false $true))
    [void]$list.Add((New-Entry 'WinLogs' 'Windows 日志' '系统日志、CBS 与 DISM 日志' 'DirContent' @("$win\Logs") '中' $false $true))
    [void]$list.Add((New-Entry 'FontCache' '字体缓存' '系统字体缓存，删除后会自动重建' 'DirContent' @("$win\ServiceProfiles\LocalService\AppData\Local\FontCache") '中' $false $true))
    [void]$list.Add((New-Entry 'NvShader' 'NVIDIA 着色器缓存' '显卡着色器缓存，删除后游戏首次加载略慢' 'DirContent' @("$la\NVIDIA\DXCache", "$la\NVIDIA\GLCache", "$pd\NVIDIA Corporation\NV_Cache") '中' $false $false))
    [void]$list.Add((New-Entry 'NvInstaller' 'NVIDIA 安装包缓存' 'NVIDIA App 下载的驱动安装包残留' 'RemoveDir' @("$pd\NVIDIA Corporation\NVIDIA App\UpdateFramework\ota-artifacts") '中' $false $true))
    [void]$list.Add((New-Entry 'PkgCache' '安装包缓存 (Package Cache)' 'VS / VC++ 运行库安装缓存，删除后修复或卸载软件时可能要重下' 'DirContent' @("$pd\Package Cache") '中' $false $true))
    [void]$list.Add((New-Entry 'EventLog' '系统事件日志' '清空事件查看器中的日志内容' 'EventLog' @() '中' $false $true))
    [void]$list.Add((New-Entry 'Dism' 'Windows 组件清理 (DISM)' '清理 WinSxS 中的旧组件，耗时较长，清理后无法回滚已装更新' 'Dism' @() '中' $false $true))
    [void]$list.Add((New-Entry 'AdobeMediaCache' 'Adobe 媒体缓存' 'Premiere / After Effects 等生成的媒体缓存，删除后需重新生成' 'DirContent' @(
        "$ad\Adobe\Common\Media Cache",
        "$ad\Adobe\Common\Media Cache Files",
        "$ad\Adobe\Common\Peak Files"
    ) '中' $false $false))
    [void]$list.Add((New-Entry 'UwpCache' '商店应用缓存' '商店 / UWP 应用的本地缓存与临时状态，个别应用会把设置放这里' 'DirContent' @(
        "$la\Packages\*\LocalCache",
        "$la\Packages\*\AC\Temp",
        "$la\Packages\*\TempState"
    ) '中' $false $false))
    [void]$list.Add((New-Entry 'OfficeCache' 'Office 缓存' 'Office 文档缓存与协作漫游缓存，删除后首次打开文档略慢' 'DirContent' @(
        "$la\Microsoft\Office\16.0\OfficeFileCache",
        "$la\Microsoft\Office\16.0\Wef"
    ) '中' $false $false))
    [void]$list.Add((New-Entry 'IdeCache' 'IDE 索引缓存' 'JetBrains / Visual Studio 的索引缓存，删除后需重新索引项目' 'DirContent' @(
        "$la\JetBrains\*\caches",
        "$la\Microsoft\VisualStudio\*\ComponentModelCache"
    ) '中' $false $false))
    [void]$list.Add((New-Entry 'SystemLogExtra' '系统组件日志与缓存' '系统组件与 ETW / WMI 追踪日志、系统图标缓存' 'DirContent' @(
        "$win\System32\LogFiles",
        "$pd\Microsoft\Windows\Caches"
    ) '中' $false $true))

    # ---------- 高风险 ----------
    [void]$list.Add((New-Entry 'MemoryDump' '内存转储文件' 'C:\MEMORY.DMP 与 Minidump，排查蓝屏用' 'RemoveDir' @("$sd\MEMORY.DMP", "$win\Minidump") '高' $false $true))
    [void]$list.Add((New-Entry 'UpgradeLeftover' '系统升级残留目录' '$WINDOWS.~BT / $WINDOWS.~WS 升级临时目录，以及 $WinREAgent / $GetCurrent / Panther 安装残留' 'RemoveDir' @("$sd\`$WINDOWS.~BT", "$sd\`$WINDOWS.~WS", "$sd\`$WinREAgent", "$sd\`$GetCurrent", "$win\Panther") '高' $false $true))
    [void]$list.Add((New-Entry 'WindowsOld' 'Windows.old' '系统升级前的旧系统备份，删除后无法回退到旧版本' 'RemoveDir' @("$sd\Windows.old") '高' $false $true))
    [void]$list.Add((New-Entry 'Hibernate' '休眠文件 (hiberfil.sys)' '关闭休眠并删除休眠文件，会同时关闭「快速启动」功能' 'Hibernate' @() '高' $false $true))

    return $list
}

function Initialize-Entries {
    param($Config)
    $script:Entries.Clear()
    foreach ($e in (Get-Catalog)) {
        if ($Config -and $Config.Selected -and $Config.Selected.ContainsKey($e.Id)) {
            $e.Selected = [bool]$Config.Selected[$e.Id]
        }
        [void]$script:Entries.Add($e)
    }
}

# ======================= 扫描与清理核心 =======================

function Measure-Entry {
    param($Entry)
    switch ($Entry.Kind) {
        'RecycleBin' {
            $Entry.Size = Get-PathSize (Join-Path $env:SystemDrive '$Recycle.Bin')
        }
        'Hibernate' {
            $Entry.Size = Get-PathSize (Join-Path $env:SystemDrive 'hiberfil.sys')
        }
        'Dism' {
            $Entry.Size = Get-PathSize (Join-Path $env:SystemRoot 'WinSxS')
        }
        'EventLog' {
            $Entry.Size = [double]0
        }
        default {
            $sum = [double]0
            foreach ($p in (Expand-Targets $Entry.Targets)) { $sum += Get-PathSize $p }
            $Entry.Size = $sum
        }
    }
}

function Invoke-Entry {
    param($Entry)
    $freed = [double]0
    switch ($Entry.Kind) {

        'RecycleBin' {
            $bin = Join-Path $env:SystemDrive '$Recycle.Bin'
            $before = Get-PathSize $bin
            try { Clear-RecycleBin -DriveLetter ($env:SystemDrive.TrimEnd(':')) -Force -ErrorAction Stop }
            catch {
                Get-ChildItem -LiteralPath $bin -Force -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                    try { [System.IO.Directory]::Delete($_.FullName, $true) } catch { }
                }
            }
            Start-Sleep -Milliseconds 800
            $after = Get-PathSize $bin
            $freed = [Math]::Max(0, $before - $after)
        }

        'Hibernate' {
            $f = Join-Path $env:SystemDrive 'hiberfil.sys'
            $before = Get-PathSize $f
            try { Start-Process -FilePath 'powercfg.exe' -ArgumentList '/h', 'off' -Wait -NoNewWindow -ErrorAction Stop } catch { }
            Start-Sleep -Seconds 2
            $after = Get-PathSize $f
            $freed = [Math]::Max(0, $before - $after)
        }

        'Dism' {
            try {
                $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\Dism.exe') `
                                   -ArgumentList '/Online', '/Cleanup-Image', '/StartComponentCleanup' `
                                   -Wait -PassThru -NoNewWindow -ErrorAction Stop
                Write-Log ('    DISM 退出码: ' + $p.ExitCode)
            } catch { Write-Log ('    DISM 执行失败: ' + $_.Exception.Message) }
            $freed = 0
        }

        'EventLog' {
            try {
                $logs = & wevtutil.exe el 2>$null
                foreach ($l in $logs) { & wevtutil.exe cl "$l" 2>$null | Out-Null }
            } catch { }
            $freed = 0
        }

        default {
            foreach ($p in (Expand-Targets $Entry.Targets)) {
                $before = Get-PathSize $p
                $keepRoot = ($Entry.Kind -eq 'DirContent')
                $r = Remove-PathPermanent -Path $p -KeepRoot:$keepRoot
                $after = Get-PathSize $p
                $freed += [Math]::Max(0, $before - $after)
                if (-not $r.Ok) { Write-Log ('    跳过 ' + $p + ' : ' + $r.Msg) }
            }
        }
    }
    return $freed
}

function Start-Clean {
    param([scriptblock]$Report, [scriptblock]$Progress)

    $script:Cleaning = $true
    $totalFreed = [double]0
    $targets = @($script:Entries | Where-Object { $_.Selected })
    $i = 0

    foreach ($e in $targets) {
        if ($script:Abort) { break }
        $i++
        if ($Progress) { & $Progress $i $targets.Count $e }
        Write-Log ('[清理] ' + $e.Name)
        $freed = Invoke-Entry -Entry $e
        $totalFreed += $freed
        Write-Log ('    释放 ' + (Format-Size $freed))
        if ($Report) { & $Report $e $freed }
    }

    $script:Cleaning = $false
    return $totalFreed
}

function Write-Log {
    param([string]$Text)
    if ($script:LogBox) {
        $script:LogBox.AppendText($Text + [Environment]::NewLine)
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
    } else {
        Write-Host $Text
    }
}

function Get-DiskInfo {
    $d = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $env:SystemDrive + "'")
    if (-not $d) { return $null }
    return [PSCustomObject]@{
        Total = [double]$d.Size
        Free  = [double]$d.FreeSpace
        Used  = [double]($d.Size - $d.FreeSpace)
    }
}

# ======================= 控制台模式 =======================

function Invoke-ConsoleMode {
    param([switch]$AutoRun)

    Write-Host ''
    Write-Host ("=== {0} v{1} (控制台模式) ===" -f $script:AppName, $script:Version)
    Write-Host ("管理员权限: {0}" -f $script:IsAdmin)
    $d0 = Get-DiskInfo
    if ($d0) { Write-Host ("磁盘 {0}  总 {1}  可用 {2}" -f $env:SystemDrive, (Format-Size $d0.Total), (Format-Size $d0.Free)) }
    Write-Host ''

    Write-Host '正在扫描...'
    foreach ($e in $script:Entries) {
        Measure-Entry -Entry $e
        $flag = '[ ]'
        if ($e.Selected) { $flag = '[x]' }
        Write-Host ('  {0} {1,-28} {2,10}  {3}' -f $flag, $e.Name, (Format-Size $e.Size), $e.Risk)
    }

    $picked = @($script:Entries | Where-Object { $_.Selected })
    if ($picked.Count -eq 0) { Write-Host '没有勾选任何项目，退出。'; return }

    Write-Host ''
    Write-Host ("将清理 {0} 个项目（永久删除，不进回收站）" -f $picked.Count)
    if (-not $AutoRun) {
        $ans = Read-Host '确认执行？输入 Y 继续'
        if ($ans -ne 'Y' -and $ans -ne 'y') { Write-Host '已取消。'; return }
    }

    $freed = Start-Clean
    $d1 = Get-DiskInfo
    Write-Host ''
    Write-Host ("清理完成，共释放 {0}" -f (Format-Size $freed))
    if ($d1) { Write-Host ("磁盘 {0}  可用 {1}" -f $env:SystemDrive, (Format-Size $d1.Free)) }
}

# ======================= 图形界面（Miuix 风格） =======================
# 设计令牌取自 Miuix 官方规范（Color System / Button / Card / Switch，Light 模式）
#   primary #3482FF  secondaryVariant #F0F0F0  surface #F7F7F7  dividerLine #E0E0E0
#   卡片与按钮圆角 16dp，按钮最小高度 40dp，字体优先 MiSans
#
# 性能要点（避免卡顿）：
#   1. 颜色 / 画刷 / 画笔 / 圆角路径 / 文本格式 全部预先构建并缓存，绘制期零新建对象
#   2. 悬停与勾选只重绘受影响的那一行，不再整列表重绘
#   3. 文字用 ClearTypeGridFit，配合 DPI 感知获得清晰字形
# 清晰度要点（避免发虚）：
#   进程声明为 DPI 感知，按真实 DPI 缩放布局，避免系统位图放大导致的模糊

$script:Mx = @{
    Primary                   = '#FF3482FF'
    PrimaryHover              = '#FF2C74E8'
    OnPrimary                 = '#FFFFFFFF'
    Secondary                 = '#FFE6E6E6'
    SecondaryVariant          = '#FFF0F0F0'
    OnSecondaryVariant        = '#FF303030'
    OnBackground              = '#FF000000'
    Surface                   = '#FFF7F7F7'
    SurfaceVariant            = '#FFFFFFFF'
    OnSurfaceSecondary        = '#CC000000'
    SurfaceContainer          = '#FFFFFFFF'
    OnSurfaceContainerVariant = '#FF959595'
    SurfaceContainerHigh      = '#FFE8E8E8'
    Outline                   = '#FFD9D9D9'
    DividerLine               = '#FFE0E0E0'
    Error                     = '#FFE94634'
    DisabledPrimary           = '#FFC2D9FF'
    DisabledOnPrimary         = '#FFF3F8FF'
    Hover                     = '#FFF0F0F0'
    ChipLowFg                 = '#FF3AA76D'
    ChipLowBg                 = '#FFE8F6EE'
    ChipMidFg                 = '#FFD98A00'
    ChipMidBg                 = '#FFFCF3E3'
    ChipHighFg                = '#FFE94634'
    ChipHighBg                = '#FFFCEFED'
    ChartCleanSel             = '#FF3482FF'
    ChartClean                = '#FFA6C6FF'
    ChartUsed                 = '#FFB9C4D6'
    ChartFree                 = '#FFE8EDF5'
}

$script:MxRadius = 16
$script:MxDpi = 96
$script:MxScale = 1.0

# ---------- DPI 感知（必须在创建任何窗口之前调用）----------

function Initialize-MxDpiAwareness {
    if (-not ('MxNative.Dpi' -as [type])) {
        try {
            Add-Type -Namespace MxNative -Name Dpi -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true)] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
[DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
[DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
[DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr hdc, int nIndex);
'@ -ErrorAction Stop
        } catch { }
    }
    if ('MxNative.Dpi' -as [type]) {
        try { [void][MxNative.Dpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { }
        try { [void][MxNative.Dpi]::SetProcessDpiAwareness(2) } catch { }
        try { [void][MxNative.Dpi]::SetProcessDPIAware() } catch { }
    }
    $dpi = 96
    try {
        if ('MxNative.Dpi' -as [type]) {
            $hdc = [MxNative.Dpi]::GetDC([IntPtr]::Zero)
            $d = [MxNative.Dpi]::GetDeviceCaps($hdc, 88)   # LOGPIXELSX
            [void][MxNative.Dpi]::ReleaseDC([IntPtr]::Zero, $hdc)
            if ($d -ge 72 -and $d -le 480) { $dpi = $d }
        }
    } catch { $dpi = 96 }
    $script:MxDpi = $dpi
    $script:MxScale = $dpi / 96.0
}

# ---------- 缩放助手（布局用逻辑单位，按 DPI 换算成像素）----------

function MxU  { param([double]$v) return [int][Math]::Round($v * $script:MxScale) }
function MxUF { param([double]$v) return ($v * $script:MxScale) }

# ---------- 颜色 / 画刷 / 画笔 缓存 ----------

$script:MxColorCache = @{}
function Get-MxColor {
    param([string]$Hex)
    if ([string]::IsNullOrWhiteSpace($Hex)) { return [System.Drawing.Color]::Transparent }
    $c = $script:MxColorCache[$Hex]
    if ($null -ne $c) { return $c }
    $col = [System.Drawing.Color]::FromArgb(
        [Convert]::ToInt32($Hex.Substring(1, 2), 16),
        [Convert]::ToInt32($Hex.Substring(3, 2), 16),
        [Convert]::ToInt32($Hex.Substring(5, 2), 16),
        [Convert]::ToInt32($Hex.Substring(7, 2), 16))
    $script:MxColorCache[$Hex] = $col
    return $col
}

$script:MxBrushCache = @{}
function Get-MxBrush {
    param([System.Drawing.Color]$Color)
    $k = $Color.ToArgb()
    $b = $script:MxBrushCache[$k]
    if ($null -ne $b) { return $b }
    $nb = New-Object System.Drawing.SolidBrush($Color)
    $script:MxBrushCache[$k] = $nb
    return $nb
}

$script:MxPenCache = @{}
function Get-MxPen {
    param([System.Drawing.Color]$Color, [double]$Width = 1)
    $k = ('{0}_{1}' -f $Color.ToArgb(), $Width)
    $p = $script:MxPenCache[$k]
    if ($null -ne $p) { return $p }
    $np = New-Object System.Drawing.Pen($Color, ([single]$Width))
    $script:MxPenCache[$k] = $np
    return $np
}

# ---------- 圆角路径 / 控件基础 ----------

function New-RoundedPath {
    param([System.Drawing.RectangleF]$Rect, [double]$Radius)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($Radius -le 0) { $p.AddRectangle($Rect); return $p }
    $d = $Radius * 2
    if ($d -gt $Rect.Width)  { $d = $Rect.Width }
    if ($d -gt $Rect.Height) { $d = $Rect.Height }
    $p.AddArc($Rect.X, $Rect.Y, $d, $d, 180, 90)
    $p.AddArc($Rect.Right - $d, $Rect.Y, $d, $d, 270, 90)
    $p.AddArc($Rect.Right - $d, $Rect.Bottom - $d, $d, $d, 0, 90)
    $p.AddArc($Rect.X, $Rect.Bottom - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Set-RoundedRegion {
    param($Control, [double]$Radius)
    if ($Control.Width -le 0 -or $Control.Height -le 0) { return }
    $r = New-Object System.Drawing.RectangleF(0, 0, $Control.Width, $Control.Height)
    $p = New-RoundedPath -Rect $r -Radius $Radius
    $Control.Region = New-Object System.Drawing.Region($p)
    $p.Dispose()
}

function Enable-DoubleBuffer {
    param($Control)
    try {
        $t = $Control.GetType()
        $pi = $t.GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
        if ($pi) { $pi.SetValue($Control, $true, $null) }
        $mi = $t.GetMethod('SetStyle', [System.Reflection.BindingFlags]'Instance,NonPublic')
        if ($mi) {
            $styles = [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer -bor `
                      [System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint -bor `
                      [System.Windows.Forms.ControlStyles]::UserPaint
            $mi.Invoke($Control, @($styles, $true)) | Out-Null
        }
    } catch { }
}

function New-MxFont {
    param(
        [double]$Size,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular,
        [string[]]$Names
    )
    if (-not $Names) { $Names = @('MiSans', 'MiSans Normal', 'Microsoft YaHei UI', 'Microsoft YaHei', 'SimSun', 'Arial') }
    foreach ($n in $Names) {
        try {
            $f = New-Object System.Drawing.Font($n, $Size, $Style)
            if ($f) { return $f }
        } catch { }
    }
    return ([System.Drawing.SystemFonts]::DefaultFont)
}

function New-MxCard {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [int]$Radius = 16)
    $c = New-Object System.Windows.Forms.Panel
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.Size = New-Object System.Drawing.Size($W, $H)
    $c.BackColor = (Get-MxColor $script:Mx.SurfaceVariant)
    Enable-DoubleBuffer $c
    Set-RoundedRegion -Control $c -Radius $Radius
    return $c
}

# ---------- 开关（路径预先算好，绘制期零分配）----------

# 按面板宽度构建开关/悬停路径。
# 放在脚本作用域是为了让绘制逻辑能在发现几何过期时自行重建，
# 不依赖某个更早的初始化时机（否则一旦时序不对，开关会整体画不出来）。
function Build-MxSwitchPaths {
    param([int]$ViewWidth)
    if ($ViewWidth -le 0) { return $false }
    $n = $script:Entries.Count
    if ($n -le 0) { return $false }

    $rowH = $script:MxRowH
    $swW = $script:MxSwW
    $swH = $script:MxSwH
    $swPad = $script:MxSwPad
    $padX = $script:MxRowPadX
    $hx = $script:MxHoverX
    $hy = $script:MxHoverY
    $hr = $script:MxHoverR

    $swX = $ViewWidth - $padX - $swW
    $hoverW = $ViewWidth - $hx * 2
    if ($swX -lt 1 -or $hoverW -lt 1) { return $false }
    if ($swH -le $swPad * 2 -or $rowH -le $hy * 2) { return $false }

    $swY0 = ($rowH - $swH) / 2
    $thumbD = $swH - $swPad * 2
    $thumbY0 = $swY0 + $swPad
    $thumbOffX = $swX + $swPad
    $thumbOnX = $swX + $swW - $swPad - $thumbD

    $track = @()
    $thumbOn = @()
    $thumbOff = @()
    $hover = @()
    for ($i = 0; $i -lt $n; $i++) {
        $top = $i * $rowH
        $track    += (New-RoundedPath -Rect (New-Object System.Drawing.RectangleF($swX, ($top + $swY0), $swW, $swH)) -Radius ($swH / 2))
        $thumbOn  += (New-RoundedPath -Rect (New-Object System.Drawing.RectangleF($thumbOnX, ($top + $thumbY0), $thumbD, $thumbD)) -Radius ($thumbD / 2))
        $thumbOff += (New-RoundedPath -Rect (New-Object System.Drawing.RectangleF($thumbOffX, ($top + $thumbY0), $thumbD, $thumbD)) -Radius ($thumbD / 2))
        $hover    += (New-RoundedPath -Rect (New-Object System.Drawing.RectangleF($hx, ($top + $hy), $hoverW, ($rowH - $hy * 2))) -Radius $hr)
    }

    # 全部构建成功后再整体替换，避免中途失败留下空数组
    $script:MxPathTrack = $track
    $script:MxPathThumbOn = $thumbOn
    $script:MxPathThumbOff = $thumbOff
    $script:MxPathHover = $hover
    $script:MxGeomVw = $ViewWidth
    return $true
}

function Draw-MxSwitchAt {
    param($Graphics, [int]$Row, [bool]$Checked, [int]$ViewWidth, [bool]$Enabled = $true)

    # 几何与当前面板宽度不符时立即重建，保证开关不会因几何过期而消失
    if ($ViewWidth -ne $script:MxGeomVw) {
        if (-not (Build-MxSwitchPaths -ViewWidth $ViewWidth)) { return }
    }

    $trackColor = Get-MxColor $script:Mx.SurfaceContainerHigh
    if ($Checked) { $trackColor = Get-MxColor $script:Mx.Primary }
    if (-not $Enabled) { $trackColor = Get-MxColor $script:Mx.DisabledPrimary }

    $trackPath = $null
    if (@($script:MxPathTrack).Count -gt $Row) { $trackPath = $script:MxPathTrack[$Row] }
    if ($null -eq $trackPath) { return }

    $Graphics.FillPath((Get-MxBrush $trackColor), $trackPath)

    $thumbPath = $null
    if (@($script:MxPathThumbOff).Count -gt $Row) { $thumbPath = $script:MxPathThumbOff[$Row] }
    if ($Checked -and @($script:MxPathThumbOn).Count -gt $Row) { $thumbPath = $script:MxPathThumbOn[$Row] }
    if ($null -eq $thumbPath) { return }

    $Graphics.FillPath((Get-MxBrush (Get-MxColor $script:Mx.OnPrimary)), $thumbPath)
    if (-not $Checked) {
        $Graphics.DrawPath((Get-MxPen (Get-MxColor $script:Mx.Outline) (MxU 1)), $thumbPath)
    }
}

# ---------- 按钮 ----------

function New-MxButton {
    param(
        [string]$Text,
        [int]$Width,
        [int]$Height = 40,
        [ValidateSet('Primary', 'Secondary', 'Text')][string]$Kind = 'Secondary',
        [scriptblock]$OnClick
    )
    $b = New-Object System.Windows.Forms.Panel
    $b.Size = New-Object System.Drawing.Size($Width, $Height)
    $b.Cursor = 'Hand'
    $b.Tag = [PSCustomObject]@{ Text = $Text; Kind = $Kind; Hover = $false; Down = $false; Enabled = $true; OnClick = $OnClick; Radius = $script:MxRadius }

    $b.add_Paint({
        param($sender, $e)
        $t = $sender.Tag
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

        $fill = Get-MxColor $script:Mx.SecondaryVariant
        $fg   = Get-MxColor $script:Mx.OnSecondaryVariant
        if ($t.Kind -eq 'Primary') {
            $fill = Get-MxColor $script:Mx.Primary
            $fg   = Get-MxColor $script:Mx.OnPrimary
            if ($t.Hover -and $t.Enabled) { $fill = Get-MxColor $script:Mx.PrimaryHover }
        } elseif ($t.Kind -eq 'Secondary') {
            if ($t.Hover -and $t.Enabled) { $fill = Get-MxColor $script:Mx.Secondary }
        }
        if (-not $t.Enabled) {
            $fill = Get-MxColor $script:Mx.DisabledPrimary
            $fg   = Get-MxColor $script:Mx.DisabledOnPrimary
        }

        $rect = New-Object System.Drawing.RectangleF(0, 0, $sender.Width, $sender.Height)
        if ($sender.Parent) { $g.Clear($sender.Parent.BackColor) }
        $path = New-RoundedPath -Rect $rect -Radius $t.Radius
        $g.FillPath((Get-MxBrush $fill), $path)
        $path.Dispose()

        $g.DrawString($t.Text, $script:FBtn, (Get-MxBrush $fg), $rect, $script:MxSfCenter)
    })

    $b.add_MouseEnter({ param($sender, $e) $sender.Tag.Hover = $true; $sender.Invalidate() })
    $b.add_MouseLeave({ param($sender, $e) $sender.Tag.Hover = $false; $sender.Tag.Down = $false; $sender.Invalidate() })
    $b.add_MouseDown({ param($sender, $e) $sender.Tag.Down = $true })
    $b.add_MouseUp({
        param($sender, $e)
        $t = $sender.Tag
        if ($t.Down -and $t.Enabled -and $t.OnClick) { & $t.OnClick }
        $t.Down = $false
    })

    Set-RoundedRegion -Control $b -Radius $script:MxRadius
    return $b
}

function New-MxCaptionButton {
    param([ValidateSet('Min', 'Close')][string]$Kind)
    $b = New-Object System.Windows.Forms.Panel
    $b.Size = New-Object System.Drawing.Size((MxU 32), (MxU 32))
    $b.Cursor = 'Hand'
    $b.Tag = [PSCustomObject]@{ Kind = $Kind; Hover = $false }
    Enable-DoubleBuffer $b

    $b.add_Paint({
        param($sender, $e)
        $t = $sender.Tag
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

        $bg = Get-MxColor $script:Mx.SecondaryVariant
        $fg = Get-MxColor $script:Mx.OnSecondaryVariant
        if ($t.Hover) {
            if ($t.Kind -eq 'Close') { $bg = Get-MxColor $script:Mx.Error; $fg = Get-MxColor $script:Mx.OnPrimary }
            else { $bg = Get-MxColor $script:Mx.Secondary }
        }
        if ($sender.Parent) { $g.Clear($sender.Parent.BackColor) }
        $rect = New-Object System.Drawing.RectangleF(0, 0, $sender.Width, $sender.Height)
        $p = New-RoundedPath -Rect $rect -Radius ($sender.Width / 2)
        $g.FillPath((Get-MxBrush $bg), $p)
        $p.Dispose()

        $pen = Get-MxPen $fg (MxUF 1.4)
        $c = $sender.Width / 2
        if ($t.Kind -eq 'Min') {
            $g.DrawLine($pen, [single]($c - (MxU 5)), [single]($c + (MxU 1)), [single]($c + (MxU 5)), [single]($c + (MxU 1)))
        } else {
            $g.DrawLine($pen, [single]($c - (MxU 4.5)), [single]($c - (MxU 4.5)), [single]($c + (MxU 4.5)), [single]($c + (MxU 4.5)))
            $g.DrawLine($pen, [single]($c + (MxU 4.5)), [single]($c - (MxU 4.5)), [single]($c - (MxU 4.5)), [single]($c + (MxU 4.5)))
        }
    })

    $b.add_MouseEnter({ param($sender, $e) $sender.Tag.Hover = $true; $sender.Invalidate() })
    $b.add_MouseLeave({ param($sender, $e) $sender.Tag.Hover = $false; $sender.Invalidate() })
    return $b
}

# ---------- 环形图 ----------

# 画一个环形图（甜甜圈）：
#   先用 FillPie 依次铺满外圆形成各扇形，再用卡片底色 FillEllipse 挖出中心，得到圆环。
#   比逐段拼接圆环路径简单，也不会有相邻弧线之间的接缝毛刺。
# 所有尺寸与颜色都从参数传入，绘制期不产生新的画刷对象（颜色统一走 Get-MxBrush 缓存）。
function Draw-MxDonut {
    param(
        [System.Drawing.Graphics]$Graphics,
        [double]$Cx, [double]$Cy,
        [double]$OuterR, [double]$InnerR,
        [double[]]$Values,
        [string[]]$Colors,
        [System.Drawing.Color]$BackColor
    )

    # 坐标一律用数值重载：FillPie 若传 RectangleF，PowerShell 会误选
    # FillPie(Brush, Rectangle, float, float) 并抛出类型转换异常。
    $ox = $Cx - $OuterR
    $oy = $Cy - $OuterR
    $od = $OuterR * 2

    $total = [double]0
    foreach ($v in $Values) { if ($v -gt 0) { $total += [double]$v } }

    if ($total -le 0) {
        # 没有任何数据时画一个完整的浅色圆环，避免出现空洞
        $Graphics.FillEllipse((Get-MxBrush (Get-MxColor $script:Mx.ChartUsed)), $ox, $oy, $od, $od)
    } else {
        $start = -90.0   # 从 12 点方向开始，顺时针铺开
        for ($i = 0; $i -lt $Values.Count; $i++) {
            $v = [double]$Values[$i]
            if ($v -le 0) { continue }
            $sweep = 360.0 * $v / $total
            if ($sweep -le 0) { continue }
            $Graphics.FillPie((Get-MxBrush (Get-MxColor $Colors[$i])), $ox, $oy, $od, $od, $start, $sweep)
            $start += $sweep
        }
    }

    # 挖中心形成圆环
    $Graphics.FillEllipse((Get-MxBrush $BackColor), ($Cx - $InnerR), ($Cy - $InnerR), ($InnerR * 2), ($InnerR * 2))
}

# ---------- 对话框 ----------

function Show-MxDialog {
    param(
        [string]$Title,
        [string]$Message,
        [string]$PrimaryText = '确定',
        [string]$SecondaryText = '',
        [int]$Width = 480,
        [switch]$ScrollBody,
        [switch]$CenterScreen
    )

    # WinForms 的多行 TextBox 由系统原生控件绘制，只把 \r\n 当换行，脚本里常见的纯 \n
    # 会被直接忽略，正文就会挤成一行。这里统一规范为 \r\n（先清掉 \r 再补，避免出现 \r\r\n）。
    $Message = ($Message -replace "`r", '') -replace "`n", "`r`n"

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.FormBorderStyle = 'None'
    $dlg.StartPosition = 'CenterParent'
    # 没有宿主窗口时（例如首次启动的免责声明，此时主界面尚未创建）CenterParent 无从对齐，改用屏幕居中
    if ($CenterScreen) { $dlg.StartPosition = 'CenterScreen' }
    $dlg.ShowInTaskbar = $false
    $dlg.BackColor = (Get-MxColor $script:Mx.SurfaceVariant)
    $dlg.Font = $script:FBody
    $dlg.KeyPreview = $true

    $pad = MxU 24
    $w = MxU $Width
    $bodyW = $w - $pad * 2

    # 测量正文高度：注意位图必须与当前 DPI 一致，否则换行位置会算错
    $bmp = New-Object System.Drawing.Bitmap(1, 1)
    $bmp.SetResolution($script:MxDpi, $script:MxDpi)
    $mg = [System.Drawing.Graphics]::FromImage($bmp)
    $mg.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $sz = $mg.MeasureString($Message, $script:FBody, [int]$bodyW)
    $mg.Dispose(); $bmp.Dispose()

    $bodyH = [int][Math]::Ceiling($sz.Height)
    $maxBody = MxU 300
    if ($bodyH -gt $maxBody) { $bodyH = $maxBody }

    $titleY = MxU 22
    $bodyY = MxU 54
    $gapY = MxU 20
    $btnH = MxU 40
    $btnW = MxU 100
    $btnY = $bodyY + $bodyH + $gapY
    $dlgH = $btnY + $btnH + $pad
    $dlg.Size = New-Object System.Drawing.Size($w, $dlgH)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = $Title
    $lblTitle.Font = $script:FHead
    $lblTitle.ForeColor = (Get-MxColor $script:Mx.OnBackground)
    $lblTitle.BackColor = [System.Drawing.Color]::Transparent
    $lblTitle.Location = New-Object System.Drawing.Point($pad, (MxU 22))
    $lblTitle.Size = New-Object System.Drawing.Size($bodyW, (MxU 24))
    $dlg.Controls.Add($lblTitle)

    if ($ScrollBody) {
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Multiline = $true
        $tb.ReadOnly = $true
        $tb.BorderStyle = 'None'
        $tb.ScrollBars = 'Vertical'
        $tb.BackColor = (Get-MxColor $script:Mx.SurfaceVariant)
        $tb.ForeColor = (Get-MxColor $script:Mx.OnSurfaceSecondary)
        $tb.Font = $script:FBody
        $tb.Text = $Message
        $tb.Location = New-Object System.Drawing.Point($pad, $bodyY)
        $tb.Size = New-Object System.Drawing.Size($bodyW, $bodyH)
        $tb.TabStop = $false
        $dlg.Controls.Add($tb)
    } else {
        $lblBody = New-Object System.Windows.Forms.Label
        $lblBody.Text = $Message
        $lblBody.Font = $script:FBody
        $lblBody.ForeColor = (Get-MxColor $script:Mx.OnSurfaceSecondary)
        $lblBody.BackColor = [System.Drawing.Color]::Transparent
        $lblBody.Location = New-Object System.Drawing.Point($pad, $bodyY)
        $lblBody.Size = New-Object System.Drawing.Size($bodyW, $bodyH)
        $dlg.Controls.Add($lblBody)
    }

    $bx = $w - $pad - $btnW
    $btnOk = New-MxButton -Text $PrimaryText -Width $btnW -Height $btnH -Kind 'Primary' -OnClick { $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close() }
    $btnOk.Location = New-Object System.Drawing.Point($bx, $btnY)
    $dlg.Controls.Add($btnOk)

    if ($SecondaryText -ne '') {
        $btnCancel = New-MxButton -Text $SecondaryText -Width $btnW -Height $btnH -Kind 'Secondary' -OnClick { $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.Close() }
        $btnCancel.Location = New-Object System.Drawing.Point(($bx - $btnW - (MxU 12)), $btnY)
        $dlg.Controls.Add($btnCancel)
    }

    Set-RoundedRegion -Control $dlg -Radius $script:MxRadius

    $dlg.add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $sender.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $sender.Close() }
    })

    $drag = [PSCustomObject]@{ On = $false; Start = [System.Drawing.Point]::Empty; Origin = [System.Drawing.Point]::Empty }
    $dlg.add_MouseDown({ param($sender, $e) $drag.On = $true; $drag.Start = [System.Windows.Forms.Cursor]::Position; $drag.Origin = $sender.Location })
    $dlg.add_MouseMove({
        param($sender, $e)
        if ($drag.On) {
            $p = [System.Windows.Forms.Cursor]::Position
            $sender.Location = New-Object System.Drawing.Point(($drag.Origin.X + $p.X - $drag.Start.X), ($drag.Origin.Y + $p.Y - $drag.Start.Y))
        }
    })
    $dlg.add_MouseUp({ param($sender, $e) $drag.On = $false })

    if ($script:RenderTo) {
        $dlg.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 350
        [System.Windows.Forms.Application]::DoEvents()
        $db = New-Object System.Drawing.Bitmap($dlg.Width, $dlg.Height)
        $dlg.DrawToBitmap($db, (New-Object System.Drawing.Rectangle(0, 0, $dlg.Width, $dlg.Height)))
        $out = ($script:RenderTo -replace '\.png$', '') + '_dialog.png'
        $db.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
        $db.Dispose()
        Write-Host ('dialog rendered -> ' + $out)
        $dlg.Close()
        $dlg.Dispose()
        return $true
    }

    $r = $dlg.ShowDialog()
    $dlg.Dispose()
    return ($r -eq [System.Windows.Forms.DialogResult]::OK)
}

# ---------- 首次启动的免责声明 ----------

$script:DisclaimerText = @'
本工具会永久删除文件，删除后不进入回收站，也无法通过常规手段恢复。请先完整阅读以下条款，点击「我已阅读并同意」后方可继续使用。

一、工具性质

本工具为个人开发并免费公开的技术实践项目，不构成商业软件或专业服务，也非微软官方产品或经其认证的组件。本工具按「现状」（AS IS）提供，不附带任何明示或默示担保。

二、风险告知

1. 本工具执行的是永久删除，被删除的文件无法通过常规手段恢复。

2. 部分清理项具有不可逆的系统级影响：清空回收站会丢失其中待恢复的文件；删除 Windows.old 与系统升级残留后无法回退到升级前的系统版本；删除休眠文件会同时关闭「快速启动」；执行 Windows 组件清理 (DISM) 后无法回滚已安装的更新；清空系统事件日志后，原有记录无法再用于事后排查。

3. 部分清理项会导致第三方软件需要重新下载依赖、重新构建或重新安装。

三、使用者的责任

1. 你应在执行清理前自行确认勾选项，并对将要删除的内容有充分了解。

2. 你应自行对重要数据做好备份，建议首次使用前创建完整备份或系统还原点。

3. 是否以管理员权限运行、是否启用启动时自动清理，均由你自主决定。

四、免责条款

在法律允许的最大范围内，作者不对使用或无法使用本工具所导致的任何直接、间接、附带或后果性损失承担责任，包括但不限于数据丢失、文件损坏、系统无法启动、业务中断及数据恢复费用；亦不对因误勾选、自行修改源码、用于违规用途、系统或硬件环境差异、以及第三方二次分发等情形造成的损失负责。

五、其他

本声明为 MIT 许可证的补充说明；若本声明与许可证条款就责任限制事项存在冲突，以对作者责任限制更严格者为准。

完整条款见程序同目录的 DISCLAIMER.md。若你不同意上述任何内容，请选择「不同意并退出」，并删除本工具及其全部副本。
'@

# ---------- 主界面 ----------

function Show-Gui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    # 关键：先声明 DPI 感知，再创建任何窗口，否则整个窗口会被系统位图放大而发虚
    Initialize-MxDpiAwareness

    # ---- Miuix 排版 ----
    # 字体尺寸用「磅」：GDI/GDI+ 会按真实 DPI 自动换算像素，
    # 因此这里不需要乘缩放系数，否则会双重放大。
    $script:FTitle = New-MxFont -Size 15 -Style ([System.Drawing.FontStyle]::Bold)
    $script:FHead  = New-MxFont -Size 12 -Style ([System.Drawing.FontStyle]::Bold)
    $script:FBody  = New-MxFont -Size 11
    $script:FBtn   = New-MxFont -Size 11
    $script:FFoot  = New-MxFont -Size 9.5
    $script:FCap   = New-MxFont -Size 8.5

    $script:MxSfCenter = New-Object System.Drawing.StringFormat
    $script:MxSfCenter.Alignment = [System.Drawing.StringAlignment]::Center
    $script:MxSfCenter.LineAlignment = [System.Drawing.StringAlignment]::Center
    $script:MxSfFar = New-Object System.Drawing.StringFormat
    $script:MxSfFar.Alignment = [System.Drawing.StringAlignment]::Far
    $script:MxSfFar.LineAlignment = [System.Drawing.StringAlignment]::Center

    # 测量用 Graphics，分辨率必须设成当前 DPI，否则文字宽度按 96 DPI 算会偏小
    $script:MxMeasureBmp = New-Object System.Drawing.Bitmap(1, 1)
    $script:MxMeasureBmp.SetResolution($script:MxDpi, $script:MxDpi)
    $script:MxMeasure = [System.Drawing.Graphics]::FromImage($script:MxMeasureBmp)
    $script:MxMeasure.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

    # ---- 首次启动：必须阅读并同意免责声明才进入主界面 ----
    # 自检 / 渲染 / 性能 / 截图模式不弹窗，避免自动化流程被阻塞在模态对话框上
    if (-not $script:DisclaimerAccepted -and -not $script:RenderTo -and -not $script:BenchPaint -and -not $script:SnapTo) {
        $agree = Show-MxDialog -Title '免责声明' -Message $script:DisclaimerText `
                               -PrimaryText '我已阅读并同意' -SecondaryText '不同意并退出' `
                               -Width 560 -ScrollBody -CenterScreen
        if (-not $agree) {
            Write-Host '未同意免责声明，程序退出。'
            return
        }
        $script:DisclaimerAccepted = $true
        Save-Config -Path $script:ConfigPath
    }

    # ---- 布局常量（逻辑单位 → 像素）----
    # 双栏结构：左栏放磁盘环形图 / 自动清理 / 风险统计，右栏放工具条与清理项列表，
    # 运行日志通栏置于底部。列表可视行数由 6 行提升到 8 行。
    $W       = MxU 1180
    $PAD     = MxU 20
    $PAGEH   = MxU 828
    $COL_LX  = $PAD
    $COL_LW  = MxU 372
    $COL_GAP = MxU 16
    $COL_RX  = $COL_LX + $COL_LW + $COL_GAP
    $COL_RW  = $W - $PAD - $COL_RX
    $ROW_H   = MxU 58
    $LIST_H  = MxU 526
    $LIST_PAD = MxU 8
    $SW_W    = MxU 46
    $SW_H    = MxU 26
    $SW_PAD  = MxU 3
    $script:MxRowH = $ROW_H
    $script:MxSwW = $SW_W
    $script:MxSwH = $SW_H
    $script:MxSwPad = $SW_PAD
    $script:MxRowPadX = MxU 24
    $script:MxNameY = MxU 10
    $script:MxDescY = MxU 32
    $script:MxChipY = MxU 12
    $script:MxChipW = MxU 34
    $script:MxChipH = MxU 18
    $script:MxChipGap = MxU 8
    $script:MxSizeW = MxU 118
    $script:MxSizeGap = MxU 12
    $script:MxHoverX = MxU 6
    $script:MxHoverY = MxU 3
    $script:MxHoverR = MxU 12
    $script:MxScrollW = MxU 4
    $script:MxDividerInset = MxU 24
    $script:MxSizeH = MxU 20
    $script:MxMinThumb = MxU 36
    $script:MxPenDivider = Get-MxPen (Get-MxColor $script:Mx.DividerLine) (MxU 1)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$script:AppName v$script:Version"
    $form.ClientSize = New-Object System.Drawing.Size($W, $PAGEH)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'None'
    $form.MaximizeBox = $false
    $form.BackColor = (Get-MxColor $script:Mx.Surface)
    $form.Font = $script:FBody
    $form.KeyPreview = $true

    $root = New-Object System.Windows.Forms.Panel
    $root.Dock = 'Fill'
    $root.BackColor = (Get-MxColor $script:Mx.Surface)
    Enable-DoubleBuffer $root
    $borderPen = Get-MxPen (Get-MxColor $script:Mx.DividerLine) (MxU 1)
    $root.add_Paint({
        param($sender, $e)
        $e.Graphics.DrawRectangle($borderPen, 0, 0, $sender.Width - 1, $sender.Height - 1)
    })
    $form.Controls.Add($root)

    # ---- 标题栏 ----
    $titleBar = New-Object System.Windows.Forms.Panel
    $titleBar.Location = New-Object System.Drawing.Point(1, 1)
    $titleBar.Size = New-Object System.Drawing.Size(($W - 2), (MxU 52))
    $titleBar.BackColor = (Get-MxColor $script:Mx.Surface)
    $root.Controls.Add($titleBar)

    $lblApp = New-Object System.Windows.Forms.Label
    $lblApp.Text = $script:AppName
    $lblApp.Font = $script:FTitle
    $lblApp.ForeColor = (Get-MxColor $script:Mx.OnBackground)
    $lblApp.BackColor = [System.Drawing.Color]::Transparent
    $lblApp.Location = New-Object System.Drawing.Point((MxU 24), (MxU 14))
    $lblApp.Size = New-Object System.Drawing.Size((MxU 320), (MxU 26))
    $titleBar.Controls.Add($lblApp)

    $lblVer = New-Object System.Windows.Forms.Label
    $lblVer.Text = ('v' + $script:Version + '  ·  Miuix')
    $lblVer.Font = $script:FCap
    $lblVer.ForeColor = (Get-MxColor $script:Mx.OnSurfaceContainerVariant)
    $lblVer.BackColor = [System.Drawing.Color]::Transparent
    $lblVer.Location = New-Object System.Drawing.Point((MxU 24), (MxU 34))
    $lblVer.Size = New-Object System.Drawing.Size((MxU 320), (MxU 16))
    $titleBar.Controls.Add($lblVer)

    $btnClose = New-MxCaptionButton -Kind 'Close'
    $btnClose.Location = New-Object System.Drawing.Point(($W - $PAD - $btnClose.Width - 1), (MxU 11))
    $btnClose.add_MouseUp({ param($sender, $e) $form.Close() })
    $titleBar.Controls.Add($btnClose)

    $btnMin = New-MxCaptionButton -Kind 'Min'
    $btnMin.Location = New-Object System.Drawing.Point(($btnClose.Left - $btnMin.Width - (MxU 8)), (MxU 11))
    $btnMin.add_MouseUp({ param($sender, $e) $form.WindowState = 'Minimized' })
    $titleBar.Controls.Add($btnMin)

    # 窗口拖动
    $drag = [PSCustomObject]@{ On = $false; Start = [System.Drawing.Point]::Empty; Origin = [System.Drawing.Point]::Empty }
    $dragStart = {
        param($sender, $e)
        $drag.On = $true
        $drag.Start = [System.Windows.Forms.Cursor]::Position
        $drag.Origin = $form.Location
    }
    $dragMove = {
        param($sender, $e)
        if ($drag.On) {
            $p = [System.Windows.Forms.Cursor]::Position
            $form.Location = New-Object System.Drawing.Point(($drag.Origin.X + $p.X - $drag.Start.X), ($drag.Origin.Y + $p.Y - $drag.Start.Y))
        }
    }
    $dragEnd = { param($sender, $e) $drag.On = $false }
    $titleBar.add_MouseDown($dragStart); $titleBar.add_MouseMove($dragMove); $titleBar.add_MouseUp($dragEnd)
    $lblApp.add_MouseDown($dragStart);   $lblApp.add_MouseMove($dragMove);   $lblApp.add_MouseUp($dragEnd)
    $lblVer.add_MouseDown($dragStart);   $lblVer.add_MouseMove($dragMove);   $lblVer.add_MouseUp($dragEnd)

    # ---- 磁盘空间卡片（左栏，环形图）----
    # 四段构成：已勾选可释放 / 可清理未勾选 / 其他已用 / 可用空间。
    # 前两段让「可清理」与「本次会释放多少」一眼可辨。
    $cardDisk = New-MxCard -X $COL_LX -Y (MxU 64) -W $COL_LW -H (MxU 392)
    $root.Controls.Add($cardDisk)

    # 图表数据由 Update-MxDisk / Update-MxSummary 写入，绘制期只读
    $script:MxChart = @{
        Total = [double]0; Used = [double]0; Free = [double]0
        CleanAll = [double]0; CleanSel = [double]0
        Unsel = [double]0; OtherUsed = [double]0
        Items = 0; SelCount = 0
        TotalText = '共 0 B'
        Lg1 = '已勾选可释放   0 B'; Lg2 = '可清理未勾选   0 B'
        Lg3 = '其他已用       0 B'; Lg4 = '可用空间       0 B'
        P1 = '0.0%'; P2 = '0.0%'; P3 = '0.0%'; P4 = '0.0%'
        LowText = '低 0 项  0 B'; MidText = '中 0 项  0 B'; HighText = '高 0 项  0 B'
    }

    $chartPanel = New-Object System.Windows.Forms.Panel
    $chartPanel.Dock = 'Fill'
    $chartPanel.BackColor = (Get-MxColor $script:Mx.SurfaceVariant)
    Enable-DoubleBuffer $chartPanel
    $chartPanel.add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $g.Clear($sender.BackColor)

        $c  = $script:MxChart
        $cw = $sender.Width
        $px = MxU 24

        $brTitle = Get-MxBrush (Get-MxColor $script:Mx.OnBackground)
        $brMuted = Get-MxBrush (Get-MxColor $script:Mx.OnSurfaceContainerVariant)
        $brBody  = Get-MxBrush (Get-MxColor $script:Mx.OnSurfaceSecondary)

        # 标题行
        $g.DrawString('磁盘空间', $script:FHead, $brTitle, $px, (MxU 18))
        $g.DrawString($c.TotalText, $script:FFoot, $brMuted,
            (New-Object System.Drawing.RectangleF($px, (MxU 22), ($cw - $px * 2), (MxU 18))), $script:MxSfFar)

        # 环形图
        $cx   = $cw / 2.0
        $cy   = MxUF 158
        $rOut = MxUF 88
        $rIn  = MxUF 60
        Draw-MxDonut -Graphics $g -Cx $cx -Cy $cy -OuterR $rOut -InnerR $rIn `
                     -Values @($c.CleanSel, $c.Unsel, $c.OtherUsed, $c.Free) `
                     -Colors @($script:Mx.ChartCleanSel, $script:Mx.ChartClean, $script:Mx.ChartUsed, $script:Mx.ChartFree) `
                     -BackColor $sender.BackColor

        # 环心文字
        $holeW = $rIn * 2
        $g.DrawString('可清理合计', $script:FCap, $brMuted,
            (New-Object System.Drawing.RectangleF(($cx - $rIn), ($cy - (MxU 19)), $holeW, (MxU 16))), $script:MxSfCenter)
        $g.DrawString((Format-Size $c.CleanAll), $script:FHead, (Get-MxBrush (Get-MxColor $script:Mx.Primary)),
            (New-Object System.Drawing.RectangleF(($cx - $rIn), ($cy + (MxU 1)), $holeW, (MxU 24))), $script:MxSfCenter)

        # 图例
        $legends = @(
            @($script:Mx.ChartCleanSel, $c.Lg1, $c.P1),
            @($script:Mx.ChartClean,    $c.Lg2, $c.P2),
            @($script:Mx.ChartUsed,     $c.Lg3, $c.P3),
            @($script:Mx.ChartFree,     $c.Lg4, $c.P4)
        )
        $ly = MxUF 264
        foreach ($lg in $legends) {
            $dr = New-Object System.Drawing.RectangleF($px, ($ly + (MxU 4)), (MxU 10), (MxU 10))
            $dp = New-RoundedPath -Rect $dr -Radius (MxU 5)
            $g.FillPath((Get-MxBrush (Get-MxColor $lg[0])), $dp)
            $dp.Dispose()
            $g.DrawString($lg[1], $script:FFoot, $brBody, ($px + (MxU 18)), $ly)
            $g.DrawString($lg[2], $script:FFoot, $brMuted,
                (New-Object System.Drawing.RectangleF($px, $ly, ($cw - $px * 2), (MxU 16))), $script:MxSfFar)
            $ly += MxUF 29
        }
    })

    $cardDisk.Controls.Add($chartPanel)

    # ---- 工具条（右栏顶部）----
    $tbY = MxU 64
    $btnRescan = New-MxButton -Text '重新扫描'   -Width (MxU 100) -Height (MxU 34) -Kind 'Secondary'
    $btnRescan.Location = New-Object System.Drawing.Point($COL_RX, $tbY)
    $root.Controls.Add($btnRescan)

    $btnLow = New-MxButton -Text '只选低风险' -Width (MxU 108) -Height (MxU 34) -Kind 'Secondary'
    $btnLow.Location = New-Object System.Drawing.Point(($COL_RX + (MxU 112)), $tbY)
    $root.Controls.Add($btnLow)

    $btnAll = New-MxButton -Text '全选'       -Width (MxU 76) -Height (MxU 34) -Kind 'Secondary'
    $btnAll.Location = New-Object System.Drawing.Point(($COL_RX + (MxU 232)), $tbY)
    $root.Controls.Add($btnAll)

    $btnNone = New-MxButton -Text '全不选'    -Width (MxU 88) -Height (MxU 34) -Kind 'Secondary'
    $btnNone.Location = New-Object System.Drawing.Point(($COL_RX + (MxU 320)), $tbY)
    $root.Controls.Add($btnNone)

    $btnHelp = New-MxButton -Text '使用说明'  -Width (MxU 100) -Height (MxU 34) -Kind 'Text'
    $btnHelp.Location = New-Object System.Drawing.Point(($W - $PAD - (MxU 100)), $tbY)
    $root.Controls.Add($btnHelp)

    # ---- 列表卡片（右栏，整块自绘 + 行级局部刷新）----
    $cardList = New-MxCard -X $COL_RX -Y (MxU 114) -W $COL_RW -H $LIST_H
    $root.Controls.Add($cardList)

    $lblListTitle = New-Object System.Windows.Forms.Label
    $lblListTitle.Text = '清理项'
    $lblListTitle.Font = $script:FHead
    $lblListTitle.ForeColor = (Get-MxColor $script:Mx.OnBackground)
    $lblListTitle.BackColor = [System.Drawing.Color]::Transparent
    $lblListTitle.Location = New-Object System.Drawing.Point((MxU 24), (MxU 14))
    $lblListTitle.Size = New-Object System.Drawing.Size((MxU 200), (MxU 22))
    $cardList.Controls.Add($lblListTitle)

    # 右上角展示扫描结果摘要（项数 / 耗时），与底部「已选」状态互补而非重复
    $lblListMeta = New-Object System.Windows.Forms.Label
    $lblListMeta.Font = $script:FFoot
    $lblListMeta.ForeColor = (Get-MxColor $script:Mx.OnSurfaceContainerVariant)
    $lblListMeta.BackColor = [System.Drawing.Color]::Transparent
    $lblListMeta.TextAlign = 'MiddleRight'
    $lblListMeta.Location = New-Object System.Drawing.Point(($COL_RW - (MxU 24) - (MxU 320)), (MxU 16))
    $lblListMeta.Size = New-Object System.Drawing.Size((MxU 320), (MxU 18))
    $lblListMeta.Text = ('共 ' + $script:Entries.Count + ' 项')
    $cardList.Controls.Add($lblListMeta)

    $LIST_TOP = MxU 46
    $listView = New-Object System.Windows.Forms.Panel
    $listView.Location = New-Object System.Drawing.Point($LIST_PAD, $LIST_TOP)
    $listView.Size = New-Object System.Drawing.Size(($COL_RW - $LIST_PAD * 2), ($LIST_H - $LIST_TOP - $LIST_PAD))
    $listView.BackColor = (Get-MxColor $script:Mx.SurfaceVariant)
    $listView.Cursor = 'Default'
    $listView.TabStop = $true
    Enable-DoubleBuffer $listView
    $cardList.Controls.Add($listView)
    $script:MxList = $listView
    $script:MxScrollY = 0
    $script:MxScrollMax = 0
    $script:MxHover = -1

    # 每行的展示数据缓存（名称宽度、说明、大小文本等），避免每帧重算
    $script:MxRowCache = @()
    for ($i = 0; $i -lt $script:Entries.Count; $i++) {
        $script:MxRowCache += [PSCustomObject]@{
            NameW = 0.0; Desc = ''; SizeText = ''
        }
    }

    # 每行的圆角路径预生成（实现见脚本作用域的 Build-MxSwitchPaths）。
    # 绘制期若发现几何与当前宽度不符，会自行重建，不依赖初始化时序。
    $script:MxGeomVw = -1
    function Build-MxRowGeometry {
        param([int]$ViewWidth)
        [void](Build-MxSwitchPaths -ViewWidth $ViewWidth)
    }

    function Update-MxRowCache {
        $rows = $script:MxRowCache
        for ($i = 0; $i -lt $script:Entries.Count; $i++) {
            $en = $script:Entries[$i]
            $c = $rows[$i]
            $c.NameW = $script:MxMeasure.MeasureString($en.Name, $script:FBody).Width
            $d = $en.Desc
            if ($en.NeedAdmin -and -not $script:IsAdmin) { $d = $d + '  ·  需管理员权限' }
            $c.Desc = $d
            $c.SizeText = Format-Size $en.Size
        }
    }

    # 首次构建行几何与展示缓存，保证第一帧就有正确内容
    Build-MxRowGeometry -ViewWidth $listView.Width
    Update-MxRowCache

    $script:MxRowPaint = {
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $g.Clear($sender.BackColor)

        $vw = $sender.Width
        $n = $script:Entries.Count
        $rowH = $script:MxRowH

        # 几何缓存与当前宽度不一致（或缺失）时立即重建，
        # 保证开关永远不会因为几何过期而被画到可视区之外。
        if ($vw -ne $script:MxGeomVw -or @($script:MxPathTrack).Count -ne $n) {
            [void](Build-MxSwitchPaths -ViewWidth $vw)
        }

        $contentH = $n * $rowH
        $script:MxScrollMax = [Math]::Max(0, $contentH - $sender.Height)

        $brText    = Get-MxBrush (Get-MxColor $script:Mx.OnBackground)
        $brDesc    = Get-MxBrush (Get-MxColor $script:Mx.OnSurfaceContainerVariant)
        $brHover   = Get-MxBrush (Get-MxColor $script:Mx.Hover)
        $brScroll  = Get-MxBrush (Get-MxColor $script:Mx.Outline)
        $penDiv    = $script:MxPenDivider
        $fName = $script:FBody
        $fDesc = $script:FCap
        $fSize = $script:FFoot

        $first = [Math]::Floor($script:MxScrollY / $rowH)
        $last = [Math]::Min($n - 1, [Math]::Ceiling(($script:MxScrollY + $sender.Height) / $rowH))

        # 预生成的开关/悬停路径使用「内容坐标」（不含滚动偏移）。
        # 这里整体平移 -滚动量，文字也统一改用内容坐标，
        # 否则滚动后开关会按未滚动的位置绘制，偏移越往下越大、最终移出可视区。
        $gsState = $g.Save()
        $g.TranslateTransform(0, -$script:MxScrollY)

        for ($i = $first; $i -le $last; $i++) {
            if ($i -lt 0 -or $i -ge $n) { continue }
            $en = $script:Entries[$i]
            $rc = $script:MxRowCache[$i]
            $top = $i * $rowH

            if ($i -eq $script:MxHover) {
                $g.FillPath($brHover, $script:MxPathHover[$i])
            }

            $tx = $script:MxRowPadX
            $g.DrawString($en.Name, $fName, $brText, $tx, ($top + $script:MxNameY))

            # 风险标签
            $chipFg = $script:Mx.ChipLowFg
            $chipBg = $script:Mx.ChipLowBg
            $chipText = '低'
            if ($en.Risk -eq '中') { $chipFg = $script:Mx.ChipMidFg; $chipBg = $script:Mx.ChipMidBg; $chipText = '中' }
            if ($en.Risk -eq '高') { $chipFg = $script:Mx.ChipHighFg; $chipBg = $script:Mx.ChipHighBg; $chipText = '高' }
            $chipX = $tx + $rc.NameW + $script:MxChipGap
            $chipRect = New-Object System.Drawing.RectangleF($chipX, ($top + $script:MxChipY), $script:MxChipW, $script:MxChipH)
            $cp = New-RoundedPath -Rect $chipRect -Radius ($script:MxChipH / 2)
            $g.FillPath((Get-MxBrush (Get-MxColor $chipBg)), $cp)
            $cp.Dispose()
            $g.DrawString($chipText, $script:FCap, (Get-MxBrush (Get-MxColor $chipFg)), $chipRect, $script:MxSfCenter)

            $g.DrawString($rc.Desc, $fDesc, $brDesc, $tx, ($top + $script:MxDescY))

            $sizeRect = New-Object System.Drawing.RectangleF(($vw - $script:MxRowPadX - $SW_W - $script:MxSizeGap - $script:MxSizeW), ($top + $script:MxNameY), $script:MxSizeW, $script:MxSizeH)
            $sizeColor = $script:Mx.OnSurfaceContainerVariant
            if ($en.Selected) { $sizeColor = $script:Mx.OnBackground }
            $g.DrawString($rc.SizeText, $fSize, (Get-MxBrush (Get-MxColor $sizeColor)), $sizeRect, $script:MxSfFar)

            Draw-MxSwitchAt -Graphics $g -Row $i -Checked $en.Selected -ViewWidth $vw

            if ($i -lt $n - 1) {
                $y = $top + $rowH - 1
                $g.DrawLine($penDiv, $script:MxDividerInset, $y, ($vw - $script:MxDividerInset), $y)
            }
        }
        $g.Restore($gsState)

        # 细滚动条（视口坐标，绘制在还原变换之后）
        if ($script:MxScrollMax -gt 0) {
            $trackH = $sender.Height
            $thumbH = [Math]::Max($script:MxMinThumb, [int]($trackH * $trackH / $contentH))
            $pos = [int](($trackH - $thumbH) * $script:MxScrollY / $script:MxScrollMax)
            $sr = New-Object System.Drawing.RectangleF(($vw - $script:MxScrollW - (MxU 3)), $pos, $script:MxScrollW, $thumbH)
            $sp = New-RoundedPath -Rect $sr -Radius ($script:MxScrollW / 2)
            $g.FillPath($brScroll, $sp)
            $sp.Dispose()
        }
    }
    $listView.add_Paint($script:MxRowPaint)

    # 只重绘指定行，避免整列表刷新造成的卡顿
    function Invalidate-MxRow {
        param([int]$Index)
        if ($Index -lt 0) { return }
        $top = [int]($Index * $script:MxRowH - $script:MxScrollY)
        if ($top -ge $script:MxList.Height) { return }
        if (($top + $script:MxRowH) -le 0) { return }
        $r = New-Object System.Drawing.Rectangle(0, $top, $script:MxList.Width, $script:MxRowH)
        $script:MxList.Invalidate($r)
    }

    $listView.add_MouseMove({
        param($sender, $e)
        $idx = [Math]::Floor(($e.Y + $script:MxScrollY) / $script:MxRowH)
        if ($idx -lt 0 -or $idx -ge $script:Entries.Count) { $idx = -1 }
        if ($idx -ne $script:MxHover) {
            $old = $script:MxHover
            $script:MxHover = $idx
            if ($old -ge 0) { Invalidate-MxRow $old }
            if ($idx -ge 0) {
                Invalidate-MxRow $idx
                $sender.Cursor = 'Hand'
            } else {
                $sender.Cursor = 'Default'
            }
        }
    })
    $listView.add_MouseLeave({
        param($sender, $e)
        $old = $script:MxHover
        $script:MxHover = -1
        if ($old -ge 0) { Invalidate-MxRow $old }
    })
    $listView.add_MouseEnter({ param($sender, $e) if (-not $sender.Focused) { $sender.Focus() } })

    $script:MxDownY = -1
    $listView.add_MouseDown({ param($sender, $e) $script:MxDownY = $e.Y })
    $listView.add_MouseUp({
        param($sender, $e)
        $dy = [Math]::Abs($e.Y - $script:MxDownY)
        $script:MxDownY = -1
        if ($dy -gt (MxU 5)) { return }
        $idx = [Math]::Floor(($e.Y + $script:MxScrollY) / $script:MxRowH)
        if ($idx -ge 0 -and $idx -lt $script:Entries.Count) {
            $en = $script:Entries[$idx]
            $en.Selected = -not $en.Selected
            Invalidate-MxRow $idx
            Update-MxSummary
            $state = '开启'
            if (-not $en.Selected) { $state = '关闭' }
            Write-Log ('[开关] ' + $en.Name + '：' + $state)
        }
    })

    $wheel = {
        param($sender, $e)
        $step = [int]($script:MxRowH * 2)
        if ($e.Delta -gt 0) { $script:MxScrollY -= $step } else { $script:MxScrollY += $step }
        if ($script:MxScrollY -lt 0) { $script:MxScrollY = 0 }
        if ($script:MxScrollY -gt $script:MxScrollMax) { $script:MxScrollY = $script:MxScrollMax }
        $script:MxList.Invalidate()
    }
    $listView.add_MouseWheel($wheel)
    $root.add_MouseWheel($wheel)
    $form.add_MouseWheel($wheel)

    # ---- 自动清理开关卡片（左栏）----
    $cardAuto = New-MxCard -X $COL_LX -Y (MxU 472) -W $COL_LW -H (MxU 76)
    $cardAuto.Cursor = 'Hand'
    $root.Controls.Add($cardAuto)
    $cardAuto.add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $g.Clear($sender.BackColor)
        $g.DrawString('启动时自动清理', $script:FBody, (Get-MxBrush (Get-MxColor $script:Mx.OnBackground)), (MxU 24), (MxU 18))
        $g.DrawString('下次打开按本次勾选自动执行，5 秒内可中止', $script:FCap, (Get-MxBrush (Get-MxColor $script:Mx.OnSurfaceContainerVariant)), (MxU 24), (MxU 42))
        $swX = $COL_LW - (MxU 24) - $SW_W
        $swY = (MxU 76 - 26) / 2
        $tr = New-Object System.Drawing.RectangleF($swX, $swY, $SW_W, $SW_H)
        $tp = New-RoundedPath -Rect $tr -Radius ($SW_H / 2)
        $tc = Get-MxColor $script:Mx.SurfaceContainerHigh
        if ($script:AutoClean) { $tc = Get-MxColor $script:Mx.Primary }
        $g.FillPath((Get-MxBrush $tc), $tp)
        $tp.Dispose()
        $thumbD = $SW_H - $SW_PAD * 2
        $thumbX = $swX + $SW_PAD
        if ($script:AutoClean) { $thumbX = $swX + $SW_W - $SW_PAD - $thumbD }
        $hr = New-Object System.Drawing.RectangleF($thumbX, ($swY + $SW_PAD), $thumbD, $thumbD)
        $hp = New-RoundedPath -Rect $hr -Radius ($thumbD / 2)
        $g.FillPath((Get-MxBrush (Get-MxColor $script:Mx.OnPrimary)), $hp)
        if (-not $script:AutoClean) { $g.DrawPath((Get-MxPen (Get-MxColor $script:Mx.Outline) (MxU 1)), $hp) }
        $hp.Dispose()
    })
    $cardAuto.add_MouseUp({
        param($sender, $e)
        $script:AutoClean = -not $script:AutoClean
        $sender.Invalidate()
    })

    # ---- 风险分级统计卡片（左栏）----
    # 与环形图共用同一份统计数据，勾选变化后由 Update-MxSummary 一并刷新
    $cardRisk = New-MxCard -X $COL_LX -Y (MxU 564) -W $COL_LW -H (MxU 76)
    $root.Controls.Add($cardRisk)
    $cardRisk.add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $g.Clear($sender.BackColor)
        $c = $script:MxChart
        $g.DrawString('风险分级', $script:FBody, (Get-MxBrush (Get-MxColor $script:Mx.OnBackground)), (MxU 24), (MxU 12))
        $g.DrawString($c.LowText,  $script:FCap, (Get-MxBrush (Get-MxColor $script:Mx.ChipLowFg)),  (MxU 24),  (MxU 44))
        $g.DrawString($c.MidText,  $script:FCap, (Get-MxBrush (Get-MxColor $script:Mx.ChipMidFg)),  (MxU 140), (MxU 44))
        $g.DrawString($c.HighText, $script:FCap, (Get-MxBrush (Get-MxColor $script:Mx.ChipHighFg)), (MxU 256), (MxU 44))
    })

    # ---- 日志卡片（底部通栏）----
    $cardLog = New-MxCard -X $COL_LX -Y (MxU 656) -W ($W - $PAD * 2) -H (MxU 92)
    $root.Controls.Add($cardLog)

    $lblLogTitle = New-Object System.Windows.Forms.Label
    $lblLogTitle.Text = '运行日志'
    $lblLogTitle.Font = $script:FCap
    $lblLogTitle.ForeColor = (Get-MxColor $script:Mx.OnSurfaceContainerVariant)
    $lblLogTitle.BackColor = [System.Drawing.Color]::Transparent
    $lblLogTitle.Location = New-Object System.Drawing.Point((MxU 16), (MxU 8))
    $lblLogTitle.Size = New-Object System.Drawing.Size((MxU 200), (MxU 14))
    $cardLog.Controls.Add($lblLogTitle)

    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Location = New-Object System.Drawing.Point((MxU 14), (MxU 26))
    $txtLog.Size = New-Object System.Drawing.Size((($W - $PAD * 2) - (MxU 28)), (MxU 56))
    $txtLog.Multiline = $true
    $txtLog.ScrollBars = 'Vertical'
    $txtLog.ReadOnly = $true
    $txtLog.BorderStyle = 'None'
    $txtLog.BackColor = (Get-MxColor $script:Mx.SurfaceVariant)
    $txtLog.ForeColor = (Get-MxColor $script:Mx.OnSurfaceSecondary)
    $txtLog.Font = New-MxFont -Size 9 -Names @('Cascadia Mono', 'Consolas', 'Courier New')
    $cardLog.Controls.Add($txtLog)
    $script:LogBox = $txtLog

    # ---- 底部操作区 ----
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Font = $script:FFoot
    $lblStatus.ForeColor = (Get-MxColor $script:Mx.OnSurfaceContainerVariant)
    $lblStatus.BackColor = [System.Drawing.Color]::Transparent
    $lblStatus.TextAlign = 'MiddleRight'
    $lblStatus.Location = New-Object System.Drawing.Point((MxU 352), (MxU 764))
    $lblStatus.Size = New-Object System.Drawing.Size(($W - (MxU 352) - $PAD), (MxU 44))
    $root.Controls.Add($lblStatus)

    $btnClean = New-MxButton -Text '开始清理' -Width (MxU 200) -Height (MxU 44) -Kind 'Primary'
    $btnClean.Location = New-Object System.Drawing.Point($PAD, (MxU 764))
    $root.Controls.Add($btnClean)

    $btnExit = New-MxButton -Text '退出' -Width (MxU 100) -Height (MxU 44) -Kind 'Secondary'
    $btnExit.Location = New-Object System.Drawing.Point(($PAD + (MxU 212)), (MxU 764))
    $btnExit.add_MouseUp({ param($sender, $e) $script:Abort = $true; if (-not $script:Cleaning) { $form.Close() } })
    $root.Controls.Add($btnExit)

    # ---- 刷新函数 ----
    # 环形图与图例的所有派生文本都在这里算好，绘制期只做画图，避免每帧拼接字符串
    function Update-MxChart {
        $c = $script:MxChart
        # 从哈希表取出的是 object，直接传给 [Math]::Max 会被按 Int32 重载绑定，
        # 遇到百 GB 级的字节数就溢出报错，因此这里显式转 double 再比较
        $otherUsed = [double]$c.Used - [double]$c.CleanAll
        if ($otherUsed -lt 0) { $otherUsed = [double]0 }
        $unsel = [double]$c.CleanAll - [double]$c.CleanSel
        if ($unsel -lt 0) { $unsel = [double]0 }
        $c.OtherUsed = $otherUsed
        $c.Unsel     = $unsel
        # 百分比与扇形使用同一分母，避免「可清理 > 已用」被截断时
        # 图形角度与图例数字对不上（正常情况下该分母就等于磁盘总容量）
        $denom = [double]$c.CleanSel + $unsel + $otherUsed + [double]$c.Free
        if ($denom -le 0) { $denom = 1 }
        $c.TotalText = ('共 ' + (Format-Size $c.Total))
        $c.Lg1 = '已勾选可释放   ' + (Format-Size $c.CleanSel)
        $c.Lg2 = '可清理未勾选   ' + (Format-Size $unsel)
        $c.Lg3 = '其他已用       ' + (Format-Size $otherUsed)
        $c.Lg4 = '可用空间       ' + (Format-Size $c.Free)
        $c.P1 = ('{0:N1}%' -f ([double]$c.CleanSel / $denom * 100))
        $c.P2 = ('{0:N1}%' -f ($unsel / $denom * 100))
        $c.P3 = ('{0:N1}%' -f ($otherUsed / $denom * 100))
        $c.P4 = ('{0:N1}%' -f ([double]$c.Free / $denom * 100))
        $chartPanel.Invalidate()
    }

    function Update-MxDisk {
        $d = Get-DiskInfo
        if (-not $d) { return }
        $script:MxChart.Total = $d.Total
        $script:MxChart.Used  = $d.Used
        $script:MxChart.Free  = $d.Free
        Update-MxChart
    }

    function Update-MxSummary {
        $sel = @($script:Entries | Where-Object { $_.Selected })
        $sum = [double]0
        foreach ($e in $sel) { $sum += $e.Size }

        $all = [double]0
        $lowN = 0;  $lowS  = [double]0
        $midN = 0;  $midS  = [double]0
        $highN = 0; $highS = [double]0
        foreach ($e in $script:Entries) {
            $all += $e.Size
            if ($e.Risk -eq '低')     { $lowN++;  $lowS  += $e.Size }
            elseif ($e.Risk -eq '中') { $midN++;  $midS  += $e.Size }
            else                      { $highN++; $highS += $e.Size }
        }

        $c = $script:MxChart
        $c.CleanSel = $sum
        $c.CleanAll = $all
        $c.SelCount = $sel.Count
        $c.Items    = $script:Entries.Count
        $c.LowText  = ('低 ' + $lowN + ' 项 ' + (Format-Size $lowS))
        $c.MidText  = ('中 ' + $midN + ' 项 ' + (Format-Size $midS))
        $c.HighText = ('高 ' + $highN + ' 项 ' + (Format-Size $highS))

        $lblStatus.Text = ('已选 ' + $sel.Count + ' / ' + $script:Entries.Count + ' 项，预计可释放 ' + (Format-Size $sum))
        $cardRisk.Invalidate()
        Update-MxChart
    }

    # ---- 昂贵项目的后台测量 ----
    # WinSxS 递归遍历约需 10 秒，若在 UI 线程执行会让界面完全冻结，
    # 因此单独放到后台 Runspace 计算，界面保持可交互。
    $script:MxAsyncPs = $null
    $script:MxAsyncHandle = $null
    $script:MxAsyncIndex = -1
    $script:MxLastScanMs = 0.0

    function Start-MxAsyncMeasure {
        param([int]$Index, [string]$Path)
        if ($null -ne $script:MxAsyncHandle) { return }
        try {
            $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
            $rs.ApartmentState = 'MTA'
            $rs.ThreadOptions = 'ReuseThread'
            $rs.Open()
            $ps = [System.Management.Automation.PowerShell]::Create()
            $ps.Runspace = $rs
            [void]$ps.AddScript({
                param($p)
                $sum = [double]0
                $stack = New-Object System.Collections.Stack
                $stack.Push($p)
                while ($stack.Count -gt 0) {
                    $d = $stack.Pop()
                    try {
                        foreach ($f in [System.IO.Directory]::EnumerateFiles($d)) {
                            try { $sum += ([System.IO.FileInfo]$f).Length } catch { }
                        }
                    } catch { }
                    try {
                        foreach ($sd in [System.IO.Directory]::EnumerateDirectories($d)) { $stack.Push($sd) }
                    } catch { }
                }
                return $sum
            }).AddArgument($Path)
            $script:MxAsyncPs = $ps
            $script:MxAsyncHandle = $ps.BeginInvoke()
            $script:MxAsyncIndex = $Index
        } catch {
            $script:MxAsyncPs = $null
            $script:MxAsyncHandle = $null
            $script:MxAsyncIndex = -1
        }
    }

    $mxTimer = New-Object System.Windows.Forms.Timer
    $mxTimer.Interval = 250
    $mxTimer.add_Tick({
        if ($null -eq $script:MxAsyncHandle) { return }
        if (-not $script:MxAsyncHandle.IsCompleted) { return }
        $idx = $script:MxAsyncIndex
        $val = [double]0
        try {
            $res = $script:MxAsyncPs.EndInvoke($script:MxAsyncHandle)
            if ($res -and $res.Count -gt 0) { $val = [double]$res[0] }
        } catch { }
        try { $script:MxAsyncPs.Runspace.Close() } catch { }
        try { $script:MxAsyncPs.Dispose() } catch { }
        $script:MxAsyncPs = $null
        $script:MxAsyncHandle = $null
        $script:MxAsyncIndex = -1
        if ($idx -ge 0 -and $idx -lt $script:Entries.Count) {
            $script:Entries[$idx].Size = $val
            $script:MxRowCache[$idx].SizeText = Format-Size $val
            Invalidate-MxRow $idx
            Update-MxSummary
            Write-Log ('[后台] ' + $script:Entries[$idx].Name + ' 大小 ' + (Format-Size $val))
        }
    })
    $mxTimer.Start()

    function Invoke-MxScan {
        $script:MxScrollY = 0
        $script:MxHover = -1
        foreach ($e in $script:Entries) { $e.Size = [double]0 }
        Update-MxRowCache
        $listView.Invalidate()
        [System.Windows.Forms.Application]::DoEvents()

        $swScan = [System.Diagnostics.Stopwatch]::StartNew()
        $deferred = 0
        for ($i = 0; $i -lt $script:Entries.Count; $i++) {
            if ($script:Abort) { break }
            $e = $script:Entries[$i]
            $lblStatus.Text = ('正在扫描：' + $e.Name + ' ...')
            [System.Windows.Forms.Application]::DoEvents()

            if ($e.Kind -eq 'Dism') {
                $script:MxRowCache[$i].SizeText = '计算中…'
                Invalidate-MxRow $i
                Start-MxAsyncMeasure -Index $i -Path (Join-Path $env:SystemRoot 'WinSxS')
                $deferred++
                continue
            }

            Measure-Entry -Entry $e
            $script:MxRowCache[$i].SizeText = Format-Size $e.Size
            Invalidate-MxRow $i
            [System.Windows.Forms.Application]::DoEvents()
        }
        $swScan.Stop()
        $script:MxLastScanMs = $swScan.Elapsed.TotalMilliseconds
        Update-MxDisk
        Update-MxSummary
        $note = ''
        if ($deferred -gt 0) { $note = '，另有 ' + $deferred + ' 项在后台计算' }
        $lblListMeta.Text = ('共 ' + $script:Entries.Count + ' 项  ·  扫描 ' + [math]::Round($script:MxLastScanMs / 1000, 2) + ' 秒')
        Write-Log ('扫描完成：' + [math]::Round($script:MxLastScanMs / 1000, 2) + ' 秒' + $note)
    }

    # ---- 按钮事件 ----
    $btnRescan.add_MouseUp({
        param($sender, $e)
        if ($script:MxBusy) { return }
        $script:MxBusy = $true
        Invoke-MxScan
        $script:MxBusy = $false
    })

    $setAll = {
        param([string]$Mode)
        foreach ($e in $script:Entries) {
            if ($Mode -eq 'Low')  { $e.Selected = ($e.Risk -eq '低') }
            if ($Mode -eq 'All')  { $e.Selected = $true }
            if ($Mode -eq 'None') { $e.Selected = $false }
        }
        $listView.Invalidate()
        Update-MxSummary
    }
    $btnLow.add_MouseUp({ param($sender, $e) & $setAll 'Low' })
    $btnAll.add_MouseUp({ param($sender, $e) & $setAll 'All' })
    $btnNone.add_MouseUp({ param($sender, $e) & $setAll 'None' })

    $btnHelp.add_MouseUp({
        param($sender, $e)
        $msg = "1. 程序打开后会自动扫描各清理项占用的空间。`r`n" +
               "2. 点击列表任意一行即可开关该项目，右侧滑块为开启状态。`r`n" +
               "3. 采用永久删除，不经过回收站，删除后不可恢复。`r`n" +
               "4. 开启「启动时自动清理」后，下次打开会按本次勾选自动执行，5 秒倒计时内可点「退出」中止。`r`n" +
               "5. 标注「需管理员权限」的项目必须以管理员身份运行，否则会被系统拒绝。`r`n" +
               "6. 风险等级：低＝随时可清；中＝有轻微副作用（首次启动变慢、需重新下载等）；高＝影响系统功能（关闭休眠、无法回退旧版本）。`r`n`r`n" +
               "配置文件 cleaner.config.json 与程序同目录，整个文件夹拷贝到其他电脑即可使用。"
        $null = Show-MxDialog -Title '使用说明' -Message $msg -PrimaryText '知道了' -Width 520 -ScrollBody
    })

    $btnClean.add_MouseUp({
        param($sender, $e)
        if ($script:Cleaning) { return }
        $targets = @($script:Entries | Where-Object { $_.Selected })
        if ($targets.Count -eq 0) {
            $null = Show-MxDialog -Title '未选择项目' -Message '请先开启至少一个清理项目。' -PrimaryText '知道了' -Width 400
            return
        }
        $hasHigh = @($targets | Where-Object { $_.Risk -eq '高' }).Count
        $msg = ('即将永久删除以下 ' + $targets.Count + ' 个项目的内容，不会进入回收站，删除后无法恢复。' + "`r`n`r`n" +
                (($targets | ForEach-Object { '· ' + $_.Name }) -join "`r`n"))
        if ($hasHigh -gt 0) { $msg += "`r`n`r`n注意：其中包含高风险项目，可能影响系统功能。" }
        $ok = Show-MxDialog -Title '确认清理' -Message $msg -PrimaryText '开始清理' -SecondaryText '取消' -Width 520 -ScrollBody
        if (-not $ok) { return }

        Save-Config -Path $script:ConfigPath

        $script:MxBusy = $true
        $sender.Tag.Enabled = $false
        $sender.Invalidate()
        $btnRescan.Tag.Enabled = $false
        $btnRescan.Invalidate()
        $txtLog.Clear()
        $script:Abort = $false

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $freed = Start-Clean -Progress {
            param($i, $n, $e)
            $lblStatus.Text = ('正在清理 (' + $i + '/' + $n + ')：' + $e.Name)
            [System.Windows.Forms.Application]::DoEvents()
        }
        $sw.Stop()

        for ($i = 0; $i -lt $script:Entries.Count; $i++) {
            if (-not $script:Entries[$i].Selected) { continue }
            Measure-Entry -Entry $script:Entries[$i]
            $script:MxRowCache[$i].SizeText = Format-Size $script:Entries[$i].Size
        }
        $listView.Invalidate()
        Update-MxDisk
        Update-MxSummary

        $sender.Tag.Enabled = $true
        $sender.Invalidate()
        $btnRescan.Tag.Enabled = $true
        $btnRescan.Invalidate()
        $script:MxBusy = $false

        Write-Log ''
        Write-Log ('=== 清理完成，共释放 ' + (Format-Size $freed) + ' ===')
        $lblStatus.Text = ('清理完成，共释放 ' + (Format-Size $freed) + '，耗时 ' + [math]::Round($sw.Elapsed.TotalSeconds, 1) + ' 秒')
        $null = Show-MxDialog -Title '清理完成' -Message ('共释放 ' + (Format-Size $freed) + '。') -PrimaryText '好的' -Width 400
    })

    # ---- 键盘 ----
    $form.add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape -and -not $script:Cleaning -and -not $script:MxBusy) { $form.Close() }
    })

    $form.add_FormClosing({
        param($sender, $e)
        try { $mxTimer.Stop() } catch { }
        if (-not $script:RenderTo -and -not $script:BenchPaint -and -not $script:SnapTo) { Save-Config -Path $script:ConfigPath }
    })

    # ---- 性能测量 ----
    if ($script:BenchPaint -gt 0) {
        for ($i = 0; $i -lt $script:Entries.Count; $i++) {
            $script:Entries[$i].Size = [double](($i + 3) * 137 * 1048576)
            $script:Entries[$i].Selected = (($i % 3) -ne 0)
        }
        Update-MxSummary
        Build-MxRowGeometry -ViewWidth $listView.Width
        Update-MxRowCache
        $form.Show()
        foreach ($k in 1..8) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }

        $n = $script:BenchPaint
        $fr = New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)
        $lr = New-Object System.Drawing.Rectangle(0, 0, $listView.Width, $listView.Height)
        $bmpF = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
        $bmpL = New-Object System.Drawing.Bitmap($listView.Width, $listView.Height)
        for ($i = 0; $i -lt 6; $i++) { $listView.DrawToBitmap($bmpL, $lr); $form.DrawToBitmap($bmpF, $fr) }

        $swA = [System.Diagnostics.Stopwatch]::StartNew()
        for ($i = 0; $i -lt $n; $i++) { $listView.DrawToBitmap($bmpL, $lr) }
        $swA.Stop()
        $swB = [System.Diagnostics.Stopwatch]::StartNew()
        for ($i = 0; $i -lt $n; $i++) { $form.DrawToBitmap($bmpF, $fr) }
        $swB.Stop()

        Write-Host ('BENCH list : ' + [math]::Round($swA.Elapsed.TotalMilliseconds / $n, 3) + ' ms/frame')
        Write-Host ('BENCH form : ' + [math]::Round($swB.Elapsed.TotalMilliseconds / $n, 3) + ' ms/frame')
        $bmpF.Dispose(); $bmpL.Dispose()
        $form.Close()
        return
    }

    # ---- 渲染自检 ----
    if ($script:RenderTo) {
        for ($i = 0; $i -lt $script:Entries.Count; $i++) {
            $script:Entries[$i].Size = [double](($i + 3) * 137 * 1048576)
            $script:Entries[$i].Selected = (($i % 3) -ne 0)
        }
        Update-MxDisk
        Update-MxSummary
        Build-MxRowGeometry -ViewWidth $listView.Width
        Update-MxRowCache
        $form.Show()
        foreach ($k in 1..6) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 120
        }
        $chartPanel.Invalidate(); $listView.Invalidate(); $cardAuto.Invalidate(); $cardRisk.Invalidate(); $root.Invalidate()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 300
        [System.Windows.Forms.Application]::DoEvents()

        $bmpOut = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
        $form.DrawToBitmap($bmpOut, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
        $bmpOut.Save($script:RenderTo, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmpOut.Dispose()
        Write-Host ('rendered -> ' + $script:RenderTo)

        $demoMsg = "即将永久删除以下 9 个项目的内容，不会进入回收站，删除后无法恢复。`r`n`r`n· 用户临时文件`r`n· 系统临时文件`r`n· 回收站`r`n· 缩略图 / 图标缓存`r`n· 崩溃转储文件`r`n· Windows 错误报告`r`n· 浏览器缓存`r`n· 开发工具缓存`r`n· 系统网络缓存"
        $null = Show-MxDialog -Title '确认清理' -Message $demoMsg -PrimaryText '开始清理' -SecondaryText '取消' -Width 520 -ScrollBody

        $form.Close()
        return
    }

    # ---- 启动 ----
    $form.Add_Shown({
        Update-MxDisk
        Build-MxRowGeometry -ViewWidth $listView.Width
        Update-MxRowCache
        if ($script:RenderTo) { return }
        Write-Log ('=== ' + $script:AppName + ' v' + $script:Version + '  ·  Miuix 界面 ===')
        Write-Log ('管理员权限: ' + $script:IsAdmin + '   缩放: ' + [math]::Round($script:MxScale * 100) + '%')
        if (-not $script:IsAdmin) { Write-Log '提示：未以管理员身份运行，标注「需管理员权限」的项目将无法清理。' }
        $listView.Focus()
        Invoke-MxScan

        if ($script:AutoClean -and $script:ConfigExisted) {
            for ($i = 5; $i -gt 0; $i--) {
                if ($script:Abort -or $form.IsDisposed) { return }
                $lblStatus.Text = ('将在 ' + $i + ' 秒后自动清理（点「退出」可中止）')
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Seconds 1
            }
            if (-not $script:Abort -and -not $form.IsDisposed) {
                $t = @($script:Entries | Where-Object { $_.Selected })
                if ($t.Count -gt 0) {
                    Write-Log '开始自动清理...'
                    $script:MxBusy = $true
                    $freed = Start-Clean -Progress {
                        param($i, $n, $e)
                        $lblStatus.Text = ('正在自动清理 (' + $i + '/' + $n + ')：' + $e.Name)
                        [System.Windows.Forms.Application]::DoEvents()
                    }
                    $script:MxBusy = $false
                    for ($i = 0; $i -lt $script:Entries.Count; $i++) {
                        if (-not $script:Entries[$i].Selected) { continue }
                        Measure-Entry -Entry $script:Entries[$i]
                        $script:MxRowCache[$i].SizeText = Format-Size $script:Entries[$i].Size
                    }
                    $listView.Invalidate()
                    Update-MxDisk
                    Update-MxSummary
                    $lblStatus.Text = ('自动清理完成，共释放 ' + (Format-Size $freed))
                }
            }
        }

        if ($script:SnapTo) {
            foreach ($k in 1..8) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 120 }
            $bmpS = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
            $form.DrawToBitmap($bmpS, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
            $bmpS.Save($script:SnapTo, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmpS.Dispose()
            Write-Host ('snapshot -> ' + $script:SnapTo)

            # 滚动后（这是之前开关消失的场景）再拍一张，用于验证滚动偏移修复
            $script:MxScrollY = $script:MxRowH * 8
            $listView.Invalidate()
            foreach ($k in 1..6) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 120 }
            $bmpS2 = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
            $form.DrawToBitmap($bmpS2, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
            $out2 = ($script:SnapTo -replace '\.png$', '') + '_scrolled.png'
            $bmpS2.Save($out2, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmpS2.Dispose()
            Write-Host ('snapshot(scrolled) -> ' + $out2)

            Write-Host ('  listView.Width=' + $listView.Width + '  Height=' + $listView.Height)
            Write-Host ('  MxRowPadX=' + $script:MxRowPadX + ' SW_W=' + $SW_W + ' SW_H=' + $SW_H + ' ROW_H=' + $ROW_H)
            Write-Host ('  geomVw=' + $script:MxGeomVw + '  scrollY=' + $script:MxScrollY + '  scrollMax=' + $script:MxScrollMax)
            $pk = $script:MxPathTrack
            if ($null -ne $pk -and @($pk).Count -gt 0) {
                Write-Host ('  trackPath count=' + @($pk).Count + '  [0]=' + $pk[0].GetBounds().ToString() + '  points=' + $pk[0].PointCount)
                Write-Host ('  hoverPath count=' + @($script:MxPathHover).Count + '  [0]=' + $script:MxPathHover[0].GetBounds().ToString())
            } else {
                Write-Host '  trackPath = NULL/EMPTY'
            }
            $form.Close()
            return
        }
    })

    [void]$form.ShowDialog()
    $form.Dispose()
}

# ======================= 自检模式 =======================

function Invoke-SelfTest {
    Write-Host ''
    Write-Host '=== 自检模式（仅在临时目录内操作，不触碰真实数据）==='
    $pass = 0
    $fail = 0

    function Check {
        param([string]$Name, [bool]$Cond, [string]$Detail)
        if ($Cond) { $script:stPass++; Write-Host ("  [通过] " + $Name) }
        else { $script:stFail++; Write-Host ("  [失败] " + $Name + "  " + $Detail) }
    }
    $script:stPass = 0
    $script:stFail = 0

    Write-Host ''
    Write-Host '1) 安全校验（应当被拒绝的路径）'
    $danger = @('C:\', 'C:\Windows', 'C:\Users', $env:USERPROFILE, $env:LOCALAPPDATA, $env:ProgramFiles, $env:SystemRoot, (Get-ScriptDir))
    foreach ($d in $danger) {
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        Check ("拒绝 " + $d) (-not (Test-SafePath $d)) '安全校验未拦截'
    }

    Write-Host ''
    Write-Host '2) 安全校验（应当被允许的路径）'
    $root = Join-Path $env:TEMP ('dc_selftest_' + [guid]::NewGuid().ToString('N'))
    Check ("允许 " + $root) (Test-SafePath $root) '正常路径被误拦'

    Write-Host ''
    Write-Host '3) 嵌套目录 + 只读文件清理（保留根目录）'
    try {
        $sub = Join-Path $root 'a\b\c'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $sub 'f1.txt'), ('x' * 2048))
        [System.IO.File]::WriteAllText((Join-Path $root 'a\f2.txt'), ('y' * 4096))
        $ro = Join-Path $root 'a\readonly.dat'
        [System.IO.File]::WriteAllText($ro, 'z')
        (Get-Item -LiteralPath $ro).Attributes = [System.IO.FileAttributes]::ReadOnly
        $before = Get-PathSize $root
        $null = Remove-PathPermanent -Path $root -KeepRoot
        $after = Get-PathSize $root
        Check '子项全部删除' ($after -eq 0) ("剩余 " + $after + " 字节")
        Check '根目录被保留' (Test-Path -LiteralPath $root) '根目录被误删'
        Check '只读文件也能删除' (-not (Test-Path -LiteralPath $ro)) '只读文件残留'
        Check '清理前有内容' ($before -gt 0) '测试数据未生成'
    } catch {
        Check '嵌套目录测试' $false $_.Exception.Message
    }

    Write-Host ''
    Write-Host '4) 整个目录删除（保留根目录关闭）'
    try {
        New-Item -ItemType Directory -Path (Join-Path $root 'x\y') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root 'x\y\g.bin'), ('q' * 1024))
        $null = Remove-PathPermanent -Path $root
        Check '目录被完整删除' (-not (Test-Path -LiteralPath $root)) '目录仍然存在'
    } catch {
        Check '整目录删除测试' $false $_.Exception.Message
    }
    if (Test-Path -LiteralPath $root) {
        try { [System.IO.Directory]::Delete($root, $true) } catch { }
    }

    Write-Host ''
    Write-Host '5) 清理项目录可用性'
    $cat = Get-Catalog
    Check ('清理项数量 = ' + $cat.Count) ($cat.Count -ge 20) '清理项过少'
    $ids = $cat | ForEach-Object { $_.Id }
    Check '清理项 ID 无重复' (($ids | Sort-Object -Unique).Count -eq $ids.Count) '存在重复 ID'

    Write-Host ''
    Write-Host ('=== 自检结束：通过 ' + $script:stPass + ' 项，失败 ' + $script:stFail + ' 项 ===')
    if ($script:stFail -eq 0) { Write-Host '结果：全部通过，程序可正常工作。' }
    else { Write-Host '结果：存在失败项，请检查。' }
}

# ======================= 入口 =======================

$script:ConfigPath = Get-ConfigPath -Override $Config
$script:RenderTo = $RenderTo
$script:BenchPaint = $BenchPaint
$script:SnapTo = $SnapTo
$script:ConfigExisted = Test-Path -LiteralPath $script:ConfigPath
$cfg = Load-Config -Path $script:ConfigPath
$script:AutoClean = [bool]$cfg.AutoClean
$script:DisclaimerAccepted = [bool]$cfg.DisclaimerAccepted

Initialize-Entries -Config $cfg

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

if ($Console) {
    Invoke-ConsoleMode -AutoRun:$Auto
    exit 0
}

if (-not $script:IsAdmin) {
    Write-Host '提示：当前未以管理员身份运行，部分系统级清理项将无法执行。'
    Write-Host '建议关闭本窗口，改用 RunCleaner.bat 启动（会自动申请管理员权限）。'
    Write-Host ''
}

Show-Gui
