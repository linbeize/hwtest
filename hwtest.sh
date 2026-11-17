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
NO_INSTALL=0
OUT=""

# ───────────────────────────── 基础工具 ─────────────────────────────

has() { command -v "$1" >/dev/null 2>&1; }

# 纯 bash 重复字符，避免每次 fork seq
rep() { local n=$1 s=$2 o=""; local i; for ((i = 0; i < n; i++)); do o+="$s"; done; printf '%s' "$o"; }

# 终端显示宽度：非 ASCII 字符按 2 列计（删掉 ASCII 后剩下的就是宽字符）
dwidth() {
  local s=$1 w
  w=${s//[ -~]/}
  printf '%s' $(( ${#s} + ${#w} ))
}

# 去掉首尾空白
trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }

REPORT=()
add() { local l; for l in "$@"; do REPORT+=("$l"); done; }

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

os_name() {
  local f
  for f in /etc/os-release /usr/lib/os-release; do
    [ -r "$f" ] && { sed -n 's/^PRETTY_NAME=//p' "$f" | tr -d '"'; return; }
  done
  uname -o 2>/dev/null || echo "$NA"
}

uptime_str() {                           # 与 uptime -p 同格式；精简系统（busybox/容器）无 -p 时自行计算
  uptime -p 2>/dev/null && return
  awk '{ s = int($1); d = int(s / 86400); h = int(s % 86400 / 3600); m = int(s % 3600 / 60)
         o = ""
         if (d) o = o d (d == 1 ? " day, " : " days, ")
         if (h) o = o h (h == 1 ? " hour, " : " hours, ")
         o = o m (m == 1 ? " minute" : " minutes")
         print "up " o }' /proc/uptime 2>/dev/null || echo "$NA"
}

collect_system() {
  local host=${HOSTNAME:-$(uname -n)}
  [ "$MASK" = 1 ] && host=$(mask_serial "$host")
  block_open "系统信息"
  row "主机名" "$host"
  row "操作系统" "$(os_name)"
  row "内核版本" "$(uname -r)"
  row "运行时间" "$(uptime_str)"
  block_close
}

# ───────────────────────────── 处理器 ─────────────────────────────

cpu_usage() {                            # 两次采样 /proc/stat 取差值
  local a b
  a=$(awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; print t, $5+$6; exit}' /proc/stat 2>/dev/null)
  sleep 0.5
  b=$(awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; print t, $5+$6; exit}' /proc/stat 2>/dev/null)
  [ -n "$a" ] && [ -n "$b" ] || { echo "$NA"; return; }
  awk -v a="$a" -v b="$b" 'BEGIN{
    split(a, A, " "); split(b, B, " ")
    dt = B[1] - A[1]; di = B[2] - A[2]
    printf "%.1f%%", (dt > 0) ? (dt - di) / dt * 100 : 0
  }'
}

cpu_cache() {                            # 优先 L3，退化 L2，统一换算成 KB
  # 兼容 "8 MiB (1 instance)"、"8192K"、"1.5 MiB" 等多种 lscpu 写法
  awk -F: '
    /^L[23] cache:/ {
      v = $2; gsub(/\(.*\)/, "", v); gsub(/ /, "", v)
      n = v + 0; u = v; sub(/^[0-9.]+/, "", u)
      if (u ~ /^M/) n *= 1024; else if (u ~ /^G/) n *= 1048576
      c[substr($1, 2, 1)] = n
    }
    END {
      n = ("3" in c) ? c["3"] : (("2" in c) ? c["2"] : 0)
      if (n > 0) printf "%d KB\n", n; else print "N/A"
    }' <<<"$LSCPU"
}

cpu_temp() {
  local t="" m=0 v z
  has sensors && t=$(sensors 2>/dev/null | awk '/^(Package id 0|Tdie|Tctl):/ && match($0, /[+-][0-9.]+°C/) {print substr($0, RSTART, RLENGTH); exit}')
  if [ -z "$t" ]; then
    for z in /sys/class/thermal/thermal_zone*/temp; do
      [ -r "$z" ] || continue
      v=$(<"$z") 2>/dev/null || continue
      [ "$v" -gt "$m" ] 2>/dev/null && m=$v
    done
    [ "$m" -gt 0 ] && t=$(awk -v x="$m" 'BEGIN{printf "+%.1f°C", x/1000}')
  fi
  echo "${t:-$NA}"
}

lscpu_get() { awk -F: -v k="$1" '$1 == k {sub(/^[ \t]+/, "", $2); print $2; exit}' <<<"$LSCPU"; }

collect_cpu() {
  local model cores threads mhz f
  LSCPU=$(lscpu 2>/dev/null)             # 只调用一次，后续都从缓存解析

  model=$(lscpu_get "Model name")
  [ -z "$model" ] && model=$(awk -F: '/^model name/{sub(/^ +/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)

  # 物理核心 = 去重后的 (core, socket) 组合；比 "Core(s) per socket" 更通用（ARM/混合架构）
  cores=$(lscpu -p=core,socket 2>/dev/null | grep -v '^#' | sort -u | grep -c .)
  if [ "${cores:-0}" -eq 0 ]; then
    local cps sk
    cps=$(lscpu_get "Core(s) per socket"); sk=$(lscpu_get "Socket(s)")
    if [[ $cps =~ ^[0-9]+$ && $sk =~ ^[0-9]+$ ]]; then cores=$((cps * sk)); else cores=$NA; fi
  fi
  threads=$(nproc --all 2>/dev/null || grep -c ^processor /proc/cpuinfo)

  mhz=$(awk -F: '/^cpu MHz/{gsub(/^ +/,"",$2); printf "%.3f MHz", $2; exit}' /proc/cpuinfo 2>/dev/null)
  if [ -z "$mhz" ]; then                 # ARM 等平台 /proc/cpuinfo 无 MHz，退回 cpufreq / lscpu
    f=/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
    if [ -r "$f" ]; then
      mhz=$(awk '{printf "%.3f MHz", $1 / 1000}' "$f")
    else
      f=$(lscpu_get "CPU max MHz")
      [ -n "$f" ] && mhz=$(awk -v x="$f" 'BEGIN{printf "%.3f MHz", x}')
    fi
  fi

  block_open "处理器信息"
  row "型号" "${model:-$NA}"
  row "核心数" "$cores"
  row "线程数" "${threads:-$NA}"
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
  # 一次读完 meminfo；内核 < 3.14 没有 MemAvailable，退化为 MemFree + Buffers + Cached
  read -r tot used avail < <(awk '
    { m[$1] = $2 }
    END {
      a = ("MemAvailable:" in m) ? m["MemAvailable:"] : m["MemFree:"] + m["Buffers:"] + m["Cached:"]
      printf "%.2f %.2f %.2f\n", m["MemTotal:"] / 1048576, (m["MemTotal:"] - a) / 1048576, a / 1048576
    }' /proc/meminfo 2>/dev/null)

  block_open "内存信息"
  row "总计" "${tot} GB"
  row "已用" "${used} GB"
  row "可用" "${avail} GB"

  if [ "$(id -u)" != "0" ]; then
    row "内存插槽" "无法读取（dmidecode 需要 root）"
  elif ! has dmidecode; then
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
    | awk '$2=="disk" && $1 !~ /^(loop|ram|zram|sr|md|dm-|nbd|rbd|zd)/ {print "/dev/"$1}'
}

smart_fail_reason() {                    # $1=smartctl 输出 $2=退出码 -> 人类可读原因
  local out=$1 rc=$2
  if grep -qi "Permission denied" <<<"$out"; then
    echo "权限不足，需要 root 运行"
  elif grep -qi "No such device\|No such file" <<<"$out"; then
    echo "设备不存在或已移除"
  elif grep -qiE "please specify device type|try adding -d|device type.*required" <<<"$out"; then
    echo "需要指定设备类型（如 -d sat / -d megaraid,N）"
  elif grep -qi "Unknown USB bridge\|unsupported" <<<"$out"; then
    echo "SMART 通过该桥接设备不可用"
  else
    echo "无法读取（smartctl 退出码 $rc）"
  fi
}

# "Key:   1,234,567 [632 GB]" -> 1234567（取冒号后第一个数字，去千分位）
smart_num() { awk -F: -v k="$1" 'index($0, k) == 1 { v = $2; gsub(/,/, "", v); if (match(v, /[0-9]+/)) print substr(v, RSTART, RLENGTH); exit }' <<<"$2"; }

smart_snapshot() {
  local dev=$1 basic health poh rd wr temp realloc pending uncorr serial fw
  basic=$(lsblk -dno SIZE,MODEL,TRAN "$dev" 2>/dev/null | tr -s ' ' | sed 's/ sata$/ ATA/; s/^ //')

  # 只调用一次 smartctl 并保留 stderr 与退出码：失败时必须说明原因，
  # 否则一排 N/A 会让人误以为磁盘本身不支持 SMART。
  # 注意：不用空数组展开 "${arr[@]}"，bash < 4.4 在 set -u 下会报 unbound variable
  local raw rc
  if [[ $dev == /dev/nvme* ]]; then
    raw=$(smartctl -a -d nvme "$dev" 2>&1)
  else
    raw=$(smartctl -a "$dev" 2>&1)
  fi
  rc=$?

  # 退出码非 0 且没有拿到任何设备标识，视为整体失败
  if [ $rc -ne 0 ] && ! grep -qiE "^(Serial Number|Device Model|Model Number|Product):" <<<"$raw"; then
    add "│   Basic Info:  ${basic:-$NA}"
    add "│   SMART状态: ${NA}"
    add "│   失败原因: $(smart_fail_reason "$raw" "$rc")"
    return
  fi

  health=$(awk -F': ' '/self-assessment test result/{print $2; exit}
                         /SMART Health Status/{print $2; exit}' <<<"$raw")
  serial=$(sed -n 's/^Serial [Nn]umber: *//p' <<<"$raw" | head -1)
  fw=$(sed -n 's/^Firmware Version: *//p' <<<"$raw" | head -1)

  if grep -q "^Data Units Read" <<<"$raw"; then
    # NVMe：1 data unit = 1000 个 512B 扇区
    local du dwu
    du=$(smart_num "Data Units Read" "$raw")
    dwu=$(smart_num "Data Units Written" "$raw")
    [ -n "$du" ]  && rd=$(lba_human "${du}000")
    [ -n "$dwu" ] && wr=$(lba_human "${dwu}000")
    poh=$(smart_num "Power On Hours" "$raw")
    temp=$(smart_num "Temperature:" "$raw")
    # NVMe 没有扇区重映射概念，只有介质错误计数
    uncorr=$(smart_num "Media and Data Integrity Errors" "$raw")
  else
    # ATA 属性表：ID NAME FLAG VALUE WORST THRESH TYPE UPDATED WHEN_FAILED RAW_VALUE
    # RAW_VALUE 可能是 "35 (Min/Max 20/45)" 或 "12345h+00m"，只取开头数字
    local attrs
    attrs=$(awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[A-Za-z]/ && NF >= 10 {v = $10; sub(/[^0-9].*/, "", v); print $1, v}' <<<"$raw")
    attr_get() { awk -v k="$1" '$1 == k && $2 != "" {print $2; exit}' <<<"$attrs"; }

    poh=$(attr_get 9)
    rd=$(attr_get 242); [ -n "$rd" ] && rd=$(lba_human "$rd")
    wr=$(attr_get 241); [ -n "$wr" ] && wr=$(lba_human "$wr")
    temp=$(attr_get 194); [ -z "$temp" ] && temp=$(attr_get 190)
    realloc=$(attr_get 5)
    pending=$(attr_get 197)
    uncorr=$(attr_get 187)

    # SAS 盘没有 ATA 属性表，用 SCSI 日志页字段兜底
    [ -z "$temp" ] && temp=$(smart_num "Current Drive Temperature" "$raw")
    [ -z "$poh" ] && poh=$(awk -F'= *' '/number of hours powered up/ {printf "%d", $2; exit}' <<<"$raw")
  fi
  [ -n "$poh" ]  && poh="${poh} hours"
  [ -n "$temp" ] && temp="${temp}°C"

  add "│   Basic Info:  ${basic:-$NA}"
  if [ "$MASK" = 1 ]; then
    add "│   序列号: $(mask_serial "$serial")"
  else
    add "│   序列号: ${serial:-$NA}"
    add "│   固件: ${fw:-$NA}"
  fi
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
  # -P 防止长设备名折行；再用 awk 统一列宽，避免 ZFS 数据集等长名字把表格挤歪
  local l
  while IFS= read -r l; do add "│ ${l}"; done < <(
    df -hP -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | awk '
      { n++; for (i = 1; i <= 6; i++) { c[n, i] = $i; if (length($i) > w[i]) w[i] = length($i) }
        for (i = 7; i <= NF; i++) c[n, 6] = c[n, 6] " " $i }      # 挂载点含空格
      END { for (j = 1; j <= n; j++)
              printf "%-*s %*s %*s %*s %*s %s\n", w[1], c[j,1], w[2], c[j,2], w[3], c[j,3], w[4], c[j,4], w[5], c[j,5], c[j,6] }')

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
    elif ! has smartctl; then
      add "│   Basic Info:  $(lsblk -dno SIZE,MODEL "$dev" 2>/dev/null | tr -s ' ' | sed 's/^ //')"
      add "│   SMART状态: ${NA}（未安装 smartmontools）"
    else
      smart_snapshot "$dev"
    fi
  done <<<"$disks"
  block_close
}

# ───────────────────────────── RAID 控制器 ─────────────────────────────

collect_raid() {
  block_open "RAID控制器信息"
  local l found=0

  # 软 RAID（mdadm）
  if [ -r /proc/mdstat ]; then
    while IFS= read -r l; do found=1; row "软RAID" "$l"; done \
      < <(awk '/^md[0-9]+ *:/{sub(/ *$/, ""); print}' /proc/mdstat)
  fi

  # 硬件存储控制器（lspci 类别 0104=RAID, 0107=SAS；缩进行从属于上一行）
  local name drv
  while IFS='|' read -r name drv; do
    [ -z "$name" ] && continue
    found=1
    row "控制器" "$name"
    row "驱动" "${drv:-$NA}"
  done < <(lspci -nnk 2>/dev/null | awk '
    function flush() { if (name != "") print name "|" d; name = d = "" }
    !/^\t/ { flush() }
    /\[0104\]|\[0107\]/ && !/^\t/ {
      name = $0; sub(/^[^ ]+ [^:]*: /, "", name)
      sub(/ \[[0-9a-f]{4}:[0-9a-f]{4}\].*/, "", name)
      next
    }
    name != "" && /Kernel driver in use:/ { d = $0; sub(/.*: /, "", d) }
    END { flush() }
  ')

  # 已配置的 device-mapper 卷（LVM / dm-crypt 等），优先显示友好名
  local dm vols=""
  for dm in /sys/class/block/dm-*; do
    [ -e "$dm" ] || continue
    l=$(cat "$dm/dm/name" 2>/dev/null)
    vols+="${l:-$(basename "$dm")} "
  done
  [ -n "$vols" ] && row "逻辑卷" "${vols% }"

  [ "$found" = 1 ] || row "状态" "未检测到"

  # 逐个 SAS/RAID HBA 读 sysfs 明细：型号、固件、BIOS、SAS 地址、下挂设备
  local h name fw bios prod sasaddr board ndev
  for h in /sys/class/scsi_host/host*/; do
    name=$(cat "${h}proc_name" 2>/dev/null) || continue
    case "$name" in
      mpt2sas|mpt3sas|megaraid_sas|aacraid|hpsa|smartpqi|mvsas|isci) ;;
      *) continue ;;
    esac

    fw=$(cat "${h}version_fw" 2>/dev/null)
    bios=$(cat "${h}version_bios" 2>/dev/null)
    prod=$(cat "${h}version_product" 2>/dev/null)
    sasaddr=$(cat "${h}host_sas_address" 2>/dev/null)
    board=$(cat "${h}board_name" 2>/dev/null)
    # 以实际块设备计数：SATA/SAS 端口空位也会建 target 目录，按目录数会虚报
    local devs="" b
    ndev=0
    for b in "$h"device/target*/*/block/*; do
      [ -e "$b" ] || continue
      devs+="${b##*/} "; ndev=$((ndev + 1))
    done
    devs=${devs% }

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
  local found=0 first=1 dev nic base bdf model state mac eth speed duplex link rx tx

  for dev in /sys/class/net/*/device; do
    [ -e "$dev" ] || continue
    nic=$(basename "$(dirname "$dev")")
    found=1
    [ "$first" = 1 ] || add "│"
    first=0

    base=/sys/class/net/$nic
    # virtio 等网卡的 device 指向 virtioN，其父目录才是 PCI 设备；保留 PCI domain
    bdf=$(readlink -f "$base/device")
    [[ ${bdf##*/} =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] || bdf=${bdf%/*}
    bdf=${bdf##*/}
    model=$(lspci -s "$bdf" 2>/dev/null | sed 's/^[^ ]* [^:]*: //')
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

dmi() { local v; v=$(trim "$(cat "/sys/devices/virtual/dmi/id/$1" 2>/dev/null)"); echo "${v:-$NA}"; }

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

# ───────────────────────────── 依赖安装 ─────────────────────────────

# 命令 -> 包名（各发行版包名不同）；$1=包管理器 $2=命令
dep_pkg() {
  case "$2" in
    lscpu|lsblk) [ "$1" = apk ] && echo "util-linux-misc lsblk" || echo util-linux ;;
    lspci)       echo pciutils ;;
    smartctl)    echo smartmontools ;;
    sensors)
      case "$1" in
        apt|apk)       echo lm-sensors ;;
        zypper)        echo sensors ;;
        *)             echo lm_sensors ;;
      esac ;;
    *)           echo "$2" ;;          # dmidecode lshw ethtool 各发行版同名
  esac
}

