# Zramod

自定义 zram 压缩算法 / 大小 / `swappiness` / `watermark_scale_factor` 的 KernelSU 模块，**nomount**（不挂载 `system`，只装开机脚本 + WebUI），开机自动应用，也支持不重启直接热应用。

## 这个模块做了什么

原本每次开机都要进终端手动敲一串命令才能把 zram 调成自己想要的样子（算法、容量、swap 优先级、`swappiness`、`watermark_scale_factor`）。Zramod 把这套流程自动化、可视化了：

- **开机自动应用**：在 `post-fs-data` 阶段（Zygote 启动前）按你保存的配置重建 zram，`late_start service` 阶段会检查一次并在没生效时补偿重试一次，`boot-completed`（开机彻底完成后）再单独补写一次 `swappiness`/`watermark_scale_factor`——因为部分设备/ROM 会在更晚的开机阶段把这两个 sysctl 覆盖回默认值，所以需要保证 Zramod 是最后写入的那个。
- **WebUI 可视化配置**：在 KernelSU 管理器里打开模块即可看到当前系统实际状态（算法、大小、swap 优先级、是否已启用、`swappiness`、`watermark_scale_factor`、物理内存），压缩算法下拉框来自**设备实时探测**（`/sys/block/zram0/comp_algorithm`），不是写死的列表，不同设备/内核支持的算法不同也能用。
- **不重启热应用**：点「保存并立即应用」直接生效，不用重启，方便反复试参数。
- **停用即还原**：首次生效前会快照当时的原始状态，「停用并恢复安装前状态」按钮可以把 zram 和相关 sysctl 恢复回模块接管前的样子；卸载模块时也会自动做同样的还原。
- **nomount**：模块目录里没有 `system/` 目录，也放了空的 `skip_mount` 文件，管理器不会挂载/覆盖任何系统文件，纯粹是"开机自动帮你敲命令 + 给你一个敲命令的界面"，不改系统本身。
- **未配置前不介入**：装完模块后如果还没在 WebUI 里保存过配置，开机脚本什么都不会做，不会用一套默认参数去动你的 zram。
- 详细设计思路见仓库根目录的 [设计方案.md](../设计方案.md)。

## 已确认可用的设备

目前只在 **一加 13（OnePlus 13）+ ColorOS 16** 上验证过可以正常工作。

其他设备/内核大概率也能用（核心逻辑都是标准的 zram sysfs 操作），但以下几点在不同设备上可能有差异，遇到问题时优先检查：

- `swapon` 在模块脚本环境里可能解析到不支持 `-p` 优先级参数的 BusyBox 实现（已做兼容处理：优先尝试 `/system/bin/swapon`，失败再退化为不带优先级重试）。
- 部分 ROM 会在开机更晚的阶段把 `swappiness`/`watermark_scale_factor` 覆盖回默认值（已在 `boot-completed` 阶段补写一次，如果你的设备覆盖发生得更晚，可能还需要进一步调整）。
- 支持的压缩算法列表因设备/内核而异，模块会现场探测，不需要手动改代码。

如果你在其他设备上装过、结果如何，欢迎反馈。

## 使用方法

1. 用 KernelSU 管理器安装模块并重启。
2. 在管理器里打开 Zramod 的 WebUI，选好算法、容量大小、swap 优先级、`swappiness`、`watermark_scale_factor`。
3. 点「保存并立即应用」——立刻生效，同时会在下次开机时自动应用。
4. 想临时停用可以点「停用并恢复安装前状态」，或者直接卸载模块（卸载时也会自动还原）。
5. 出问题时点「查看日志」，或者直接看 `/data/adb/zramod/zramod.log`。

## 配置与日志存放位置

用户配置和运行日志都放在模块目录**之外**的 `/data/adb/zramod/`，模块升级不会丢配置：

- `/data/adb/zramod/config.conf` — 当前保存的配置
- `/data/adb/zramod/original.conf` — 模块首次接管前的原始状态快照（用于还原）
- `/data/adb/zramod/status.conf` — 最近一次应用/恢复操作的结果
- `/data/adb/zramod/zramod.log` — 运行日志
