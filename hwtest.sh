#!/usr/bin/env bash
# hwtest.sh —— Linux 硬件信息采集报告（纯 shell 实现）
#
# 用法:
#   ./hwtest.sh                        # 默认保存 hwtest_report_<时间戳>.txt 并打印
#   ./hwtest.sh -o hw.txt              # 保存 hw_<时间戳>.txt
#   ./hwtest.sh -o out/                # 保存到 out/hwtest_report_<时间戳>.txt
#   ./hwtest.sh -o hw.txt --no-stamp   # 精确写入 hw.txt（不加时间戳）
#   ./hwtest.sh --stdout               # 只打印到屏幕，不写文件
#   ./hwtest.sh --mask                 # 脱敏主机名/MAC/磁盘与内存序列号
#   ./hwtest.sh --no-disk              # 跳过 SMART 采集（快速模式）
#
# 依赖命令: lscpu dmidecode lshw smartctl sensors df lsblk ethtool lspci
# 内存条明细需要 root；非 root 自动降级为提示文字，不中断。

set -u

# 必须用 UTF-8 locale：C locale 下 bash 的 ${#s} 按字节计数，中文宽度算错；
# 同时 awk 的 length() 也需字符口径。优先 C.UTF-8（命令输出仍为英文）。
for _lc in C.UTF-8 C.utf8 en_US.UTF-8; do
  if LC_ALL=$_lc locale charmap >/dev/null 2>&1; then
    export LC_ALL=$_lc
    break
  fi
done

LABEL_W=20               # 标签列显示宽度
NA="N/A"
MASK=0
NO_DISK=0
OUT=""

# ───────────────────────────── 基础工具 ─────────────────────────────

# 纯 bash 重复字符，避免每次 fork seq
rep() { local n=$1 s=$2 o=""; local i; for ((i = 0; i < n; i++)); do o+="$s"; done; printf '%s' "$o"; }

# 终端显示宽度：非 ASCII 字符按 2 列计
dwidth() {
  local s=$1 i c n=0
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    if [[ $c == [!$'\x20'-$'\x7e'] ]]; then n=$((n + 2)); else n=$((n + 1)); fi
  done
  printf '%s' "$n"
}

LINES=()
add() { local l; for l in "$@"; do LINES+=("$l"); done; }

row() {                                  # row 标签 值
  local lab=$1 val=$2 p
  p=$((LABEL_W - $(dwidth "$lab")))
  ((p < 0)) && p=0
  add "│ ${lab}$(rep "$p" ' '): ${val}"
}

block_open() {                           # 标题字符数 + 2 = 分隔横线数
  add "┌─ $1"
  add "├$(rep $((${#1} + 2)) '─')"
}
block_close() { add "└$(rep 50 '─')"; }

human() {                                # 字节 -> 人类可读
  awk -v n="$1" 'BEGIN{
    split("B KB MB GB TB PB", u, " "); i = 1
    while (n >= 1024 && i < 6) { n /= 1024; i++ }
    printf "%.2f %s", n, u[i]
  }'
}

lba_human() {                            # SMART LBA 计数(512B/扇区) -> 人类可读
  awk -v v="$1" 'BEGIN{
    n = v * 512; if (n <= 0) { print "N/A"; exit }
    split("B KB MB GB TB PB", u, " "); i = 1
    while (n >= 1024 && i < 6) { n /= 1024; i++ }
    printf "%.2f %s", n, u[i]
  }'
}

mask_mac()    { awk -F: '{printf "%s:%s:%s:XX:XX:XX\n", $1, $2, $3}' <<<"$1"; }
# SAS WWN：保留 OUI 前缀六位十六进制，其余置 0
mask_sas()    { local s=$1; printf '0x%s%s\n' "${s:2:6}" "$(rep $(( ${#s} > 8 ? ${#s} - 8 : 0 )) '0')"; }
# 保留前 4 位便于比对，其余打星；短串（如主机名）整体保留首位
mask_serial() { local s=$1
                [ -z "$s" ] && { echo "$NA"; return; }
                if [ "${#s}" -le 4 ]; then
                  printf '%s%s\n' "${s:0:1}" "$(rep $(( ${#s} - 1 )) '*')"
                else
                  printf '%s%s\n' "${s:0:4}" "$(rep $(( ${#s} - 4 )) '*')"
                fi
              }

