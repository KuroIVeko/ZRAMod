#!/system/bin/sh
MODDIR=${0%/*}
DATADIR=/data/adb/zramod
LOG="$DATADIR/zramod.log"
mkdir -p "$DATADIR" 2>/dev/null

# 有些设备会在开机流程更晚的阶段（比 post-fs-data/service.sh 更靠后）用自己的默认值把
# vm.swappiness、vm.watermark_scale_factor 覆盖掉。这里在开机彻底完成后再补写一次，
# 只动这两个 sysctl，不碰 zram 设备本身，避免不必要地重建 swap。
sh "$MODDIR/common/zram_apply.sh" sysctl >> "$LOG" 2>&1

{
  echo "$(date '+%Y-%m-%d %H:%M:%S') boot-completed: 开机流程结束，当前状态："
  sh "$MODDIR/common/zram_apply.sh" detect
} >> "$LOG" 2>&1
