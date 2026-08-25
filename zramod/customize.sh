ui_print "- 安装 Zramod（nomount：不挂载 system，仅安装开机脚本与 WebUI）"

DATADIR=/data/adb/zramod
mkdir -p "$DATADIR"
[ -f "$DATADIR/zramod.log" ] || touch "$DATADIR/zramod.log"

set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in post-fs-data.sh service.sh boot-completed.sh uninstall.sh action.sh common/zram_apply.sh; do
  [ -f "$MODPATH/$f" ] && set_perm "$MODPATH/$f" 0 0 0755
done

ui_print "- 安装完成，本模块默认不会自动修改你的 zram"
ui_print "- 请在管理器中打开本模块的 WebUI，完成配置并点击「保存并立即应用」"
