#!/usr/bin/env bash
#
# build.sh -- build an ImmortalWrt / OpenWrt image for the Tenbay WR1204S
#             (Siflower SF19A2890 + Airoha AN8855, 128 MiB RAM, 16 MiB SPI NOR)
#
# What this does, in order:
#   1. clone the selected base tree (ImmortalWrt by default)
#   2. replace target/linux/siflower wholesale with the hardware-complete tree
#      that actually supports this SoC (upstream ImmortalWrt's copy only knows
#      the Siflower EVB, has no AN8855 driver and is marked source-only)
#   3. drop in the AN8855 driver (DSA + MDIO + PHY + MFD + EFUSE)
#   4. add our board: dts/sf19a2890_wr1204s.dts + image/sf19a2890.mk entry
#   5. assemble package/kernel/sf_smac from the Siflower open WiFi driver,
#      apply the linux-6.18 port, and install the LMAC firmware blobs
#   6. clear the source-only flag, seed the kernel config, build
#
# Usage:
#   ./build.sh                    # ImmortalWrt base, LuCI + a few tools
#   ./build.sh --base ulli        # upstream hardware tree as the base instead
#   ./build.sh --base bleach      # BleachWrt base (coolsnowwolf/lede) + Argon
#   ./build.sh --min              # no LuCI, smallest rootfs
#   ./build.sh --prepare          # stop after the kernel patches are applied (~10 min)
#   ./build.sh --tools            # build only the host tools (~30 min, isolates toolchain bugs)
#   ./build.sh --jobs 8           # parallel build jobs
#   ./build.sh --clean            # wipe the source tree first
#
# Requirements (Ubuntu 22.04+):
#   sudo apt install -y build-essential clang flex bison g++ gawk gcc-multilib \
#        g++-multilib gettext git libncurses-dev libssl-dev python3-distutils \
#        rsync unzip zlib1g-dev file wget subversion
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SRC:-$HERE/openwrt}"
BASE="immortal"
JOBS="$(nproc 2>/dev/null || echo 4)"
MINIMAL=0
CLEAN=0
PREPARE_ONLY=0
SKIP_ELFUTILS=0
TOOLS_ONLY=0
KEEP_ELFUTILS=0

IMMORTAL_URL="https://github.com/immortalwrt/immortalwrt.git"
IMMORTAL_REF="master"
ULLI_URL="https://github.com/ulli-kroll/openwrt.git"
ULLI_REF="openwrt-siflower/v6.18/sf19/master"
# BleachWrt is built on top of Lean's LEDE (coolsnowwolf/lede). Its tree now
# carries target/linux/siflower/sf19a2890 on kernel 6.18 -- the same branch we
# already run -- but only ships the Siflower EVB dts and is marked source-only,
# so the same board overlay below applies unchanged.
BLEACH_URL="https://github.com/coolsnowwolf/lede.git"
# Pinned, not "master": a moving upstream turns every CI iteration into two
# variables (our change + whatever Lean merged overnight). Bump deliberately.
BLEACH_REF="a0c958aee9d6dda2dc2241318b0c7507053ea21b"

DRIVER_URL="https://github.com/Siflower/sf_wifi.git"
DRIVER_COMMIT="da991fafab179a2ed495c2925a0bf219ef38e22e"

while [ $# -gt 0 ]; do
	case "$1" in
		--base)   BASE="$2"; shift ;;
		--jobs)   JOBS="$2"; shift ;;
	--min)    MINIMAL=1 ;;
	--clean)  CLEAN=1 ;;
	--prepare) PREPARE_ONLY=1 ;;
	--skip-elfutils) SKIP_ELFUTILS=1 ;;
	--tools)   TOOLS_ONLY=1 ;;
	--keep-elfutils) KEEP_ELFUTILS=1 ;;
		--src)    SRC="$2"; shift ;;
		-h|--help) sed -n '2,30p' "$0"; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
	shift
done

case "$BASE" in
	immortal|ulli|bleach) ;;
	*) echo "--base must be immortal, ulli or bleach" >&2; exit 1 ;;
esac

