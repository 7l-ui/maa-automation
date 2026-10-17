# MAA 定时自动刷任务（雷电模拟器版）

> **开源版说明**：路径已脱敏（示例为 `C:\MAA` / `C:\leidian\LDPlayer9`）；仓库内不含任何账号信息、MAA 配置、运行日志或截图。
> **许可证**：MIT（本仓库脚本与文档）。MAA 本体为 AGPL-3.0，本仓库未包含其源码。

到点自动完成：**拉起雷电模拟器 → MAA 自己启动明日方舟 → 跑任务链 → 跑完自动关掉模拟器**，并且你随时可以手动停止本次。

两条路线都做过**真实端到端验证**（详见文末）。当前启用的是**模拟器路线**。

---

## 一、架构

```
登录 Windows
 ├─ 计划任务 MAA-Autostart（最高权限、静默无 UAC）
 │    └─ MAA 常驻托盘，RunDirectly=false（手动开它不会自动跑）
 │         ├─ 定时执行（MAA 内置）：01:00 / 09:00（在 MAA 界面里随时改）
 │         ├─ 到点 → 开始前脚本 ensure-emulator.ps1 → 模拟器没开就启动并等 Android 启动完成
 │         ├─ 到点 → 任务链（开始唤醒 → 理智作战·剿灭 → 理智作战·刷土 → 基建换班 → 自动公招 → 信用收支 → 领取奖励）
 │         │        └─「开始唤醒」由 MAA 自己用 ADB 启动游戏（PC 端做不到这点）
 │         └─ 跑完 → 结束后操作「退出 模拟器」（MAA 原生）→ 释放约 3 GB
 └─ 计划任务 MAA-Refresh（最高权限）：每 5 分钟巡检一次
      └─ refresh-maa.ps1 → ① 预跑窗口（00:25-00:40 / 08:25-08:40）刷新 MAA 与资源；
         ② 跑批中途卡死（任务未结束且日志静默 > 15 分钟）→ 换掉僵死模拟器 + 重启 MAA；
         ③ 其余时间什么都不做
```

> 关于时间点：`01:00` 在游戏每日 `04:00` 刷新**之前**，那一次的价值主要是消耗理智（避免一夜溢出到上限）；当天的日常（基建换班 / 自动公招 / 信用收支 / 领取奖励）由 `09:00` 那次负责。

### 为什么 MAA 仍需提权

PC 端需要提权（`MAA.dll` 原文：`PC 端连接需要管理员权限`）。模拟器虽然用 ADB、本身不需要提权，但**提权是唯一在两种情况下都成立的选择**：

| 场景 | 非提权 MAA | 提权 MAA |
|---|---|---|
| 模拟器被 MAA 拉起（提权） | ❌ 关闭失败（实测 `EmulatorHelper 拒绝访问`） | ✅ 成功（实测） |
| 模拟器由你点快捷方式拉起（非提权） | ✅ | ✅ |

完整性级别是**单向**的：高的能操作低的，反之不行。所以让 MAA 保持提权，两种情况都能正常收尾。

### 为什么仍然需要「开始前脚本」

实测：模拟器完全关闭时，定时到点后 MAA 只报 `正在尝试启动模拟器`，重试 ADB 连接约 5 次、14 秒后放弃（`连接失败`）。它的日志里 `"pid":-1` —— MAA 是在找**已在运行**的模拟器进程去重启，冷启动不归它管，而 `StartEmulator` 选项的说明是「启动 MAA 后自动开启模拟器」。所以冷启动必须由钩子完成。**这一点和 PC 端是同一个性质的缺口。**

**这个结论做过两次独立实验**（路径字段 `StartUpSettings.EmulatorPath` 与 `ConnectSettings.Extras.LDPlayer.EmulatorPath` 都确认已正确设置，`StartEmulator` 与 `RestartEmulatorWhenAdbFailed` 均为 true）：

| 实验 | 条件 | 结果 |
|---|---|---|
| A | 模拟器关着，MAA 启动（`StartEmulator=true`） | ❌ 全程未创建雷电进程 |
| B | 模拟器关着，定时到点（`RestartEmulatorWhenAdbFailed=true`） | ❌ 14 秒后 `连接失败`，未创建雷电进程 |
| C | 实验 B 的基础上**勾选「强制定时启动」** | ❌ 完全一样，14 秒后失败 |

也就是说：**MAA 在这套配置下不会冷启动模拟器，勾「强制定时启动」也没有任何帮助**（上游也有同名 issue：`定时任务无法开启模拟器 · Issue #1369`）。

