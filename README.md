# WR1204S ImmortalWrt 构建工程

给 **Tenbay WR1204S**（eWeLink / twifi 贴牌，深圳诺信诚 ODM）做一份能刷的  
ImmortalWrt / OpenWrt 固件。

---

## 一、为什么需要自己编

官方下载站上**没有**这个型号的镜像，也不是随便漏了：

| 检查项                                                            | 实测结果                                      |
| -------------------------------------------------------------- | ----------------------------------------- |
| `downloads.immortalwrt.org/releases/25.12.x/targets/siflower/` | 只有 `sf21/`（RISC-V 的 Banana Pi）            |
| 同上 `.../siflower/sf19a2890/`                                   | **404**，所有版本全 404                         |
| 源码里 `sf19a2890/target.mk`                                      | `FEATURES+=fpu source-only` ← **故意不出二进制** |
| 源码里 `image/sf19a2890.mk`                                       | 只定义了 `siflower_sf19a2890-evb` 一块评估板       |
| Linux 主线的 `drivers/net/dsa/`                                   | **没有** airoha / an8855 驱动                 |

所以要出镜像，必须做三件事：去掉 `source-only`、补上 AN8855 驱动、写上本机板型。

这个工程把三件都做完了。

---

## 二、硬件事实（全部来自设备实测）

| 项目      | 值                                      | 来源                                                            |
| ------- | -------------------------------------- | ------------------------------------------------------------- |
| SoC     | Siflower SF19A2890 / SF19A28，MIPS 24Kc | 后台 `route_model: SF19A28`                                     |
| 内存      | 128 MiB                                | `memory@0 reg = <0x0 0x8000000>`                              |
| Flash   | 16 MiB SPI NOR                         | `/proc/mtd` 合计 0x1000000                                      |
| **交换机** | **Airoha AN8855，6 口（CPU@5）**           | `swconfig`: `Siflower MII Bus:01(AN8855), ports: 6 (cpu @ 5)` |
| 端口      | 0/1/2 = LAN（vlan1），3 = WAN（vlan2）      | `/etc/config/network`                                         |
| Reset 键 | **GPIO 14**                            | `/sys/kernel/debug/gpio`: `gpio-14 reset in hi`               |
| WPS 键   | **GPIO 27**                            | `gpio-27 wps in hi`                                           |
| LED     | 绿=1，蓝=2，红=3                            | `/sys/class/leds/`                                            |
| 串口      | 115200 8N1                             | `ttylogin '1'`                                                |

> ⚠️ 矽昌官方 EVB 和 BPI-WiFi5 的 dts 都把 reset 写成 **GPIO 27**。  
> 在这块板子上 27 是 **WPS**，reset 是 **14**。用错的话按键完全没反应。

真实分区（与 EVB / BPI 都不同）：

```
0x000000  0x020000  spl-loader    read-only
0x020000  0x060000  u-boot        read-only
0x080000  0x010000  u-boot-env
0x090000  0x010000  factory       MAC / SN / RGMII delay / 无线校准
0x0A0000  0x010000  product       ← EVB/BPI 没有
0x0B0000  0xF40000  firmware      15.25 MiB  ← EVB/BPI 从 0xA0000 起，8 MiB
0xFF0000  0x010000  custom        ← EVB/BPI 没有
```

`product` 和 `custom` 两个分区、以及 firmware 起点偏后 64K，  
是「照抄 BPI 镜像刷进去起不来」的根本原因。

---

## 三、编译

**本机编不了**：没有管理员权限，`HypervisorPresent = False`，装不了 WSL / Docker。  
三条路任选一条。

### 路线 A：GitHub Actions（推荐，免费，不用自己的机器）

1. 在 GitHub 新建一个 **私有** 仓库（public 也行，Actions 都免费）
2. 把本目录整个上传上去（`.github/` 是隐藏目录，别漏）
   ```bash
   cd iwrt_build
   git init
   git add -A
   git commit -m "WR1204S build"
   git remote add origin https://github.com/<你的账号>/<仓库名>.git
   git push -u origin main
   ```

3. 仓库页 → **Actions** → 左侧 `build-wr1204s` → 右侧 **Run workflow**
   - `base` 选 `immortal`
   - `minimal` 想先要小镜像就勾上（无 LuCI）
4. 等 2–4 小时。跑完在 run 页面底部 **Artifacts** 下载  
   `wr1204s-immortalwrt-<编号>.zip`

