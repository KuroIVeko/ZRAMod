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

# ---- 关于 post-fs-data.sh 卡住会不会卡开机：不会自动兜底，要老实面对 ----
# 之前这里写过"KernelSU 有 10 秒硬超时兜底"，是没查证据就写的，是错的。
# 实际去看了 KernelSU 源码（userspace/ksud/src/init_event.rs 的 on_post_data_fs()，
# 调用 module::exec_stage_script("post-fs-data", true)；module.rs 里 block=true 时走
# command.status() 同步等待，代码里就是一行 `// TODO: Add timeout`）：目前没有任何超时保护，
# 一个模块的 post-fs-data.sh 卡住，会让 ksud 卡在那一行，进而卡住整个开机流程。这是 KernelSU
# 现状的一个已知缺口，不是我们能从模块脚本这一层完全解决的。
#
# run_bounded 只能挡住"卡在用户态"的情况（等锁、等其它进程、重试循环之类），挡不住内核里
# 真正的不可中断睡眠（D 状态）——那种状态下进程根本不响应 SIGTERM/SIGKILL，timeout 发出信号后
# 只能等内核自己把系统调用跑完才会生效，等于没拦住。zram_reset_device()/zram_meta_alloc()
# 在极端内存压力下确实走的是这种可睡眠、理论上可长时间阻塞的内核路径，所以下面的 reset/
# disksize 这几个 sysfs echo 写没有用 run_bounded 包——不是因为"不会阻塞"（会），而是包了在
# 真正卡住的那种情况下也没用，只会让代码显得有保护但其实没有。这是本模块目前吃不掉的残余风险，
# 概率上集中在"开机这一刻系统内存已经很紧张"这种少见场景。
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
else
  log "警告: 本设备没有 timeout 命令，swapoff/mkswap/swapon 这几步将不带超时保护地执行（卡住就是真卡住，没有兜底）"
fi

