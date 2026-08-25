#!/system/bin/sh
# Zramod 核心逻辑，被 post-fs-data.sh / service.sh / action.sh / boot-completed.sh / uninstall.sh / WebUI 共用
# 用法: zram_apply.sh [apply|restore|detect]
#   apply   读取 /data/adb/zramod/config.conf 并应用（未配置或 ENABLED!=true 时什么都不做）
#   restore 读取 /data/adb/zramod/original.conf，把 zram/内核参数恢复到首次接管前的状态
#   detect  探测设备当前 zram 状态与支持的算法列表，以 key=value 的形式输出到 stdout

DATADIR=/data/adb/zramod
CONF="$DATADIR/config.conf"
ORIG="$DATADIR/original.conf"
LOG="$DATADIR/zramod.log"
STATUS="$DATADIR/status.conf"

ZDEV=/dev/block/zram0
ZSYS=/sys/block/zram0

mkdir -p "$DATADIR" 2>/dev/null

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null
}

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# 纯字符串匹配判断是否全部由 '0' 组成（即数值上等于 0），不做任何算术运算。
# 原因：disksize 这类字节数常年是十位数以上的大整数，设备上部分 sh/toybox 的
# `[ -eq/-gt ]` 数值比较是按 32 位有符号整数做的，25769803776（24GiB，恰好是
# 6*2^32）这类值会直接被截断成 0，导致后续判断全部错误。所以凡是可能超过
# 2^31 的字节数值，一律只用字符串比较，绝不喂给 -eq/-gt/-lt。
is_zero_str() {
  case "$1" in
    ''|*[!0]*) return 1 ;;
    *) return 0 ;;
  esac
}

current_algo() {
  sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$ZSYS/comp_algorithm" 2>/dev/null
}

supported_algos() {
  cat "$ZSYS/comp_algorithm" 2>/dev/null | tr -d '[]'
}

is_swapon() {
  grep -q "^$ZDEV " /proc/swaps 2>/dev/null
}

swap_priority() {
  awk -v d="$ZDEV" '$1==d{print $5}' /proc/swaps 2>/dev/null
}

write_status() {
  # $1 = ok/fail  $2 = 简短说明
  {
    echo "LAST_RESULT=$1"
    echo "LAST_MESSAGE=$2"
    echo "LAST_TIME=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "ACTUAL_ALGO=$(current_algo)"
    echo "ACTUAL_SIZE_BYTES=$(cat "$ZSYS/disksize" 2>/dev/null)"
    echo "ACTUAL_SWAPPINESS=$(cat /proc/sys/vm/swappiness 2>/dev/null)"
    echo "ACTUAL_WSF=$(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null)"
    if is_swapon; then echo "ACTUAL_SWAPON=true"; else echo "ACTUAL_SWAPON=false"; fi
    echo "ACTUAL_PRIORITY=$(swap_priority)"
  } > "$STATUS" 2>/dev/null
}

snapshot_original() {
  [ -f "$ORIG" ] && return 0
  {
    echo "ORIG_ALGO=$(current_algo)"
    echo "ORIG_SIZE_BYTES=$(cat "$ZSYS/disksize" 2>/dev/null)"
    echo "ORIG_SWAPPINESS=$(cat /proc/sys/vm/swappiness 2>/dev/null)"
    echo "ORIG_WSF=$(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null)"
    if is_swapon; then
      echo "ORIG_SWAPON=true"
      echo "ORIG_PRIORITY=$(swap_priority)"
    else
      echo "ORIG_SWAPON=false"
      echo "ORIG_PRIORITY=32767"
    fi
  } > "$ORIG" 2>/dev/null
  log "已保存原始状态快照到 $ORIG"
}

