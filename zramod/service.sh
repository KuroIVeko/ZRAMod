#!/system/bin/sh
MODDIR=${0%/*}
DATADIR=/data/adb/zramod
CONF="$DATADIR/config.conf"
LOG="$DATADIR/zramod.log"

mkdir -p "$DATADIR" 2>/dev/null

[ -f "$CONF" ] || exit 0

ENABLED=""
. "$CONF"
[ "$ENABLED" = "true" ] || exit 0

if ! grep -q "^/dev/block/zram0 " /proc/swaps 2>/dev/null; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') service.sh: 检测到 post-fs-data 阶段未成功让 zram0 进入 swapon 状态，尝试补偿执行一次" >> "$LOG"
  sh "$MODDIR/common/zram_apply.sh" apply
fi