STEP=0
say()  { STEP=$((STEP+1)); printf '\n\033[1;36m[%02d] ==> %s\033[0m\n' "$STEP" "$*"; }
info() { printf '     %s\n' "$*"; }
ok()   { printf '     \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '     \033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- host deps --
say "Checking host tools"
missing=""
for t in git make gcc g++ python3 rsync wget unzip file bc patch; do
	command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
[ -z "$missing" ] || die "missing host tools:$missing"
ok "all host tools present"
info "cpu cores: $JOBS"

# -------------------------------------------------------------------- source --
say "Preparing source tree ($BASE)"
if [ "$CLEAN" = 1 ] && [ -d "$SRC" ]; then
	info "removing $SRC"
	rm -rf "$SRC"
fi
case "$BASE" in
	immortal) URL="$IMMORTAL_URL"; REF="$IMMORTAL_REF" ;;
	ulli)     URL="$ULLI_URL";     REF="$ULLI_REF"     ;;
	bleach)   URL="$BLEACH_URL";   REF="$BLEACH_REF"   ;;
	*) die "unknown base '$BASE' (immortal | ulli | bleach)" ;;
esac
if [ ! -d "$SRC/.git" ]; then
	info "cloning $URL ($REF) -- this is ~300 MB, be patient"
	if printf '%s' "$REF" | grep -qE '^[0-9a-f]{40}$'; then
		# a bare sha cannot be passed to `git clone -b`, fetch it directly
		mkdir -p "$SRC"
		git -C "$SRC" init -q
		git -C "$SRC" remote add origin "$URL"
		git -C "$SRC" fetch -q --depth 1 origin "$REF" || die "fetch failed: $URL $REF"
		git -C "$SRC" checkout -q FETCH_HEAD || die "checkout failed: $REF"
	else
		git clone --depth 1 -b "$REF" "$URL" "$SRC" || die "clone failed: $URL"
	fi
else
	info "reusing existing tree at $SRC"
fi
ok "source tree ready"

# ---------------------------------------------- replace the siflower target --
# ImmortalWrt's target/linux/siflower knows only the Siflower EVB: 16 kernel
# patches, no AN8855 driver, and sf19a2890 is flagged `source-only` so no image
# is ever produced. The archived upstream copy has the full hardware support
# (45+ patches, AN8855 DSA driver, working gmac/wifi glue), so we swap it in
# wholesale and keep ImmortalWrt's packages/feeds/LuCI untouched.
say "Installing hardware-complete siflower target"
[ -d "$HERE/upstream/target/linux/siflower" ] || die "missing $HERE/upstream/target/linux/siflower"
rm -rf "$SRC/target/linux/siflower"
cp -a "$HERE/upstream/target/linux/siflower" "$SRC/target/linux/siflower"
ok "target/linux/siflower replaced ($(find "$SRC/target/linux/siflower" -type f | wc -l) files)"

say "Installing Airoha AN8855 driver"
# Drivers live as file overrides under generic/files-6.18; the Kconfig/Makefile
# wiring is already inside the siflower patches-6.18 (737-*, 730-*, 738-*).
# A base tree without any per-version override dir gets them merged into
# generic/files/ instead, which every kernel version reads.
GEN="$SRC/target/linux/generic"
mkdir -p "$GEN"
if compgen -G "$GEN/files-[0-9]*" >/dev/null 2>&1; then
	cp -a "$HERE/upstream/target/linux/generic/files-6.18" "$GEN/"
	GENFILES="$GEN/files-6.18"
else
	info "base tree has no per-version override dirs; merging into generic/files/"
	mkdir -p "$GEN/files"
	cp -a "$HERE/upstream/target/linux/generic/files-6.18/." "$GEN/files/"
	GENFILES="$GEN/files"
fi
[ -f "$GENFILES/drivers/net/dsa/an8855.c" ] || die "AN8855 driver not installed"
ok "5 driver sources + 1 header in ${GENFILES#$SRC/}"

