# Path-Cleanup（Windows PATH 清理/恢复工具）

本仓库包含两个 PowerShell 脚本，用于清理与恢复 Windows 环境变量 PATH（系统/用户），并在写入前自动生成备份文件，降低误操作风险。

## 脚本列表

- `清理系统path_Pro_公开版.ps1`：面向系统 PATH（Machine）的清理与恢复（更精简）
- `清理系统path_Plus_公开版.ps1`：支持系统 PATH + 用户 PATH 的清理与恢复（功能更完整）

## 运行环境

- Windows
- PowerShell 5.1（脚本会自动尝试提权到管理员权限）

## 使用方式

请先使用git克隆此仓库到本地电脑或者下载压缩包解压到本地目录。
- 运行前先右键ps1和bat脚本打开属性取消类似于自动阻止的勾选并点击应用，因为Windows默认会阻止在网络上下载的脚本运行。

如果PS1已经关联了power shell推荐直接双击ps1脚本运行：

- `清理系统path_Plus_公开版.ps1`（需要时会弹出 UAC 请求管理员权限）
- `清理系统path_Pro_公开版.ps1`（需要时会弹出 UAC 请求管理员权限）

如果PS1没有关联到PowerShell 推荐直接双击运行 BAT 启动器（不依赖系统把 `.ps1` 默认关联到 PowerShell）：

- `run_plus.bat`：运行 `清理系统path_Plus_公开版.ps1`（需要时会弹出 UAC 请求管理员权限）
- `run_pro.bat`：运行 `清理系统path_Pro_公开版.ps1`（需要时会弹出 UAC 请求管理员权限）
- `set_ps1_default.bat`：尝试把 `.ps1` 的双击默认打开方式设置为 PowerShell（Win10/11 可能因为 UserChoice 保护而无法强制覆盖；脚本会输出检测结果与手动设置提示）

也可以在 PowerShell / Windows Terminal 中手动运行（建议以管理员身份启动终端）：
```powershell
cd "这里替换为脚本所在目录"
powershell.exe -ExecutionPolicy Bypass -File ".\清理系统path_Pro_公开版.ps1"
powershell.exe -ExecutionPolicy Bypass -File ".\清理系统path_Plus_公开版.ps1"
```

## 为什么 BAT 里是 Base64（-EncodedCommand）

`run_plus.bat` / `run_pro.bat` 使用了 PowerShell 的 `-EncodedCommand`，它本质是把要执行的 PowerShell 代码按 UTF-16LE 编码后再做 Base64 编码（是“编码”，不是“加密”）。

这样做的目的：

- 避免批处理里引号/百分号/转义过于复杂导致的运行失败
- 避免中文输出在不同系统代码页下出现乱码
- 方便把“提权逻辑 + 寻找脚本 + 执行脚本”的代码放在一行里分发

## 如何解码/审计 BAT 内的 PowerShell 代码

方式 1：手动复制 `-EncodedCommand` 后面的 Base64 字符串，然后在 PowerShell 执行：

```powershell
$b64 = '这里粘贴 Base64'
[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($b64))
```

方式 2：自动从 BAT 文件里提取并解码（以 `run_plus.bat` 为例）：

```powershell
$b64 = (Get-Content .\run_plus.bat -Raw) -replace '(?s).*?-EncodedCommand\\s+([A-Za-z0-9+/=]+).*','$1'
[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($b64))
```

如果你想自行修改并重新编码回去：

```powershell
$code = @'
这里放你修改后的 PowerShell 代码
'@
[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
```

## 手动把 .ps1 默认打开方式改成 Windows PowerShell（当脚本无法强制覆盖时）

有些 Win10/11 设备会把 `.ps1` 绑定到“记事本/打开方式”一类的默认应用，而且 `UserChoice` 有系统保护，脚本无法稳定强制覆盖。这时按下面步骤手动设置一次即可：

1. 右键任意 `.ps1` 文件 → 打开方式
2. 这个列表里一般不会直接显示 Windows PowerShell：往下滑 → 选择“在这台电脑上选择其他应用/选择在计算机上选择打开的方式”（类似字样）
3. 在弹窗里选择“更多应用”并滚动到底 → 选择“在这台电脑上查找其他应用/在计算机上选择应用”（类似字样）
4. 在文件选择窗口的地址栏输入路径并回车：`%SystemRoot%\System32\WindowsPowerShell\v1.0\`
5. 选择 `powershell.exe` → 打开
6. 勾选“始终使用此应用打开 .ps1 文件” → 确定/如果是Windows11没有“始终使用此应用打开 .ps1 文件”点击始终

## 功能概览

- 自动备份 PATH 到文本文件（默认保存到桌面，桌面不可用时会引导选择目录）
- 从备份文件恢复 PATH（提供文件选择窗口）
- 清理逻辑（按脚本内选项开启/关闭）：
  - 去重（重复路径合并）
  - 硬编码路径替换为环境变量形式（如 `C:\Windows` → `%SystemRoot%`）
  - 删除无效路径（不存在的目录）
  - 补齐必要系统项（仅系统 PATH）
  - 排序整理

## 风险提示与免责声明

- 本工具会读取并可能写入 Windows 环境变量 PATH：
  - 系统 PATH（Machine）：注册表 `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment` 的 `Path`
  - 用户 PATH（User）：注册表 `HKCU:\Environment` 的 `Path`（仅 Plus 版本在选择扫描用户 PATH 时会涉及）
- 请在运行前自行确认脚本内容与来源，非官方仓库下载的二创脚本请检查后再运行。
- 强烈建议在“重要工作前”不要修改 PATH：PATH 变更可能导致软件无法启动、命令行找不到程序、开发环境失效等。
- 脚本会在写入前尝试自动备份 PATH 到文本文件（备份文件后缀名为txt，默认保存到桌面，桌面不可用时会引导选择目录）：
  - 请确认备份文件已成功生成并可打开，检查备份文件与原文无误后再继续执行后续写入步骤
  - 建议至少保留备份文件 7 天，或直到你确认系统与常用软件运行正常
- 清理选项可能执行的行为（视你在菜单中选择而定）：
  - 去重/排序整理：可能改变 PATH 项的顺序；部分软件依赖顺序（例如同名可执行文件的优先级）
  - 删除不存在路径：若路径来自网络盘/可移动磁盘/按需挂载目录，可能在“暂时不可用”时被误判不存在
  - 硬编码替换为环境变量形式：用于增强可移植性，但可能影响某些依赖绝对路径的场景
  - 补齐系统必要项：仅针对系统 PATH，避免误删导致基础命令不可用
- 本工具不提供任何担保。你需要自行承担运行脚本及修改 PATH 可能带来的全部风险与后果。

## 许可证

本项目使用 GPL-3.0-only 开源。详情请查看仓库根目录的 `LICENSE` 文件或访问 [GNU 官方网站](https://www.gnu.org/licenses/gpl-3.0.html)。
GPL-3.0 的非官方中文翻译可参考 [jxself 译文](https://jxself.org/translations/gpl-3.zh.shtml)（非 FSF 官方发布，法律效力以英文原文为准）；其他语言版本见 [GNU 翻译页面](https://www.gnu.org/licenses/translations.html)。


