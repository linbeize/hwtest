#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""hwtest.py —— Linux 硬件信息采集报告

按「┌─ 分块 + 中文标签 20 列对齐」格式输出硬件快照。

用法:
    python3 hwtest.py                 # 打印报告
    python3 hwtest.py -o hw.txt       # 打印并写入文件
    python3 hwtest.py --mask          # 脱敏 MAC 地址与磁盘序列号
    python3 hwtest.py --no-disk       # 跳过 SMART 采集（快速模式）

系统命令依赖（缺哪个就降级为 N/A，不中断）:
    lscpu dmidecode lshw smartctl sensors df lsblk ethtool lspci
内存条 / SMART 明细需要 root；非 root 自动降级。
"""

import argparse
import glob
import os
import re
import shutil
import socket
import subprocess
import sys
import unicodedata
from datetime import datetime

LABEL_W = 20                       # 标签列宽（终端显示宽度）
CLOSE = "└" + "─" * 50             # 分块闭合线
NA = "N/A"


# ───────────────────────────── 基础设施 ─────────────────────────────

def dw(s):
    """字符串的终端显示宽度：全角字符占 2 列。"""
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def pad(s, w):
    return s + " " * max(0, w - dw(s))


def sh_rc(cmd, timeout=25):
    """执行命令并合并 stderr，返回 (输出, 退出码)。不抛异常。"""
    try:
        p = subprocess.run(
            cmd, shell=True, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, errors="replace", timeout=timeout,
        )
        return (p.stdout or ""), p.returncode
    except Exception:
        return "", 127


def sh(cmd, timeout=25):
    """执行命令并合并 stderr，失败返回空串（不抛异常）。"""
    return sh_rc(cmd, timeout)[0]


def row(label, value):
    return "│ " + pad(label, LABEL_W) + ": " + str(value)


def block(title, body):
    return ["┌─ " + title, "├" + "─" * (len(title) + 2)] + body + [CLOSE]


def safe(fn, *a, **kw):
    """单块采集失败不影响整篇报告。"""
    try:
        return fn(*a, **kw)
    except Exception as exc:
        return ["│ [采集异常] " + str(exc), CLOSE]


def human(n, base=1024):
    """字节数格式化为人类可读，保留 2 位小数。"""
    try:
        n = float(n)
    except (TypeError, ValueError):
        return NA
    for unit in ("B", "KB", "MB", "GB", "TB", "PB"):
        if n < base or unit == "PB":
            return "%.2f %s" % (n, unit)
        n /= base


def mask_mac(mac):
    p = mac.split(":")
    return ":".join(p[:3] + ["XX"] * (len(p) - 3)) if len(p) == 6 else mac


def mask_serial(s):
    """保留前 4 位便于比对，其余打星；短串（如主机名）保留首位。"""
    if not s or s == NA:
        return s
    if len(s) <= 4:
        return s[:1] + "*" * (len(s) - 1)
    return s[:4] + "*" * (len(s) - 4)


def read_file(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


# ───────────────────────────── 系统信息 ─────────────────────────────

def collect_system(mask=False):
    os_name = ""
    for ln in read_file("/etc/os-release").splitlines():
        if ln.startswith("PRETTY_NAME="):
            os_name = ln.split("=", 1)[1].strip().strip('"')
    if not os_name:
        os_name = sh("uname -s").strip()
    host = socket.gethostname()
    return block("系统信息", [
        row("主机名", mask_serial(host) if mask else host),
        row("操作系统", os_name or NA),
        row("内核版本", sh("uname -r").strip() or NA),
        row("运行时间", sh("uptime -p").strip() or NA),
    ])


# ───────────────────────────── 处理器 ─────────────────────────────

def cpu_usage(sample=0.5):
    """两次采样 /proc/stat 求平均使用率。"""
    def snap():
        parts = read_file("/proc/stat").splitlines()[0].split()[1:]
        v = [int(x) for x in parts]
        idle = v[3] + (v[4] if len(v) > 4 else 0)
        return sum(v), idle
    t1, i1 = snap()
    import time as _t
    _t.sleep(sample)
    t2, i2 = snap()
    dt, di = t2 - t1, i2 - i1
    return (dt - di) / dt * 100.0 if dt > 0 else 0.0


def cpu_temp():
    """优先 coretemp 的 Package id 0，其次 thermal_zone 最大值。"""
    for ln in sh("sensors").splitlines():
        if ln.strip().startswith("Package id 0:"):
            m = re.search(r"[-+]?\d+\.\d+°C", ln)
            if m:
                return m.group(0)
    temps = []
    for z in glob.glob("/sys/class/thermal/thermal_zone*/temp"):
        v = read_file(z)
        if v.isdigit():
            temps.append(int(v) / 1000.0)
    return "+%.1f°C" % max(temps) if temps else NA


def cache_kb():
    """从 sysfs 读 L3 缓存（KB），退化到 L2。"""
    for idx in (3, 2, 1):
        s = read_file("/sys/devices/system/cpu/cpu0/cache/index%d/size" % idx)
        m = re.match(r"(\d+)\s*([KMG]?)", s)
        if m:
            n = int(m.group(1))
            return n * {"": 1, "K": 1, "M": 1024, "G": 1024 * 1024}[m.group(2).upper() or "K"]
    return None


def collect_cpu():
    model = ""
    for ln in sh("lscpu").splitlines():
        if ln.startswith("Model name:"):
            model = ln.split(":", 1)[1].strip()
    if not model:
        m = re.search(r"^model name\s*:\s*(.+)$", read_file("/proc/cpuinfo"), re.M)
        model = m.group(1).strip() if m else NA

    cores = sockets = None
    for ln in sh("lscpu").splitlines():
        if ln.startswith("Core(s) per socket:"):
            cores = int(re.search(r"\d+", ln).group())
        elif ln.startswith("Socket(s):"):
            sockets = int(re.search(r"\d+", ln).group())
    total_cores = cores * sockets if cores and sockets else (os.cpu_count() or 0)

    mhz = ""
    m = re.search(r"^cpu MHz\s*:\s*([\d.]+)", read_file("/proc/cpuinfo"), re.M)
    if m:
        mhz = "%.3f MHz" % float(m.group(1))

    kb = cache_kb()

    return block("处理器信息", [
        row("型号", model),
        row("核心数", total_cores or NA),
        row("线程数", os.cpu_count() or NA),
        row("频率", mhz or NA),
        row("缓存", ("%d KB" % kb) if kb else NA),
        row("使用率", "%.1f%%" % cpu_usage()),
        row("CPU温度", cpu_temp()),
    ])


# ───────────────────────────── 内存 ─────────────────────────────

def mem_modules():
    """解析 dmidecode -t 17。无权限返回 None，无内存条返回 []。"""
    out = sh("dmidecode -t 17")
    if "Memory Device" not in out:
        return None          # 无权限或未安装 dmidecode，均归为不可读
    mods, cur = [], None
    for ln in out.splitlines():
        s = ln.strip()
        if s.startswith("Memory Device"):
            if cur:
                mods.append(cur)
            cur = {}
        elif ":" in s and cur is not None:
            k, v = s.split(":", 1)
            cur[k.strip()] = v.strip()
    if cur:
        mods.append(cur)

    result = []
    for m in mods:
        if m.get("Size", "No Module Installed") in ("No Module Installed", "0 MB"):
            continue
        result.append({
            "size": m.get("Size", NA),
            "type": m.get("Type", NA),
            "speed": m.get("Speed", NA),
            "mfr": m.get("Manufacturer", NA),
            "serial": m.get("Serial Number", NA),
            "part": m.get("Part Number", NA).strip(),
        })
    return result


def render_table(headers, rows):
    cols = len(headers)
    widths = [max([dw(headers[i])] + [dw(r[i]) for r in rows]) for i in range(cols)]

    def mk(cells):
        return "│ " + " │ ".join(pad(c, widths[i]) for i, c in enumerate(cells)) + " │"

    rule = dw(mk(headers)) - 2
    out = ["├" + "─" * rule + "┤", mk(headers), "├" + "─" * rule + "┤"]
    out += [mk(r) for r in rows]
    out.append("└" + "─" * rule + "┘")
    return out


def collect_mem(mask=False):
    info = {}
    for ln in read_file("/proc/meminfo").splitlines():
        if ":" in ln:
            k, v = ln.split(":", 1)
            parts = v.split()
            if parts and parts[0].isdigit():
                info[k.strip()] = int(parts[0])       # kB
    total = info.get("MemTotal", 0) / 1048576.0
    avail = info.get("MemAvailable", 0) / 1048576.0

    body = [
        row("总计", "%.2f GB" % total),
        row("已用", "%.2f GB" % (total - avail)),
        row("可用", "%.2f GB" % avail),
    ]

    mods = mem_modules()
    if mods:                      # 仅在拿到真实内存条时展开表格
        body += [
            row("内存插槽", "%d 条已安装" % len(mods)),
            "│",
            "│ Memory Modules:",
        ]
        body += render_table(
            ["大小", "类型", "频率", "制造商", "序列号", "型号"],
            [[m["size"], m["type"], m["speed"], m["mfr"],
              mask_serial(m["serial"]) if mask else m["serial"], m["part"]] for m in mods],
        )
    else:
        reason = "需要 root" if os.geteuid() != 0 else "未安装 dmidecode"
        body.append(row("内存插槽", "无法读取（%s）" % reason if mods is None
                        else "未检测到已安装内存条"))
    return block("内存信息", body)


# ───────────────────────────── 硬盘 ─────────────────────────────

def physical_disks():
    out = []
    for d in sorted(os.listdir("/sys/block")):
        if re.match(r"^(loop|ram|zram|dm-|md|sr|fd|nbd|rbd|nvme-fabrics)", d):
            continue
        out.append("/dev/" + d)
    return out


def smart_fail_reason(raw, rc):
    """把 smartctl 的失败输出翻译成可操作的原因。"""
    low = (raw or "").lower()
    if "permission denied" in low:
        return "权限不足，需要 root 运行"
    if "no such device" in low or "no such file" in low:
        return "设备不存在或已移除"
    if "please specify device type" in low or "try adding -d" in low:
        return "需要指定设备类型（如 -d sat / -d megaraid,N）"
    if "unknown usb bridge" in low or "unsupported" in low:
        return "SMART 通过该桥接设备不可用"
    if rc == 127 or "command not found" in low:
        return "未安装 smartmontools"
    return "无法读取（smartctl 退出码 %s）" % rc


def smart_snapshot(dev, mask):
    """返回 (basic, health, poh, read, write, temp, realloc, pending, uncorr, serial, fw)。

    整体失败时返回 (basic, NA, 失败原因字符串, ...)，由调用方决定如何展示。
    """
    basic = sh("lsblk -dno SIZE,MODEL,TRAN %s" % dev).strip()
    basic = re.sub(r"\s+", " ", basic).replace(" sata", " ATA").strip()

    args = "-d nvme " if dev.startswith("/dev/nvme") else ""
    raw, rc = sh_rc("smartctl -a %s %s" % (args, dev), timeout=30)

    # 判定整体失败：命令不可用/退出码非 0，且没拿到任何设备标识
    has_id = bool(re.search(r"Serial Number:|Device Model:|Model Number:", raw))
    if rc != 0 and not has_id:
        return (basic or NA, NA, smart_fail_reason(raw, rc),
                NA, NA, NA, NA, NA, NA, NA, NA)

    serial = re.search(r"Serial Number:\s*(.+)", raw)
    fw = re.search(r"Firmware Version:\s*(.+)", raw)
    serial = serial.group(1).strip() if serial else NA
    fw = fw.group(1).strip() if fw else NA

    health = NA
    m = re.search(r"self-assessment test result:\s*(.+)", raw)
    if m:
        health = m.group(1).strip()
    else:
        m = re.search(r"SMART Health Status:\s*(.+)", raw)   # SCSI 风格
        if m:
            health = m.group(1).strip()

    # ATA 属性表：ID NAME FLAG VALUE WORST THRESH TYPE UPDATED WHEN_FAILED RAW
    # 例: 194 Temperature_Celsius 0x0022 071 059 000 Old_age Always - 29 (Min/Max 18/41)
    attrs = {}
    for ln in raw.splitlines():
        m = re.match(
            r"\s*(\d+)\s+(\S+)\s+0x[0-9a-fA-F]+\s+(\d+)\s+(\d+)\s+(\d+)\s+"
            r"(\S+)\s+(\S+)\s+(\S+)\s+(\S+)", ln)
        if m:
            attrs[int(m.group(1))] = m.group(9)   # RAW_VALUE 首 token

    def g(k, fallback=NA):
        return attrs.get(k, fallback)

    temp = g(194)
    if temp == NA:
        temp = g(190)
    temp = ("%s°C" % temp) if temp != NA else NA

    # LBA 单位按 512 字节
    def lba(k):
        v = attrs.get(k)
        if v is None or not v.isdigit():
            return NA
        return human(int(v) * 512)

    if not attrs:   # NVMe 分支
        def pick(pat):
            m = re.search(pat, raw)
            return m.group(1).strip() if m else NA
        poh = pick(r"Power On Hours:\s*([\d,]+)").replace(",", "")
        temp = pick(r"Temperature:\s*(\d+)")
        temp = ("%s°C" % temp) if temp != NA else NA
        du = re.search(r"Data Units Read:\s*([\d,]+)", raw)
        dw_ = re.search(r"Data Units Written:\s*([\d,]+)", raw)
        return (
            basic or NA, health,
            ("%s hours" % poh) if poh != NA else NA,
            human(int(du.group(1).replace(",", "")) * 512000) if du else NA,
            human(int(dw_.group(1).replace(",", "")) * 512000) if dw_ else NA,
            temp,
            pick(r"Media and Data Integrity Errors:\s*([\d,]+)"),
            pick(r"Media and Data Integrity Errors:\s*([\d,]+)"),
            pick(r"Media and Data Integrity Errors:\s*([\d,]+)"),
            serial, fw,
        )

    poh = g(9)
    return (
        basic or NA, health,
        ("%s hours" % poh) if poh != NA else NA,
        lba(242), lba(241), temp,
        g(5), g(197), g(187),
        mask_serial(serial) if mask else serial, fw,
    )


def collect_disk(no_disk, mask):
    body = []
    dfout = sh("df -h -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs")
    for ln in dfout.splitlines()[1:]:
        if ln.strip():
            body.append("│ " + ln.rstrip())

    body += ["│", "│ Physical Disks Details:"]
    disks = physical_disks()
    show_fw = not mask
    if not disks:
        body.append("│   (未检测到物理磁盘)")
        return block("硬盘信息", body)

    for dev in disks:
        body.append("│")
        body.append("│ ═══ %s ═══" % dev)
        if no_disk:
            info = sh("lsblk -dno SIZE,MODEL %s" % dev).strip()
            body.append("│   Basic Info:  " + (re.sub(r"\s+", " ", info) or NA))
            body.append("│   (--no-disk：已跳过 SMART 采集)")
            continue
        basic, health, poh, rd, wr, temp, realloc, pending, uncorr, serial, fw = smart_snapshot(dev, mask)
        body.append("│   Basic Info:  " + str(basic))
        if health == NA and serial == NA and poh != NA:
            # 整体读取失败：poh 位置携带的是失败原因
            body.append("│   SMART状态: " + NA)
            body.append("│   失败原因: " + str(poh))
            continue
        body.append("│   序列号: " + str(serial))
        if show_fw:
            body.append("│   固件: " + str(fw))
        body.append("│   SMART状态: " + str(health))
        body.append("│   通电时间: " + str(poh))
        body.append("│   总读取量: " + str(rd))
        body.append("│   总写入量: " + str(wr))
        body.append("│   温度: " + str(temp))
        body.append("│   重映射扇区: " + str(realloc))
        body.append("│   待处理扇区: " + str(pending))
        body.append("│   报告的不可校正: " + str(uncorr))
    return block("硬盘信息", body)


# ───────────────────────────── RAID 控制器 ─────────────────────────────

def mask_sas(s):
    """SAS WWN：保留 OUI 前缀六位十六进制，其余置 0。"""
    if not s or s == NA or len(s) < 8:
        return s
    return "0x" + s[2:8] + "0" * (len(s) - 8)


def raid_hba_detail(mask=False):
    """枚举 SAS/RAID HBA，返回 sysfs 可读的明细行。"""
    out = []
    drivers = ("mpt2sas", "mpt3sas", "megaraid_sas", "aacraid",
               "hpsa", "smartpqi", "mvsas", "isci")
    for host in sorted(glob.glob("/sys/class/scsi_host/host*")):
        name = read_file(os.path.join(host, "proc_name"))
        if name not in drivers:
            continue

        def attr(f):
            return read_file(os.path.join(host, f))

        # 以实际块设备计数：端口空位也会建 target 目录，按目录数会虚报
        devs = [os.path.basename(d.rstrip("/"))
                for d in glob.glob(os.path.join(host, "device/target*/*/block/*"))]

        out.append("│")
        out.append("│ ═══ %s (%s) ═══" % (os.path.basename(host), name))
        sas = attr("host_sas_address")
        for label, val in (("芯片", attr("version_product")),
                           ("板卡", attr("board_name")),
                           ("固件版本", attr("version_fw")),
                           ("BIOS版本", attr("version_bios")),
                           ("SAS地址", mask_sas(sas) if mask else sas)):
            if val:
                out.append("│   %s: %s" % (label, val))
        out.append("│   下挂设备: %d 个" % len(devs))
        if not devs:
            out.append("│   （该卡当前未接任何磁盘/扩展器）")
        else:
            out.append("│   关联磁盘: " + " ".join(devs))

        # SAS PHY：未接线时 negotiated 为 Unknown
        hid = os.path.basename(host).replace("host", "")
        phys = sorted(glob.glob("/sys/class/sas_phy/phy-%s:*" % hid))
        if phys:
            up, phy_max = 0, ""
            for p in phys:
                rate = read_file(os.path.join(p, "negotiated_linkrate"))
                if rate and rate != "Unknown":
                    up += 1
                    phy_max = read_file(os.path.join(p, "maximum_linkrate")) or phy_max
            if up:
                out.append("│   SAS通道: %d/%d 已连接（最高 %s）" % (up, len(phys), phy_max or NA))
            else:
                out.append("│   SAS通道: %d 个，全部未连接" % len(phys))
    return out


def collect_raid(mask=False):
    body = []
    mdstat = read_file("/proc/mdstat")
    arrays = re.findall(r"^(md\d+)\s*:\s*(.+)$", mdstat, re.M)
    if arrays:
        for name, detail in arrays:
            body.append(row("状态", "%s  %s" % (name, detail.strip())))
        return block("RAID控制器信息", body)

    # 无软 RAID：回落到硬件存储控制器探测（lspci 一个设备一块，缩进行从属于上一行）
    lines = sh("lspci -nnk").splitlines()
    idx = next((i for i, l in enumerate(lines) if re.search(r"\[0104\]|\[0107\]", l)), None)
    if idx is None:
        body.append(row("状态", "未检测到"))
        return block("RAID控制器信息", body)

    head = lines[idx]
    hw = re.search(
        r"(?:RAID bus controller|Serial Attached SCSI controller|Mass storage controller)"
        r"\s*(?:\[[0-9a-f]{4}\])?\s*:\s*(.+?)\s*\[[0-9a-f]{4}:[0-9a-f]{4}\]", head)
    name = hw.group(1).strip() if hw else head.split(":", 1)[-1].strip()
    driver = NA
    for l in lines[idx + 1:]:
        if not l.startswith("\t"):     # 下一个设备，停止
            break
        if "Kernel driver in use:" in l:
            driver = l.split(":", 1)[1].strip()
            break

    body.append(row("状态", "未检测到软 RAID；存在硬件存储控制器"))
    body.append(row("控制器", name))
    body.append(row("驱动", driver))

    # 已配置的逻辑卷/阵列
    vols = re.findall(r"^(md\d+)\s*:", mdstat, re.M)
    vols += [os.path.basename(d) for d in glob.glob("/sys/class/block/dm-*")]
    if vols:
        body.append(row("逻辑卷", " ".join(vols)))

    body += raid_hba_detail(mask)
    return block("RAID控制器信息", body)


# ───────────────────────────── 网卡 ─────────────────────────────

def collect_net(mask):
    body = []
    nics = [n for n in sorted(os.listdir("/sys/class/net"))
            if os.path.exists("/sys/class/net/%s/device" % n)]
    if not nics:
        return block("网卡信息", ["│   (未检测到物理网卡)"])

    for i, nic in enumerate(nics):
        if i:
            body.append("│")
        base = "/sys/class/net/%s" % nic
        bdf = os.path.basename(os.path.realpath(base + "/device"))
        pci = sh("lspci -s %s" % ":".join(bdf.split(":")[1:])).strip()
        model = pci.split(":", 2)[2].strip() if pci.count(":") >= 2 else NA

        state = read_file(base + "/operstate").upper() or NA
        mac = read_file(base + "/address")
        if mask:
            mac = mask_mac(mac)

        eth = sh("ethtool %s" % nic)
        speed = re.search(r"Speed:\s*(\S+)", eth)
        duplex = re.search(r"Duplex:\s*(\S+)", eth)
        link = re.search(r"Link detected:\s*(\S+)", eth)
        speed = speed.group(1).replace("Mb/s", " Mbps") if speed else NA
        duplex = duplex.group(1).lower() if duplex else NA
        link = "Yes" if (link and link.group(1).lower() == "yes") else "No"
        # ethtool 在断链时回 "Unknown!"，按状态归一化为 N/A
        if state != "UP":
            if speed.startswith("Unknown"):
                speed = NA
            if duplex.startswith("unknown"):
                duplex = NA

        rx = read_file(base + "/statistics/rx_bytes")
        tx = read_file(base + "/statistics/tx_bytes")

        body += [
            "│ ═══ %s ═══" % nic,
            "│   型号: " + model,
            "│   状态: " + state,
            "│   MAC地址: " + (mac or NA),
            "│   速度: " + speed,
            "│   双工模式: " + duplex,
            "│   链接检测: " + link,
            "│   RX: " + (human(int(rx)) if rx.isdigit() else NA),
            "│   TX: " + (human(int(tx)) if tx.isdigit() else NA),
        ]
    return block("网卡信息", body)


# ───────────────────────────── 显卡 ─────────────────────────────

def collect_gpu():
    body = ["│", "│ Graphics Cards (PCI):"]
    pci = [l.strip() for l in sh("lspci").splitlines()
           if re.search(r"VGA|3D controller|Display controller", l, re.I)]
    body += [("│   " + l) for l in pci] or ["│   (未检测到)"]

    body += ["│", "│ Display Hardware Summary:"]
    lshw = [l.rstrip() for l in sh("lshw -short -C display").splitlines() if l.strip()]
    if len(lshw) >= 1:
        body += [("│   " + l) for l in lshw[1:]]      # 丢掉 "H/W path Device Class" 表头
    else:
        fb = glob.glob("/dev/fb*")
        body += [("│   " + f) for f in fb] or ["│   (未检测到显示设备)"]
    return block("显卡信息", body)


# ───────────────────────────── 主板 ─────────────────────────────

def collect_board():
    dmi = "/sys/devices/virtual/dmi/id/"
    def d(name):
        return read_file(dmi + name) or NA
    return block("主板信息", [
        row("厂商", d("board_vendor")),
        row("型号", d("board_name")),
        row("Version", d("board_version")),
        row("BIOS Vendor", d("bios_vendor")),
        row("BIOS Version", d("bios_version")),
    ])


# ───────────────────────────── 主流程 ─────────────────────────────

def resolve_output(out, stamp=True):
    """未指定 -> 当前目录；目录 -> hwtest_report_<时间戳>.txt；
    文件名 -> 追加 _<时间戳>。stamp=False 时精确使用给定文件名。"""
    if out is None:
        out = "."
    as_dir = os.path.isdir(out) or out.endswith(os.sep) or out.endswith("/")
    if as_dir:
        d = out.rstrip("/\\") or "."
        return os.path.join(d, "hwtest_report_%s.txt" % datetime.now().strftime("%Y%m%d-%H%M%S"))
    if not stamp:
        return out
    d, b = os.path.split(out)
    base, ext = os.path.splitext(b)
    if b.startswith("."):          # 隐藏文件不切分扩展名
        base, ext = b, ""
    return os.path.join(d, "%s_%s%s" % (base, datetime.now().strftime("%Y%m%d-%H%M%S"), ext))


def main():
    ap = argparse.ArgumentParser(description="硬件信息采集报告（框线格式）")
    ap.add_argument("-o", "--output", help="输出文件或目录；默认当前目录，文件名自动带时间戳")
    ap.add_argument("--stdout", action="store_true", help="只打印到屏幕，不写文件")
    ap.add_argument("--no-stamp", action="store_true", help="不加时间戳，精确写入指定文件名")
    ap.add_argument("--mask", action="store_true", help="脱敏 MAC 地址与磁盘序列号")
    ap.add_argument("--no-disk", action="store_true", help="跳过 SMART 采集（快速模式）")
    args = ap.parse_args()

    lines = []
    for fn, a in (
        (collect_system, (args.mask,)),
        (collect_cpu, ()),
        (collect_mem, (args.mask,)),
        (collect_disk, (args.no_disk, args.mask)),
        (collect_raid, (args.mask,)),
        (collect_net, (args.mask,)),
        (collect_gpu, ()),
        (collect_board, ()),
    ):
        lines += safe(fn, *a)

    lines.append("报告生成完成！")
    lines.append("Generated on: " + datetime.now().astimezone().strftime("%a %b %d %I:%M:%S %p %Z %Y"))
    text = "\n".join(lines)
    print(text)

    if not args.stdout:
        path = resolve_output(args.output, not args.no_stamp)
        d = os.path.dirname(path)
        try:
            if d:
                os.makedirs(d, exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(text + "\n")
        except OSError as exc:
            print("错误: 无法写入 %s（%s）" % (path, exc.strerror or exc), file=sys.stderr)
            sys.exit(1)
        print("\n[已写入 %s]" % path, file=sys.stderr)


if __name__ == "__main__":
    main()
