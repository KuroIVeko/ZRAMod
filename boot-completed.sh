#!/system/bin/sh
MODDIR=${0%/*}
DATADIR=/data/adb/zramod
CONF="$DATADIR/config.conf"
LOG="$DATADIR/zramod.log"
mkdir -p "$DATADIR" 2>/dev/null

# 有些设备会在开机流程更晚的阶段（比 post-fs-data/service.sh、乃至 BOOT_COMPLETED 广播本身还要晚，
# 实测观察到大约是 BOOT_COMPLETED 之后 10 秒左右）用自己的默认值把 vm.swappiness、
# watermark_scale_factor 覆盖掉。所以这里不是收到 BOOT_COMPLETED 就立刻补写，而是先等一会儿，
# 尽量等那个"迟到的覆盖"先发生，我们再写，确保是最后写入的那个。这个延迟秒数可以在
# config.conf 里用 BOOT_SYSCTL_DELAY_SEC 调整（WebUI 高级选项里也能改），默认 20 秒。
BOOT_SYSCTL_DELAY_SEC=""
[ -f "$CONF" ] && . "$CONF"
case "$BOOT_SYSCTL_DELAY_SEC" in
  ''|*[!0-9]*) BOOT_SYSCTL_DELAY_SEC=20 ;;
esac

[ "$BOOT_SYSCTL_DELAY_SEC" -gt 0 ] && sleep "$BOOT_SYSCTL_DELAY_SEC"

sh "$MODDIR/common/zram_apply.sh" sysctl >> "$LOG" 2>&1

{
  echo "$(date '+%Y-%m-%d %H:%M:%S') boot-completed: 开机流程结束（延迟 ${BOOT_SYSCTL_DELAY_SEC}s 补写 sysctl 后），当前状态："
  sh "$MODDIR/common/zram_apply.sh" detect
} >> "$LOG" 2>&1