# do_rebuild algo size priority swappiness wsf doswapon
# 任何一步失败只记录日志并尽量继续/安全退出，绝不让开机路径挂死
do_rebuild() {
  algo="$1"; size="$2"; prio="$3"; swappiness="$4"; wsf="$5"; doswapon="$6"

  # zram_ok/zram_msg 只跟踪 zram 本身（swapoff/reset/算法/大小/mkswap/swapon）这条链路的成败；
  # swappiness/watermark_scale_factor 是完全独立的内核参数，跟 zram 是否配置成功无关，必须始终尝试，
  # 不能因为前面某一步失败就 return 提前退出导致它们被跳过。
  zram_ok=1
  zram_msg="applied"

  if [ ! -d "$ZSYS" ]; then
    log "错误: 未找到 $ZSYS，设备可能没有 zram0，跳过 zram 相关设置"
    zram_ok=0; zram_msg="zram0_not_found"
  fi

  if [ "$zram_ok" -eq 1 ] && is_swapon; then
    swapoff "$ZDEV" >>"$LOG" 2>&1
    if [ $? -ne 0 ]; then
      log "错误: swapoff $ZDEV 失败"
      zram_ok=0; zram_msg="swapoff_failed"
    fi
  fi

  if [ "$zram_ok" -eq 1 ]; then
    echo 1 > "$ZSYS/reset" 2>>"$LOG"
    if [ $? -ne 0 ]; then
      log "错误: reset zram0 失败"
      zram_ok=0; zram_msg="reset_failed"
    fi
  fi

  if [ "$zram_ok" -eq 1 ] && [ -n "$algo" ]; then
    supported=" $(supported_algos) "
    case "$supported" in
      *" $algo "*)
        echo "$algo" > "$ZSYS/comp_algorithm" 2>>"$LOG"
        [ "$?" -eq 0 ] || log "警告: 写入算法 $algo 失败"
        applied="$(current_algo)"
        [ "$applied" = "$algo" ] || log "警告: 算法回读不一致，期望 $algo 实际 $applied"
        ;;
      *)
        log "警告: 算法 $algo 不在设备支持列表内 ($(supported_algos))，跳过设置算法"
        ;;
    esac
  fi

  if [ "$zram_ok" -eq 1 ]; then
    if is_uint "$size" && ! is_zero_str "$size"; then
      echo "$size" > "$ZSYS/disksize" 2>>"$LOG"
      if [ $? -ne 0 ]; then
        log "错误: 设置 disksize=$size 失败"
        zram_ok=0; zram_msg="disksize_failed"
      else
        actual_size="$(cat "$ZSYS/disksize" 2>/dev/null)"
        [ "$actual_size" = "$size" ] || log "警告: disksize 回读不一致，期望 $size 实际 $actual_size"
      fi
    elif is_uint "$size" && is_zero_str "$size"; then
      # 常见于 restore：设备原本就没有配置过 zram（原始 disksize=0），reset 后保持不使用即可，不算失败
      log "目标大小为 0，跳过设置 disksize/mkswap/swapon，zram 保持未使用状态"
      doswapon="false"
      zram_msg="left_unconfigured"
    else
      log "错误: 无效的 size ($size)"
      zram_ok=0; zram_msg="invalid_size"
    fi
  fi

  if [ "$zram_ok" -eq 1 ] && [ "$doswapon" = "true" ]; then
    if ! command -v mkswap >/dev/null 2>&1; then
      log "错误: 未找到 mkswap 命令，放弃 swapon"
      zram_ok=0; zram_msg="mkswap_missing"
    else
      mkswap "$ZDEV" >>"$LOG" 2>&1
      if [ $? -ne 0 ]; then
        log "错误: mkswap $ZDEV 失败"
        zram_ok=0; zram_msg="mkswap_failed"
      else
        # 部分设备上模块脚本环境里 swapon 解析到的是不支持 -p 的 BusyBox 实现
        # （只有 -a/-e/-d，没有优先级参数），优先尝试系统自带的 swapon，失败再退化为不带优先级重试，
        # 保证至少能把 swap 打开，而不是因为优先级参数就整体失败。
        swapon_bin=swapon
        [ -x /system/bin/swapon ] && swapon_bin=/system/bin/swapon
        is_uint "$prio" || prio=32767
        "$swapon_bin" -p "$prio" "$ZDEV" >>"$LOG" 2>&1
        if [ $? -ne 0 ]; then
          log "警告: $swapon_bin -p $prio 失败（当前 swapon 实现可能不支持 -p），尝试不带优先级重试"
          "$swapon_bin" "$ZDEV" >>"$LOG" 2>&1
          if [ $? -ne 0 ]; then
            log "错误: swapon $ZDEV 失败"
            zram_ok=0; zram_msg="swapon_failed"
          else
            log "警告: swapon 已生效，但未能设置优先级 $prio（当前 swapon 实现不支持 -p）"
          fi
        fi
        [ "$zram_ok" -eq 1 ] && { is_swapon || log "警告: swapon 返回成功但 /proc/swaps 中未找到 $ZDEV"; }
      fi
    fi
  fi

  if is_uint "$swappiness"; then
    echo "$swappiness" > /proc/sys/vm/swappiness 2>>"$LOG"
    if [ $? -ne 0 ] && [ "$swappiness" -gt 100 ]; then
      log "警告: swappiness=$swappiness 写入失败，回退到 100 重试"
      echo 100 > /proc/sys/vm/swappiness 2>>"$LOG"
    fi
  fi

  if is_uint "$wsf"; then
    [ "$wsf" -lt 1 ] && wsf=1
    [ "$wsf" -gt 1000 ] && wsf=1000
    echo "$wsf" > /proc/sys/vm/watermark_scale_factor 2>>"$LOG"
  fi

  if [ "$zram_ok" -eq 1 ]; then
    write_status ok "$zram_msg"
  else
    write_status fail "$zram_msg"
  fi
  log "本次操作完成: algo=$(current_algo) size=$(cat "$ZSYS/disksize" 2>/dev/null) swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null) wsf=$(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null) swapon=$(is_swapon && echo true || echo false)"
  [ "$zram_ok" -eq 1 ] && return 0
  return 1
}

