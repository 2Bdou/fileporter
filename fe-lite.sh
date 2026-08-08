#!/usr/bin/env bash
# ============================================================
# FileExpress 轻量部署脚本（无 Docker）
# 适用：1核 256MB 5GB 小机器
# 组件：Node 22 官方二进制 + systemd + Caddy（自动 HTTPS，替代 nginx+certbot）
# 仓库：https://github.com/alivedou/FileExpress (v2)
#
# 用法：
#   ./fe-lite.sh pack                   # 在有 Node20+ 的机器上构建打包（产出 fileexpress-lite.tar.gz）
#   ./fe-lite.sh deploy [tar路径|URL]   # 在小机器上部署（首次）
#   ./fe-lite.sh update [tar路径|URL]   # 用新包更新代码（保留数据与配置）
#   ./fe-lite.sh status                 # 查看服务状态
#   ./fe-lite.sh logs                   # 查看日志
#   ./fe-lite.sh uninstall              # 卸载（保留数据）
# ============================================================
set -euo pipefail

BASE_DIR=/opt/fileexpress
APP_USER=fileexpress
APP_PORT=3000
NODE_MAJOR=22
PACK_NAME=fileexpress-lite.tar.gz
REPO_URL=https://github.com/alivedou/FileExpress.git
REPO_BRANCH=v2

# ---------- 基础工具 ----------
GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; NC='\033[0m'
ok()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn(){ echo -e "${YELLOW}[!]${NC} $*"; }
err() { echo -e "${RED}[✗]${NC} $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || err "缺少命令: $1（请先安装）"; }

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) err "不支持的架构: $(uname -m)" ;;
  esac
}

get_node_latest() {
  # 从 nodejs.org 解析 latest-v22.x 的最新版本号
  curl -sL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/" \
    | grep -oE "node-v${NODE_MAJOR}\.[0-9]+\.[0-9]+" | head -1 | sed 's/node-//'
}

ensure_root() {
  [ "$(id -u)" = "0" ] || err "请用 root 运行（sudo ./fe-lite.sh ...）"
}

# ============================================================
# pack：构建 + 打包（在有大内存的机器上跑，256MB 机器不要跑这个）
# ============================================================
cmd_pack() {
  need git
  need npm
  local node_ver
  node_ver=$(node -v 2>/dev/null | sed 's/v//' | cut -d. -f1)
  [ -n "$node_ver" ] && [ "$node_ver" -ge 20 ] 2>/dev/null || err "需要 Node 20+（当前: $(node -v 2>/dev/null || echo 无)）"

  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp:-}"' EXIT
  local out_tar="$PWD/${PACK_NAME}"

  ok "拉取源码 $REPO_BRANCH ..."
  git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$tmp/fe" >/dev/null 2>&1

  cd "$tmp/fe"
  ok "安装依赖 (npm ci) ..."
  npm ci --no-audit --no-fund >/dev/null 2>&1

  ok "构建 (vite + esbuild) ..."
  npm run build >/dev/null 2>&1

  # 产物目录：重新干净安装生产依赖（prune 会误删嵌套依赖，弃用）
  ok "安装生产依赖 (npm ci --omit=dev) ..."
  mkdir -p "$tmp/out"
  cp -r dist package.json package-lock.json .env.example "$tmp/out/"
  ( cd "$tmp/out" && npm ci --omit=dev --no-audit --no-fund >/dev/null 2>&1 )

  ok "打包 ${PACK_NAME} ..."
  ( cd "$tmp/out" && tar czf "$out_tar" \
    --exclude='*.map' --exclude='node_modules/.cache' \
    . )

  ls -lh "$out_tar"
  ok "打包完成！把 ${PACK_NAME} 传到小机器后运行: ./fe-lite.sh deploy ${PACK_NAME}"
}