> 首次运行会下载约 3 GB 源码。workflow 里已经先清掉 runner 上  
> 预装的无用组件（.NET / Android SDK / JVM 等），腾出约 45 GB。

### 路线 B：自有 Linux 机器 / 云服务器

Ubuntu 22.04 或更新，**磁盘至少 50 GB**：

```bash
sudo apt update && sudo apt install -y \
  build-essential clang flex bison g++ gawk gcc-multilib g++-multilib \
  gettext git libncurses5-dev libncursesw5-dev libssl-dev \
  python3-setuptools python3-dev rsync unzip zlib1g-dev file wget \
  subversion patch bc

cd iwrt_build
./build.sh                      # 默认 immortal base + LuCI + 少量工具
# ./build.sh --min              # 不要 LuCI，最小体积
# ./build.sh --jobs 8           # 指定并行数
```

产物在 `out/`。

### 路线 C：换 base

```bash
./build.sh --base ulli
```

`ulli` 是硬件支持的原作者树（OpenWrt 主线 + siflower 完整支持）。  
如果 `immortal` 那条路在内核补丁上撞了上下文冲突，用这条先跑通。

---

## 四、固件里带什么

### 4.1 预置配置（保持原厂设置，一项都没改）

`files/` 目录会被 OpenWrt 合并进 rootfs，刷完开机就是原来的样子：

| 项目      | 值                                                                 | 来源                       |
| ------- | ----------------------------------------------------------------- | ------------------------ |
| LAN     | `192.168.100.1/24`，DNS 223.5.5.5 / 8.8.8.8                        | 原 `/etc/config/network`  |
| WAN     | 静态 `44.0.30.233/24`，网关 `44.0.30.129`，DNS `59.51.78.210`           | 同上                       |
| 2.4G    | SSID `TENDAINF-D9DA`，密码 `9876543210`，WPA/WPA2 混合，HT20，信道 auto     | 原 `/etc/config/wireless` |
| 5G      | SSID `TENDAINF-D9DA-5G`，密码 `9876543210`，WPA/WPA2 混合，VHT80，信道 auto | 同上                       |
| 主机名     | `WR1204S`                                                         | 原 `/etc/config/system`   |
| 时区      | `CST-8` / `Asia/Shanghai`                                         | 同上                       |
| NTP     | ntp.ntsc.ac.cn 等 5 个国内源                                           | 同上                       |
| DHCP    | 池 2–249，租期 24h                                                    | 原 `/etc/config/dhcp`     |
| **SSH** | **端口 12580，`admin/admin` 或 `root/admin`**                         | 见下                       |

原厂那两套没用到的无线配置没搬：`MAP-E4671ECCD9DA`（厂商 mesh 回程，隐藏）和 `*-Guest`（原厂就是 disabled）。

**关于账号**

原厂网页是 `admin/admin`，但那套密码存在产品配置里，跟 `/etc/shadow` 无关  
（`tbadmin` 那个哈希经实测不是 `admin`）。OpenWrt 的 LuCI 只认 root，所以：

| 入口      | 用户名     | 密码      |
| ------- | ------- | ------- |
| LuCI 网页 | `root`  | `admin` |
| SSH     | `admin` | `admin` |
| SSH     | `root`  | `admin` |

`admin` 是 uci-defaults 建的 UID 0 账户，密码哈希 `$1$k42SP.sZ$fmfeQ57MfaC/ZRp4/HVcC1`  
（`openssl passwd -1 -salt k42SP.sZ admin` 可复现）。

原厂 SSH 是 `PasswordAuth off` + `RootPasswordAuth off` + 没有 authorized_keys，  
端口开着但谁也进不去；这次把两个开关打开，端口仍保留 12580，并且只监听 LAN。

### 4.2 软件包

`--min` 之外，默认带：

| 包                                                        | 用途                |
| -------------------------------------------------------- | ----------------- |
| `luci` + 中文语言包                                           | 网页后台              |
| `luci-app-firewall` / `package-manager` / `filetransfer` | 防火墙、装包、传文件        |
| `htop` `curl` `wget-ssl` `nano` `tcpdump` `iperf3`       | 常用工具              |
| `openssh-sftp-server`                                    | 让 `scp`/`sftp` 能用 |
| `kmod-input-gpio-keys`                                   | reset / WPS 按键    |
| `kmod-usb-*` `kmod-fs-ext4/vfat`                         | USB 存储            |

**装得下的东西有限。** firmware 分区 15.25 MiB，基础镜像约 7 MB，  
留给 rootfs_data（可写覆盖层）的只有约 1.4 MiB。