# Port 5 (the RGMII CPU port) needs its MAC sideband forced to the negotiated
# speed. Without this the link reports up at the right speed on both ends and
# not a single frame crosses it, with no error counted anywhere.
say "Patching AN8855 MAC5 sideband (CPU port)"
if [ -f "$HERE/patches/0004-an8855-force-mac5-sideband.patch" ]; then
	# The patch is written against generic/files-6.18, but a base tree without
	# per-version override dirs got the drivers merged into generic/files.
	# Rewrite the prefix on the fly so -p1 lands on the real location.
	GENREL="${GENFILES#$SRC/}"
	( cd "$SRC" && sed "s|target/linux/generic/files-6\.18|$GENREL|g" \
		"$HERE/patches/0004-an8855-force-mac5-sideband.patch" \
		| patch -p1 --no-backup-if-mismatch -s ) \
		|| die "AN8855 sideband patch failed (driver dir: $GENREL)"
	grep -q "AN8855_RG_FORCE_MAC5_SB" "$GENFILES/drivers/net/dsa/an8855.h" \
		|| die "sideband patch did not take"
	ok "MAC5 sideband forced for port 5 in RGMII mode ($GENREL)"
else
	info "patch not found, skipping (Ethernet may not pass traffic)"
fi

# ------------------------------------------------------------------- board --
say "Adding Tenbay WR1204S board definition"
cp "$HERE/dts/sf19a2890_wr1204s.dts" "$SRC/target/linux/siflower/dts/" \
	|| die "could not install dts"
grep -q "wr1204s" "$SRC/target/linux/siflower/dts/sf19a2890_wr1204s.dts" \
	|| die "dts sanity check failed"
ok "dts: sf19a2890_wr1204s.dts"

# The archived upstream copy defines the EVB, BPI-WiFi5 and both GL.iNet
# boards; ours re-declares Device/Default plus the WR1204S entries and keeps
# the EVB recipe for reference. Straight overwrite -- no fragile awk merging.
IMG_MK="$SRC/target/linux/siflower/image/sf19a2890.mk"
cp "$HERE/image/sf19a2890.mk" "$IMG_MK" || die "could not install image/sf19a2890.mk"
grep -q "tenbay_wr1204s" "$IMG_MK" || die "device definition not installed"
grep -q "DEVICE_DTS := sf19a2890_wr1204s" "$IMG_MK" || die "dts reference missing"
ok "device: tenbay_wr1204s (BOARD_NAME tenbay,wr1204s, IMAGE_SIZE 15616k)"

say "Pinning the kernel to 6.18"
# The archived target tree ships KERNEL_PATCHVER:=6.12 with 6.18 only behind
# KERNEL_TESTING_PATCHVER. The board runs 6.18.35 and every patch, config and
# the AN8855 file override (generic/files-6.18) is keyed to 6.18, so the default
# has to be 6.18 or the build silently produces a 6.12 image with no Ethernet.
TMK="$SRC/target/linux/siflower/Makefile"
sed -i 's/^KERNEL_PATCHVER:=.*/KERNEL_PATCHVER:=6.18/' "$TMK"
grep -q '^KERNEL_PATCHVER:=6.18' "$TMK" || die "could not pin KERNEL_PATCHVER to 6.18"
sed -i 's/^KERNEL_TESTING_PATCHVER:=6\.18$/KERNEL_TESTING_PATCHVER:=6.12/' \
	"$SRC/target/linux/siflower/sf19a2890/target.mk" 2>/dev/null || true
ok "KERNEL_PATCHVER:=6.18 (testing left at 6.12)"

say "Clearing the source-only flag"
TMK="$SRC/target/linux/siflower/sf19a2890/target.mk"
[ -f "$TMK" ] || die "missing $TMK"
sed -i 's/^FEATURES+=fpu source-only$/FEATURES+=fpu/' "$TMK"
if grep -q "source-only" "$TMK"; then
	info "flag still present, forcing"
	sed -i 's/ source-only//g' "$TMK"
fi
grep -q "source-only" "$TMK" && die "could not clear source-only" || ok "sf19a2890 is buildable"