# ============================================================
# deploy：小机器部署
# ============================================================
cmd_deploy() {
  ensure_root
  local arch; arch=$(detect_arch)
  local tar_src="${1:-$PACK_NAME}"

  ok "目标机器: $(uname -m) / $(nproc)核 / $(free -m | awk '/Mem:/{print $2}')MB 内存"

  # ---- 0. 获取 tar 包 ----
  local tmp; tmp=$(mktemp -d)
  trap 'rm -rf "${tmp:-}"' EXIT
  if [[ "$tar_src" =~ ^https?:// ]]; then
    ok "下载部署包 $tar_src ..."
    curl -sL -o "$tmp/$PACK_NAME" "$tar_src"
    tar_src="$tmp/$PACK_NAME"
  fi
  [ -f "$tar_src" ] || err "找不到部署包: $tar_src（先在有 Node 的机器上跑 ./fe-lite.sh pack）"

  # ---- 1. 内存 < 512MB 自动加 swap 兜底 ----
  local mem_mb; mem_mb=$(free -m | awk '/Mem:/{print $2}')
  if [ "$mem_mb" -lt 512 ] && ! swapon --show | grep -q .; then
    warn "内存仅 ${mem_mb}MB 且无 swap，自动创建 512MB swap 兜底"
    fallocate -l 512M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=512
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "swap 已启用"
  fi

  # ---- 2. 安装 Node 官方二进制 ----
  if ! command -v node >/dev/null 2>&1 || [ "$(node -v | sed 's/v//' | cut -d. -f1)" -lt "$NODE_MAJOR" ]; then
    need curl
    need tar
    local nver; nver=$(get_node_latest)
    local narch=x64; [ "$arch" = "arm64" ] && narch=arm64
    ok "安装 Node ${nver} (linux-${narch}) ..."
    curl -sL -o "$tmp/node.tar.xz" "https://nodejs.org/dist/${nver}/node-${nver}-linux-${narch}.tar.xz"
    tar xJf "$tmp/node.tar.xz" -C /usr/local --strip-components=1
    ln -sf /usr/local/bin/node /usr/local/bin/node
    ok "Node: $(node -v)"
  else
    ok "Node 已就绪: $(node -v)"
  fi

  # ---- 3. 解压部署包 ----
  need tar
  [ -d "$BASE_DIR" ] && err "$BASE_DIR 已存在（如需更新用 ./fe-lite.sh update）"
  ok "解压到 $BASE_DIR ..."
  mkdir -p "$BASE_DIR"
  tar xzf "$tar_src" -C "$BASE_DIR"

  # ---- 4. 生成 .env ----
  if [ ! -f "$BASE_DIR/.env" ]; then
    local key; key=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(date +%s%N | md5sum | cut -d' ' -f1)")
    cat > "$BASE_DIR/.env" <<EOF
# FileExpress 配置（自动生成，可自行修改后 systemctl restart fileexpress）
NODE_ENV=production
APP_NAME=File Express
APP_SUBTITLE=极简、安全、临时的文件传输中心
PORT=${APP_PORT}
MAX_SINGLE_FILE_SIZE_MB=10
MAX_ZIP_PAYLOAD_SIZE_MB=100
MAX_TOTAL_STORAGE_MB=500
MAX_STORAGE_HOURS=24
MAX_DOWNLOADS=100
STORAGE_ENCRYPTION_KEY=${key}
EOF
    chmod 600 "$BASE_DIR/.env"
    ok ".env 已生成（加密密钥已随机生成，勿外泄）"
  fi

  # ---- 5. 专用用户 + systemd ----
  id -u "$APP_USER" >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin "$APP_USER"
  chown -R "$APP_USER":"$APP_USER" "$BASE_DIR"

  cat > /etc/systemd/system/fileexpress.service <<EOF
[Unit]
Description=FileExpress Lite
After=network.target

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${BASE_DIR}
ExecStart=/usr/local/bin/node dist/server.cjs
Restart=always
RestartSec=3
# 小内存机器限制，防止 OOM 前疯狂占内存
Environment=NODE_OPTIONS=--max-old-space-size=128

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now fileexpress >/dev/null 2>&1
  sleep 1
  systemctl is-active fileexpress >/dev/null 2>&1 || { journalctl -u fileexpress -n 20 --no-pager; err "fileexpress 启动失败，看上面日志"; }
  ok "fileexpress 运行中 (http://127.0.0.1:${APP_PORT})"

  # ---- 6. Caddy（自动 HTTPS，替代 nginx+certbot）----
  if ! command -v caddy >/dev/null 2>&1; then
    need curl
    need tar
    ok "安装 Caddy (linux-${arch}) ..."
    curl -sL -o "$tmp/caddy.tar.gz" "https://caddyserver.com/api/download?os=linux&arch=${arch}"
    tar xzf "$tmp/caddy.tar.gz" -C /usr/local/bin caddy
    chmod +x /usr/local/bin/caddy
    ok "Caddy: $(caddy version | head -c 30)"
  fi

  # 域名配置：留空则仅本机访问；填域名则自动 HTTPS
  echo -n "请输入要绑定的域名（留空跳过 HTTPS，如 file.example.com）: "
  read -r domain
  if [ -n "$domain" ]; then
    mkdir -p /etc/caddy
    cat > /etc/caddy/Caddyfile <<EOF
${domain} {
    reverse_proxy 127.0.0.1:${APP_PORT}
}
EOF
    systemctl enable caddy >/dev/null 2>&1 || true
    if systemctl list-unit-files | grep -q '^caddy.service'; then
      systemctl restart caddy
    else
      # 无 systemd 服务则手动启动（多数发行版装完有服务；没有就前台守护用这个兜底）
      nohup caddy run --config /etc/caddy/Caddyfile >/var/log/caddy.log 2>&1 &
    fi
    ok "Caddy 已配置 ${domain}（确保域名 A 记录已指向本机 IP，且 80/443 端口放行）"
  else
    warn "未配置域名，仅 127.0.0.1:${APP_PORT} 可访问"
  fi

  # ---- 7. 验证 ----
  sleep 1
  local api; api=$(curl -s http://127.0.0.1:${APP_PORT}/api/health 2>/dev/null | head -c 200)
  if [ -n "$api" ]; then
    ok "本机 API 验证通过"
  else
    warn "API 暂未响应，稍后 curl http://127.0.0.1:${APP_PORT} 自测"
  fi
  ok "部署完成！"
  echo "  状态: ./fe-lite.sh status   日志: ./fe-lite.sh logs"
  [ -n "$domain" ] && echo "  访问: https://${domain}"
}

# ============================================================
# update：更新代码（保留 .env 和 local_storage）
# ============================================================
cmd_update() {
  ensure_root
  local tar_src="${1:-$PACK_NAME}"
  local tmp; tmp=$(mktemp -d)
  trap 'rm -rf "${tmp:-}"' EXIT
  [ -d "$BASE_DIR" ] || err "$BASE_DIR 不存在，请先 deploy"

  if [[ "$tar_src" =~ ^https?:// ]]; then
    ok "下载更新包 ..."
    curl -sL -o "$tmp/$PACK_NAME" "$tar_src"
    tar_src="$tmp/$PACK_NAME"
  fi
  [ -f "$tar_src" ] || err "找不到更新包: $tar_src"

  ok "解压更新包 ..."
  mkdir -p "$tmp/new"
  tar xzf "$tar_src" -C "$tmp/new"

  systemctl stop fileexpress
  cp -a "$tmp/new/." "$BASE_DIR/"     # 覆盖代码，local_storage/.env 原样保留
  chown -R "$APP_USER":"$APP_USER" "$BASE_DIR"
  systemctl start fileexpress
  sleep 1
  systemctl is-active fileexpress >/dev/null 2>&1 || err "更新后启动失败，日志: journalctl -u fileexpress -n 20"
  ok "更新完成，服务已重启"
}

# ============================================================
cmd_status() { systemctl status fileexpress --no-pager 2>/dev/null | head -15; [ -f /etc/caddy/Caddyfile ] && echo "--- Caddy ---" && caddy list-modules >/dev/null 2>&1; systemctl is-active caddy 2>/dev/null; }
cmd_logs()   { journalctl -u fileexpress -n "${1:-50}" --no-pager; }

cmd_uninstall() {
  ensure_root
  echo -n "确认卸载？数据将保留在 ${BASE_DIR}（仅停服务删配置）[y/N]: "
  read -r yn
  [ "$yn" = "y" ] || [ "$yn" = "Y" ] || { echo "已取消"; exit 0; }
  systemctl stop fileexpress 2>/dev/null || true
  systemctl disable fileexpress 2>/dev/null || true
  rm -f /etc/systemd/system/fileexpress.service
  systemctl daemon-reload
  echo "服务已卸载，数据仍在 ${BASE_DIR}（如需彻底删除: rm -rf ${BASE_DIR}）"
}

# ============================================================
case "${1:-}" in
  pack)      cmd_pack ;;
  deploy)    shift; cmd_deploy "${1:-}" ;;
  update)    shift; cmd_update "${1:-}" ;;
  status)    cmd_status ;;
  logs)      shift; cmd_logs "${1:-50}" ;;
  uninstall) cmd_uninstall ;;
  *) echo "用法: $0 {pack|deploy [tar]|update [tar]|status|logs|uninstall}"
     echo "  pack    在有 Node20+ 的机器构建打包 → ${PACK_NAME}"
     echo "  deploy  在小机器部署（自动装 Node+Caddy+swap）"
     echo "  update  用新包更新代码（保留数据配置）"
     exit 0 ;;
esac