# ───────────────────────────── 系统信息 ─────────────────────────────

collect_system() {
  block_open "系统信息"
  if [ "$MASK" = 1 ]; then
    row "主机名" "$(mask_serial "$(hostname)")"
  else
    row "主机名" "$(hostname)"
  fi
  row "操作系统" "$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release)"
  row "内核版本" "$(uname -r)"
  row "运行时间" "$(uptime -p 2>/dev/null || uptime | sed 's/.*up //; s/,.*load.*//')"
  block_close
}

# ───────────────────────────── 处理器 ─────────────────────────────

cpu_usage() {                            # 两次采样 /proc/stat 取平均
  local a b
  a=$(awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; print t, $5+$6}' /proc/stat)
  sleep 0.5
  b=$(awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; print t, $5+$6}' /proc/stat)
  awk -v a="$a" -v b="$b" 'BEGIN{
    split(a, A, " "); split(b, B, " ")
    dt = B[1] - A[1]; di = B[2] - A[2]
    printf "%.1f%%", (dt > 0) ? (dt - di) / dt * 100 : 0
  }'
}

cpu_cache() {                            # 优先 L3，退化 L2，统一换算成 KB
  local line v u
  line=$(lscpu | awk -F'[: ]+' '/^L3 cache:/{print $3" "$4; exit}')
  [ -z "$line" ] && line=$(lscpu | awk -F'[: ]+' '/^L2 cache:/{print $3" "$4; exit}')
  [ -z "$line" ] && { echo "$NA"; return; }
  v=${line%% *}; u=${line##* }
  case "$u" in
    KiB|KB)          : ;;
    MiB|MB)          v=$((v * 1024)) ;;
    GiB|GB)          v=$((v * 1048576)) ;;
  esac
  echo "${v} KB"
}

cpu_temp() {
  local t m=0 v z
  t=$(sensors 2>/dev/null | awk '/^Package id 0:/{print $4; exit}')
  if [ -z "$t" ]; then
    for z in /sys/class/thermal/thermal_zone*/temp; do
      [ -r "$z" ] || continue
      v=$(cat "$z" 2>/dev/null) || continue
      [ "$v" -gt "$m" ] 2>/dev/null && m=$v
    done
    [ "$m" -gt 0 ] && t=$(awk -v x="$m" 'BEGIN{printf "+%.1f°C", x/1000}')
  fi
  echo "${t:-$NA}"
}

collect_cpu() {
  local model cores sockets threads mhz
  model=$(lscpu | awk -F: '/^Model name:/{sub(/^ +/, "", $2); print $2; exit}')
  [ -z "$model" ] && model=$(awk -F: '/^model name/{sub(/^ +/, "", $2); print $2; exit}' /proc/cpuinfo)

  cores=$(lscpu | awk -F: '/^Core\(s\) per socket:/{gsub(/ /,"",$2); print $2; exit}')
  sockets=$(lscpu | awk -F: '/^Socket\(s\):/{gsub(/ /,"",$2); print $2; exit}')
  threads=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
  mhz=$(awk -F: '/^cpu MHz/{gsub(/^ +/,"",$2); printf "%.3f MHz", $2; exit}' /proc/cpuinfo)

  block_open "处理器信息"
  row "型号" "${model:-$NA}"
  row "核心数" "$((${cores:-1} * ${sockets:-1}))"
  row "线程数" "$threads"
  row "频率" "${mhz:-$NA}"
  row "缓存" "$(cpu_cache)"
  row "使用率" "$(cpu_usage)"
  row "CPU温度" "$(cpu_temp)"
  block_close
}

# ───────────────────────────── 内存 ─────────────────────────────

