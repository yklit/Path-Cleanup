#requires -version 5.1
try {
    $self = $PSCommandPath
    if ($self -and (Test-Path -LiteralPath $self)) {
        $zone = Get-Item -LiteralPath $self -Stream Zone.Identifier -ErrorAction SilentlyContinue
        if ($zone) {
            Remove-Item -LiteralPath $self -Stream Zone.Identifier -ErrorAction SilentlyContinue
            Write-Host "[安全提示] 检测到来自 Internet 标记，已自动解除。" -ForegroundColor Yellow
        }
    }
}
catch {}

try {
    $root = Split-Path -Parent $PSCommandPath
    Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            if (Get-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue
            }
        }
}
catch {}

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($true) } catch {}

$ScriptVersion = "Path Plus v8 Full (2026-02-13)"

# =========================================================
# 1) 错误显示 / 暂停
# =========================================================
function Show-ExceptionDetails($errRecord) {
    $ex = $null
    $inv = $null

    if ($errRecord -is [System.Management.Automation.ErrorRecord]) {
        $ex = $errRecord.Exception
        $inv = $errRecord.InvocationInfo
    } elseif ($errRecord -is [System.Exception]) {
        $ex = $errRecord
    } else {
        try { $ex = $errRecord.Exception } catch {}
        try { $inv = $errRecord.InvocationInfo } catch {}
    }

    Write-Host "---- 详细错误信息 ----" -ForegroundColor Red
    if ($ex) {
        Write-Host ("异常类型: {0}" -f $ex.GetType().FullName) -ForegroundColor Red
        Write-Host ("异常消息: {0}" -f $ex.Message) -ForegroundColor Red
        try { Write-Host ("HResult : 0x{0:X8}" -f $ex.HResult) -ForegroundColor DarkRed } catch {}
        if ($ex.InnerException) { Write-Host ("内部异常: {0}" -f $ex.InnerException.Message) -ForegroundColor DarkRed }
    }
    if ($inv) {
        Write-Host ("脚本: {0}" -f $inv.ScriptName) -ForegroundColor DarkRed
        Write-Host ("行号: {0}" -f $inv.ScriptLineNumber) -ForegroundColor DarkRed
        if ($inv.Line) { Write-Host ("出错命令: {0}" -f $inv.Line.Trim()) -ForegroundColor DarkRed }
    }
    Write-Host "----------------------" -ForegroundColor Red
}

function Pause-And-Return([string]$msg) {
    if ($msg) { Write-Host $msg -ForegroundColor Yellow }
    Write-Host ""
    Read-Host "按回车返回菜单" | Out-Null
}