run_bounded() {
  # 用法: run_bounded <超时秒数> <命令...>
  # 只能拦住"卡在用户态"的挂起；对内核不可中断睡眠（D 状态）无效，见上面的说明。
  secs="$1"; shift
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$secs" "$@"
  else
    "$@"
  fi
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

# /proc/swaps 第 4 列，KB 为单位，当前 zram 里实际驻留的（已压缩）数据量。这个数字量级是
# 真实物理内存的 KB 数，即使 24GB 内存的设备也在千万级，远小于 shell 32 位整数比较会出问题
# 的量级（is_zero_str 那个坑是给字节数用的，这里不需要那一套）。
swap_used_kb() {
  awk -v d="$ZDEV" '$1==d{print $4}' /proc/swaps 2>/dev/null
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

apply_sysctls() {
  # $1 = swappiness  $2 = watermark_scale_factor
  # 只负责写这两个 sysctl 本身，不判断"该不该写"——那是调用方的责任（见下面三处调用点的说明）。
  sw="$1"; w="$2"
  if is_uint "$sw"; then
    echo "$sw" > /proc/sys/vm/swappiness 2>>"$LOG"
    if [ $? -ne 0 ] && [ "$sw" -gt 100 ]; then
      log "警告: swappiness=$sw 写入失败，回退到 100 重试"
      echo 100 > /proc/sys/vm/swappiness 2>>"$LOG"
    fi
  fi
  if is_uint "$w"; then
    [ "$w" -lt 1 ] && w=1
    [ "$w" -gt 1000 ] && w=1000
    echo "$w" > /proc/sys/vm/watermark_scale_factor 2>>"$LOG"
  fi
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

# do_rebuild algo size priority doswapon
# 只负责 zram 设备本身这条链路（swapoff/reset/算法/大小/mkswap/swapon），不碰 swappiness/
# watermark_scale_factor——那两个是否要写、写哪个值，是调用方（cmd_apply/cmd_restore）根据
# 自己的语义决定的，不应该在这里被动跟着 zram_ok 走同一套规则，因为 apply 失败和 restore 失败
# 对"该不该动 sysctl"的答案是不一样的，见 cmd_apply/cmd_restore 里的注释。
# 任何一步失败只记录日志并尽量继续/安全退出，绝不让开机路径挂死
do_rebuild() {
  algo="$1"; size="$2"; prio="$3"; doswapon="$4"

  zram_ok=1
  zram_msg="applied"

  # swapoff 要把 zram 里已经压缩驻留的数据全部搬回真实内存才能返回，用量越大越慢、
  # 内存越紧张越可能真的堵住（这才是实质性降低"卡在 swapoff 里"概率的手段，选 post-fs-data
  # 这个阶段只是选了个通常风险较低的时机，不等于消除了风险）。这里直接检查当前用量，
  # 超过阈值就不动手，跟"失败"一样处理，而不是硬着头皮上。阈值可以在 config.conf 里用
  # SWAP_USAGE_SKIP_KB 调整（单位 KB），默认 1GiB；设成 unlimited 则完全关闭这项检查
  # （WebUI 里对应"不限制"档位，选它之前会展示清楚的风险说明）。
  SWAP_USAGE_SKIP_KB=""
  [ -f "$CONF" ] && . "$CONF" 2>/dev/null
  if [ "$SWAP_USAGE_SKIP_KB" = "unlimited" ]; then
    SWAP_USAGE_SKIP_KB=""
  else
    case "$SWAP_USAGE_SKIP_KB" in
      ''|*[!0-9]*) SWAP_USAGE_SKIP_KB=1048576 ;;
    esac
  fi

  if [ ! -d "$ZSYS" ]; then
    log "错误: 未找到 $ZSYS，设备可能没有 zram0，跳过 zram 相关设置"
    zram_ok=0; zram_msg="zram0_not_found"
  fi

  if [ "$zram_ok" -eq 1 ] && is_swapon; then
    used_kb="$(swap_used_kb)"
    if [ -n "$SWAP_USAGE_SKIP_KB" ] && is_uint "$used_kb" && [ "$used_kb" -gt "$SWAP_USAGE_SKIP_KB" ]; then
      log "警告: 当前 zram 已用 ${used_kb}KB，超过安全阈值 ${SWAP_USAGE_SKIP_KB}KB，swapoff 需要把这些数据搬回内存可能很慢甚至阻塞，本次跳过重建、保持现状不动。可以先释放内存（关掉几个应用）或稍后再试；阈值可在 config.conf 的 SWAP_USAGE_SKIP_KB 调整，设成 unlimited 可关闭此检查（有风险）"
      zram_ok=0; zram_msg="swap_usage_too_high"
    else
      run_bounded 5 swapoff "$ZDEV" >>"$LOG" 2>&1
      if [ $? -ne 0 ]; then
        log "错误: swapoff $ZDEV 失败或超时（>5s 未返回，视为失败继续往下走；如果是内核态卡死，这个超时本身也拦不住，见文件头说明）"
        zram_ok=0; zram_msg="swapoff_failed"
      fi
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
      run_bounded 15 mkswap "$ZDEV" >>"$LOG" 2>&1
      if [ $? -ne 0 ]; then
        log "错误: mkswap $ZDEV 失败或超时（>15s 未返回，视为失败继续往下走；如果是内核态卡死，这个超时本身也拦不住，见文件头说明）"
        zram_ok=0; zram_msg="mkswap_failed"
      else
        # 部分设备上模块脚本环境里 swapon 解析到的是不支持 -p 的 BusyBox 实现
        # （只有 -a/-e/-d，没有优先级参数），优先尝试系统自带的 swapon，失败再退化为不带优先级重试，
        # 保证至少能把 swap 打开，而不是因为优先级参数就整体失败。
        swapon_bin=swapon
        [ -x /system/bin/swapon ] && swapon_bin=/system/bin/swapon
        is_uint "$prio" || prio=32767
        run_bounded 5 "$swapon_bin" -p "$prio" "$ZDEV" >>"$LOG" 2>&1
        if [ $? -ne 0 ]; then
          log "警告: $swapon_bin -p $prio 失败或超时（当前 swapon 实现可能不支持 -p），尝试不带优先级重试"
          run_bounded 5 "$swapon_bin" "$ZDEV" >>"$LOG" 2>&1
          if [ $? -ne 0 ]; then
            log "错误: swapon $ZDEV 失败或超时（>5s 未返回，视为失败继续往下走；如果是内核态卡死，这个超时本身也拦不住，见文件头说明）"
            zram_ok=0; zram_msg="swapon_failed"
          else
            log "警告: swapon 已生效，但未能设置优先级 $prio（当前 swapon 实现不支持 -p）"
          fi
        fi
        [ "$zram_ok" -eq 1 ] && { is_swapon || log "警告: swapon 返回成功但 /proc/swaps 中未找到 $ZDEV"; }
      fi
    fi
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
  do_rebuild "$ZRAM_ALGO" "$ZRAM_SIZE_BYTES" "$ZRAM_PRIORITY" "true"
  zram_result=$?

  # swappiness/watermark_scale_factor 只在确认"我们的 zram 配置真的生效了"之后才写新值。
  # 原因：如果 zram 这条链路失败了（比如卡在 swapoff 那一步），当前实际生效的 zram 到底是
  # 什么状态是不确定的——可能是很早以前某次成功 apply 留下的旧自定义配置，也可能是设备原始
  # 配置，不一定等于 original.conf 里那份"首次接管前"的快照。把为新配置算出来的 swappiness
  # 硬写上去，等于是在猜一个我们并不清楚细节的状态上打补丁，猜错的概率不比不猜低。所以失败时
  # 干脆不动这两个值，保持系统当前实际值不变，等下次 apply 成功再一起生效。
  if [ "$zram_result" -eq 0 ]; then
    apply_sysctls "$VM_SWAPPINESS" "$VM_WATERMARK_SCALE_FACTOR"
  else
    log "zram 配置未成功生效，本次不写入新的 swappiness/watermark_scale_factor（避免配到一个状态不明的 zram 上），系统当前值保持不变"
  fi
  return "$zram_result"
}

cmd_sysctl() {
  # 只重新写 swappiness / watermark_scale_factor，不动 zram 设备本身（不 swapoff/reset/mkswap）。
  # 存在的原因：不少设备/ROM 会在开机流程后段（比 post-fs-data / late_start service 更晚，
  # 很可能是某个在 on boot 或 sys.boot_completed 触发的 init 脚本 / vendor 服务）用设备自己的默认值
  # 把 vm.swappiness、vm.watermark_scale_factor 覆盖掉，导致 post-fs-data.sh 里设置的值“开机后不生效，
  # 只有手动跑一遍才有效”。所以额外在 boot-completed 阶段（用户手动在终端敲命令时机之后）再补写一次，
  # 确保我们是“最后写入的那个”。
  #
  # 跟 cmd_apply 一样只在 zram 确认处于 swapon 状态时才补写：这里存在的意义是"把已经成功生效的
  # 配置再确认一遍、防止被 ROM 晚起的进程覆盖掉"，如果 zram 压根没起来，就没有"已生效配置"可言，
  # 硬写这两个值没有意义，反而可能把一个我们不了解细节的当前状态强行改掉。
  if [ ! -f "$CONF" ]; then
    return 0
  fi
  ENABLED=""; VM_SWAPPINESS=""; VM_WATERMARK_SCALE_FACTOR=""
  . "$CONF"
  if [ "$ENABLED" != "true" ]; then
    return 0
  fi

  if ! is_swapon; then
    log "boot-completed: zram0 当前未处于 swapon 状态，跳过补写 swappiness/watermark_scale_factor"
    return 0
  fi

  apply_sysctls "$VM_SWAPPINESS" "$VM_WATERMARK_SCALE_FACTOR"
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
  do_rebuild "$ORIG_ALGO" "$ORIG_SIZE_BYTES" "$ORIG_PRIORITY" "$ORIG_SWAPON"
  zram_result=$?

  # restore 跟 apply 不一样：这里不管 zram 设备这条链路有没有完全恢复成功，都无条件把
  # swappiness/watermark_scale_factor 写回 original.conf 里的原值。因为 restore/卸载的
  # 目的就是清除本模块留下的痕迹，这两个 sysctl 是我们改过的东西，理应无条件收回；如果因为
  # zram 设备那部分失败就连 sysctl 也不还原，会出现"模块都卸载了，swappiness 还停在
  # 自定义值，且以后再也没有 boot-completed 帮你补写"的更差状态。
  apply_sysctls "$ORIG_SWAPPINESS" "$ORIG_WSF"
  [ "$zram_result" -eq 0 ] || log "警告: zram 设备部分未能恢复到原始状态，但 swappiness/watermark_scale_factor 已恢复"
  return "$zram_result"
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
  echo "CURRENT_USED_KB=$(swap_used_kb)"
  if [ -f "$CONF" ]; then echo "CONFIG_EXISTS=true"; else echo "CONFIG_EXISTS=false"; fi
  if [ -f "$ORIG" ]; then echo "ORIGINAL_EXISTS=true"; else echo "ORIGINAL_EXISTS=false"; fi
}

case "$1" in
  restore) cmd_restore ;;
  detect) cmd_detect ;;
  sysctl) cmd_sysctl ;;
  *) cmd_apply ;;
esac