mem_modules() {                          # 输出: 大小|类型|频率|制造商|序列号|型号
  dmidecode -t 17 2>/dev/null | awk -F': ' '
    /^Memory Device/ {
      if (sz != "" && sz !~ /No Module/) print sprintf("%s|%s|%s|%s|%s|%s", sz, ty, sp, mf, se, pn)
      sz = ty = sp = mf = se = pn = ""
      next
    }
    /^\tSize:/          { sub(/^ +/, "", $2); sz = $2 }
    /^\tType:/          { sub(/^ +/, "", $2); ty = $2 }
    /^\tSpeed:/         { sub(/^ +/, "", $2); sp = $2 }
    /^\tManufacturer:/  { sub(/^ +/, "", $2); mf = $2 }
    /^\tSerial Number:/ { sub(/^ +/, "", $2); se = $2 }
    /^\tPart Number:/   { sub(/^ +/, "", $2); pn = $2; sub(/ +$/, "", pn) }
    END { if (sz != "" && sz !~ /No Module/) print sprintf("%s|%s|%s|%s|%s|%s", sz, ty, sp, mf, se, pn) }
  '
}

mem_table() {                            # 读 stdin 的 | 分隔行，输出自洽宽度表格
  awk -F'|' '
    BEGIN {
      h[1] = "大小"; h[2] = "类型"; h[3] = "频率"
      h[4] = "制造商"; h[5] = "序列号"; h[6] = "型号"
      hw[1] = 4; hw[2] = 4; hw[3] = 4; hw[4] = 6; hw[5] = 6; hw[6] = 4
      for (i = 1; i <= 6; i++) w[i] = hw[i]
    }
    {
      n++
      for (i = 1; i <= 6; i++) {
        v = $i; r[n, i] = v
        if (length(v) > w[i]) w[i] = length(v)
      }
    }
    END {
      if (!n) exit
      total = 1
      for (i = 1; i <= 6; i++) total += w[i] + 3
      rule = sprintf("%*s", total - 2, ""); gsub(/ /, "─", rule)

      printf "├%s┤\n", rule
      line = "│"
      for (i = 1; i <= 6; i++) line = line " " h[i] sprintf("%*s", w[i] - hw[i], "") " │"
      printf "%s\n", line
      printf "├%s┤\n", rule
      for (j = 1; j <= n; j++) {
        line = "│"
        for (i = 1; i <= 6; i++)
          line = line " " r[j, i] sprintf("%*s", w[i] - length(r[j, i]), "") " │"
        printf "%s\n", line
      }
      printf "└%s┘\n", rule
    }
  '
}

collect_mem() {
  local tot avail used mods
  tot=$(awk '/^MemTotal:/{printf "%.2f", $2/1048576}' /proc/meminfo)
  avail=$(awk '/^MemAvailable:/{printf "%.2f", $2/1048576}' /proc/meminfo)
  used=$(awk -v t="$tot" -v a="$avail" 'BEGIN{printf "%.2f", t-a}')

  block_open "内存信息"
  row "总计" "${tot} GB"
  row "已用" "${used} GB"
  row "可用" "${avail} GB"

  if [ "$(id -u)" != "0" ]; then
    row "内存插槽" "无法读取（dmidecode 需要 root）"
  elif ! command -v dmidecode >/dev/null 2>&1; then
    row "内存插槽" "无法读取（未安装 dmidecode）"
  else
    mods=$(mem_modules)
    if [ -z "$mods" ]; then
      row "内存插槽" "未检测到已安装内存条"
    else
      row "内存插槽" "$(grep -c . <<<"$mods") 条已安装"
      add "│"
      add "│ Memory Modules:"
      # --mask 时脱敏第 5 列（序列号）
      if [ "$MASK" = 1 ]; then
        mods=$(awk -F'|' 'BEGIN{OFS="|"} {$5 = (length($5) > 4) ? substr($5,1,4) substr("***************", 1, length($5)-4) : "****"; print}' <<<"$mods")
      fi
      # 全部内存条一次性喂给 awk，列宽跨行统一取最大值
      while IFS= read -r l; do add "$l"; done < <(mem_table <<<"$mods")
    fi
  fi
  block_close
}

# ───────────────────────────── 硬盘 ─────────────────────────────