# ---------------------------------------------------------- default config --
# OpenWrt merges the tree-root `files/` directory into the rootfs, so this is
# where the device's existing settings are preserved: LAN 192.168.100.1, the
# static WAN 44.0.30.233, both SSIDs and the WiFi key, hostname, NTP, and the
# SSH credentials (admin/admin on port 12580).
say "Installing default configuration (keeps the current settings)"
[ -d "$HERE/files" ] || die "missing $HERE/files"
mkdir -p "$SRC/files"
cp -a "$HERE/files/." "$SRC/files/"
chmod 0755 "$SRC"/files/etc/uci-defaults/* 2>/dev/null || true
# sanity: the pieces that would silently break a fresh boot
[ -f "$SRC/files/etc/config/network" ]  || die "files/etc/config/network missing"
[ -f "$SRC/files/etc/config/wireless" ] || die "files/etc/config/wireless missing"
[ -f "$SRC/files/etc/config/dropbear" ] || die "files/etc/config/dropbear missing"
grep -q "192.168.99.1"  "$SRC/files/etc/config/network"  || die "LAN IP not preserved"
grep -q "44.0.30.233"   "$SRC/files/etc/config/network"  || die "WAN IP not preserved"
grep -q "TENDAINF-D9DA" "$SRC/files/etc/config/wireless" || die "2.4G SSID not preserved"
grep -q "9876543210"    "$SRC/files/etc/config/wireless" || die "WiFi key not preserved"
ok "network/wireless/dhcp/system/firewall/dropbear + uci-defaults installed"
info "LAN 192.168.99.1 | WAN 44.0.30.233 static | WiFi TENDAINF-D9DA + -5G"
info "SSH admin/admin on port 12580 (also root/admin)"

# -------------------------------------------------------------- wifi driver --
say "Assembling the WiFi driver package (sf_smac)"
DRV_SRC="$HERE/sf_wifi"
if [ ! -d "$DRV_SRC/.git" ]; then
	info "cloning $DRIVER_URL"
	git clone --single-branch "$DRIVER_URL" "$DRV_SRC" || die "wifi driver clone failed"
fi
( cd "$DRV_SRC" && git fetch -q origin && git checkout -q --detach "$DRIVER_COMMIT" \
	&& git reset -q --hard "$DRIVER_COMMIT" && git clean -qfd ) \
	|| die "could not pin the driver to $DRIVER_COMMIT"

PKG="$SRC/package/kernel/sf_smac"
rm -rf "$PKG"; mkdir -p "$PKG"
cp -a "$DRV_SRC/sf_smac/src"    "$PKG/src"
cp -a "$DRV_SRC/sf_smac/config" "$PKG/config"
cp -a "$HERE/wifi/siflower_include" "$PKG/"
cp    "$HERE/wifi/sf_smac.Makefile"  "$PKG/Makefile"
cp    "$HERE/wifi/sf_factory_read.c" "$PKG/"
cp -a "$HERE/wifi/files" "$PKG/files"
patch -p1 -s -d "$PKG/src" < "$HERE/wifi/0001-sf_wifi-port-to-linux-6.18.patch" \
	|| die "WiFi driver port to linux-6.18 failed"
# the port must be there, or the build silently produces a 4.14 driver that
# will not load on 6.18
grep -q "timer_container_of" "$PKG/src/bb_src/umac/siwifi_utils.c" \
	|| die "driver port did not apply cleanly"
ok "driver tree at $DRIVER_COMMIT + linux-6.18 port"

# LMAC firmware. The memory-opt blobs from a newer SDK commit leave every fresh
# 5 GHz station without unicast for 2-25 s after association; the pinned older
# build does not, and matches the vendor firmware behaviour.
say "Installing LMAC firmware blobs"
LMAC_DIR="$PKG/config/a28fullmask/memory-opt"
[ -d "$LMAC_DIR" ] || die "missing $LMAC_DIR in driver tree"
for f in sf1688_hb_fmac.bin sf1688_lb_fmac.bin; do
	want="fdb7c5dfb665e0cb4cf30d4987fabb44"
	[ "$f" = "sf1688_lb_fmac.bin" ] && want="5842b583b20d7a8711d54209d2fbcc0d"
	src_blob="$HERE/wifi/lmac/$f"
	[ -f "$src_blob" ] || die "missing blob $src_blob"
	got="$(md5sum "$src_blob" | cut -d' ' -f1)"
	[ "$got" = "$want" ] || die "$f md5 mismatch: got $got want $want"
	cp "$src_blob" "$LMAC_DIR/$f"
	ok "$f ($(wc -c < "$src_blob") bytes, md5 verified)"
done

# ------------------------------------------------------------ kernel config --
# The upstream config-6.18 already carries the whole AN8855/DSA/stmmac set and
# is the config the hardware was validated against -- notably it keeps
# "# CONFIG_DWMAC_GENERIC is not set" on purpose. So: append only what is
# absent, never rewrite an existing key.
say "Seeding kernel config (append-only)"
CFG="$SRC/target/linux/siflower/sf19a2890/config-6.18"
[ -f "$CFG" ] || die "missing $CFG"
added=0
while IFS= read -r line; do
	case "$line" in
		''|'#'*) continue ;;
	esac
	key="${line%%=*}"
	if grep -qE "^(# )?${key}(=| is not set)" "$CFG"; then
		continue
	fi
	printf '%s\n' "$line" >> "$CFG"
	info "appended $line"
	added=$((added+1))
done < "$HERE/config-6.18.fragment"
ok "$added key(s) appended; existing AN8855/DSA options left untouched"
for k in NET_DSA_AN8855 MFD_AIROHA_AN8855 AIR_AN8855_PHY; do
	grep -q "^CONFIG_${k}=y" "$CFG" || die "upstream config lost CONFIG_${k}=y"
done
ok "AN8855 driver options confirmed present"

# ------------------------------------------------------------------- feeds --
say "Updating feeds"
( cd "$SRC" && ./scripts/feeds update -a >/dev/null 2>&1 ) || die "feeds update failed"
( cd "$SRC" && ./scripts/feeds install -a >/dev/null 2>&1 ) || die "feeds install failed"
ok "feeds ready"

# ------------------------------------------------------------------ config --
say "Writing .config"
DEVICE="tenbay_wr1204s"
[ "$MINIMAL" = 1 ] && DEVICE="tenbay_wr1204s-min"

cat > "$SRC/.config" <<EOF
CONFIG_TARGET_siflower=y
CONFIG_TARGET_siflower_sf19a2890=y
CONFIG_TARGET_siflower_sf19a2890_DEVICE_${DEVICE}=y
CONFIG_TARGET_MULTI_PROFILE=y
CONFIG_TARGET_DEVICE_siflower_sf19a2890_DEVICE_${DEVICE}=y
CONFIG_TARGET_ROOTFS_SQUASHFS=y
CONFIG_TARGET_ROOTFS_INITRAMFS=y
CONFIG_TARGET_KERNEL_PARTSIZE=0
CONFIG_ALL_KMODS=n
CONFIG_DEVEL=n
CONFIG_STRIP_KERNEL_EXPORTS=y
CONFIG_USE_MKLIBS=y
EOF

if [ "$MINIMAL" = 0 ]; then
	cat >> "$SRC/.config" <<'EOF'
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-ssl=y
CONFIG_PACKAGE_luci-app-firewall=y
CONFIG_PACKAGE_luci-app-package-manager=y
CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
CONFIG_PACKAGE_luci-i18n-firewall-zh-cn=y
CONFIG_PACKAGE_luci-i18n-package-manager-zh-cn=y
CONFIG_PACKAGE_htop=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_wget-ssl=y
CONFIG_PACKAGE_nano=y
CONFIG_PACKAGE_tcpdump=y
CONFIG_PACKAGE_iperf3=y
CONFIG_PACKAGE_openssh-sftp-server=y
CONFIG_PACKAGE_luci-app-filetransfer=y
EOF
	# BleachWrt look: Argon is the theme that upstream LuCI dropped, so it only
	# exists in the Lean luci feed. ~600 KiB once the assets are gzipped.
	if [ "$BASE" = "bleach" ]; then
		cat >> "$SRC/.config" <<'EOF'
CONFIG_PACKAGE_luci-theme-argon=y
CONFIG_PACKAGE_luci-app-argon-config=y
EOF
	fi
fi

DEFLOG="$HERE/defconfig.log"
if ! ( cd "$SRC" && make defconfig >"$DEFLOG" 2>&1 ); then
	info "defconfig returned non-zero -- tail of $DEFLOG:"
	tail -25 "$DEFLOG" | sed 's/^/       /'
fi
# Newer trees emit CONFIG_TARGET_DEVICE_<board>_<subtarget>_DEVICE_<name> and no
# longer the legacy CONFIG_TARGET_<board>_<subtarget>_DEVICE_<name>; accept either.
PROF_OK=0
for sym in "CONFIG_TARGET_DEVICE_siflower_sf19a2890_DEVICE_${DEVICE}" \
           "CONFIG_TARGET_siflower_sf19a2890_DEVICE_${DEVICE}"; do
	grep -q "^${sym}=y" "$SRC/.config" && PROF_OK=1
done
if [ "$PROF_OK" = 0 ]; then
	printf '\n\033[1;31m--- profile lost: diagnostics ---\033[0m\n'
	printf 'defconfig log tail:\n'
	tail -30 "$DEFLOG" 2>/dev/null | sed 's/^/  | /' || echo '  | (no log)'
	printf '\ntarget symbols surviving in .config:\n'
	grep -E '^CONFIG_TARGET' "$SRC/.config" | sed 's/^/  | /' | head -20
	printf '\ndevice recipes found:\n'
	grep -rn "TARGET_DEVICES.*tenbay_wr1204s\|Device/tenbay_wr1204s" \
		"$SRC/target/linux/siflower/image/" 2>/dev/null | sed 's/^/  | /' | head -10
	printf '\nsubtarget target.mk:\n'
	sed 's/^/  | /' "$SRC/target/linux/siflower/sf19a2890/target.mk" 2>/dev/null
	die "profile ${DEVICE} did not survive defconfig -- the device recipe was renamed or dropped"
fi
ok "profile ${DEVICE} active"

# ---------------------------------------------------------------- preflight --
# The 61 siflower patches-6.18 files were written against kernel 6.18.35, while
# Lean's tree tracks 6.18.62. Same stable series, but hunks can still drift. A
# full build spends 2-4 h before it ever reaches a failing patch, so --prepare
# stops right after the kernel is extracted and every patch is applied: about
# ten minutes to learn whether the overlay is compatible with this base.
if [ "$PREPARE_ONLY" = 1 ]; then
	say "Preflight: extracting the kernel and applying every target patch"
	LOG="$HERE/prepare.log"
	if ( cd "$SRC" && make -j1 target/linux/prepare V=s 2>&1 | tee "$LOG" | tail -40 ); then
		ok "kernel prepared -- make returned 0"
		# Proof, not faith: these five files are created by the siflower patches
		# and exist nowhere else, so finding them means the patches really ran.
		KDIR="$(ls -d "$SRC"/build_dir/target-*/linux-*/linux-6.18* 2>/dev/null | head -1 || true)"
		[ -n "$KDIR" ] || die "no linux-6.18 build dir -- prepare used the wrong KERNEL_PATCHVER (look for linux-6.12 in the log)"
		case "$KDIR" in
			*linux-6.18*) ;;
			*) die "prepared kernel is not 6.18: $KDIR" ;;
		esac
		info "kernel tree: ${KDIR#$SRC/}"
		awk '/^VERSION =/{v=$3} /^PATCHLEVEL =/{p=$3} /^SUBLEVEL =/{s=$3} END{printf "       kernel %s.%s.%s\n",v,p,s}' "$KDIR/Makefile"
		miss=0
		for p in drivers/net/dsa/lantiq/mxl-gsw1xx.c \
		         drivers/net/dsa/lantiq/mxl-gsw1xx.h \
		         drivers/net/dsa/lantiq/mxl-gsw1xx_pce.h \
		         drivers/net/dsa/lantiq/lantiq_gswip_common.c \
		         net/dsa/tag_mxl-gsw1xx.c; do
			[ -f "$KDIR/$p" ] || { info "MISSING $p"; miss=$((miss+1)); }
		done
		[ "$miss" = 0 ] || die "$miss patch-created file(s) absent -- the patches did not apply"
		ok "all 5 patch-created files present -- siflower patches applied"
		info "log: $LOG"
		exit 0
	fi
	printf '\n\033[1;31m========== PATCH FAILURES ==========\033[0m\n'
	grep -nE 'Patch failed|patch.*failed|Hunk #[0-9]+ (FAILED|succeeded)|^Applying .*patch' "$LOG" \
		| tail -40 || true
	printf '\n  full log: %s\n' "$LOG"
	die "preflight failed -- the patches above need re-basing onto this base"