# 缺失的依赖自动安装；失败只警告不中断（报告里对应项降级为 N/A）
ensure_deps() {
  local cmds=(lscpu lsblk lspci dmidecode lshw smartctl sensors ethtool)
  local missing=() c pm pkgs=() p
  for c in "${cmds[@]}"; do has "$c" || missing+=("$c"); done
  [ ${#missing[@]} -eq 0 ] && return 0

  if [ "$(id -u)" != 0 ]; then
    echo "[提示] 缺少命令: ${missing[*]}；用 root 运行可自动安装" >&2
    return 0
  fi

  for pm in apt-get dnf yum zypper pacman apk; do has "$pm" && break; pm=""; done
  if [ -z "$pm" ]; then
    echo "[提示] 缺少命令: ${missing[*]}；未识别包管理器，请手动安装" >&2
    return 0
  fi
  [ "$pm" = apt-get ] && pm=apt

  for c in "${missing[@]}"; do
    for p in $(dep_pkg "$pm" "$c"); do
      [[ " ${pkgs[*]-} " == *" $p "* ]] || pkgs+=("$p")
    done
  done
  echo "[安装依赖] ${pkgs[*]} （${pm}）..." >&2

  # 安装命令一律 </dev/null：curl | bash 时脚本本身就在 stdin 上，
  # 包管理器若读 stdin 会把剩余脚本吃掉
  pm_install() {
    case "$pm" in
      apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" ;;
      dnf)    dnf install -y -q "$@" ;;
      yum)    yum install -y -q "$@" ;;
      zypper) zypper -n -q install "$@" ;;
      pacman) pacman -S --noconfirm --needed "$@" ;;
      apk)    apk add -q "$@" ;;
    esac </dev/null >/dev/null 2>&1
  }

  # apt 软件源索引可能从未更新过（新装系统 / 容器）
  [ "$pm" = apt ] && apt-get update -qq </dev/null >/dev/null 2>&1
  [ "$pm" = apk ] && apk update -q </dev/null >/dev/null 2>&1

  # 先整体装；失败（某个包在该发行版源里不存在）再逐个装，避免一个包拖垮全部
  if ! pm_install "${pkgs[@]}"; then
    for p in "${pkgs[@]}"; do
      pm_install "$p" || echo "[安装依赖] $p 安装失败，相关项将显示 N/A" >&2
    done
  fi
  hash -r

  missing=()
  for c in "${cmds[@]}"; do has "$c" || missing+=("$c"); done
  if [ ${#missing[@]} -eq 0 ]; then
    echo "[安装依赖] 完成" >&2
  else
    echo "[安装依赖] 仍缺少: ${missing[*]}" >&2
  fi
}

# 不读 "$0" 解析注释：curl | bash 管道执行时 $0 是 "bash"，那样会拿不到帮助
usage() {
  cat <<'EOF'
hwtest.sh —— Linux 硬件信息采集报告

用法:
  ./hwtest.sh                        # 默认保存 hwtest_report_<时间戳>.txt 并打印
  ./hwtest.sh -o hw.txt              # 保存 hw_<时间戳>.txt
  ./hwtest.sh -o out/                # 保存到 out/hwtest_report_<时间戳>.txt
  ./hwtest.sh -o hw.txt --no-stamp   # 精确写入 hw.txt（不加时间戳）
  ./hwtest.sh --stdout               # 只打印到屏幕，不写文件
  ./hwtest.sh --mask                 # 脱敏主机名/MAC/磁盘与内存序列号
  ./hwtest.sh --no-disk              # 跳过 SMART 采集（快速模式）
  ./hwtest.sh --no-install           # 不自动安装缺失的依赖

一键运行:
  curl -fsSL https://raw.githubusercontent.com/linbeize/hwtest/main/hwtest.sh | sudo bash
  curl -fsSL https://raw.githubusercontent.com/linbeize/hwtest/main/hwtest.sh | sudo bash -s -- --mask

依赖命令: lscpu dmidecode lshw smartctl sensors df lsblk ethtool lspci
以 root 运行时会自动安装缺失的依赖（apt/dnf/yum/zypper/pacman/apk），--no-install 可关闭。
内存条明细与 SMART 需要 root；非 root 自动降级为提示文字，不中断。
EOF
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
      --no-install) NO_INSTALL=1; shift ;;
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

  [ "$NO_INSTALL" = 1 ] || ensure_deps

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
    if printf '%s\n' "${REPORT[@]}" > "$OUT"; then
      printf '%s\n' "${REPORT[@]}"
      echo "[已写入 $OUT]" >&2
    else
      printf '%s\n' "${REPORT[@]}"                       # 落盘失败仍把报告交给屏幕
      echo "错误: 无法写入 $OUT（目录不存在或不可写）" >&2
      exit 1
    fi
  else
    printf '%s\n' "${REPORT[@]}"      # --stdout：仅打印，不落盘
  fi
}

main "$@"