physical_disks() {
  lsblk -dn -o NAME,TYPE 2>/dev/null \
    | awk '$2=="disk" && $1 !~ /^(loop|ram|zram|sr|md|dm-|nbd|rbd)/ {print "/dev/"$1}'
}

smart_health() {
  smartctl -a "$1" 2>/dev/null \
    | awk -F': ' '/self-assessment test result/{print $2; exit}
                  /SMART Health Status/{print $2; exit}'
}

smart_attr() {                           # $1=设备 $2=属性ID -> RAW_VALUE 首 token
  smartctl -a "$1" 2>/dev/null | awk -v k="$2" '$1==k && NF>=10 {print $10; exit}'
}

smart_snapshot() {
  local dev=$1 basic health poh rd wr temp realloc pending uncorr serial fw
  basic=$(lsblk -dno SIZE,MODEL,TRAN "$dev" 2>/dev/null | tr -s ' ' | sed 's/ sata$/ ATA/' | sed 's/^ //')

  local -a sargs=()
  [[ $dev == /dev/nvme* ]] && sargs=(-d nvme)

  health=$(smart_health "$dev")
  serial=$(smartctl -a "${sargs[@]}" "$dev" 2>/dev/null | sed -n 's/^Serial Number: *//p' | head -1)
  fw=$(smartctl -a "${sargs[@]}" "$dev" 2>/dev/null | sed -n 's/^Firmware Version: *//p' | head -1)

  poh=$(smart_attr "$dev" 9)
  [ -n "$poh" ] && poh="${poh} hours"

  rd=$(smart_attr "$dev" 242); [ -n "$rd" ] && rd=$(lba_human "$rd")
  wr=$(smart_attr "$dev" 241); [ -n "$wr" ] && wr=$(lba_human "$wr")

  temp=$(smart_attr "$dev" 194)
  [ -z "$temp" ] && temp=$(smart_attr "$dev" 190)
  [ -n "$temp" ] && temp="${temp}°C"

  realloc=$(smart_attr "$dev" 5)
  pending=$(smart_attr "$dev" 197)
  uncorr=$(smart_attr "$dev" 187)

  add "│   Basic Info:  ${basic:-$NA}"
  add "│   序列号: $( [ "$MASK" = 1 ] && mask_serial "$serial" || echo "${serial:-$NA}")"
  [ "$MASK" = 1 ] || add "│   固件: ${fw:-$NA}"
  add "│   SMART状态: ${health:-$NA}"
  add "│   通电时间: ${poh:-$NA}"
  add "│   总读取量: ${rd:-$NA}"
  add "│   总写入量: ${wr:-$NA}"
  add "│   温度: ${temp:-$NA}"
  add "│   重映射扇区: ${realloc:-$NA}"
  add "│   待处理扇区: ${pending:-$NA}"
  add "│   报告的不可校正: ${uncorr:-$NA}"
}

collect_disk() {
  block_open "硬盘信息"
  while IFS= read -r l; do add "│ ${l}"; done \
    < <(df -h -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | tail -n +2)

  add "│"
  add "│ Physical Disks Details:"

  local disks dev
  disks=$(physical_disks)
  if [ -z "$disks" ]; then
    add "│   (未检测到物理磁盘)"
    block_close
    return
  fi

  while IFS= read -r dev; do
    add "│"
    add "│ ═══ ${dev} ═══"
    if [ "$NO_DISK" = 1 ]; then
      add "│   Basic Info:  $(lsblk -dno SIZE,MODEL "$dev" 2>/dev/null | tr -s ' ' | sed 's/^ //')"
      add "│   (--no-disk：已跳过 SMART 采集)"
      continue
    fi
    smart_snapshot "$dev"
  done <<<"$disks"
  block_close
}

# ───────────────────────────── RAID 控制器 ─────────────────────────────

