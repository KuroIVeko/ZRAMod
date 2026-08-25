#!/system/bin/sh
MODDIR=${0%/*}
sh "$MODDIR/common/zram_apply.sh" apply
echo "Zramod: 已按 /data/adb/zramod/config.conf 重新应用配置，详情见 /data/adb/zramod/zramod.log"
