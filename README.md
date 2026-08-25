# ZRAMod

自定义 zram 压缩算法 / 大小 / `swappiness` / `watermark_scale_factor` 的 KernelSU 模块，**nomount**（不挂载 `system`，只装开机脚本 + WebUI），开机自动应用，也支持不重启直接热应用。

## 这个模块做了什么

原本每次开机都要进终端手动敲一串命令才能把 zram 调成自己想要的样子（算法、容量、swap 优先级、`swappiness`、`watermark_scale_factor`）。ZRAMod 把这套流程自动化、可视化了：

- **开机自动应用**：在 `post-fs-data` 阶段（Zygote 启动前）按你保存的配置重建 zram，`late_start service` 阶段会检查一次并在没生效时补偿重试一次，`boot-completed`（开机彻底完成后，再额外延迟一段可调的秒数，默认 20 秒）再单独补写一次 `swappiness`/`watermark_scale_factor`——因为部分设备/ROM 会在开机完成之后才把这两个 sysctl 覆盖回默认值，所以需要保证 ZRAMod 是最后写入的那个；这个延迟秒数可以在 WebUI 里调整（对应 `config.conf` 里的 `BOOT_SYSCTL_DELAY_SEC`）。
- **WebUI 可视化配置**：在 KernelSU 管理器里打开模块即可看到当前系统实际状态（算法、大小、swap 优先级、是否已启用、`swappiness`、`watermark_scale_factor`、物理内存），压缩算法下拉框来自**设备实时探测**（`/sys/block/zram0/comp_algorithm`），不是写死的列表，不同设备/内核支持的算法不同也能用。
- **不重启热应用**：点「保存并立即应用」直接生效，不用重启，方便反复试参数。
- **停用即还原**：首次生效前会快照当时的原始状态，「停用并恢复安装前状态」按钮可以把 zram 和相关 sysctl 恢复回模块接管前的样子；卸载模块时也会自动做同样的还原。
- **nomount**：模块目录里没有 `system/` 目录，也放了空的 `skip_mount` 文件，管理器不会挂载/覆盖任何系统文件，纯粹是"开机自动帮你敲命令 + 给你一个敲命令的界面"，不改系统本身。
- **未配置前不介入**：装完模块后如果还没在 WebUI 里保存过配置，开机脚本什么都不会做，不会用一套默认参数去动你的 zram。

## 已确认可用的设备

目前只在 **一加 13（OnePlus 13）+ ColorOS 16** 上验证过可以正常工作。

其他设备/内核大概率也能用（核心逻辑都是标准的 zram sysfs 操作），但以下几点在不同设备上可能有差异，遇到问题时优先检查：

- `swapon` 在模块脚本环境里可能解析到不支持 `-p` 优先级参数的 BusyBox 实现（已做兼容处理：优先尝试 `/system/bin/swapon`，失败再退化为不带优先级重试）。
- 部分 ROM 会在开机完成之后才把 `swappiness`/`watermark_scale_factor` 覆盖回默认值（一加 13 上实测大约在开机完成后 10 秒左右）。ZRAMod 会在 `boot-completed` 之后延迟一段时间再补写一次，默认延迟 20 秒，够用；如果你的设备上过一会儿又被覆盖回去了，说明覆盖发生得比这个延迟还晚，去 WebUI「开机后延迟补写…」那一项把秒数调大一些即可，不需要改代码。
- 支持的压缩算法列表因设备/内核而异，模块会现场探测，不需要手动改代码。

如果你在其他设备上装过、结果如何，欢迎反馈。

## 已知限制：post-fs-data.sh 理论上可能拖住开机

`post-fs-data.sh` 里的 `swapoff`/`reset`/`mkswap`/`swapon` 这几步会阻塞式地跑（这是刻意的，为了让 zram 在 Zygote 启动前就绪）。查过 KernelSU 源码（`userspace/ksud/src/init_event.rs` 的 `on_post_data_fs()`，源码里这一行前面就是 `// TODO: Add timeout`）确认：**KernelSU 目前对模块的 post-fs-data.sh 执行没有任何超时保护**，如果这几步里有一步真的卡进内核不可中断睡眠（极端内存压力下 `zram_reset_device()`/`zram_meta_alloc()` 理论上可以走到这种路径），整个开机流程会被拖住。

脚本里给 `swapoff`/`mkswap`/`swapon` 包了 `timeout`，但这层保护只能拦住"卡在用户态"的挂起（等锁、等资源），对内核不可中断睡眠无效——这是明确知道、接受下来的残余风险，不是没处理。之所以还是选择留在 `post-fs-data.sh` 而不挪到非阻塞的 `service.sh`，是因为这个场景（开机这一刻、系统内存就已经很紧张）概率很低，权衡下来更看重 zram 尽早就绪。如果之后实测中出现开机异常卡顿，这是第一个要怀疑的地方，可以考虑把 zram 重建部分挪到 `service.sh`。

除了选阶段和包 `timeout`，还有一层更直接的保护：`swapoff` 要把 zram 里已经压缩驻留的数据全部搬回真实内存才能返回，用量越大越慢、内存越紧张越可能真的堵住，这是实际拖慢/堵住 `swapoff` 的主因。所以重建前会先读 `/proc/swaps` 里 zram0 当前的已用量（KB），超过阈值（默认 1GiB，可在 `config.conf` 用 `SWAP_USAGE_SKIP_KB` 调整，或设成 `unlimited` 关闭这项检查）就直接跳过这次重建、保持现状不动，而不是硬着头皮上——这一条对开机自动应用、`service.sh` 补偿重试、WebUI 热应用是同一份逻辑，因为都走同一个 `do_rebuild`。跳过时不会假装成功：`status.conf` 里的结果会标成 `swap_usage_too_high`，WebUI 的"上次操作结果"和提交后的提示都会明确说明本次没有生效、以及为什么。如果一直触发（比如 `swappiness` 设得很激进、zram 常年占用很高），需要先关几个应用释放内存，或者调大这个阈值。

WebUI 里这一项有「限制（推荐）」/「不限制」两档。选「不限制」会关闭上面这项检查，直接尝试 `swapoff`，页面会同时显示当前 zram 的实时已用量和一段风险说明：用量大的时候 `swapoff` 可能卡住数秒；极端情况下（比如系统内存本身已经很紧张）会进入内核不可中断睡眠状态，**这时候连正常重启都无法完成，只能强制断电重启设备**——不是"大不了重启一下"能兜底的级别，选之前请确认自己知道这个风险。

## 使用方法

1. 用 KernelSU 管理器安装模块并重启。
2. 在管理器里打开 ZRAMod 的 WebUI，选好算法、容量大小、swap 优先级、`swappiness`、`watermark_scale_factor`。
3. 点「保存并立即应用」——立刻生效，同时会在下次开机时自动应用。
4. 想临时停用可以点「停用并恢复安装前状态」，或者直接卸载模块（卸载时也会自动还原）。
5. 出问题时点「查看日志」，或者直接看 `/data/adb/zramod/zramod.log`。

## 配置与日志存放位置

用户配置和运行日志都放在模块目录**之外**的 `/data/adb/zramod/`，模块升级不会丢配置：

- `/data/adb/zramod/config.conf` — 当前保存的配置
- `/data/adb/zramod/original.conf` — 模块首次接管前的原始状态快照（用于还原）
- `/data/adb/zramod/status.conf` — 最近一次应用/恢复操作的结果
- `/data/adb/zramod/zramod.log` — 运行日志
