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

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($true) } catch { }

$ScriptVersion = "Path Pro v4 (2026-02-13)"

function Show-ExceptionDetails($errRecord) {
    $ex = $null
    $inv = $null

    if ($errRecord -is [System.Management.Automation.ErrorRecord]) {
        $ex = $errRecord.Exception
        $inv = $errRecord.InvocationInfo
    } elseif ($errRecord -is [System.Exception]) {
        $ex = $errRecord
    } else {
        try { $ex = $errRecord.Exception } catch { }
        try { $inv = $errRecord.InvocationInfo } catch { }
    }

    Write-Host "---- 详细错误信息 ----" -ForegroundColor Red
    if ($ex) {
        Write-Host ("异常类型: {0}" -f $ex.GetType().FullName) -ForegroundColor Red
        Write-Host ("异常消息: {0}" -f $ex.Message) -ForegroundColor Red
        try { Write-Host ("HResult : 0x{0:X8}" -f $ex.HResult) -ForegroundColor DarkRed } catch { }
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
    Read-Host "按回车返回菜单"
}

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

function Get-Timestamp { Get-Date -Format "yyyyMMdd_HHmmss" }

function Normalize-PathLike([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return "" }
    $q = $p.Trim()
    while ($q.Length -gt 3 -and ($q.EndsWith("\") -or $q.EndsWith("/"))) {
        $q = $q.Substring(0, $q.Length - 1)
    }
    return $q.ToLowerInvariant()
}

function Expand-Env([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $p }
    return [Environment]::ExpandEnvironmentVariables($p)
}

function Split-PathList([string]$raw) {
    @($raw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}

function Get-DesktopPathRobust {
    $candidates = New-Object System.Collections.Generic.List[string]
    try { $p1 = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory); if ($p1) { $candidates.Add($p1) | Out-Null } } catch { }
    try { $p2 = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop);          if ($p2) { $candidates.Add($p2) | Out-Null } } catch { }
    try {
        $reg = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
        $desktopReg = (Get-ItemProperty -Path $reg -Name "Desktop" -ErrorAction Stop).Desktop
        if ($desktopReg) {
            $p3 = [Environment]::ExpandEnvironmentVariables([string]$desktopReg)
            if ($p3) { $candidates.Add($p3) | Out-Null }
        }
    } catch { }

    foreach ($c in $candidates | Select-Object -Unique) {
        try { if (Test-Path -LiteralPath $c -PathType Container) { return $c } } catch { }
    }
    return $null
}

function Try-LoadWinForms {
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop | Out-Null; return $true } catch { return $false }
}

function Pick-FolderDialog {
    if (-not (Try-LoadWinForms)) { return $null }
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "无法自动定位桌面路径，请选择一个用于保存备份的文件夹"
    $dlg.ShowNewFolderButton = $true
    $res = $dlg.ShowDialog()
    if ($res -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $dlg.SelectedPath
}

function Ask-FolderFromConsole {
    while ($true) {
        $p = Read-Host "请输入一个用于保存备份的文件夹路径（留空取消）"
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
    if ($desktop) { return $desktop }

    Write-Host "无法自动获取桌面路径（可能桌面被迁移/注册表异常/权限问题）。" -ForegroundColor Yellow

    $picked = Pick-FolderDialog
    if ($picked) { return $picked }

    Write-Host "无法打开系统文件夹选择窗口（可能 WinForms 不可用）。将改为命令行输入路径。" -ForegroundColor Yellow
    return (Ask-FolderFromConsole)
}

$RegEnvPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"

function Read-MachinePathRaw {
    try { return [string](Get-ItemProperty -Path $RegEnvPath -Name "Path" -ErrorAction Stop).Path }
    catch { return [Environment]::GetEnvironmentVariable("Path", "Machine") }
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
    } catch { }
}

function Write-MachinePathRaw([string]$newPath) {
    Set-ItemProperty -Path $RegEnvPath -Name "Path" -Value $newPath -ErrorAction Stop | Out-Null
    Notify-EnvChanged
}

function Backup-MachinePath([string]$rawPath) {
    $dir = Resolve-BackupDirectory
    if (-not $dir) { throw "用户取消选择备份目录，已中止写入。" }

    New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    $file = Join-Path $dir ("系统path备份[{0}].txt" -f (Get-Timestamp))

    Write-Host ("备份保存目录：{0}" -f $dir) -ForegroundColor Gray
    Write-Host ("备份文件路径：{0}" -f $file) -ForegroundColor Gray

    $rawPath | Out-File -Encoding UTF8 -LiteralPath $file -ErrorAction Stop
    return $file
}

function Pick-TxtFileFromDialog {
    if (-not (Try-LoadWinForms)) { throw "无法加载 System.Windows.Forms，无法打开选择文件窗口。" }
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "选择要恢复的系统 PATH 备份文件"
    $init = Get-DesktopPathRobust
    if (-not $init) { $init = (Get-Location).Path }
    $dlg.InitialDirectory = $init
    $dlg.Filter = "TXT 文本文件 (*.txt)|*.txt"
    $dlg.Multiselect = $false
    $dlg.CheckFileExists = $true
    $dlg.CheckPathExists = $true
    $result = $dlg.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $dlg.FileName
}

$HardcodeMap = @(
    @{ Hard = "C:\Windows";                                   Var = "%SystemRoot%" },
    @{ Hard = "C:\Windows\System32";                           Var = "%SystemRoot%\System32" },
    @{ Hard = "C:\Windows\System32\Wbem";                      Var = "%SystemRoot%\System32\Wbem" },
    @{ Hard = "C:\Windows\System32\WindowsPowerShell\v1.0";    Var = "%SystemRoot%\System32\WindowsPowerShell\v1.0\" },
    @{ Hard = "C:\Windows\System32\OpenSSH";                   Var = "%SystemRoot%\System32\OpenSSH\" }
)

$RequiredSystem = @(
    "%SystemRoot%\System32",
    "%SystemRoot%",
    "%SystemRoot%\System32\Wbem",
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\",
    "%SystemRoot%\System32\OpenSSH\"
)

$NuitkaMarker = "\appdata\local\nuitka\nuitka\cache\downloads\"

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
    $q3 = Read-Host "执行【路径存在性扫描（删除不存在路径）】？（Y/N）"
    Write-Host ""
    $q4 = Read-Host "执行【缺失路径补齐（SystemRoot 等）】？（Y/N）"
    Write-Host ""
    $q5 = Read-Host "执行【排序整理】？（Y/N）"
    Write-Host ""

    $opt.ScanDuplicates    = ($q1 -in @("Y","y"))
    $opt.ScanHardcoded     = ($q2 -in @("Y","y"))
    $opt.ScanPathExistence = ($q3 -in @("Y","y"))
    $opt.ScanMissingToAdd  = ($q4 -in @("Y","y"))
    $opt.SortAndOrganize   = ($q5 -in @("Y","y"))

    return $opt
}

function Analyze-And-Build([string[]]$itemsOld, $opt) {

    $foundDup = @()
    $foundHard = New-Object System.Collections.Generic.List[string]
    $needAddFromHard = New-Object System.Collections.Generic.List[string]
    $foundMissingOnDisk = New-Object System.Collections.Generic.List[string]
    $needAdd = New-Object System.Collections.Generic.List[string]

    $normSet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($p in $itemsOld) { [void]$normSet.Add((Normalize-PathLike $p)) }

    $toDelete = New-Object System.Collections.Generic.HashSet[string]

    if ($opt.ScanDuplicates) {
        Write-Host "正在扫描重复的路径..." -ForegroundColor Cyan
        $groups = $itemsOld | Group-Object { Normalize-PathLike $_ }
        foreach ($g in ($groups | Where-Object { $_.Count -gt 1 })) {
            $foundDup += [pscustomobject]@{ Path = $g.Group[0]; Count = $g.Count }
        }
    }

    if ($opt.ScanHardcoded) {
        Write-Host "正在扫描硬编码的路径..." -ForegroundColor Cyan
        foreach ($m in $HardcodeMap) {
            $hardN = Normalize-PathLike $m.Hard
            $varN  = Normalize-PathLike $m.Var
            if ($normSet.Contains($hardN)) {
                $foundHard.Add($m.Hard) | Out-Null
                [void]$toDelete.Add($hardN)
                if (-not $normSet.Contains($varN)) { $needAddFromHard.Add($m.Var) | Out-Null }
            }
        }
    }

    Write-Host "正在扫描需要删除的路径..." -ForegroundColor Cyan
    foreach ($p in $itemsOld) {
        $np = Normalize-PathLike $p
        if ($np.Contains($NuitkaMarker)) { [void]$toDelete.Add($np) }
    }

    if ($opt.ScanPathExistence) {
        Write-Host "正在扫描不存在的路径..." -ForegroundColor Cyan
        foreach ($p in $itemsOld) {
            $expanded = Expand-Env $p
            try {
                if (-not (Test-Path -LiteralPath $expanded -ErrorAction Stop)) {
                    $foundMissingOnDisk.Add($p) | Out-Null
                    [void]$toDelete.Add((Normalize-PathLike $p))
                }
            } catch { }
        }
    }

    if ($opt.ScanMissingToAdd) {
        Write-Host "正在扫描缺失的路径..." -ForegroundColor Cyan
        foreach ($req in $RequiredSystem) {
            if (-not $normSet.Contains((Normalize-PathLike $req))) { $needAdd.Add($req) | Out-Null }
        }
        foreach ($a in $needAddFromHard) {
            if (-not $normSet.Contains((Normalize-PathLike $a))) { $needAdd.Add($a) | Out-Null }
        }
    }

    Write-Host "扫描完成 开始整理..." -ForegroundColor Green

    $seen = New-Object System.Collections.Generic.HashSet[string]
    $kept = New-Object System.Collections.Generic.List[string]
    $dupExtraToDelete = New-Object System.Collections.Generic.List[string]

    foreach ($p in $itemsOld) {
        $np = Normalize-PathLike $p
        if ($toDelete.Contains($np)) { continue }

        if ($opt.ScanDuplicates) {
            if (-not $seen.Add($np)) { $dupExtraToDelete.Add($p) | Out-Null; continue }
        } else {
            $seen.Add($np) | Out-Null
        }
        $kept.Add($p) | Out-Null
    }

    if ($opt.ScanMissingToAdd) {
        foreach ($a in ($needAdd | Sort-Object -Unique)) {
            $an = Normalize-PathLike $a
            if (-not $seen.Contains($an)) {
                $kept.Add($a) | Out-Null
                [void]$seen.Add($an)
            }
        }
    }

    $final = @($kept)

    if ($opt.SortAndOrganize) {
        function Get-Rank([string]$p) {
            $np = Normalize-PathLike $p
            foreach ($req in $RequiredSystem) { if ($np -eq (Normalize-PathLike $req)) { return 0 } }
            if ($np.StartsWith((Normalize-PathLike "%systemroot%"))) { return 1 }
            if ($np -like "*\programdata\chocolatey\bin" -or $np -like "*\program files\dotnet*") { return 2 }
            if ($np -like "*microsoft sql server*" -or $np -like "*windows performance toolkit*") { return 3 }
            if ($np -like "*\git\cmd" -or $np -like "*vs code\bin" -or $np -like "*\python*" -or
                $np -like "*\gradle*\bin" -or $np -like "*\android-sdk*" -or $np -like "*\mongodb\bin" -or
                $np -like "*\ffmpeg*\bin" -or $np -like "*\upx*") { return 4 }
            return 5
        }

        $indexed = for ($i=0; $i -lt $final.Count; $i++) {
            [pscustomobject]@{ Index = $i; Path = $final[$i]; Rank = (Get-Rank $final[$i]) }
        }
        $final = $indexed | Sort-Object Rank, Index | ForEach-Object { $_.Path }
    }

    Write-Host "整理完成" -ForegroundColor Green

    $needDeleteDisplay = @(
        ($dupExtraToDelete | Sort-Object -Unique) +
        ($foundHard | Sort-Object -Unique) +
        ($foundMissingOnDisk | Sort-Object -Unique) +
        ($itemsOld | Where-Object { (Normalize-PathLike $_).Contains($NuitkaMarker) } | Sort-Object -Unique)
    ) | Sort-Object -Unique

    return [pscustomobject]@{
        NewItems           = @($final)
        FoundDupGroups     = @($foundDup)
        FoundMissingOnDisk = @($foundMissingOnDisk | Sort-Object -Unique)
        FoundHardcoded     = @($foundHard | Sort-Object -Unique)
        NeedDeleteDisplay  = @($needDeleteDisplay)
        NeedAdd            = @($needAdd | Sort-Object -Unique)
    }
}

function Show-MainMenu {
    Write-Host ""
    Write-Host "==============================" -ForegroundColor DarkCyan
    Write-Host " 系统 PATH 清理/恢复 工具" -ForegroundColor Cyan
    Write-Host " 仅处理：系统（Machine）PATH" -ForegroundColor Cyan
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

# =========================
# 主循环
# =========================
while ($true) {
    Show-MainMenu
    $choice = Read-Host "请输入选项（0/1/2）"

    if ($choice -eq "0") { break }
    if ($choice -notin @("1","2")) { Pause-And-Return "未知选项，请重新选择。"; continue }

    $rawOld   = Read-MachinePathRaw
    $itemsOld = Split-PathList $rawOld

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
            $confirm = Read-Host "是否保存（写入注册表）？（Y/N）"
            if ($confirm -notin @("Y","y")) { Pause-And-Return "已取消（未写入）。"; continue }

            $bk = Backup-MachinePath $rawOld
            Write-Host ("已创建写入前备份：{0}" -f $bk) -ForegroundColor Green

            Write-MachinePathRaw $rawNew
            Pause-And-Return "恢复完成！建议注销或重启一次，让所有进程刷新 PATH。"
        }
        catch {
            Write-Host "恢复备份时遇到错误：" -ForegroundColor Red
            Show-ExceptionDetails $_
            Pause-And-Return
        }
        continue
    }

    if ($choice -eq "2") {
        try {
            $opt = Get-CleanOptions
            if ($opt -eq $null) { Pause-And-Return "输入无效，返回菜单。"; continue }
            if ($opt -eq "EXIT") { break }

            $res = Analyze-And-Build $itemsOld $opt

            # ★新增：如果没有任何需要更改的东西，直接提示并返回菜单
            $noChanges =
                ($res.FoundDupGroups.Count -eq 0) -and
                ($res.FoundMissingOnDisk.Count -eq 0) -and
                ($res.FoundHardcoded.Count -eq 0) -and
                ($res.NeedDeleteDisplay.Count -eq 0) -and
                ($res.NeedAdd.Count -eq 0)

            if ($noChanges) {
                Pause-And-Return "扫描完成，没有发现需要更改的选项。"
                continue
            }

            $newItems = $res.NewItems

            Write-Host ""
            Write-Host ("=======发现重复的路径 (共 {0} 个)======" -f $res.FoundDupGroups.Count) -ForegroundColor Cyan
            if ($res.FoundDupGroups.Count -eq 0) { Write-Host "（无）" -ForegroundColor DarkGray }
            else { foreach ($d in ($res.FoundDupGroups | Sort-Object Count -Descending)) { Write-Host ("{0} (重复 {1} 次)" -f $d.Path, $d.Count) } }

            Write-Host ""
            Write-Host ("=======发现不存在的路径 (共 {0} 个)======" -f $res.FoundMissingOnDisk.Count) -ForegroundColor Cyan
            if ($res.FoundMissingOnDisk.Count -eq 0) { Write-Host "（无）" -ForegroundColor DarkGray }
            else { $res.FoundMissingOnDisk | ForEach-Object { Write-Host $_ } }

            Write-Host ""
            Write-Host ("======发现硬编码路径 (共 {0} 个)======" -f $res.FoundHardcoded.Count) -ForegroundColor Cyan
            if ($res.FoundHardcoded.Count -eq 0) { Write-Host "（无）" -ForegroundColor DarkGray }
            else { $res.FoundHardcoded | ForEach-Object { Write-Host $_ } }

            Write-Host ""
            Write-Host ("======需要删除的路径 (共 {0} 个)======" -f $res.NeedDeleteDisplay.Count) -ForegroundColor Cyan
            if ($res.NeedDeleteDisplay.Count -eq 0) { Write-Host "（无）" -ForegroundColor DarkGray }
            else { $res.NeedDeleteDisplay | ForEach-Object { Write-Host $_ } }

            Write-Host ""
            $line = "======发现缺少需要添加的路径 (共 {0} 个)======" -f $res.NeedAdd.Count
            Write-Host $line -ForegroundColor Cyan
            if ($res.NeedAdd.Count -eq 0) { Write-Host "（无）" -ForegroundColor DarkGray }
            else { $res.NeedAdd | ForEach-Object { Write-Host $_ } }

            Write-Host ""
            Write-Host ("======将要覆盖写入的路径[路径预览] (共 {0} 个)======" -f $newItems.Count) -ForegroundColor Cyan
            $newItems | ForEach-Object { Write-Host $_ }

            Write-Host ""
            $confirm = Read-Host "是否保存（写入注册表）？（Y/N）"
            if ($confirm -notin @("Y","y")) { Pause-And-Return "已取消（未写入）。"; continue }

            $rawNew = ($newItems -join ";")

            $bk = Backup-MachinePath $rawOld
            Write-Host ("已创建写入前备份：{0}" -f $bk) -ForegroundColor Green

            Write-MachinePathRaw $rawNew
            Pause-And-Return "清理完成！建议注销或重启一次，让所有进程刷新 PATH。"
        }
        catch {
            Write-Host "清理系统 PATH 时遇到错误：" -ForegroundColor Red
            Show-ExceptionDetails $_
            Pause-And-Return
        }
        continue
    }
}

Write-Host "已退出。" -ForegroundColor Gray
