#!/system/bin/sh
MODDIR=${0%/*}
sh "$MODDIR/common/zram_apply.sh" restore