fi

# ------------------------------------------------------------------- build --
MAKELOG="$HERE/make.log"
: >"$MAKELOG"

# Drop tools/elfutils (and its only consumer, dwarves/pahole) from the host tool
# list. Neither is needed for a MIPS router image: they exist to generate BTF
# debug info, and this profile does not enable CONFIG_DEBUG_INFO_BTF.
drop_elfutils() {
	local TM="$SRC/tools/Makefile"
	[ -f "$TM" ] || { warn "no $TM -- cannot drop elfutils"; return 0; }
	if ! grep -q '^tools-y += elfutils' "$TM"; then
		warn "tools/Makefile has no 'tools-y += elfutils' line -- nothing to drop"
		return 0
	fi
	cp "$TM" "$TM.orig"
	sed -i -E \
		-e 's|^tools-y \+= elfutils$|# &  # dropped: BTF/pahole not used|' \
		-e 's|^(\s*)\$\(curdir\)/dwarves/compile|#\1$(curdir)/dwarves/compile|' \
		-e 's|^(\s*)tools-\$\(if \$\(CONFIG_BUILD_ALL_HOST_TOOLS\)\$\(CONFIG_DWARVES\),y\) \+= dwarves|#\1&|' \
		"$TM"
	info "tools/Makefile: $(grep -c '^#' "$TM.orig") -> $(grep -c '^#' "$TM") comment lines"
	ok "elfutils + dwarves removed from the host tool list"
}