所以：**不要指望 OpenClash / Docker / AdGuardHome**。  
OpenClash 单独就要 15–25 MB，physically 放不下。这跟编译水平无关，是 16 MB flash 的硬上限。

要加小工具，编译时改 `build.sh` 里的包列表，或者刷好后 `opkg install`（前提是镜像还留了空间）。

---

## 五、刷入

### 5.0 手上已有一个能立刻刷的镜像

`../flash_kit/firmware/openwrt-wr1204s-adapted.bin`（7,340,920 字节，  
sha256 `ae0497be…a21df`）是把别人编译好的 BPI-WiFi5 镜像改到本机的结果：

| 改动          | 原值                 | 新值                     |
| ----------- | ------------------ | ---------------------- |
| memory      | 64 MiB             | **128 MiB**            |
| firmware 分区 | 0xa0000 / 0x760000 | **0xb0000 / 0xf40000** |
| reset 键     | GPIO 27            | **GPIO 14**            |

内核 LZMA 解压 → 改 DTB → 重压 → uImage 双 CRC 重算，全部自校验通过；  
尾部 rootfs + metadata 与原镜像**逐字节一致**。

**但它不带预置配置**——squashfs 是只读的，塞不进去。刷完是 OpenWrt 默认的  
`192.168.1.1`、无 WiFi 密码。要恢复你的配置，用配置包：

```
flash_kit/wr1204s_config.tar.gz     4,115 字节
├── apply.sh                        在路由器上跑，写完配置自动重启
└── etc/config/{network,wireless,dhcp,system,firewall,dropbear}
    etc/uci-defaults/99-wr1204s     建 admin 账户、设密码、开 SSH
```

用法：

```bash
scp wr1204s_config.tar.gz root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'cd /tmp && tar xzf wr1204s_config.tar.gz -C wr1204s_config 2>/dev/null; sh /tmp/wr1204s_config/apply.sh'
# 重启后就是 192.168.100.1 + 原来的 WiFi + admin/admin
```

> 这份配置包的 `network` 用了 BPI 镜像的端口名：  
> `wan`=物理 LAN1，`lan2`/`lan3`=物理 LAN2/LAN3，`lan4`=物理 WAN。  
> 所以 LAN 桥是 `wan lan2 lan3`，WAN 是 `lan4`，物理口正好对上。  
> 自己编译的固件用 dts 里的 `lan1/lan2/lan3/wan`，配置在 `files/` 里，不用管这段。

### 5.1 前置：确认能进 U-Boot（这是唯一的安全网）

```
拔电源 → 按住 Reset 不放 → 插电源 → continue holding
指示灯闪 5 下后变白 → 松开
电脑设 192.168.1.2/24，网线接 LAN 口
浏览器开 http://192.168.1.1
```

进得去 U-Boot 网页，就永远能救回来。**进不去之前不要刷。**

### 方式 1：系统内 mtd 写入（有 root 时最快）

```bash
# 设备上已有 root（root@192.168.100.1:12580，密码 wr1204s）
scp -P 12580 -o PubkeyAcceptedKeyTypes=+ssh-rsa \
    out/*sysupgrade.bin root@192.168.100.1:/tmp/fw.bin

ssh -p 12580 root@192.168.100.1
mtd -r write /tmp/fw.bin firmware      # 写完自动重启
```

### 方式 2：U-Boot 网页

浏览器 `http://192.168.1.1` → 选 `sysupgrade.bin` → 烧写。  
U-Boot 这一层**不校验型号**（型号校验是运行中的厂商固件做的），所以能刷进去。

### 回滚

原厂全分区备份在 `../router_probe/backup_flash/`（7 个分区，MD5 全对过）：

```bash
scp -P 12580 backup_flash/mtd5_firmware.bin root@192.168.100.1:/tmp/
ssh -p 12580 root@192.168.100.1 'mtd -r write /tmp/mtd5_firmware.bin firmware'
```

起不来的话走 U-Boot 网页刷回 `mtd5_firmware.bin`。

---

## 六、目录说明

