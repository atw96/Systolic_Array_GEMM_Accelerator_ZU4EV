# PetaLinux 2020.1 构建指南（ACU4EV 真实硬件移植版）
## 平台：ALINX ACU4EV（XCZU4EV） | WSL2 Ubuntu 18.04

> 本指南已根据 `porting_env_hardware_config.md` 中记录的 **真实板卡验证环境**
> 更新，与初版 Demo 文档相比有以下关键差异，请优先注意：
>
> | 项 | 初版 Demo 假设 | 本移植版（真实环境）|
> |---|---|---|
> | PL 控制口基地址 | `0xA000_0000` | **`0x8005_0000`**（有效孔径仅 0x8000_0000 [512M]）|
> | PS Master 口 | M_AXI_HPM0_FPD | **M_AXI_HPM0_LPD** |
> | 板端软件访问 | UIO (`/dev/uio0`) | **`/dev/mem` 直接 mmap**（无需设备树改动）|
> | PetaLinux settings 路径 | `/opt/pkg/petalinux/2020.1/settings.sh` | **`/opt/pkg/petalinux/settings.sh`** |
> | WSL 工程根 | 任意路径 | **`$HOME/work/<project>`**（禁止用 `/mnt/<windows_drive>/...` 综合）|
> | 迭代加载方式 | 每次重新打包整张 SD 卡 | **fpga_manager 动态加载 `.bit`**（秒级，无需重刷卡）|
> | 板卡 IP / 登录 | 未知 | DHCP-assigned `<board_ip>`, SSH as `root` via dropbear |

---

## 前提条件检查

```bash
# 检查 Vivado / Vitis HLS 2020.1
ls /tools/Xilinx/Vivado/2020.1/settings64.sh
ls /tools/Xilinx/Vitis_HLS/2020.1/settings64.sh

# 检查 PetaLinux 2020.1（注意：无版本子目录！）
ls /opt/pkg/petalinux/settings.sh

# 检查磁盘空间（PetaLinux 构建需要约 50GB）
df -h ~

# 确认工程根路径符合规范（不要用 /mnt/<windows_drive>/... 做综合）
pwd   # 应显示 $HOME/work/<project>
```

> **铁律**（对照 porting_env_hardware_config.md 2.1）：
> 板子上**禁止**跑 Vivado / PetaLinux 构建；
> WSL 内工程根**必须**用 `$HOME/...`，**禁止**用 `/mnt/<windows_drive>/...` 做综合。

---

## Step 0：WSL2 环境预处理（首次使用必做）

### 0.1 安装必要依赖

```bash
sudo apt-get update
sudo apt-get install -y \
    gawk wget git-core diffstat unzip texinfo gcc-multilib \
    build-essential chrpath socat libsdl1.2-dev xterm \
    zlib1g-dev libssl-dev libncurses5-dev python3-pip \
    iproute2 net-tools rsync bc lzma lz4 xz-utils \
    tftpd-hpa tftp mtd-utils u-boot-tools curl
```

### 0.2 修复 WSL2 已知兼容性问题

```bash
# 问题 1：PetaLinux 检测 /bin/sh 是否为 bash
sudo dpkg-reconfigure dash
# 在交互菜单中选 "No"（使用 bash 作为 /bin/sh）

# 问题 2：TMPDIR 设置到 WSL 本地路径
mkdir -p ~/petalinux_tmp
echo 'export TMPDIR=~/petalinux_tmp' >> ~/.bashrc

# 问题 3：locale
sudo locale-gen en_US.UTF-8
echo 'export LANG=en_US.UTF-8' >> ~/.bashrc
source ~/.bashrc

# 问题 4：ulimit
echo '* soft nofile 65536' | sudo tee -a /etc/security/limits.conf
echo '* hard nofile 65536' | sudo tee -a /etc/security/limits.conf
```

---

## Step 1：初始化 PetaLinux 环境

```bash
# 【关键改动】真实环境路径无版本子目录
source /opt/pkg/petalinux/settings.sh

# 验证
echo $PETALINUX
```

> 若你的机器上 `/opt/pkg/petalinux/settings.sh` 不存在而是
> `/opt/pkg/petalinux/2020.1/settings.sh`，请以实际 `ls` 结果为准，
> 两种路径在不同主机上都可能出现，本指南以
> `porting_env_hardware_config.md` 记录的真实路径为准。

---

## Step 2：进入工程目录（真实路径规范）

```bash
# 【关键改动】WSL 主路径固定规范
cd $HOME/work/
# 建议为本工程单独建目录，与 EdgeAI-ZU4EV_Claude 平级
mkdir -p systolic_gemm_accel && cd systolic_gemm_accel

# 若源文件在 Windows 侧，仅用 /mnt/<windows_drive>/ 做「过渡拷贝」，不要在此路径下综合：
# cp -r /path/to/windows_copy/systolic_array_project/* .
```