# A hung child (a stalled package download is the usual one) keeps make alive
# forever: make reports the failed package and then waits on its outstanding
# jobs, so nothing downstream ever runs. Run #8 burned its whole 350-minute
# budget that way. A hard timeout turns that into a normal, diagnosable failure.
MAKE_TIMEOUT="${MAKE_TIMEOUT:-260m}"

run_make() {
	if ( cd "$SRC" && timeout --signal=INT --kill-after=3m "$MAKE_TIMEOUT" \
			make -j"$JOBS" 2>&1 | tee -a "$MAKELOG" | tail -40 ); then
		return 0
	fi

	FAILED="$(grep -oE 'ERROR: [^ ]+ failed to build' "$MAKELOG" | tail -1 | awk '{print $2}')"
	if [ -z "$FAILED" ]; then
		warn "could not identify a failing package from the make output"
		return 1
	fi

	# `make -j` prints one summary line per failed package and swallows the
	# compiler message, so re-run the culprit alone to put the reason on record.
	warn "make failed at $FAILED -- rebuilding it alone with V=s to surface the reason"
	{
		printf '\n========== VERBOSE RETRY: %s ==========\n' "$FAILED"
		( cd "$SRC" && make "$FAILED/clean" V=s >/dev/null 2>&1 || true
		  make -j1 "$FAILED/compile" V=s 2>&1 | tail -150 )
		printf '\n========== END VERBOSE RETRY ==========\n'
	} 2>&1 | tee -a "$MAKELOG" | tail -160 || true

	if [ "$FAILED" = "tools/elfutils" ] && [ "$SKIP_ELFUTILS" = 0 ]; then
		warn "elfutils is only required by dwarves/pahole for BTF -- not used by this image"
		warn "dropping it and resuming the build (same run, no new CI job)"
		drop_elfutils
		SKIP_ELFUTILS=1
		return 2
	fi
	return 1
}