```
iwrt_build/
├── build.sh                     主构建脚本（7 步，每步带校验）
├── config-6.18.fragment         内核配置补丁（只有 2 项，追加式）
├── dts/
│   └── sf19a2890_wr1204s.dts    本机设备树（338 行，参数全部实测）
├── image/
│   └── sf19a2890.mk             设备定义（tenbay_wr1204s + minimal）
├── files/                       ★ 预置配置，编译时并入 rootfs
│   ├── etc/config/network       LAN 192.168.100.1 + WAN 44.0.30.233 静态
│   ├── etc/config/wireless      TENDAINF-D9DA / -5G，密码 9876543210
│   ├── etc/config/dhcp|system|firewall
│   ├── etc/config/dropbear      端口 12580，密码认证开，只监听 LAN
│   └── etc/uci-defaults/99-wr1204s
│                                root/admin + UID0 的 admin/admin
├── patches/
│   └── 0004-an8855-force-mac5-sideband.patch
│                                CPU 口(port5) sideband 强制，缺了网口不通
├── upstream/                    上游 target 离线存档（1.7 MB）
│   └── target/linux/
│       ├── siflower/            181 文件，含 45+ 内核补丁
│       └── generic/files-6.18/  AN8855 驱动 6 个文件
├── wifi/                        WiFi 驱动包
│   ├── 0001-sf_wifi-port-to-linux-6.18.patch   93 KB
│   ├── sf_smac.Makefile / sf_factory_read.c
│   ├── siflower_include/        驱动缺的 3 个头文件
│   ├── files/                   热管理脚本
│   └── lmac/                    LMAC 固件（md5 已校验）
└── .github/workflows/build.yml  CI 工作流
```

### build.sh 做了什么

1. 检查宿主工具
2. clone 源码树（ImmortalWrt master）
3. **整个替换 `target/linux/siflower`** —— 官方那份只有 EVB、没有 AN8855、还带 `source-only`
4. 铺 AN8855 驱动到 `target/linux/generic/files-6.18`
5. 打 sideband 补丁（缺了 CPU 口不通，全网段静默丢包且不计数）
6. 装入 dts + 设备定义
7. 清掉 `source-only`
8. 组装 `package/kernel/sf_smac`：拉 Siflower 开源驱动 → 打 6.18 移植补丁 → 装 LMAC 固件（md5 校验）
9. 追加 2 项内核配置（**只追加，不覆盖已有的** —— 上游故意把 `DWMAC_GENERIC` 设成 not set）
10. feeds + defconfig + make

---

## 七、已知风险

| 风险                 | 说明                                            | 应对                                     |
| ------------------ | --------------------------------------------- | -------------------------------------- |
| **交换机 reset GPIO** | dts 用了 GPIO 8（设备上唯一空闲的高电平输出）。实际可能是 11 或不需要    | 起不来网口就改 dts 里 `reset-gpios`，试 11 或整行删掉 |
| 内核补丁上下文            | ImmortalWrt 的 6.18 与上游树有日期差，patch 可能 fuzz 或失败 | 换 `--base ulli` 先跑通                    |
| WiFi 驱动移植          | `sf_wifi` 仓库原本是 linux-6.6，靠 93 KB 补丁移植到 6.18  | 构建脚本会校验 `timer_container_of` 存在，缺失即报错  |
| **远程刷机变砖**         | 刷完起不来 + SSH 没了 = 只能拆机上 TTL 串口                 | **刷之前先进一次 U-Boot 确认能进**                |
| 空间                 | rootfs_data 只有约 1.4 MiB                       | 别装大插件                                  |

---

## 八、附：可立即验证的一步

工程 `../flash_kit/firmware/` 里已有别人编译好的 **BPI-WiFi5 initramfs**  
（同款 SoC + 同款 AN8855，SHA256 已校验）：

```
openwrt-bpi-wifi5-v3-initramfs.bin   6,894,014 字节
f66909e9772be6908989911e0bfb5ca8b2e7cbadd14cf8178ec2f42d9705b65e
```

它**只在内存里跑，一个字节都不写 flash**。用它可以在不承担任何风险的前提下  
先把 SoC、交换机、无线摸清楚：

```
U-Boot 里（串口或网页）
  setenv ipaddr 192.168.1.2; setenv serverip 192.168.1.10
  tftpboot 0x81000000 openwrt-bpi-wifi5-v3-initramfs.bin
  bootm 0x81000000
```

或者 U-Boot 网页上传说它是 firmware 直接引导（不同 U-Boot 版本界面不一样）。

|                                |                                        |
| ------------------------------ | -------------------------------------- |
| 进去之后 `ip link`、\`dmesg         | grep -i an8855`、`iwinfo\`，就能确认硬件是否对得上。 |
| 确认没问题再去刷会写 flash 的 sysupgrade。 |                                        |