## Step 3：创建 PetaLinux 工程

```bash
petalinux-create -t project --template zynqMP -n systolic_gemm_proj
cd systolic_gemm_proj
```

---

## Step 4：导入硬件描述文件（XSA）

> XSA 由 Vivado 实现完成后导出：
> `write_hw_platform -fixed -include_bit -force -file systolic_gemm_accel.xsa`
> （对照 `create_bd.tcl` Step 11，已按本工程命名习惯注释好）

```bash
XSA_PATH="../vivado_project/systolic_gemm_accel.xsa"
petalinux-config --get-hw-description=${XSA_PATH} --silentconfig
```

菜单中确认（若交互式打开 `petalinux-config`）：

```
DTG Settings → MACHINE_NAME: zcu104-revc   (ACU4EV 无官方 BSP，借用做基础)
Subsystem AUTO Hardware Settings → Serial Settings → UART: psu_uart_0
```

---

## Step 5：设备树（默认可跳过）

> **【关键改动】** 本移植版默认使用 `/dev/mem` 访问寄存器，
> **不需要**修改设备树，直接跳到 Step 6。
>
> 仅当你确定要改用 UIO 方式时，才执行以下步骤，并参考
> `petalinux/system-user.dtsi`（文件头部已标注为可选方案）：
>
> ```bash
> DTSI_DIR="project-spec/meta-user/recipes-bsp/device-tree/files/"
> mkdir -p ${DTSI_DIR}
> cp ../../petalinux/system-user.dtsi ${DTSI_DIR}
> ```
>
> 并在 `petalinux-config -c kernel` 中启用：
> `Device Drivers → Userspace I/O drivers →`
> `[*] Userspace I/O platform driver`
> `[*] Userspace I/O platform driver with generic IRQ handling`

---

## Step 6：构建根文件系统（确保有 devmem 工具，可选）

```bash
petalinux-config -c rootfs
```

推荐启用（`devmem` 命令便于板端快速调试寄存器）：

```
Filesystem Packages → misc → [*] busybox（默认已含 devmem）
Filesystem Packages → misc → [*] packagegroup-core-buildessential   # gcc/make
```

按 **ESC → Yes** 保存。

---

## Step 7：完整构建

```bash
petalinux-build

# 打包启动文件（首次全量构建时需要，用于制作可启动 SD 卡的基础镜像）
petalinux-package --boot \
    --fsbl  ./images/linux/zynqmp_fsbl.elf \
    --pmufw ./images/linux/pmufw.elf \
    --u-boot \
    --force
```

> 说明：这一步只需做**一次**（构建带有 fpga_manager + `/dev/mem` 支持的
> 基础 PetaLinux 系统）。之后每次修改 RTL / bitstream，**不需要**重新
> `petalinux-build`，只需用 Step 9 的 fpga_manager 动态加载即可，大幅
> 缩短迭代周期。

---

## Step 8：制作 SD 卡（仅首次构建基础系统时需要）

在 Windows 用磁盘工具将 SD 卡分区：分区 1（FAT32，~100MB），分区 2（ext4，剩余）。

```bash
cp images/linux/BOOT.BIN  /mnt/<sd_fat_mount>/     # FAT32 分区盘符按实际替换
cp images/linux/image.ub   /mnt/<sd_fat_mount>/
cp images/linux/boot.scr   /mnt/<sd_fat_mount>/
# rootfs.tar.gz 解压到 ext4 分区（用 balenaEtcher 或手动 tar -x）
```

插卡、上电、确认串口能看到 `login:` 提示（COM3，115200 8N1，无流控）。

---

## Step 9：【推荐】用 fpga_manager 动态加载 bitstream（快速迭代）

基础系统跑起来后，后续每次 RTL 改动只需重新综合出新的 `.bit`，
**无需重建 PetaLinux / 重刷 SD 卡**，直接用 fpga_manager 热加载：

```bash
# PC 端（WSL）：传输 bit 文件到板卡
export BOARD_IP=<board_ip>   # set to your board address
scp deploy/systolic_gemm_accel.bit \
    scripts/board_load_gemm.sh \
    software/test_app \
    root@${BOARD_IP}:/tmp/gemm_bench/

# 板端：加载 + 验证（一条命令完成）
ssh -o ConnectTimeout=8 root@${BOARD_IP} \
  "cd /tmp/gemm_bench && sh board_load_gemm.sh systolic_gemm_accel.bit"

# 确认加载成功
ssh -o ConnectTimeout=8 root@${BOARD_IP} \
  "cat /sys/class/fpga_manager/fpga0/state"
# 期望输出: operating
```