# tools/elfutils fails on the stock runner and takes the whole run with it:
# run 7 died there, run 8 hung there for six hours, run 13 hit it again in the
# tools-only stage. Nothing in a MIPS router image needs it -- it is only a
# dependency of dwarves/pahole, which generate BTF, and CONFIG_DEBUG_INFO_BTF
# is off -- so drop it before any make runs, in every mode.
if [ "$KEEP_ELFUTILS" = 1 ]; then
	info "keeping tools/elfutils (--keep-elfutils)"
else
	drop_elfutils
fi

# Host tools are the riskiest stage on a fresh tree: they are compiled with the
# host gcc, they run first, and one failure there costs the whole run. --tools
# builds just that stage (~30 min) so a broken tool can be diagnosed without
# spending the 4-hour budget.
if [ "$TOOLS_ONLY" = 1 ]; then
	say "Host tools only (make tools/compile) -- isolates toolchain failures"
	: >"$MAKELOG"
	( cd "$SRC" && timeout --signal=INT --kill-after=3m "${TOOLS_TIMEOUT:-70m}" \
			make -j"$JOBS" tools/compile 2>&1 | tee -a "$MAKELOG" | tail -40 ) || true
	FAILED="$(grep -oE 'ERROR: [^ ]+ failed to build' "$MAKELOG" | tail -1 | awk '{print $2}')"
	if [ -n "$FAILED" ]; then
		warn "host tool failed: $FAILED -- rebuilding it alone with V=s"
		{
			echo; echo "========== VERBOSE RETRY: $FAILED =========="
			( cd "$SRC" && make "$FAILED/clean" V=s >/dev/null 2>&1 || true
			  make -j1 "$FAILED/compile" V=s 2>&1 | tail -150 )
			echo; echo "========== END VERBOSE RETRY =========="
		} 2>&1 | tee -a "$MAKELOG" | tail -160 || true
		die "host tools failed at $FAILED -- see $MAKELOG"
	fi
	grep -qE 'make(\[[0-9]+\])?: \*\*\*' "$MAKELOG" && die "make errored without naming a package -- see $MAKELOG"
	ok "host tools built clean"
	exit 0