cmd_apply() {
  if [ ! -f "$CONF" ]; then
    log "未找到配置文件 $CONF，跳过（模块尚未配置，不会自动改动 zram）"
    return 0
  fi

  ENABLED=""; ZRAM_ALGO=""; ZRAM_SIZE_BYTES=""; ZRAM_PRIORITY=""; VM_SWAPPINESS=""; VM_WATERMARK_SCALE_FACTOR=""; BOOT_SYSCTL_DELAY_SEC=""
  . "$CONF"
  log "读取到配置: ENABLED=$ENABLED ZRAM_ALGO=$ZRAM_ALGO ZRAM_SIZE_BYTES=$ZRAM_SIZE_BYTES ZRAM_PRIORITY=$ZRAM_PRIORITY VM_SWAPPINESS=$VM_SWAPPINESS VM_WATERMARK_SCALE_FACTOR=$VM_WATERMARK_SCALE_FACTOR BOOT_SYSCTL_DELAY_SEC=$BOOT_SYSCTL_DELAY_SEC"

  if [ "$ENABLED" != "true" ]; then
    log "配置中 ENABLED!=true，跳过应用"
    return 0
  fi

  if [ ! -d "$ZSYS" ]; then
    log "错误: 未找到 $ZSYS，跳过应用"
    return 0
  fi

  snapshot_original
  do_rebuild "$ZRAM_ALGO" "$ZRAM_SIZE_BYTES" "$ZRAM_PRIORITY" "$VM_SWAPPINESS" "$VM_WATERMARK_SCALE_FACTOR" "true"
}

cmd_sysctl() {
  # 只重新写 swappiness / watermark_scale_factor，不动 zram 设备本身（不 swapoff/reset/mkswap）。
  # 存在的原因：不少设备/ROM 会在开机流程后段（比 post-fs-data / late_start service 更晚，
  # 很可能是某个在 on boot 或 sys.boot_completed 触发的 init 脚本 / vendor 服务）用设备自己的默认值
  # 把 vm.swappiness、vm.watermark_scale_factor 覆盖掉，导致 post-fs-data.sh 里设置的值“开机后不生效，
  # 只有手动跑一遍才有效”。所以额外在 boot-completed 阶段（用户手动在终端敲命令时机之后）再补写一次，
  # 确保我们是“最后写入的那个”。
  if [ ! -f "$CONF" ]; then
    return 0
  fi
  ENABLED=""; VM_SWAPPINESS=""; VM_WATERMARK_SCALE_FACTOR=""
  . "$CONF"
  if [ "$ENABLED" != "true" ]; then
    return 0
  fi

  if is_uint "$VM_SWAPPINESS"; then
    echo "$VM_SWAPPINESS" > /proc/sys/vm/swappiness 2>>"$LOG"
    if [ $? -ne 0 ] && [ "$VM_SWAPPINESS" -gt 100 ]; then
      echo 100 > /proc/sys/vm/swappiness 2>>"$LOG"
    fi
  fi

  if is_uint "$VM_WATERMARK_SCALE_FACTOR"; then
    w="$VM_WATERMARK_SCALE_FACTOR"
    [ "$w" -lt 1 ] && w=1
    [ "$w" -gt 1000 ] && w=1000
    echo "$w" > /proc/sys/vm/watermark_scale_factor 2>>"$LOG"
  fi

  log "boot-completed 补写 sysctl: swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null) wsf=$(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null)"
}

cmd_restore() {
  if [ ! -f "$ORIG" ]; then
    log "未找到原始状态快照 $ORIG，无法恢复（可能还从未成功应用过一次配置）"
    write_status fail "no_snapshot"
    return 1
  fi
  ORIG_ALGO=""; ORIG_SIZE_BYTES=""; ORIG_SWAPPINESS=""; ORIG_WSF=""; ORIG_SWAPON=""; ORIG_PRIORITY=""
  . "$ORIG"
  log "开始恢复到本模块首次接管前的原始状态"
  do_rebuild "$ORIG_ALGO" "$ORIG_SIZE_BYTES" "$ORIG_PRIORITY" "$ORIG_SWAPPINESS" "$ORIG_WSF" "$ORIG_SWAPON"
}

cmd_detect() {
  if [ -d "$ZSYS" ]; then
    echo "ZRAM_PRESENT=true"
  else
    echo "ZRAM_PRESENT=false"
  fi
  echo "SUPPORTED_ALGOS=$(supported_algos)"
  echo "CURRENT_ALGO=$(current_algo)"
  echo "CURRENT_SIZE_BYTES=$(cat "$ZSYS/disksize" 2>/dev/null)"
  echo "MEM_TOTAL_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)"
  echo "CURRENT_SWAPPINESS=$(cat /proc/sys/vm/swappiness 2>/dev/null)"
  echo "CURRENT_WSF=$(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null)"
  if is_swapon; then echo "CURRENT_SWAPON=true"; else echo "CURRENT_SWAPON=false"; fi
  echo "CURRENT_PRIORITY=$(swap_priority)"
  if [ -f "$CONF" ]; then echo "CONFIG_EXISTS=true"; else echo "CONFIG_EXISTS=false"; fi
  if [ -f "$ORIG" ]; then echo "ORIGINAL_EXISTS=true"; else echo "ORIGINAL_EXISTS=false"; fi
}

case "$1" in
  restore) cmd_restore ;;
  detect) cmd_detect ;;
  sysctl) cmd_sysctl ;;
  *) cmd_apply ;;
esac
