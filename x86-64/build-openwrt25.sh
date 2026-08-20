#!/bin/bash
# ====================================================================
# 基于 OpenWrt 25.12.5 官方 ImageBuilder
# 通过注入 ImmortalWrt 25.12.1 软件源，使用本项目的插件列表构建固件
# 说明：OpenWrt 官方已发布 25.12.5，但 ImmortalWrt 暂未发布 25.12.5
#       本脚本用 OpenWrt 25.12.5 官方 ImageBuilder 作为基础系统
#       追加 ImmortalWrt 25.12.1 软件源以获取 passwall/rclone/sirpdboy 等插件
# 运行环境：在 OpenWrt ImageBuilder 解压目录内运行
#           项目文件（shell/, files/）需已复制到当前目录
# ====================================================================
set -e

LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting build-openwrt25.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

# ============= 注入 ImmortalWrt 25.12.1 软件源 =============
# OpenWrt 25.12.5 官方源已存在于 repositories 文件
# 追加 ImmortalWrt 25.12.1 源，提供 passwall/rclone/sirpdboy 等 ImmortalWrt 特有包
# 注意：不追加 ImmortalWrt 的 kmods 源（内核版本不匹配会冲突）
IMM_VERSION="25.12.1"
IMM_BASE="https://downloads.immortalwrt.org/releases/${IMM_VERSION}"

echo "========================================"
echo "注入 ImmortalWrt ${IMM_VERSION} 软件源"
echo "========================================"

# 备份原始 repositories
cp repositories repositories.backup

# 追加 ImmortalWrt 源（base/luci/packages/routing/telephony + targets packages）
{
  echo ""
  echo "# ====== ImmortalWrt ${IMM_VERSION} packages (passwall/rclone/sirpdboy 等) ======"
  echo "${IMM_BASE}/targets/x86/64/packages/packages.adb"
  echo "${IMM_BASE}/packages/x86_64/base/packages.adb"
  echo "${IMM_BASE}/packages/x86_64/luci/packages.adb"
  echo "${IMM_BASE}/packages/x86_64/packages/packages.adb"
  echo "${IMM_BASE}/packages/x86_64/routing/packages.adb"
  echo "${IMM_BASE}/packages/x86_64/telephony/packages.adb"
} >> repositories

echo ">>> repositories.conf 内容:"
cat repositories

# ============= 加载第三方插件列表 =============
source shell/apk-custom-packages.sh
echo "第三方apk软件包: $CUSTOM_PACKAGES"

# ============= 创建 pppoe 配置 =============
echo "Create pppoe-settings"
mkdir -p files/etc/config

cat << EOF > files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat files/etc/config/pppoe-settings

# ============= 同步第三方 apk 仓库 =============
if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  # ============= 同步第三方插件库==============
  # 同步第三方软件仓库run/apk
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://github.com/wukongdaily/apk.git /tmp/store-apk-repo

  # 拷贝 run/x86 下所有 run 文件和apk文件 到 extra-packages 目录
  mkdir -p extra-packages
  cp -r /tmp/store-apk-repo/run/x86/* extra-packages/ 2>/dev/null || true

  echo "✅ Run files copied to extra-packages:"
  # 解压并拷贝apk到packages目录
  sh shell/apk-prepare-packages.sh
  ls -lah packages/ 2>/dev/null || true
fi

# ============= imm仓库内的插件 ==============
# 定义所需安装的包列表 下列插件你都可以自行删减
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"

# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
# ======== shell/apk-custom-packages.sh =======
# 合并imm仓库以外的第三方插件
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# 若构建openclash 则添加内核
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    # Download clash_meta
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    # Download GeoIP and GeoSite
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
    # Download latest openclash Client
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*apk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest apk: $URL"
    [ -n "$URL" ] && wget "$URL" -P packages/ || true
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

if echo "$PACKAGES" | grep -q "luci-app-ssr-plus"; then
    echo "✅ 已选择 luci-app-ssr-plus，添加 mihomo core"
    mkdir -p files/usr/bin
    # Download mihomo
    MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.24/mihomo-linux-amd64-compatible-v1.19.24.gz"
    mkdir -p files/usr/bin
    wget -qO- "$MIHOMO_URL" | gzip -dc > files/usr/bin/mihomo
    chmod +x files/usr/bin/mihomo
    echo "✅ 已下载 mihomo core"
    ls -lah files/usr/bin
else
    echo "⚪️ 未选择 luci-app-ssr-plus"
fi

# ============= 构建镜像 =============
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."
echo "Building image with the following packages:"
echo "$PACKAGES"

# 注入 ImmortalWrt 25.12.1 签名公钥到 apk 信任列表
# 解决 OpenWrt ImageBuilder 无法信任 ImmortalWrt 源的签名问题
echo "=== 注入 ImmortalWrt 签名公钥到 /etc/apk/keys/ ==="
mkdir -p /etc/apk/keys
cp shell/immortalwrt-25.12-key.pem /etc/apk/keys/ 2>/dev/null || true
chmod 644 /etc/apk/keys/immortalwrt-25.12-key.pem 2>/dev/null || true
ls -la /etc/apk/keys/

make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="$PWD/files" ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