fi

say "Building (jobs=$JOBS) -- first run downloads ~3 GB of sources and takes 2-4 h"
# elfutils was already dropped above, before either branch could run make.
rc=0
run_make || rc=$?
if [ "$rc" = 2 ]; then
	info "resuming after the elfutils fallback"
	rc=0
	run_make || rc=$?
fi
[ "$rc" = 0 ] || die "build failed -- full output in $MAKELOG"

# ---------------------------------------------------------------- artifacts --
say "Collecting artifacts"
OUT="$HERE/out"
mkdir -p "$OUT"
found=0
for pat in "*wr1204s*factory.bin" "*wr1204s*sysupgrade.bin" "*wr1204s*initramfs*" "*wr1204s*Image*"; do
	for f in "$SRC"/bin/targets/siflower/sf19a2890/$pat; do
		[ -f "$f" ] || continue
		case "$f" in *.itb|*.bin|*.tar) cp "$f" "$OUT/" && found=$((found+1)) ;; esac
	done
done
[ "$found" -gt 0 ] || die "no artifacts found under $SRC/bin/targets/siflower/sf19a2890/"

printf '\n\033[1;32m========== BUILD OK ==========\033[0m\n'
for f in "$OUT"/*; do
	[ -f "$f" ] || continue
	printf '  %-58s %10d bytes\n' "$(basename "$f")" "$(wc -c < "$f")"
	printf '     sha256 %s\n' "$(sha256sum "$f" | cut -d' ' -f1)"
done
printf '\n  flash on the router (no sysupgrade -- custom partition layout):\n'
printf '    cat factory.bin | ssh root@192.168.100.1 "cat > /tmp/fw.bin"\n'
printf '    ssh root@192.168.100.1 "wr1204s-upgrade -n /tmp/fw.bin && wr1204s-upgrade /tmp/fw.bin && reboot"\n\n'

# 触发探测（2026-11-15 08:40）：验证 push 事件是否还能拉起工作流