# =========================================================
# 2) 启动即自动提权（WT 优先）
# =========================================================
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Admin {
    if (Test-IsAdmin) { return $true }

    Write-Host "检测到当前不是管理员权限，正在尝试提权（UAC）..." -ForegroundColor Yellow

    $script = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($script)) {
        Write-Host "无法定位脚本路径（PSCommandPath 为空）。请先保存为 .ps1 再运行。" -ForegroundColor Red
        return $false
    }

    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    $argsForPwsh = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$script`""
    ) -join ' '

    try {
        if ($wt) {
            # 说明：UAC 无法“原地升权”同一个 tab，只能开管理员 WT 新 tab/新窗口
            $wtArgs = @("-w","0","new-tab","powershell.exe",$argsForPwsh)
            Start-Process -FilePath "wt.exe" -Verb RunAs -ArgumentList $wtArgs | Out-Null
            return $false
        }

        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argsForPwsh | Out-Null
        return $false
    }
    catch {
        Write-Host "提权失败：" -ForegroundColor Red
        Show-ExceptionDetails $_
        Write-Host "请右键 Windows Terminal → 以管理员身份运行 → 再执行脚本。" -ForegroundColor Red
        return $false
    }
}

if (-not (Ensure-Admin)) { exit }

# =========================================================
# 3) 基础工具
# =========================================================
function Get-Timestamp { Get-Date -Format "yyyyMMdd_HHmmss" }

function Normalize-PathLike([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return "" }
    $q = $p.Trim()
    while ($q.Length -gt 3 -and ($q.EndsWith("\") -or $q.EndsWith("/"))) {
        $q = $q.Substring(0, $q.Length - 1)
    }
    return $q.ToLowerInvariant()
}

function Split-PathList([string]$raw) {
    @($raw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}

function Expand-Env([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $p }
    [Environment]::ExpandEnvironmentVariables($p)
}

# =========================================================
# 4) PATH 读写（系统/用户）
# =========================================================
$RegMachineEnvPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
$RegUserEnvPath    = "HKCU:\Environment"

function Read-PathRaw([ValidateSet("System","User")]$scope) {
    try {
        if ($scope -eq "System") {
            return [string](Get-ItemProperty -Path $RegMachineEnvPath -Name "Path" -ErrorAction Stop).Path
        } else {
            return [string](Get-ItemProperty -Path $RegUserEnvPath -Name "Path" -ErrorAction Stop).Path
        }
    } catch {
        # fallback
        if ($scope -eq "System") {
            return [Environment]::GetEnvironmentVariable("Path","Machine")
        } else {
            return [Environment]::GetEnvironmentVariable("Path","User")
        }
    }
}

function Notify-EnvChanged {
    $sig = @'
[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    try {
        Add-Type -MemberDefinition $sig -Name "Win32SMT" -Namespace Win32 -ErrorAction SilentlyContinue | Out-Null
        $HWND_BROADCAST = [IntPtr]0xffff
        $WM_SETTINGCHANGE = 0x001A
        $r = [UIntPtr]::Zero
        [Win32.Win32SMT]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, "Environment", 2, 5000, [ref]$r) | Out-Null
    } catch {}
}

function Write-PathRaw([ValidateSet("System","User")]$scope, [string]$newPath) {
    if ($scope -eq "System") {
        Set-ItemProperty -Path $RegMachineEnvPath -Name "Path" -Value $newPath -ErrorAction Stop | Out-Null
    } else {
        New-Item -Path $RegUserEnvPath -Force -ErrorAction SilentlyContinue | Out-Null
        Set-ItemProperty -Path $RegUserEnvPath -Name "Path" -Value $newPath -ErrorAction Stop | Out-Null
    }
    Notify-EnvChanged
}

# =========================================================
# 5) 桌面路径（迁移兼容）+ 备份（支持 []，使用 -LiteralPath）
# =========================================================
function Get-DesktopPathRobust {
    $candidates = New-Object System.Collections.Generic.List[string]
    try { $p1 = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory); if ($p1) { $candidates.Add($p1) | Out-Null } } catch {}
    try { $p2 = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop);          if ($p2) { $candidates.Add($p2) | Out-Null } } catch {}
    try {
        $reg = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
        $desktopReg = (Get-ItemProperty -Path $reg -Name "Desktop" -ErrorAction Stop).Desktop
        if ($desktopReg) {
            $p3 = [Environment]::ExpandEnvironmentVariables([string]$desktopReg)
            if ($p3) { $candidates.Add($p3) | Out-Null }
        }
    } catch {}

    foreach ($c in $candidates | Select-Object -Unique) {
        try { if (Test-Path -LiteralPath $c -PathType Container) { return $c } } catch {}
    }
    return (Get-Location).Path
}

function Try-LoadWinForms {
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop | Out-Null; return $true } catch { return $false }
}

function Pick-FolderDialog {
    if (-not (Try-LoadWinForms)) { return $null }
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "请选择用于保存备份的文件夹（默认桌面不可用时使用）"
    $dlg.ShowNewFolderButton = $true
    $res = $dlg.ShowDialog()
    if ($res -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $dlg.SelectedPath
}

function Ask-FolderFromConsole {
    while ($true) {
        $p = Read-Host "请输入用于保存备份的文件夹路径（留空取消）"
        if ([string]::IsNullOrWhiteSpace($p)) { return $null }
        try {
            New-Item -ItemType Directory -Path $p -Force -ErrorAction Stop | Out-Null
            if (Test-Path -LiteralPath $p -PathType Container) { return $p }
        } catch {
            Write-Host ("路径不可用或无权限：{0}" -f $p) -ForegroundColor Red
            Show-ExceptionDetails $_
        }
    }
}

function Resolve-BackupDirectory {
    $desktop = Get-DesktopPathRobust
    if ($desktop -and (Test-Path -LiteralPath $desktop -PathType Container)) { return $desktop }

    Write-Host "无法自动获取桌面路径，将让你选择保存目录。" -ForegroundColor Yellow

    $picked = Pick-FolderDialog
    if ($picked) { return $picked }

    Write-Host "无法打开选择窗口，将改为命令行输入路径。" -ForegroundColor Yellow
    return (Ask-FolderFromConsole)
}

function Backup-Path([ValidateSet("System","User")]$scope, [string]$rawPath) {
    $dir = Resolve-BackupDirectory
    if (-not $dir) { throw "用户取消选择备份目录，已中止写入。" }

    New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    $tag = if ($scope -eq "System") { "系统PATH备份" } else { "用户PATH备份" }
    $file = Join-Path $dir ("{0}[{1}].txt" -f $tag, (Get-Timestamp))

    # 关键：必须用 -LiteralPath，避免 [] 被当成通配符
    $rawPath | Out-File -Encoding UTF8 -LiteralPath $file -ErrorAction Stop
    return $file
}

# =========================================================
# 6) 文件选择窗口（恢复备份，仅 TXT）
# =========================================================
function Pick-TxtFileFromDialog {
    if (-not (Try-LoadWinForms)) { throw "无法加载 System.Windows.Forms，无法打开选择文件窗口。" }
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "选择要恢复的 PATH 备份文件"
    $dlg.InitialDirectory = Get-DesktopPathRobust
    $dlg.Filter = "TXT 文本文件 (*.txt)|*.txt"
    $dlg.Multiselect = $false
    $dlg.CheckFileExists = $true
    $dlg.CheckPathExists = $true
    $result = $dlg.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $dlg.FileName
}

# =========================================================
# 7) 扫描规则：硬编码 → 变量版；Nuitka 缓存路径删除；RequiredSystem 只补系统
# =========================================================
$HardcodeMap = @(
    @{ Hard = "C:\Windows";                                   Var = "%SystemRoot%" },
    @{ Hard = "C:\Windows\System32";                           Var = "%SystemRoot%\System32" },
    @{ Hard = "C:\Windows\System32\Wbem";                      Var = "%SystemRoot%\System32\Wbem" },
    @{ Hard = "C:\Windows\System32\WindowsPowerShell\v1.0";    Var = "%SystemRoot%\System32\WindowsPowerShell\v1.0\" },
    @{ Hard = "C:\Windows\System32\OpenSSH";                   Var = "%SystemRoot%\System32\OpenSSH\" }
)

# 只给系统 PATH 补齐，用户 PATH 不补
$RequiredSystem = @(
    "%SystemRoot%",
    "%SystemRoot%\System32",
    "%SystemRoot%\System32\OpenSSH\",
    "%SystemRoot%\System32\Wbem",
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\"
)

$NuitkaMarker = "\appdata\local\nuitka\nuitka\cache\downloads\"

# =========================================================
# 8) 菜单
# =========================================================
function Show-MainMenu {
    Write-Host ""
    Write-Host "==============================" -ForegroundColor DarkCyan
    Write-Host " PATH 清理/恢复 工具" -ForegroundColor Cyan
    Write-Host "==============================" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host ("版本：{0}" -f $ScriptVersion) -ForegroundColor DarkGray
    Write-Host ("脚本路径：{0}" -f $PSCommandPath) -ForegroundColor DarkGray
    Write-Host "GitHub作者:yklit" -ForegroundColor DarkGray
    Write-Host "项目开源地址:https://github.com/yklit/Path-Cleanup" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "⚠️ 免责声明与用户协议：" -ForegroundColor Red
    Write-Host "1. 此脚本会修改系统注册表（HKLM\SYSTEM\...\Environment），仅建议熟悉系统的用户使用"
    Write-Host "2. 操作前会自动备份 PATH 到桌面（命名格式：系统path备份[时间戳].txt），请务必保留备份至少7天"
    Write-Host "3. 若因使用本脚本导致系统异常，作者不承担任何责任"
    Write-Host "4. 本脚本在GitHub上使用gpl V3协议进行开源,非官方途径下载的二创脚本运行前请检查脚本内容"
    Write-Host "如果不同意以上协议，请立即关闭并删除本脚本" -ForegroundColor Red
    Write-Host ""
    Write-Host "请选择操作：" -ForegroundColor Cyan
    Write-Host "  [1] 恢复备份（弹出选择文件窗口）"
    Write-Host "  [2] 清理PATH"
    Write-Host "  [0] 退出"
    Write-Host ""
}

function Get-ScanScope {
    Write-Host ""
    Write-Host "请选择操作：" -ForegroundColor Cyan
    Write-Host "  [1] 仅扫描系统path"
    Write-Host "  [2] 仅扫描用户path"
    Write-Host "  [3] 扫描全部（系统和用户的path都扫描）"
    Write-Host "  [0] 退出"
    Write-Host ""
    $m = Read-Host "请输入选项（0/1/2/3）"
    if ($m -notin @("0","1","2","3")) { return $null }
    if ($m -eq "0") { return "EXIT" }
    if ($m -eq "1") { return @("System") }
    if ($m -eq "2") { return @("User") }
    return @("System","User")
}

function Get-CleanOptions {
    Write-Host ""
    Write-Host "请选择操作：" -ForegroundColor Cyan
    Write-Host "  [1] 完整扫描"
    Write-Host "  [2] 跳过路径存在性扫描"
    Write-Host "  [3] 自定义（逐项开关）"
    Write-Host "  [0] 退出"
    Write-Host ""

    $m = Read-Host "请输入选项（0/1/2/3）"
    if ($m -notin @("0","1","2","3")) { return $null }
    if ($m -eq "0") { return "EXIT" }

    $opt = [pscustomobject]@{
        ScanDuplicates     = $true
        ScanHardcoded      = $true
        ScanNeedDelete     = $true
        ScanPathExistence  = $true
        ScanMissingToAdd   = $true
        SortAndOrganize    = $true
    }

    if ($m -eq "1") { return $opt }
    if ($m -eq "2") { $opt.ScanPathExistence = $false; return $opt }

    Write-Host ""
    $q1 = Read-Host "执行【重复项扫描/去重】？（Y/N）"
    Write-Host ""
    $q2 = Read-Host "执行【硬编码扫描/替换为变量版】？（Y/N）"
    Write-Host ""
    $q3 = Read-Host "执行【需要删除扫描（如 Nuitka 缓存等）】？（Y/N）"
    Write-Host ""
    $q4 = Read-Host "执行【路径存在性扫描（删除不存在路径）】？（Y/N）"
    Write-Host ""
    $q5 = Read-Host "执行【缺失路径补齐（仅系统 SystemRoot 等）】？（Y/N）"
    Write-Host ""
    $q6 = Read-Host "执行【排序整理】？（Y/N）"
    Write-Host ""

    $opt.ScanDuplicates    = ($q1 -in @("Y","y"))
    $opt.ScanHardcoded     = ($q2 -in @("Y","y"))
    $opt.ScanNeedDelete    = ($q3 -in @("Y","y"))
    $opt.ScanPathExistence = ($q4 -in @("Y","y"))
    $opt.ScanMissingToAdd  = ($q5 -in @("Y","y"))
    $opt.SortAndOrganize   = ($q6 -in @("Y","y"))

    return $opt
}

# =========================================================
# 9) 核心分析：输出你要求的 6 大分类 + 最终预览
# =========================================================
function Analyze-And-Build([string]$scope, [string[]]$itemsOld, $opt) {

    $foundDupGroups = @()
    $foundHard = New-Object System.Collections.Generic.List[string]
    $foundMissingOnDisk = New-Object System.Collections.Generic.List[string]
    $needAdd = New-Object System.Collections.Generic.List[string]
    $needDelete = New-Object System.Collections.Generic.List[string]

    $normSet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($p in $itemsOld) { [void]$normSet.Add((Normalize-PathLike $p)) }

    # 1) 重复项
    if ($opt.ScanDuplicates) {
        Write-Host "正在扫描重复的路径..." -ForegroundColor Cyan
        $groups = $itemsOld | Group-Object { Normalize-PathLike $_ }
        foreach ($g in ($groups | Where-Object { $_.Count -gt 1 })) {
            $foundDupGroups += [pscustomobject]@{ Path = $g.Group[0]; Count = $g.Count }
        }
    }

    # 2) 硬编码项（只负责“识别 + 标记删除硬编码版 + 标记需要添加变量版”）
    $needAddFromHard = New-Object System.Collections.Generic.List[string]
    $hardToDeleteNorm = New-Object System.Collections.Generic.HashSet[string]

    if ($opt.ScanHardcoded) {
        Write-Host "正在扫描硬编码的路径..." -ForegroundColor Cyan
        foreach ($m in $HardcodeMap) {
            $hardN = Normalize-PathLike $m.Hard
            $varN  = Normalize-PathLike $m.Var
            if ($normSet.Contains($hardN)) {
                $foundHard.Add($m.Hard) | Out-Null
                [void]$hardToDeleteNorm.Add($hardN)
                $needDelete.Add($m.Hard) | Out-Null
                if (-not $normSet.Contains($varN)) { $needAddFromHard.Add($m.Var) | Out-Null }
            }
        }
    }

    # 3) 需要删除（Nuitka 等）
    $deleteNorm = New-Object System.Collections.Generic.HashSet[string]
    if ($opt.ScanNeedDelete) {
        Write-Host "正在扫描需要删除的路径..." -ForegroundColor Cyan
        foreach ($p in $itemsOld) {
            $np = Normalize-PathLike $p
            if ($np.Contains($NuitkaMarker)) {
                [void]$deleteNorm.Add($np)
                $needDelete.Add($p) | Out-Null
            }
        }
    }

    # 4) 不存在路径
    if ($opt.ScanPathExistence) {
        Write-Host "正在扫描不存在的路径..." -ForegroundColor Cyan
        foreach ($p in $itemsOld) {
            $expanded = Expand-Env $p
            try {
                if (-not (Test-Path -LiteralPath $expanded -ErrorAction Stop)) {
                    $foundMissingOnDisk.Add($p) | Out-Null
                    [void]$deleteNorm.Add((Normalize-PathLike $p))
                    $needDelete.Add($p) | Out-Null
                }
            } catch {
                # 访问出错（权限/奇怪路径）就“继续保留”，不加入删除
            }
        }
    }

    # 5) 缺失需要添加（仅系统）
    if ($opt.ScanMissingToAdd) {
        Write-Host "正在扫描缺失的路径..." -ForegroundColor Cyan

        if ($scope -eq "System") {
            foreach ($req in $RequiredSystem) {
                if (-not $normSet.Contains((Normalize-PathLike $req))) { $needAdd.Add($req) | Out-Null }
            }
            foreach ($a in $needAddFromHard) {
                if (-not $normSet.Contains((Normalize-PathLike $a))) { $needAdd.Add($a) | Out-Null }
            }
        } else {
            # 用户 PATH：只补“由硬编码替换产生的变量版”（如果你硬编码扫描开了）
            foreach ($a in $needAddFromHard) {
                if (-not $normSet.Contains((Normalize-PathLike $a))) { $needAdd.Add($a) | Out-Null }
            }
        }
    } else {
        # 即便 ScanMissingToAdd 关闭，也要保证硬编码扫描产生的变量版能被添加（如果用户只想替换）
        foreach ($a in $needAddFromHard) {
            if (-not $normSet.Contains((Normalize-PathLike $a))) { $needAdd.Add($a) | Out-Null }
        }
    }

    Write-Host "扫描完成 开始整理..." -ForegroundColor Green

    # 去重/过滤
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $final = New-Object System.Collections.Generic.List[string]

    foreach ($p in $itemsOld) {
        $np = Normalize-PathLike $p

        if ($hardToDeleteNorm.Contains($np)) { continue }
        if ($deleteNorm.Contains($np)) { continue }

        if ($opt.ScanDuplicates) {
            if (-not $seen.Add($np)) { continue }
        } else {
            [void]$seen.Add($np)
        }

        $final.Add($p) | Out-Null
    }

    # 添加缺失项（needAdd）
    foreach ($a in ($needAdd | Sort-Object -Unique)) {
        $an = Normalize-PathLike $a
        if (-not $seen.Contains($an)) {
            $final.Add($a) | Out-Null
            [void]$seen.Add($an)
        }
    }

    # 排序整理（可开关）
    $finalArr = @($final)
    if ($opt.SortAndOrganize) {
        function Get-Rank([string]$p) {
            $np = Normalize-PathLike $p
            if ($np.StartsWith((Normalize-PathLike "%systemroot%"))) { return 0 }
            if ($np -like "*\programdata\chocolatey\bin") { return 1 }
            if ($np -like "*\program files\dotnet*") { return 2 }
            if ($np -like "*microsoft sql server*" -or $np -like "*windows performance toolkit*") { return 3 }
            return 9
        }
        $indexed = for ($i=0; $i -lt $finalArr.Count; $i++) {
            [pscustomobject]@{ Index = $i; Path = $finalArr[$i]; Rank = (Get-Rank $finalArr[$i]) }
        }
        $finalArr = $indexed | Sort-Object Rank, Index | ForEach-Object { $_.Path }
    }

    Write-Host "整理完成" -ForegroundColor Green

    return [pscustomobject]@{
        NewItems           = @($finalArr)
        FoundDupGroups     = @($foundDupGroups)
        FoundMissingOnDisk = @($foundMissingOnDisk | Sort-Object -Unique)
        FoundHardcoded     = @($foundHard | Sort-Object -Unique)
        NeedDeleteDisplay  = @($needDelete | Sort-Object -Unique)
        NeedAdd            = @($needAdd | Sort-Object -Unique)
    }
}

function Has-Changes($res) {
    return -not (
        ($res.FoundDupGroups.Count -eq 0) -and
        ($res.FoundMissingOnDisk.Count -eq 0) -and
        ($res.FoundHardcoded.Count -eq 0) -and
        ($res.NeedDeleteDisplay.Count -eq 0) -and
        ($res.NeedAdd.Count -eq 0)
    )
}

function Print-ScopeResult([string]$label, $res, [string[]]$newItems) {
    Write-Host ""
    Write-Host ("=======[{0}] 发现重复的路径 (共 {1} 个)======" -f $label, $res.FoundDupGroups.Count) -ForegroundColor Cyan
    if ($res.FoundDupGroups.Count -eq 0) { Write-Host "（无）" -ForegroundColor DarkGray }
    else { foreach ($d in ($res.FoundDupGroups | Sort-Object Count -Descending)) { Write-Host ("{0} (重复 {1} 次)" -f $d.Path, $d.Count) } }

    Write-Host ""
    Write-Host ("=======[{0}] 发现不存在的路径 (共 {1} 个)======" -f $label, $res.FoundMissingOnDisk.Count) -ForegroundColor Cyan
    if ($res.FoundMissingOnDisk.Count -eq 0) { Write-Host "（无）" -ForegroundColor DarkGray }
    else { $res.FoundMissingOnDisk | ForEach-Object { Write-Host $_ } }

    Write-Host ""
    Write-Host ("=======[{0}] 发现硬编码路径 (共 {1} 个)======" -f $label, $res.FoundHardcoded.Count) -ForegroundColor Cyan
    if ($res.FoundHardcoded.Count -eq 0) { Write-Host "（无）" -ForegroundColor DarkGray }
    else { $res.FoundHardcoded | ForEach-Object { Write-Host $_ } }

    Write-Host ""
    Write-Host ("=======[{0}] 需要删除的路径 (共 {1} 个)======" -f $label, $res.NeedDeleteDisplay.Count) -ForegroundColor Cyan
    if ($res.NeedDeleteDisplay.Count -eq 0) { Write-Host "（无）" -ForegroundColor DarkGray }
    else { $res.NeedDeleteDisplay | ForEach-Object { Write-Host $_ } }

    Write-Host ""
    Write-Host ("=======[{0}] 发现缺少需要添加的路径 (共 {1} 个)======" -f $label, $res.NeedAdd.Count) -ForegroundColor Cyan
    if ($res.NeedAdd.Count -eq 0) { Write-Host "（无）" -ForegroundColor DarkGray }
    else { $res.NeedAdd | ForEach-Object { Write-Host $_ } }

    Write-Host ""
    Write-Host ("=======[{0}] 将要覆盖写入的路径[路径预览] (共 {1} 个)======" -f $label, $newItems.Count) -ForegroundColor Cyan
    $newItems | ForEach-Object { Write-Host $_ }
}

# =========================================================
# 10) 主循环
# =========================================================
while ($true) {
    Show-MainMenu
    $choice = Read-Host "请输入选项（0/1/2）"

    if ($choice -eq "0") { break }
    if ($choice -notin @("1","2")) { Pause-And-Return "未知选项，请重新选择。"; continue }

    # -------------------------
    # [1] 恢复备份
    # -------------------------
    if ($choice -eq "1") {
        try {
            $file = Pick-TxtFileFromDialog
            if (-not $file) { Pause-And-Return "已取消选择文件。"; continue }

            Write-Host ("已选择备份文件：{0}" -f $file) -ForegroundColor Gray
            Write-Host ("文件存在性检查：{0}" -f (Test-Path -LiteralPath $file)) -ForegroundColor Gray

            $rawNew = Get-Content -LiteralPath $file -Raw -ErrorAction Stop
            $preview = Split-PathList $rawNew

            Write-Host ""
            Write-Host ("======将要覆盖写入的路径[路径预览] (共 {0} 个)======" -f $preview.Count) -ForegroundColor Cyan
            $preview | ForEach-Object { Write-Host $_ }

            Write-Host ""
            $target = Read-Host "写入到（1=系统 2=用户 0=取消）"
            if ($target -notin @("0","1","2")) { Pause-And-Return "输入无效，已取消。"; continue }
            if ($target -eq "0") { Pause-And-Return "已取消（未写入）。"; continue }

            $scope = if ($target -eq "1") { "System" } else { "User" }
            $rawOld = Read-PathRaw $scope

            Write-Host ""
            $confirm = Read-Host "确认写入？(Y/N)"
            if ($confirm -notin @("Y","y")) { Pause-And-Return "已取消（未写入）。"; continue }

            # 写入前备份（失败则中止）
            try {
                $bk = Backup-Path $scope $rawOld
                Write-Host ("已创建写入前备份：{0}" -f $bk) -ForegroundColor Green
            } catch {
                Write-Host "创建备份失败（将中止写入，以免无法回滚）：" -ForegroundColor Red
                Show-ExceptionDetails $_
                Pause-And-Return
                continue
            }

            Write-PathRaw $scope $rawNew
            Pause-And-Return "恢复完成！建议注销或重启一次，让所有进程刷新 PATH。"
        }
        catch {
            Write-Host "恢复备份时遇到错误：" -ForegroundColor Red
            Show-ExceptionDetails $_
            Pause-And-Return
        }
        continue
    }

    # -------------------------
    # [2] 清理 PATH
    # -------------------------
    if ($choice -eq "2") {
        try {
            $scopes = Get-ScanScope
            if ($scopes -eq $null) { Pause-And-Return "输入无效，返回菜单。"; continue }
            if ($scopes -eq "EXIT") { break }

            $opt = Get-CleanOptions
            if ($opt -eq $null) { Pause-And-Return "输入无效，返回菜单。"; continue }
            if ($opt -eq "EXIT") { break }

            $results = @()

            foreach ($s in @("System","User")) {
                if ($scopes -notcontains $s) { continue }

                $scopeLabel = if ($s -eq "System") { "系统" } else { "用户" }
                $rawOld = Read-PathRaw $s
                $itemsOld = Split-PathList $rawOld

                Write-Host ""
                Write-Host ("======== 开始扫描 [{0}] PATH ========" -f $scopeLabel) -ForegroundColor DarkCyan

                $res = Analyze-And-Build $s $itemsOld $opt

                $results += [pscustomobject]@{
                    Scope   = $s
                    Label   = $scopeLabel
                    RawOld  = $rawOld
                    Res     = $res
                    NewItems= $res.NewItems
                }
            }

            $anyChanges = $false
            foreach ($r in $results) { if (Has-Changes $r.Res) { $anyChanges = $true; break } }

            # 无变化：直接返回（你要求的行为）
            if (-not $anyChanges) {
                Pause-And-Return "扫描完成，没有发现需要更改的选项。"
                continue
            }

            # 输出（先系统后用户；无变化的 scope 不打印）
            foreach ($r in ($results | Sort-Object { if ($_.Scope -eq "System") { 0 } else { 1 } })) {
                if (-not (Has-Changes $r.Res)) { continue }
                Print-ScopeResult $r.Label $r.Res $r.NewItems
            }

            Write-Host ""
            $confirm = Read-Host "是否保存（写入注册表）？（Y/N）"
            if ($confirm -notin @("Y","y")) { Pause-And-Return "已取消（未写入）。"; continue }

            # 写入：逐 scope 写；每个 scope 写入前备份一次（失败则跳过该 scope 写入）
            foreach ($r in ($results | Sort-Object { if ($_.Scope -eq "System") { 0 } else { 1 } })) {
                if (-not (Has-Changes $r.Res)) { continue }

                $rawNew = ($r.NewItems -join ";")

                try {
                    $bk = Backup-Path $r.Scope $r.RawOld
                    Write-Host ("已创建 [{0}] 写入前备份：{1}" -f $r.Label, $bk) -ForegroundColor Green
                } catch {
                    Write-Host ("[{0}] 创建备份失败（将中止该项写入，以免无法回滚）：" -f $r.Label) -ForegroundColor Red
                    Show-ExceptionDetails $_
                    continue
                }

                Write-PathRaw $r.Scope $rawNew
                Write-Host ("[{0}] 写入完成。" -f $r.Label) -ForegroundColor Green
            }

            Pause-And-Return "写入流程结束！建议注销或重启一次，让所有进程刷新 PATH。"
        }
        catch {
            Write-Host "清理 PATH 时遇到错误：" -ForegroundColor Red
            Show-ExceptionDetails $_
            Pause-And-Return
        }
        continue
    }
}

Write-Host "已退出。" -ForegroundColor Gray
