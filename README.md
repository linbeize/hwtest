# hwtest

Linux 硬件信息采集报告脚本，输出带框线的中文硬件快照。

同一功能提供两个版本：纯 shell（`hwtest.sh`，无 Python 依赖）与 Python（`hwtest.py`），两者输出逐行一致。

## 输出内容

八个分块：系统信息、处理器信息、内存信息、硬盘信息、RAID控制器信息、网卡信息、显卡信息、主板信息。

采集项包括 CPU 型号/核心/频率/使用率/温度、内存总量与内存条明细（型号/频率/制造商/序列号）、分区占用、SMART 健康与读写量/通电时间/温度、SAS/RAID 卡固件与通道状态、各网卡型号/速率/流量、GPU 与显示设备、主板与 BIOS 版本。

## 用法

```bash
./hwtest.sh                        # 默认保存 hwtest_report_<时间戳>.txt 并打印
./hwtest.sh -o hw.txt              # 保存 hw_<时间戳>.txt
./hwtest.sh -o out/                # 保存到 out/hwtest_report_<时间戳>.txt
./hwtest.sh -o hw.txt --no-stamp   # 精确写入 hw.txt（不加时间戳）
./hwtest.sh --stdout               # 只打印到屏幕，不写文件
./hwtest.sh --mask                 # 脱敏主机名/MAC/磁盘与内存序列号
./hwtest.sh --no-disk              # 跳过 SMART 采集（快速模式）
```

Python 版参数相同：

```bash
python3 hwtest.py --mask --no-disk
```

也可以直接管道执行：

```bash
curl -fsSL <raw-url>/hwtest.sh | bash
```

## 依赖

优先使用外部命令，缺失时自动降级为 `N/A` 并继续输出，不会中断。

```
lscpu  dmidecode  lshw  smartctl  sensors  df  lsblk  ethtool  lspci
```

内存条明细需要 root（读 `dmidecode`）；非 root 会显示「无法读取」而非崩溃。

Debian/Ubuntu 安装依赖：

```bash
apt-get install -y util-linux pciutils usbutils dmidecode lshw smartmontools lm-sensors ethtool
```

## 说明

- 输出采用终端显示宽度对齐：全角字符按 2 列计算，标题分隔符长度跟随标题。
- 输出文件名默认带时间戳（`YYYYmmdd-HHMMSS`），避免多次运行互相覆盖；需要覆盖固定文件时用 `--no-stamp`。
- 落盘失败（目录不可写）时退出码为 1，并仍把报告打印到屏幕，不会谎报成功。
- `--mask` 保留序列号前 4 位便于比对，其余以 `*` 替代。

## 示例输出

见 [sample-report.txt](sample-report.txt)（已脱敏）。本机为 Supermicro X10SL7-F + Xeon E3-1240 v3。

## License

MIT