collect_raid() {
  block_open "RAID控制器信息"
  if grep -qE '^md[0-9]+ *:' /proc/mdstat 2>/dev/null; then
    while IFS= read -r l; do row "状态" "$l"; done \
      < <(awk '/^md[0-9]+ *:/{sub(/ *$/, ""); print}' /proc/mdstat)
    block_close
    return
  fi

  # 无软 RAID：探测硬件存储控制器（lspci 缩进行从属于上一行）
  local parsed ctlname drv
  parsed=$(lspci -nnk 2>/dev/null | awk '
    /\[0104\]|\[0107\]/ && !found {
      found = 1; name = $0
      sub(/.*: /, "", name)
      sub(/ \[[0-9a-f]{4}:[0-9a-f]{4}\].*/, "", name)
      next
    }
    found && /^\t/ { if (/Kernel driver in use:/) { d = $0; sub(/.*: /, "", d) } next }
    found && !/^\t/ { exit }
    END { if (found) print name "|" d; else print "NONE" }
  ')

  if [ "$parsed" = "NONE" ] || [ -z "$parsed" ]; then
    row "状态" "未检测到"
    block_close
    return
  fi
  ctlname=${parsed%%|*}
  drv=${parsed##*|}

  row "状态" "未检测到软 RAID；存在硬件存储控制器"
  row "控制器" "$ctlname"
  row "驱动" "${drv:-$NA}"

  # 已配置的逻辑卷/阵列（软 RAID、LVM、DM）
  local vols=""
  vols=$(awk '/^md[0-9]+ *:/{print $1}' /proc/mdstat 2>/dev/null | tr '\n' ' ')
  local dm
  for dm in /sys/class/block/dm-*; do
    [ -e "$dm" ] || continue
    vols="${vols}$(basename "$dm") "
  done
  [ -n "$(echo "$vols" | tr -d ' ')" ] && row "逻辑卷" "$(echo "$vols" | sed 's/ *$//')"

  # 逐个 SAS/RAID HBA 读 sysfs 明细：型号、固件、BIOS、SAS 地址、下挂设备
  local h name fw bios prod sasaddr board ndev
  for h in /sys/class/scsi_host/host*/; do
    name=$(cat "$h/proc_name" 2>/dev/null) || continue
    case "$name" in
      mpt2sas|mpt3sas|megaraid_sas|aacraid|hpsa|smartpqi|mvsas|isci) ;;
      *) continue ;;
    esac

    fw=$(cat "$h/version_fw" 2>/dev/null)
    bios=$(cat "$h/version_bios" 2>/dev/null)
    prod=$(cat "$h/version_product" 2>/dev/null)
    sasaddr=$(cat "$h/host_sas_address" 2>/dev/null)
    board=$(cat "$h/board_name" 2>/dev/null)
    # 以实际块设备计数：SATA/SAS 端口空位也会建 target 目录，按目录数会虚报
    local devs
    devs=$(ls -d "$h"/device/target*/*/block/* 2>/dev/null | xargs -r -n1 basename 2>/dev/null | tr '\n' ' ')
    devs=$(echo "$devs" | sed 's/ *$//')
    ndev=$( [ -n "$devs" ] && echo "$devs" | wc -w || echo 0)

    add "│"
    add "│ ═══ $(basename "$h") ($name) ═══"
    [ -n "$prod" ]    && add "│   芯片: ${prod}"
    [ -n "$board" ]   && add "│   板卡: ${board}"
    [ -n "$fw" ]      && add "│   固件版本: ${fw}"
    [ -n "$bios" ]    && add "│   BIOS版本: ${bios}"
    if [ -n "$sasaddr" ]; then
      [ "$MASK" = 1 ] && sasaddr=$(mask_sas "$sasaddr")
      add "│   SAS地址: ${sasaddr}"
    fi
    add "│   下挂设备: ${ndev} 个"
    [ "$ndev" = 0 ] && add "│   （该卡当前未接任何磁盘/扩展器）"
    [ -n "$devs" ] && add "│   关联磁盘: ${devs}"

    # SAS PHY：每通道协商速率，未接线时 negotiated 为 Unknown
    local phys phy n_up=0 n_tot=0 rate maxr phy_max="" hid
    hid=$(basename "$h"); hid=${hid#host}                 # host0 -> 0
    phys=$(ls -d /sys/class/sas_phy/phy-${hid}:* 2>/dev/null)
    if [ -n "$phys" ]; then
      for phy in $phys; do
        n_tot=$((n_tot + 1))
        rate=$(cat "$phy/negotiated_linkrate" 2>/dev/null)
        maxr=$(cat "$phy/maximum_linkrate" 2>/dev/null)
        case "$rate" in
          Unknown|"") ;;
          *) n_up=$((n_up + 1)); [ -z "$maxr" ] || phy_max=$maxr ;;
        esac
      done
      if [ "$n_tot" -gt 0 ]; then
        if [ "$n_up" -gt 0 ]; then
          add "│   SAS通道: ${n_up}/${n_tot} 已连接（最高 ${phy_max:-$NA}）"
        else
          add "│   SAS通道: ${n_tot} 个，全部未连接"
        fi
      fi
    fi
  done
  block_close
}

# ───────────────────────────── 网卡 ─────────────────────────────

collect_net() {
  block_open "网卡信息"
  local found=0 i first=1 dev nic base bdf short model state mac eth speed duplex link rx tx

  for dev in /sys/class/net/*/device; do
    [ -e "$dev" ] || continue
    nic=$(basename "$(dirname "$dev")")
    found=1
    [ "$first" = 1 ] || add "│"
    first=0

    base=/sys/class/net/$nic
    bdf=$(basename "$(readlink -f "$base/device")")
    short=$(cut -d: -f2- <<<"$bdf")
    model=$(lspci -s "$short" 2>/dev/null | cut -d: -f3- | sed 's/^ //')
    [ -z "$model" ] && model="$NA"

    state=$(tr 'a-z' 'A-Z' <"$base/operstate" 2>/dev/null)
    mac=$(cat "$base/address" 2>/dev/null)
    [ "$MASK" = 1 ] && mac=$(mask_mac "$mac")

    eth=$(ethtool "$nic" 2>/dev/null)
    speed=$(awk -F': ' '/Speed:/{print $2; exit}' <<<"$eth" | sed 's/Mb\/s/ Mbps/')
    duplex=$(awk -F': ' '/Duplex:/{print $2; exit}' <<<"$eth" | tr 'A-Z' 'a-z')
    link=$(awk -F': ' '/Link detected:/{print $2; exit}' <<<"$eth")
    if [ -z "$link" ]; then
      link="$NA"                    # ethtool 缺失/不支持时不能断言网线状态
    elif [ "$link" = "yes" ]; then
      link="Yes"
    else
      link="No"
    fi
    if [ "$state" != "UP" ]; then     # 断链时 ethtool 回 Unknown!，归一化
      [[ $speed == Unknown* ]] && speed="$NA"
      [[ $duplex == unknown* ]] && duplex="$NA"
    fi

    rx=$(cat "$base/statistics/rx_bytes" 2>/dev/null)
    tx=$(cat "$base/statistics/tx_bytes" 2>/dev/null)

    add "│ ═══ ${nic} ═══"
    add "│   型号: ${model}"
    add "│   状态: ${state:-$NA}"
    add "│   MAC地址: ${mac:-$NA}"
    add "│   速度: ${speed:-$NA}"
    add "│   双工模式: ${duplex:-$NA}"
    add "│   链接检测: ${link}"
    add "│   RX: $( [ -n "$rx" ] && human "$rx" || echo "$NA")"
    add "│   TX: $( [ -n "$tx" ] && human "$tx" || echo "$NA")"
  done

  [ "$found" = 1 ] || add "│   (未检测到物理网卡)"
  block_close
}

# ───────────────────────────── 显卡 ─────────────────────────────

collect_gpu() {
  block_open "显卡信息"
  add "│"
  add "│ Graphics Cards (PCI):"
  local hit=0 l
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    hit=1
    add "│   ${l}"
  done < <(lspci 2>/dev/null | grep -Ei 'VGA|3D controller|Display controller')
  [ "$hit" = 1 ] || add "│   (未检测到)"

  add "│"
  add "│ Display Hardware Summary:"
  hit=0
  while IFS= read -r l; do            # 丢掉 lshw 的 "H/W path Device Class" 表头
    [ -z "$l" ] && continue
    hit=1
    add "│   ${l}"
  done < <(lshw -short -C display 2>/dev/null | tail -n +2)
  [ "$hit" = 1 ] || { [ -e /dev/fb0 ] && add "│   /dev/fb0" || add "│   (未检测到显示设备)"; }
  block_close
}

# ───────────────────────────── 主板 ─────────────────────────────

dmi() { local f=/sys/devices/virtual/dmi/id/$1 v; v=$(cat "$f" 2>/dev/null); v=${v%"${v##*[![:space:]]}"}; echo "${v:-$NA}"; }

collect_board() {
  block_open "主板信息"
  row "厂商" "$(dmi board_vendor)"
  row "型号" "$(dmi board_name)"
  row "Version" "$(dmi board_version)"
  row "BIOS Vendor" "$(dmi bios_vendor)"
  row "BIOS Version" "$(dmi bios_version)"
  block_close
}

# ───────────────────────────── 主流程 ─────────────────────────────

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  local STAMP=1 STDOUT_ONLY=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -o|--output)
        # 缺值或误跟其他选项都必须显式报错：否则 shift 2 失败会让参数不被消费而无限循环
        if [ $# -lt 2 ] || [ -z "${2:-}" ] || [ "${2#-}" != "$2" ]; then
          echo "错误: $1 需要指定输出路径（收到 '${2:-}'）" >&2; usage >&2; exit 2
        fi
        OUT=$2; shift 2 ;;
      --stdout)    STDOUT_ONLY=1; shift ;;
      --no-stamp)  STAMP=0; shift ;;
      --mask)      MASK=1; shift ;;
      --no-disk)   NO_DISK=1; shift ;;
      -h|--help)   usage; exit 0 ;;
      *)           echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
    esac
  done

  # 输出路径：默认写当前目录的 hwtest_report_<时间戳>.txt
  # 目录 -> hwtest_report_<时间戳>.txt；文件名 -> 追加 _<时间戳>
  # --no-stamp 可关闭，精确写入指定文件名
  if [ "$STDOUT_ONLY" = 0 ]; then
    local isdir=0 dir base ext
    [ -z "$OUT" ] && OUT="."                       # 未指定则用当前目录
    [ -d "$OUT" ] && isdir=1
    [ "${OUT%/}" != "$OUT" ] && isdir=1            # 尾随 / 视为目录（可自动创建）

    if [ "$isdir" = 1 ]; then
      dir=${OUT%/}; [ -z "$dir" ] && dir="."
      mkdir -p "$dir" || { echo "无法创建目录: $dir" >&2; exit 1; }
      OUT="${dir}/hwtest_report_$(date '+%Y%m%d-%H%M%S').txt"
    elif [ "$STAMP" = 1 ]; then
      dir=$(dirname "$OUT"); base=$(basename "$OUT")
      case "$base" in
        .*)  ext="" ;;                                   # 隐藏文件不加扩展名切分
        *.*) ext=".${base##*.}"; base="${base%.*}" ;;
        *)   ext="" ;;
      esac
      mkdir -p "$dir" || { echo "无法创建目录: $dir" >&2; exit 1; }
      OUT="${dir}/${base}_$(date '+%Y%m%d-%H%M%S')${ext}"
    fi
  fi

  collect_system
  collect_cpu
  collect_mem
  collect_disk
  collect_raid
  collect_net
  collect_gpu
  collect_board

  add "报告生成完成！"
  add "Generated on: $(date '+%a %b %d %I:%M:%S %p %Z %Y')"

  if [ -n "$OUT" ]; then
    # 先落盘再判断结果：tee 失败时不能谎报"已写入"
    if printf '%s\n' "${LINES[@]}" > "$OUT"; then
      printf '%s\n' "${LINES[@]}"
      echo "[已写入 $OUT]" >&2
    else
      printf '%s\n' "${LINES[@]}"                       # 落盘失败仍把报告交给屏幕
      echo "错误: 无法写入 $OUT（目录不存在或不可写）" >&2
      exit 1
    fi
  else
    printf '%s\n' "${LINES[@]}"      # --stdout：仅打印，不落盘
  fi
}

main "$@"