> **安全规则**（对照 porting_env_hardware_config.md 7.2）：
> 1. 任何 `/dev/mem` 访问前，必须确认 `fpga0 state=operating`
> 2. 未加载 PL 时禁止访问 AXI 寄存器地址 `0x8005_0000`
> 3. 禁止并发 SSH 访问板子
> 4. SSH 必须带 `-o ConnectTimeout=8`
> 5. **WSL 内执行** SSH/SCP；禁止在 PowerShell 中直接 `ssh`（引号语义不同会破坏命令）

---

## Step 10：运行验证程序

```bash
# 在板卡 root shell（或通过 ssh 远程执行）
cd /tmp/gemm_bench
sudo ./test_app 2>&1 | tee board_result.txt
```

期望输出（默认依次运行内置的 5 组测试向量，N=24）：

```
---- test_id=0 ----
RESULT_0: 2566
RESULT_1: 36255
...
RESULT_23: -6247
  [PASS] test_id=0 与内置 GOLDEN 表完全一致
...
汇总: 5 PASS, 0 FAIL (共 5 组)
*** 全部测试通过 — 上板验证 PASS ***
```

PC 端最终比对：

```bash
python3 python/golden_model.py --array_size 24 --test_id 0 --mode board
```

---

## Step 11：（可选）以太网结果上传

除本地验证外，`test_app` 还可以在每组测试计算完成后，把结果通过 TCP
上传到上位机（对应本次优化需求 1）：

```bash
# PC 端先启动接收服务（阻塞监听）
python3 python/host_eth_receiver.py --port 9000 --array_size 24

# 板端指定上位机 IP 运行
sudo ./test_app --host <上位机IP> --port 9000
```

`host_eth_receiver.py` 收到每条结果后会立即用 `golden_model.py` 重新计算
期望值并比对，实时打印 `[HOST-VERIFIED PASS/FAIL]`，无需等全部跑完再手动
核对。协议细节（JSON 字段、超时策略）见 `README.md` 中"PS → Ethernet
result upload"一节的说明，以及 `test_app.c` / `host_eth_receiver.py` 内的
注释。

---

```bash
python3 python/golden_model.py --test_id 0 --mode board
# ✓ [PASS] 板卡结果与 Golden Model 完全一致
```

---

## 常见问题排查

| 问题 | 可能原因 | 解决方法 |
|------|----------|----------|
| `mmap` 失败 / `Invalid argument` | 地址超出有效孔径 | 确认基地址是 `0x8005_0000` 而非 `0xA000_0000` |
| `/dev/mem: Operation not permitted` | 权限或 STRICT_DEVMEM | `sudo ./test_app`；若仍失败检查内核 `CONFIG_STRICT_DEVMEM` |
| `fpga0` 目录不存在 | 内核未启用 FPGA Manager | 确认 `CONFIG_FPGA_MGR_ZYNQMP_FPGA=y` |
| `fpga_manager` 加载后 state 不是 operating | bit 文件损坏或与 XSA 不匹配 | 重新从同一次 Vivado 导出的 bit/xsa 部署 |
| STATUS_REG 始终读 0 或全 F | 地址映射错误 / PL 未加载 | 先确认 `fpga0 state=operating` 再访问寄存器 |
| PetaLinux 构建在 WSL2 上报网络/权限错误 | WSL2 已知限制 | 参考 Step 0.2；必要时改用 `edgeai_39` 远程 Linux 构建 |
| SSH 命令在 PowerShell 里语法出错 | 引号被 PowerShell 解析 | 改为在 WSL 内执行 ssh/scp |

---

## 与 EdgeAI-ZU4EV 工程共存注意事项

若未来希望把本 GEMM 加速器与 EdgeAI-ZU4EV 的 CNN 加速器 **合并到同一个
Block Design**，需要注意地址不冲突：

| 外设 | 基地址 |
|---|---|
| AXI DMA（EdgeAI-ZU4EV） | `0x8004_0000` |
| **axi_ctrl_top（本工程）** | **`0x8005_0000`** ← 已避开冲突 |
| axi_gpio_debug | `0x8008_0000` |
| axi_gpio_led | `0x8009_0000` |
| axi_uart_dbg | `0x800A_0000` |

本工程无需 HP0 高速数据通路（不用 AXI-DMA），因此**不需要**执行
EdgeAI-ZU4EV 文档中提到的 HP0 64-bit AFIFM2 修复步骤
（`scripts/board_fix_hp0_width.py`），那是专门针对 `S_AXI_HP0_FPD` 的问题。