### 「强制定时启动」到底是什么

它和启动模拟器**无关**。从 MAA 的界面元素看，它管的是「到点时 MAA 正忙怎么办」，配套选项是 `停止当前任务` / `重启游戏并开始新任务` / `强制定时启动前显示窗口`（后者用于「避免最小化时看不到倒计时」）。

我们的场景里到点时 MAA 一定是空闲的（它常驻不动，只等定时器），所以**不需要勾**，保持 `false`。

> 「自定义配置选择」同理不需要：它用于到点切换到另一套任务配置，而你只有 `Default` 一套。

### 剿灭 + 刷土：为什么是「两个理智作战任务」

需求是「**每周打满剿灭（周上限 1800 合成玉），剩余理智全刷 1-7**」。官方文档给的做法就是**两个理智作战任务**：

> 剿灭属于常驻关卡：若在关卡选择 / 备选关卡中被选中，**其后的备选关卡不会继续识别执行**。
> 若希望先打剿灭，**可单独再添加一个理智作战任务**，关卡只选剿灭，并把它拖到现有理智作战任务上方。
> —— [MAA 文档 · 理智作战](https://docs.maa.plus/zh-cn/manual/introduction/combat.html)

所以任务队列（顺序即优先级）：

```
StartUp → Fight[关卡=剿灭·龙门外环] → Fight[关卡=1-7] → 基建换班 → 自动公招 → 信用收支 → 领取奖励
```

两条都是原生行为（文档 + 实测双确认）：

| 情况 | 表现 |
|---|---|
| 本周剿灭**没满** | 先打剿灭（用「全权委托/扫荡」，一次约 25 理智），到 `1800 / 1800` 后**自动停**。实测 01:04→01:06 打满 6 次、约 1.5 分钟 |
| 本周剿灭**已满** | 导航时找不到剿灭入口 → **任务直接结束，不算失败**（秒退），紧接着执行下面那条 1-7 |
| 周上限重置 | 每周一 `04:00` 之后第一次运行自动打满，无需人工干预 |

> 两条 `Fight` 都**不勾「周计划」**，即每天都会顺手检查一次剿灭：没满就打满，满了就秒退。这样周一那次万一失败，周二还能补上（官方建议的「周计划只勾周一」更省几秒，但漏一次就整周没有剿灭）。

**走过的弯路（都已排除，别再试）**：

| 想法 | 为什么不行 |
|---|---|
| 一条任务里放「备选关卡 = 剿灭 + 1-7」，指望打完剿灭接着刷土 | 「备选关卡」是**按当天开放情况的日程表**，既不是失败回退也不是接力；且剿灭是常驻关卡，会**吃掉它后面所有候选**（日志原文：`当前选中的关卡 ｢剿灭模式｣ 为常驻关卡或当前/上次，其后的关卡不会被选中执行`） |
| 用「剩余理智」把剩余理智导向 1-7 | 上游 `ref/FightTask.cs` 里**没有任何剩余理智字段**（已下载源码逐字段核对），这条路不存在 |
| 用「指定次数」限死每周剿灭次数 | `EnableTimesLimit` 是**每次执行**的上限，不是每周计数；剿灭本来就自带周上限自动停，不需要它 |

### 自动更新：MAA 自己会更新，但要有人「跑前重启」它

关键事实：**MAA 只在启动时（以及游戏换日的两个时间点）检查更新**。它常驻不动，所以光开开关不够，必须定期把它重启一次。现在是四层配合：

| 层 | 设置 / 机制 | 状态与作用 |
|---|---|---|
| MAA · 启动时检查更新 `CheckOnStartup` | 配置项 | 已开。每次启动拉 `api/version/summary.json`、资源热更 `resource/tasks.json`、**活动数据 `gui/StageActivityV2.json`** |
| MAA · 定时检查更新 `CheckOnSchedule` | 配置项 | **本次新开**。MAA 界面原话：`游戏内 00:00 / 18:00（对应服务器当地时间 04:00 / 22:00）`——正好是游戏换日活动的时间点 |
| MAA · 自动下载 / **自动安装**更新包 | `AutoDownloadUpdatePackage` / `AutoInstallUpdatePackage` | 下载原本就开，**自动安装本次新开**：有新版就自己下、自己装（走 `MAA.Updater.exe`） |
| MAA · **资源**更新 | 没有自动开关 | MAA 只*检测*并提示「请前往 设置-更新设置-资源更新 手动更新，或配置 Mirror酱 CDK 以自动更新」→ 改由 `refresh-maa.ps1` 代劳，见下一节 |
| 计划任务 `MAA-Refresh` + `refresh-maa.ps1` | **每 5 分钟**巡检 | **新增**。① 预跑窗口（00:25-00:40 / 08:25-08:40）刷新 MAA 与资源；② 跑批中途卡死时自动换掉模拟器 + 重启 MAA（见下一节）。全程通过 `wscript` 无窗口运行，桌面上不会闪脚本窗口 |

> 另外把 `MinimizeOnStartup` 打开了：预跑刷新时的重启不再弹窗打扰你。

**为什么刷新任务必须提权（`RunLevel=Highest`）**：MAA 自动安装更新是**由更新器重启自己**，重启后的 MAA **不再属于 `MAA-Autostart` 任务**（实测：`MAA-Autostart` 显示 `Ready` 而 MAA 进程还在）。此时 `Stop-ScheduledTask` 管不到它，普通权限 `Stop-Process` 直接 `Access is denied`。所以 `refresh-maa.ps1` 走两条路：先 `Stop-ScheduledTask`，杀不掉再提权强杀；`register-maa-refresh.ps1` 因此需要一次性 UAC。

**实测（2026-09-27 23:19，就是上面那个「孤儿 MAA」场景）**：

```
23:19:41 [refresh-maa] start: elevated=True force=False task=MAA-Autostart
23:19:41 [refresh-maa] MAA log idle for 6.5 min; refreshing MAA.
23:20:01 [refresh-maa] MAA still alive (likely restarted by its own updater, so outside the task); killing the process.
23:20:01 [refresh-maa] MAA killed.
23:20:04 [refresh-maa] MAA started again; it will re-check program and resource updates on startup.
23:20:19 HTTP: NotModified GET .../api/version/summary.json                    <- 版本检查
23:20:19 [ResourceUpdater] current resource latest version is 2026-09-24 08:39:16.000
```

**它解决了哪三个真实故障**（2026-09-24 ~ 09-27）：

| 现象 | 根因 | 现在 |
|---|---|---|
| 9/24、9/27 的 **09:00 整条链报错**（`任务出错: 开始唤醒`），而当天 01:00 正常 | 游戏 `04:00` 换日后出现**新活动弹窗**，旧版 MAA / 旧资源不认识它、叉不掉，后面任务全错。当时跑的是 v6.17.5（9/10 构建），而 v6.18.0 早在 9/24 05:18 就发布了 | 跑前重启会加载新版 MAA + 最新资源与活动数据；新弹窗模板随资源下发 |
| 9/25 01:05 之后**卡死 8 小时以上**，09:00 定时器没触发；9/26 01:00 同样整段缺失 | MAA 卡在任务里、进程一直"忙"，后续定时槽全部作废（MAA 自己每 30 分钟报 `任务日志输出已超过 25 分钟无更新…可能需要手动干预`） | 每次跑前 30 分钟重启，卡死状态不会带到下一跑 |
| 你手动点「检查更新」才发现落后两个版本 | MAA 只在启动时检查，而它常驻不重启 | 每天两次自动检查 + 自动安装 |

### 资源更新：MAA 只提示、不自动装，所以脚本代劳

MAA 对**资源**的处理是**只检测**：启动或定时检查时发现新资源，它只会弹一句提示，然后等你手动点（或用付费的 Mirror酱 CDK）。而资源包里装的正是**新活动弹窗 / 新关卡的识别模板** —— 也就是"游戏更新后 MAA 突然不认界面"的直接原因。所以 `refresh-maa.ps1` 在预跑窗口里自己干（用 MAA 官方同款包）：

| 步骤 | 细节 |
|---|---|
| 比对版本 | 拉 `MaaResource/main/resource/version.json`，与本机 `resource/version.json` 的 `last_updated` 做序数比较（零填充格式，字符串比较即精确） |
| 下载 | `codeload.github.com/.../MaaResource/zip/refs/heads/main`（实测 13.45 MB、5291 个文件、解压 99 MB、约 26 秒） |
| 覆盖 | 解压到临时目录 → `Copy-Item -Recurse -Force` **合并**到本地 `resource/`（本地多出的 `onnx/ PaddleOCR/ minitouch/` 等安装包自带内容原样保留）。全程在 **MAA 停止状态**下进行 |
| 收尾 | 删临时文件 → 启动 MAA（它启动时才加载资源） |

**实测（2026-10-01 01:44，本地资源落后 6 天）**：

```
01:44:31 resource version: local='2026-09-24 08:39:16.000' remote='2026-09-30 13:33:44.000'
01:44:54 downloaded 13.4 MB
01:44:59 resources updated: 2026-09-24 08:39:16.000 -> 2026-09-30 13:33:44.000
01:45:00 MAA started again
```

生效验证：MAA 窗口标题从 `逐影集趣#0924` 变成 **`矢量突破#3 拟生态#0930`**，启动日志 `AsstLoadResource ret: true`，且不再出现 `New version found`。

> 这个覆盖是**合并**而不是清空，所以万一下载中断，最坏是资源新旧混杂；MAA 自己的 `设置-更新设置-资源更新` 按钮随时可以再手动修一次。

### 跑批中途卡死怎么办（2026-10-01 的真实故障与自愈）

**现象**：01:00 那一跑走到 `开始行动 1~10 次`（01:03:35）后**彻底没声音**，MAA 每 30 分钟报一次 `任务日志输出已超过 25 分钟无更新…可能需要手动干预`，它自己不会恢复；而且进程一直"忙"，09:00 的定时器也不会触发。

**根因**（实测）：

| 探测 | 结果 |
|---|---|
| `adb get-state` | `device` ✅ |
| `adb shell pidof …` / `screencap` | **20 秒无响应 / `device offline`** ❌ |
| 模拟器进程内存 | dnplayer 40 MB、Ld9BoxHeadless 35 MB —— 几乎全被换出到页面文件 |

当时物理内存 15.63 GB、**可用仅 0.82 GB**，提交 32 GB，占用前列：`ChatGPT 3.2 GB + QQ 2.3 GB + dwm 1.6 GB + Edge/WebView 2.5 GB + 模拟器 1.3 GB + MAA 1.1 GB`。内存挤压 → 模拟器的**游戏渲染进程被换出冻结** → MAA 截图永远等不到结果。注意 `getprop` 这类小进程可能仍能应答，**判据不能只看 ADB 有没有反应**。

**自愈机制**（`refresh-maa.ps1`，每 5 分钟跑一次）：

1. 判定"卡死" = **任务已开始但未结束**（日志里 `Start Task Chain:` 之后没有 `Completed Task Chain:`）**且**最后一条非 `[WRN]` 日志静默超过 10 分钟。
   > 为什么排除 `[WRN]`：MAA 卡住时自己每 30 分钟打一条停滞警告，会把"日志多久没动"骗过去 —— 第一版就踩了这个坑（实测 `logIdle=8.1min`，于是放过了卡死）。
   > 另外判据只用 ASCII 锚点（`Start/Completed Task Chain:`）：无 BOM 的 `.ps1` 在 PowerShell 5.1 里按 GBK 读取，写中文正则会变乱码导致永不匹配。
2. 命中后：**杀掉模拟器**（游戏渲染僵死时 `getprop` 仍可能应答，所以卡死一律换新的）→ 结束并重启 MAA。
3. **还要看 MAA 进程活不活**（2026-10-12 补上）。以前只判断"日志闲不闲"，于是 10/12 08:40 MAA 启动后 2 秒崩溃（任务退出码 `0xC0000005` 访问违例）时，看门狗整整 7.5 小时都在说"空闲，无事可做"，那天的 09:00 跑批直接消失。现在：进程不在 → 直接拉起；拉起后还要做**健康自检**（要求日志出现 `Timer wait time` / `Init: false to true`），不健康就拆掉重试一次。
4. **画面冻结的秒级识别**（2026-10-12 补上）。游戏本体被换出冻死时，ADB 照样应答、MAA 照样截图（实测 `ScreencapCost avg 6ms`）、日志也一直在写 —— 所以上面所有判据都不会响。真正的信号在**核心日志** `debug/asst.log` 里：`"cur_retry":N` 会一路爬到 `retry_times`(20)。现在尾部出现 `cur_retry >= 15` 就判定"画面不推进"，直接换模拟器 + 重启 MAA。
   > 实锤证据：10/12 01:06:06 与 01:07:04 两张失败截图 **sha256 完全相同** —— 游戏在 1-7 载入画面整整 58 秒一个像素都没变；MAA 的 20 次重试全部落空，于是基建换班 / 公招 / 信用收支 / 领取奖励四连错。
5. 实测输出（2026-10-01 01:40）：

```
01:40:02 [refresh-maa] acting: wedged task: still marked running but the log has been silent for 36 min
01:40:02 [refresh-maa] killing the emulator so the next run boots a fresh instance through ensure-emulator.ps1.
01:40:07 [refresh-maa] killed Ld9BoxSVC (PID 32880)
01:40:09 [refresh-maa] MAA stopped cleanly.
01:40:09 [refresh-maa] MAA is running again.
模拟器进程 0 个，可用内存 0.82 GB -> 3.51 GB
```

6. **模拟器本体死亡检测**（2026-10-12 补上）：跑批进行中如果 `dnplayer` / `Ld9BoxHeadless` 进程消失（VM 崩了，只剩 `Ld9BoxSVC` 服务），MAA 会一直对着死掉的 ADB 目标重试。判据 = "任务进行中 + 日志静默 > 3 分钟 + VM 进程不在"，命中后重启 MAA 并自动补跑。实测 18:05 完整走通：检测 → 重启 MAA → 健康自检 → 补跑 → 钩子冷启动新模拟器。
7. **冻结判据必须用截图确认**（2026-10-12 踩坑修正）：只看 `cur_retry` 会误杀 —— 基建换班的「会客室」本来就会把重试打满 20 次（实测因此误杀了一次**正常**的基建换班）。现在改成：重试 ≥ 18 后**再抓两张截图比对 SHA256**，只有完全相同才判定"画面冻死"（这也正是 10/12 那次失败的铁证：两张失败截图 sha256 相同）。
死进程恢复的实测（2026-10-12 16:10，先手动停掉 MAA 再触发）：

```
16:10:24 [refresh-maa] start: ... maaRunning=False logIdle=0.1min
16:10:24 [refresh-maa] acting: MAA is not running (crashed or was closed); starting it
16:10:29 [refresh-maa] MAA started (attempt 1); it will re-check program and resource updates on startup.
16:10:50 [refresh-maa] MAA is up and healthy (attempt 1).
```

> **恢复之后会自动补跑一次**（2026-10-12 新增）：脚本用 MAA 的全局热键 `Ctrl+Shift+Alt+L` 直接起一次新跑批；每个跑批只补一次（状态记在 `refresh-state.json`，避免无限重试）。同一机制也覆盖"跑完了但带着任务错误"的情况 —— 检测到 `[ERR][TaskQueueViewModel]` 且该跑批已结束，就补跑一次。
>
> 手动补跑：在 `C:\MAA\scripts\` 下建一个空文件 `start-run.flag`，再 `Start-ScheduledTask -TaskName MAA-Refresh` 即可。
>
> ⚠️ `Ctrl+Shift+Alt+L` 是**开关**：跑批进行中按它会**停掉当前跑批**（2026-10-12 实测踩到，一次验证跑因此被中断）。所以补跑逻辑里有硬保护：只有 MAA 空闲时才按热键；`Start Task Chain: StartUp` 之后出现 `Idle: false to true` 才算回到空闲。
>
> **有一种情况补跑也救不了**：游戏客户端自身更新完成后，启动器会停在「下载完毕，请前往安装」等你点一下（10/10 两次 `开始唤醒` 失败就是这个，失败截图存在 `debug/interface/`）。这只能人工点一次。
>
> 这个 5 分钟节奏是脚本自己加上去的（提权运行时检测到没有重复触发器就补一个），不需要再授权。
>
> 同理，任务动作也被脚本自动换成了 `wscript.exe //B run-hidden.vbs`：直接用 `powershell.exe` 时 Windows 每次都会闪一下控制台窗口（`-WindowStyle Hidden` 挡不住"创建瞬间"那一下），换成 GUI 子系统的 wscript 并让 `WshShell.Run` 用隐藏窗口启动，**桌面上就完全不会出现窗口了**；提权也不受影响（实测日志里仍是 `elevated=True`）。

**降低复发概率的两件事**（按需选）：

| 做法 | 效果 |
|---|---|
| 雷电实例内存 4096 → 3072、CPU 8 → 4 | 少约 1 GB 提交 + 减少 CPU 争抢（2026-10-12 已改） |
| 跑批时段（01:00 / 09:00）少挂 `clash-verge` / QQ / ChatGPT / chrome | 2026-10-12 实测它们合计约 9.4 GB（其中 `clash-verge` 单项 3.67 GB，疑似内存泄漏，重启它即可回落） |

---

## 二、文件清单

| 路径 | 作用 |
|---|---|
| `C:\MAA\scripts\ensure-emulator.ps1` | **当前启用**。开始前脚本：模拟器没开就启动 `dnplayer.exe`，轮询 `sys.boot_completed` 直到 Android 启动完成 |
| `apply-maa-emulator.ps1`（本工作区） | 切到模拟器路线：连接设置 / 启动模拟器 / 结束后操作 / 脚本钩子 / 时间槽 / 任务列表，可重复运行 |
| `C:\MAA\scripts\maa-hooks.log` | 钩子日志（排查首选） |
| `C:\MAA\debug\gui.log` | MAA 主日志 |
| `C:\MAA\scripts\register-maa-autostart.ps1` | 注册/刷新登录自启任务（**需提权**） |
| `C:\MAA\scripts\cleanup-leftovers.ps1` | 强制清理（提权结束 MAA/游戏/模拟器） |
| **PC 端路线（备用，当前未使用）** | `ensure-game.ps1`、`close-game.ps1`、`apply-maa-schedule.ps1` |
| `ref/FightTask.cs`、`ref/FightSettingsUserControlModel.cs` | MAA 官方源码（`dev` 分支）本地留档：理智作战到底有哪些字段 |
| `ref/TaskQueueViewModel.cs`、`ref/AsstProxy.cs` | MAA 官方源码：收尾逻辑（`Post actions` / `CheckAfterCompleted`）在这里 |
| `C:\MAA\scripts\refresh-maa.ps1` | **当前启用**（计划任务 `MAA-Refresh`，每 10 分钟）：预跑刷新（版本 + 资源）、卡死自愈、模拟器僵死检测，并自动维护自己的触发节奏与无窗口启动方式 |
| `C:\MAA\scripts\run-hidden.vbs` | `MAA-Refresh` 的实际入口：以隐藏窗口启动 `refresh-maa.ps1`，桌面不闪窗 |
| `C:\MAA\scripts\register-maa-refresh.ps1` | 一次性提权注册 `MAA-Refresh`（最高权限、Owner 为当前用户），已执行 |

所有 `.ps1` 一律**保持纯 ASCII**（注释和日志也用英文）：Windows PowerShell 5.1 会用系统 ANSI 代码页（本机 GBK）读取无 BOM 的 `.ps1`，源码里的中文会变乱码。本项目的脚本已全部校验为 0 个非 ASCII 字节。

---

## 三、日常操作

**改时间（你要的面板）**：MAA → 设置 → 定时执行。8 个槽，填「时:分」勾选，立即生效。

**手动启动一次**：MAA 窗口点「开始」，或全局热键 `Ctrl+Shift+Alt+L`。

**手动停止本次**：MAA 窗口点「停止」，或 `Ctrl+Shift+Alt+M` 呼出窗口。
> 注意：`PostActions`（退出模拟器）**不会**在手动停止时触发，所以手动停止会留下模拟器在跑。想让它也关掉，就得挂一个 PostRunScript。

**启停 MAA（免提权，走计划任务）**：
```powershell
Start-ScheduledTask -TaskName MAA-Autostart    # 启动 / 恢复常驻
Stop-ScheduledTask  -TaskName MAA-Autostart    # 停止
```
> 计划任务的动作就是 `MAA.exe` 本身，所以 Task Scheduler 能直接结束这个管理员进程 —— 这是唯一免 UAC 关掉管理员 MAA 的办法。

**改配置**（先停 MAA，否则 MAA 退出时会覆盖）：
```powershell
Stop-ScheduledTask -TaskName MAA-Autostart
& 'apply-maa-emulator.ps1' -Times '05:00','17:00' -Tasks 'StartUp','Fight','Infrast','Recruit','Mall','Award'
& 'apply-maa-emulator.ps1' -KeepTimers      # 只重设连接/钩子/结束动作，不动时间点
Start-ScheduledTask -TaskName MAA-Autostart
```

---

## 四、排查

```powershell
Get-Content 'C:\MAA\scripts\maa-hooks.log' -Tail 20   # 模拟器有没有被拉起 / 看 [refresh-maa] 行
Get-Content 'C:\MAA\debug\gui.log' -Tail 60           # 连接/任务链走到哪
Get-Process | Where-Object Name -match 'dnplayer|Ld9Box'       # 模拟器是否在跑
$c = Get-Content 'C:\MAA\config\gui.new.json' -Raw -Encoding UTF8 | ConvertFrom-Json
$c.Timers.List | Where-Object IsEnabled | Format-Table Id,Hour,Minute
```

**跑完模拟器没自动关？** 查日志有没有 `全部任务完成` 和 `Post actions: 退出 模拟器` 这两行。若只有任务完成、没有这两行，说明 MAA 的收尾分支没进去（2026-09-24 凌晨那次就是这样，当时配置里塞了 2 个候选关卡在结尾反复刷新 `StagePlan`）。此时手动关掉模拟器窗口即可，不影响下次：到点时 `ensure-emulator.ps1` 会把残留进程清掉再冷启动（这条路径 09-24 已验证）。

**整套停用**：MAA → 设置 → 定时执行 → 取消所有槽。
**卸载自启**：`Unregister-ScheduledTask -TaskName 'MAA-Autostart' -Confirm:$false`（需提权）。
**恢复配置**：`C:\MAA\config\` 下有历次 `gui.new.json.bak-*`，复制回去即可。

**切回 PC 端**：
```powershell
Stop-ScheduledTask -TaskName MAA-Autostart
& 'apply-maa-schedule.ps1' -Times '04:30','12:30','20:30' -Tasks 'StartUp','Fight','Infrast','Recruit','Mall','Award'
Start-ScheduledTask -TaskName MAA-Autostart
```

---

## 五、两条路线的实测对比

| | PC 端 | 雷电模拟器（当前） |
|---|---|---|
| MAA 启动游戏 | ❌ 做不到，`MAA.dll` 无 `Arknights.exe`/`Hypergryph` | ✅ ADB 原生启动（实测 `开始唤醒` 完成） |
| 需要「开始前脚本」 | ✅ 需要 | ✅ 需要（冷启动缺口同上） |
| 需要「结束后脚本」 | ✅ 需要 | ❌ 不需要，原生 `PostActions=ExitEmulator` 生效 |
| 需要提权 | ✅ | ✅（唯一两种场景都成立的档位） |
| 连接耗时 | 附加窗口约 1 秒 | ADB 约 5–6 秒 |
| 内存（含游戏） | 游戏私有约 2.26 GB | 模拟器私有约 1.77 GB |
| 掉落物识别上报 | ❌ 日志实测：`PC 端鼠标为独立渲染…已自动跳过本次上报` | ✅ 无此限制 |
| 自定义部件数 | 3（2 脚本 + 计划任务） | 2（1 脚本 + 计划任务） |

结论：模拟器**少一个脚本、多一项原生能力（启动游戏）、识别更完整**；内存并不比 PC 端更重（这点我先前判断错了，已按实测更正）。

---

## 六、已踩过的坑（都已规避）

| 坑 | 现象 | 处理 |
|---|---|---|
| 只启用「开始唤醒」一个任务 | MAA 启动后自动把它也关掉（判定为"只登录没意义"），结果什么都不跑 | 保持 6 个任务启用；应用脚本在这种参数下会告警 |
| 非提权 MAA + 提权模拟器 | 收尾报 `EmulatorHelper 拒绝访问` → `模拟器关闭失败` | 让 MAA 保持提权 |
| MAA 冷启动模拟器 | 只报 `正在尝试启动模拟器`，13 秒后 `连接失败`，模拟器根本没起来 | 由 `ensure-emulator.ps1` 负责冷启动 |
| `dnconsole.exe` / `com.hypergryph.arknights_ld.exe` | 报 `requires elevation` | 不依赖它们；用 `dnplayer.exe`（`asInvoker`）和 `adb` |
| 管理员 MAA / 计划任务 | 普通会话 `Stop-Process` 报 `Access is denied` | 用 `Stop-ScheduledTask` |
| 无 BOM 的 `.ps1` 里有中文 | 5.1 按 GBK 读，源码乱码 | 脚本一律纯 ASCII |
| `[ERR][AutoStart] Failed to set startup` | 每次启动 MAA 都报一行 | 无害：提权模式下 MAA 试图清除自己的注册表自启项，而该项不存在。忽略即可 |
| MAA 自动更新后「脱离」计划任务 | `MAA-Autostart` 显示 `Ready`，但 MAA 进程还在（更新器重启的，不是任务的子进程）；此时 `Stop-ScheduledTask` 停不掉、普通权限 `Stop-Process` 报 `Access is denied` | `refresh-maa.ps1` 先试计划任务、再提权强杀；`MAA-Refresh` 以最高权限运行 |
| MAA 卡在一个任务里 | 后续定时槽全部不触发（日志每 30 分钟报一次 `任务日志输出已超过 25 分钟无更新`） | 每次跑前 30 分钟的 `MAA-Refresh` 会把它重启掉 |

---

## 七、雷电实例设置：已改好

原先实例是 **120 FPS + 6 核 + 2560×1440 @320dpi + 4 GB**，MAA 每次跑都警告插帧可能导致识别不稳定。已改为：

| 项 | 原值 | 现值 | 说明 |
|---|---|---|---|
| `basicSettings.heightFrameRate` | `true` | **`false`** | **真正的元凶**。这是雷电的「高帧率模式」，会盖过 `fps` 的值 |
| `basicSettings.fps` | 120 | **60** | 游戏原生上限 |
| `advancedSettings.resolution` | 2560×1440 | **1920×1080** | MAA 推荐值，仍是 16:9 |
| `advancedSettings.resolutionDpi` | 320 | **240** | 1080p 的标准搭配 |
| `advancedSettings.cpuCount` | 6 | 6（未改） | 想更省可以降到 4 |
| `advancedSettings.memorySize` | 4096 | 4096（未改） | 实测实际占用约 1.77 GB；想更省可降到 2048 |

**踩坑记录**：只改 `fps: 60` **没用**，MAA 依旧报 120 —— 因为它查的是模拟器**实际刷新率**，不是配置文件里的值。必须同时关掉 `heightFrameRate`。改完用 ADB 验证：

```
DisplayDeviceInfo{"内置屏幕", 1920 x 1080, ..., fps=60.000004}
PhysicalDisplayInfo{1920 x 1080, 60.000004 fps, density 1.5, 240.0 x 240.0 dpi}
SurfaceFlinger: present offset 0 ns (refresh 16666666 ns)   ← 正好 1/60 秒
```

改完后再跑一次任务链，`检测到模拟器设置帧率为 120 FPS` 这行警告彻底消失。

> 改的是 `C:\leidian\LDPlayer9\vms\config\leidian0.config`，原文件已备份为同目录下的
> `leidian0.config.bak-*`。**改这个文件必须在模拟器关闭时进行**，且雷电启动时会重写该文件（本次改动被正确保留）。

---

## 八、验证记录（2026-09-17 凌晨，均为真实端到端）

### 模拟器路线（当前启用）

| 时间 | 日志 | 结论 |
|---|---|---|
| 03:04:23 | `Scheduled start: Timer Index: 0` | 定时器触发（模拟器关着、MAA 提权常驻） |
| 03:04:24 | `[ensure-emulator] started dnplayer.exe` | 钩子把模拟器拉起来 |
| 03:04:53 | `ADB device is up; waiting for Android boot` | 等 guest 启动完成 |
| 03:05:01 | `emulator booted and ready` → `完成任务: 开始前脚本` | 钩子阻塞到就绪才交棒 |
| 03:05:01 → 03:05:07 | `正在连接模拟器` → `开始唤醒` | ADB 连接 6 秒 |
| 03:05:07 → 03:07:02 | `开始唤醒` 完成 | **MAA 自己用 ADB 启动了游戏** |
| 03:07:04 → 03:07:09 | `领取奖励` 完成 | 任务链正常 |
| 03:07:10 → 03:07:14 | `Post actions: 退出 模拟器` → 进程归零 | **原生收尾生效** |
| — | MAA 仍在托盘；可用内存 0.37 → 3.23 GB | 常驻待命 |

另有两轮前置实测：模拟器开着时定时跑通（连接 6 秒）；非提权 MAA 同样能连上（证明 ADB 不需要提权），但**关不掉提权模拟器** —— 由此确定 MAA 必须保持提权。

**03:24 / 03:31 两轮复测**（改完雷电设置后）：定时器 → `[ensure-emulator] started dnplayer.exe` → `emulator booted and ready` → 连接 5 秒 → 开始唤醒 → 领取奖励 → `Post actions: 退出 模拟器` → 进程归零；可用内存回到 3.31 GB。其中 03:31 那轮日志里**不再出现帧率警告**。

**冷启动实验**（03:16 / 03:19）：另有三次独立实验专门验证「MAA 能否自己启动模拟器」，均失败，详见第一节的表格。

### PC 端路线（备用，已验证）

`01:38:23` 定时器触发 → `[ensure-game] started Arknights.exe` → `game window ready` → 开始唤醒完成 → 领取奖励完成 → `开始任务: 结束后脚本` → `[close-game] game closed.`（游戏进程归零）→ MAA 仍在托盘；可用内存 0.2 → 1.13 GB。

> 早期还有一次非管理员干跑，暴露了 PC 端的权限问题：MAA 卡在 `正在连接模拟器……`，随后弹窗要求 `RestartAsAdmin`。这正是「必须用最高权限计划任务」的直接证据。
