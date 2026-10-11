#!/usr/bin/env bash
# wgr — WireGuard 反向隧道一键部署
#   线路机 (line)：用户入口 VLESS+REALITY+XHTTP，WG 被动监听，按用户分流到各落地
#   落地机 (land)：主动拨 WG 到线路机，SS-2022 只监听隧道内网 IP，零公网入站
# 多线路 × 多落地：每台线路机一个 WG hub (wgr0)，落地机对每台线路机建一个独立接口 (wgr-<线路ID>)
# 所有文件独立于系统自带 xray / wireguard：/etc/wgr、/usr/local/lib/wgr、wgr-line / wgr-land 服务
set -euo pipefail

WGR_URL="${WGR_URL:-https://raw.githubusercontent.com/zhuoyi0918/wgr/main/wgr.sh}"
WGR_DIR=/etc/wgr
BIN_DIR=/usr/local/lib/wgr
XRAY=$BIN_DIR/xray
LINE_STATE=$WGR_DIR/line.json
LAND_STATE=$WGR_DIR/land.json
LINE_IF=wgr0
SS_METHOD=2022-blake3-aes-128-gcm
SS_PORT=8388
MTU=1380

die()  { echo -e "\e[31m[x] $*\e[0m" >&2; exit 1; }
info() { echo -e "\e[32m[+]\e[0m $*"; }
warn() { echo -e "\e[33m[!]\e[0m $*"; }
hr()   { echo "------------------------------------------------------------"; }

need_root() { [ "$(id -u)" = 0 ] || die "请用 root 运行"; }
valid_name() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,24}$ ]] || die "名字只能是字母/数字/_/-，最长 24：$1"; }

# ---------------------------------------------------------------- 安装依赖
install_deps() {
  if command -v apt-get >/dev/null; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq unzip openssl wireguard-tools iproute2 >/dev/null
  elif command -v dnf >/dev/null; then
    dnf install -y -q curl jq unzip openssl wireguard-tools iproute >/dev/null
  elif command -v yum >/dev/null; then
    yum install -y -q epel-release >/dev/null 2>&1 || true
    yum install -y -q curl jq unzip openssl wireguard-tools iproute >/dev/null
  else
    die "不支持的系统（需要 apt/dnf/yum）"
  fi
  local c; for c in curl jq unzip openssl wg wg-quick ip ss; do
    command -v "$c" >/dev/null || die "缺少命令：$c"
  done
  modprobe wireguard 2>/dev/null || true
  if ip link add wgr-probe type wireguard 2>/dev/null; then
    ip link del wgr-probe
  else
    die "内核不支持 WireGuard（LXC/OpenVZ 容器？需要 KVM 或内核 ≥5.6）"
  fi
}

install_self() {
  mkdir -p "$WGR_DIR" "$BIN_DIR"; chmod 700 "$WGR_DIR"
  local src; src=$(readlink -f "$0" 2>/dev/null || true)
  if [ "$src" = /usr/local/bin/wgr ]; then return; fi
  if [ -f "$src" ] && head -c 200 "$src" | grep -q 'wgr'; then
    install -m 755 "$src" /usr/local/bin/wgr
  else
    curl -fsSL "$WGR_URL" -o /usr/local/bin/wgr.tmp && chmod 755 /usr/local/bin/wgr.tmp \
      && mv /usr/local/bin/wgr.tmp /usr/local/bin/wgr || warn "下载 wgr 到 /usr/local/bin 失败，后续命令请用 bash <(curl -fsSL $WGR_URL)"
  fi
}

install_xray() {
  if [ -x "$XRAY" ] && [ "${1:-}" != force ]; then return; fi
  local f tmp
  case "$(uname -m)" in
    x86_64|amd64)  f=64 ;;
    aarch64|arm64) f=arm64-v8a ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac
  tmp=$(mktemp -d)
  info "下载 Xray-core (latest, linux-$f)"
  curl -fsSL -o "$tmp/x.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$f.zip" \
    || { rm -rf "$tmp"; die "下载 Xray 失败"; }
  unzip -qo "$tmp/x.zip" xray -d "$tmp"
  install -m 755 "$tmp/xray" "$XRAY.new" && mv -f "$XRAY.new" "$XRAY"
  rm -rf "$tmp"
  info "Xray $("$XRAY" version | head -1 | awk '{print $2}')"
}

write_unit() { # $1=服务名 $2=配置文件
  cat >/etc/systemd/system/"$1".service <<EOF
[Unit]
Description=wgr $1 (xray)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$XRAY run -c $2
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

apply_xray() { # $1=服务名 $2=配置文件 $3=新配置内容
  local tmp="$2.new"
  printf '%s\n' "$3" >"$tmp"; chmod 600 "$tmp"
  "$XRAY" run -test -c "$tmp" >/dev/null 2>&1 || { "$XRAY" run -test -c "$tmp" || true; rm -f "$tmp"; die "Xray 配置测试未通过，未改动原配置"; }
  [ -f "$2" ] && cp -a "$2" "$2.bak"
  mv -f "$tmp" "$2"
  systemctl enable "$1" >/dev/null 2>&1
  systemctl restart "$1"
  sleep 1
  systemctl is-active --quiet "$1" || { journalctl -u "$1" -n 20 --no-pager; die "$1 启动失败"; }
}

# ---------------------------------------------------------------- 工具函数
port_used_tcp() { ss -Hltn "sport = :$1" 2>/dev/null | grep -q .; }
port_used_udp() { ss -Hlun "sport = :$1" 2>/dev/null | grep -q .; }
rand_udp_port() { local p; while :; do p=$((RANDOM % 20000 + 40000)); port_used_udp "$p" || { echo "$p"; return; }; done; }

pick_subnet() { # 随机 10.200-249.x.0/24，避开本机已有地址/路由
  local a b _
  for _ in $(seq 1 200); do
    a=$((RANDOM % 50 + 200)); b=$((RANDOM % 256))
    if ! ip -4 addr | grep -q " 10\.$a\.$b\." && ! ip -4 route | grep -q "^10\.$a\.$b\."; then
      echo "10.$a.$b"; return
    fi
  done
  die "找不到空闲内网段"
}

pub_ip() {
  curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null \
    || curl -4 -fsS --max-time 6 https://ifconfig.me 2>/dev/null \
    || curl -4 -fsS --max-time 6 https://ip.sb 2>/dev/null || true
}

# 防火墙：只要装了 ufw 就加规则（未启用时预先写入，启用后自动生效；不会替你启用 ufw）
ufw_rule() { # $1=port $2=tcp|udp [$3=接口]  → 输出 ufw 规则参数
  if [ -n "${3:-}" ]; then echo "in on $3 to any port $1 proto $2"; else echo "$1/$2"; fi
}
fw_open() { # $1=port $2=tcp|udp [$3=只放行该接口]
  local desc="$1/$2${3:+ (仅 $3)}"
  if command -v ufw >/dev/null; then
    # shellcheck disable=SC2046
    ufw allow $(ufw_rule "$@") comment wgr >/dev/null || { warn "ufw 放行 $desc 失败，请手动处理"; return 0; }
    if ufw status 2>/dev/null | grep -qw active; then
      info "ufw 已放行 $desc"
    else
      info "检测到 ufw（未启用），已预先添加放行规则 $desc，启用后生效"
    fi
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    if [ -n "${3:-}" ]; then
      firewall-cmd -q --permanent --zone=trusted --add-interface="$3"
    else
      firewall-cmd -q --permanent --add-port="$1/$2"
    fi
    firewall-cmd -q --reload && info "firewalld 已放行 $desc"
  fi
  return 0
}
fw_close() { # 参数同 fw_open
  if command -v ufw >/dev/null; then
    # shellcheck disable=SC2046
    ufw delete allow $(ufw_rule "$@") >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    if [ -n "${3:-}" ]; then
      firewall-cmd -q --permanent --zone=trusted --remove-interface="$3" 2>/dev/null || true
    else
      firewall-cmd -q --permanent --remove-port="$1/$2" 2>/dev/null || true
    fi
    firewall-cmd -q --reload || true
  fi
  return 0
}

wg_up_or_sync() { # $1=接口
  if ip link show "$1" >/dev/null 2>&1; then
    wg syncconf "$1" <(wg-quick strip "$1")
  else
    systemctl enable --now "wg-quick@$1" >/dev/null 2>&1 || { journalctl -u "wg-quick@$1" -n 20 --no-pager; die "wg-quick@$1 启动失败"; }
  fi
}

jset() { # $1=state文件 $2...=jq 参数（最后一个为表达式）
  local f=$1; shift
  local out; out=$(jq "$@" "$f") || die "更新状态失败"
  printf '%s\n' "$out" >"$f.tmp" && chmod 600 "$f.tmp" && mv -f "$f.tmp" "$f"
}

# ================================================================ 线路机 line
line_render() {
  local s; s=$(cat "$LINE_STATE")
  # WireGuard
  {
    echo "[Interface]"
    echo "PrivateKey = $(jq -r .wg_priv <<<"$s")"
    echo "Address = $(jq -r .subnet <<<"$s").1/24"
    echo "ListenPort = $(jq -r .wg_port <<<"$s")"
    echo "MTU = $MTU"
    jq -r '.subnet as $sn | .lands[] | "\n[Peer]\n# \(.name)\nPublicKey = \(.pub)\nAllowedIPs = \($sn).\(.n)/32"' <<<"$s"
  } >/etc/wireguard/$LINE_IF.conf
  chmod 600 /etc/wireguard/$LINE_IF.conf
  wg_up_or_sync "$LINE_IF"

  # Xray
  local cfg
  cfg=$(jq --arg m "$SS_METHOD" --argjson sp "$SS_PORT" '
    . as $s | {
      log: {loglevel: "warning"},
      inbounds: [{
        tag: "user-in", listen: "0.0.0.0", port: .port, protocol: "vless",
        settings: {clients: [.users[] | {id: .uuid, email: .name}], decryption: "none"},
        streamSettings: {
          network: "xhttp", security: "reality",
          xhttpSettings: {path: .path, mode: "auto"},
          realitySettings: {target: (.sni + ":443"), serverNames: [.sni],
                            privateKey: .reality_priv, shortIds: [.sid]}
        },
        sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}
      }],
      outbounds: ([{tag: "block", protocol: "blackhole"}] + [.lands[] | {
        tag: ("land-" + .name), protocol: "shadowsocks",
        settings: {servers: [{address: ($s.subnet + "." + (.n|tostring)), port: $sp, method: $m, password: .ss}]}
      }]),
      routing: {rules: [.lands[] | .name as $ln
        | ([$s.users[] | select(.land == $ln) | .name]) as $u
        | select($u | length > 0)
        | {type: "field", user: $u, outboundTag: ("land-" + $ln)}]}
    }' <<<"$s")
  apply_xray wgr-line "$WGR_DIR/line-xray.json" "$cfg"
}

line_link() { # $1=user
  local s; s=$(cat "$LINE_STATE")
  jq -r --arg u "$1" '
    (.users[] | select(.name == $u)) as $x
    | "vless://\($x.uuid)@\(.endpoint):\(.port)?encryption=none&security=reality&type=xhttp&path=\(.path|@uri)&mode=auto&sni=\(.sni)&fp=chrome&pbk=\(.reality_pub)&sid=\(.sid)#\($x.name)"' <<<"$s"
}

line_joincmd() { # $1=land
  local s blob; s=$(cat "$LINE_STATE")
  blob=$(jq -c --arg l "$1" --argjson sp "$SS_PORT" '
    (.lands[] | select(.name == $l)) as $x
    | {v: 1, line_id: .id, endpoint: .endpoint, wg_port: .wg_port, line_pub: .wg_pub,
       line_ip: (.subnet + ".1"), addr: (.subnet + "." + ($x.n|tostring)),
       priv: $x.priv, ss: $x.ss, ss_port: $sp, name: $x.name}' <<<"$s" | base64 -w0)
  [ -n "$blob" ] || die "落地不存在：$1"
  echo "bash <(curl -fsSL $WGR_URL) land join $blob"
}

line_init() {
  [ -f "$LINE_STATE" ] && die "本机已是线路机（$LINE_STATE）。重装请先：wgr uninstall line"
  local endpoint="" port=443 sni=www.microsoft.com wg_port=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --endpoint) endpoint=$2; shift 2 ;;
      --port)     port=$2; shift 2 ;;
      --sni)      sni=$2; shift 2 ;;
      --wg-port)  wg_port=$2; shift 2 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  port_used_tcp "$port" && die "TCP $port 已被占用：$(ss -Hltnp "sport = :$port" | head -1)"
  ip link show "$LINE_IF" >/dev/null 2>&1 && die "接口 $LINE_IF 已存在"

  install_deps; install_self; install_xray

  if ! timeout 6 openssl s_client -connect "$sni:443" -servername "$sni" -tls1_3 </dev/null 2>/dev/null | grep -q "TLSv1.3"; then
    warn "$sni 未通过 TLS1.3 检测，建议换一个 --sni"
  fi
  [ -n "$endpoint" ] || endpoint=$(pub_ip)
  [ -n "$endpoint" ] || die "探测公网 IP 失败，请加 --endpoint <域名或IP>"
  if [ -z "$wg_port" ]; then wg_port=51820; port_used_udp $wg_port && wg_port=$(rand_udp_port); fi
  port_used_udp "$wg_port" && die "UDP $wg_port 已被占用"

  local wpriv wpub keys rpriv rpub
  wpriv=$(wg genkey); wpub=$(wg pubkey <<<"$wpriv")
  keys=$("$XRAY" x25519)
  rpriv=$(sed -n 1p <<<"$keys" | awk -F': *' '{print $2}')
  rpub=$(sed -n 2p <<<"$keys" | awk -F': *' '{print $2}')
  [ -n "$rpriv" ] && [ -n "$rpub" ] || die "生成 REALITY 密钥失败"

  jq -n --arg id "$(openssl rand -hex 3)" --arg ep "$endpoint" --argjson port "$port" --arg sni "$sni" \
        --argjson wp "$wg_port" --arg sn "$(pick_subnet)" --arg wpriv "$wpriv" --arg wpub "$wpub" \
        --arg rpriv "$rpriv" --arg rpub "$rpub" --arg sid "$(openssl rand -hex 8)" --arg path "/$(openssl rand -hex 12)" \
    '{id:$id, endpoint:$ep, port:$port, sni:$sni, path:$path, sid:$sid, reality_priv:$rpriv, reality_pub:$rpub,
      wg_port:$wp, subnet:$sn, wg_priv:$wpriv, wg_pub:$wpub, lands:[], users:[]}' >"$LINE_STATE"
  chmod 600 "$LINE_STATE"

  write_unit wgr-line "$WGR_DIR/line-xray.json"
  line_render
  fw_open "$port" tcp; fw_open "$wg_port" udp

  hr
  info "线路机初始化完成  ID=$(jq -r .id "$LINE_STATE")  入口=$endpoint:$port/tcp  WG=$wg_port/udp"
  warn "云厂商安全组请放行：$port/tcp、$wg_port/udp"
  echo "下一步：wgr line add-land <落地名>"
}

line_add_land() {
  [ -f "$LINE_STATE" ] || die "本机还不是线路机，先 wgr line init"
  local name=${1:-}; [ -n "$name" ] || die "用法：wgr line add-land <落地名>"; valid_name "$name"
  jq -e --arg n "$name" '.lands[] | select(.name == $n)' "$LINE_STATE" >/dev/null && die "落地 $name 已存在"
  local n; n=$(jq '[.lands[].n] | (max // 1) + 1' "$LINE_STATE")
  [ "$n" -le 254 ] || die "落地数量已满"
  local priv pub ss uuid
  priv=$(wg genkey); pub=$(wg pubkey <<<"$priv"); ss=$(openssl rand -base64 16); uuid=$("$XRAY" uuid)
  jset "$LINE_STATE" --arg name "$name" --argjson n "$n" --arg priv "$priv" --arg pub "$pub" --arg ss "$ss" --arg uuid "$uuid" \
    '.lands += [{name:$name, n:$n, priv:$priv, pub:$pub, ss:$ss}]
     | if any(.users[]; .name == $name) then . else .users += [{name:$name, uuid:$uuid, land:$name}] end'
  line_render
  hr; info "已添加落地 $name（隧道 IP $(jq -r .subnet "$LINE_STATE").$n）"
  echo; echo "▶ 在落地机 $name 上执行："; echo; line_joincmd "$name"; echo
  if jq -e --arg n "$name" '.users[] | select(.name == $n and .land == $n)' "$LINE_STATE" >/dev/null; then
    echo "▶ 客户端链接（用户 $name → 落地 $name）："; echo; line_link "$name"; echo
  else
    warn "已有同名用户 $name 走别的落地，未自动建用户；用 wgr line add-user <用户> $name 添加"
  fi
}

line_del_land() {
  local name=${1:-}; [ -n "$name" ] || die "用法：wgr line del-land <落地名>"
  jq -e --arg n "$name" '.lands[] | select(.name == $n)' "$LINE_STATE" >/dev/null || die "落地不存在：$name"
  jset "$LINE_STATE" --arg n "$name" '.lands |= map(select(.name != $n)) | .users |= map(select(.land != $n))'
  line_render
  info "已删除落地 $name 及其用户。落地机上执行：wgr land leave $(jq -r .id "$LINE_STATE")"
}

line_add_user() {
  local u=${1:-} l=${2:-}; [ -n "$u" ] && [ -n "$l" ] || die "用法：wgr line add-user <用户名> <落地名>"
  valid_name "$u"
  jq -e --arg n "$l" '.lands[] | select(.name == $n)' "$LINE_STATE" >/dev/null || die "落地不存在：$l"
  jq -e --arg n "$u" '.users[] | select(.name == $n)' "$LINE_STATE" >/dev/null && die "用户已存在：$u"
  jset "$LINE_STATE" --arg u "$u" --arg l "$l" --arg id "$("$XRAY" uuid)" '.users += [{name:$u, uuid:$id, land:$l}]'
  line_render; info "已添加用户 $u → $l"; line_link "$u"
}

line_move_user() {
  local u=${1:-} l=${2:-}; [ -n "$u" ] && [ -n "$l" ] || die "用法：wgr line move-user <用户名> <落地名>"
  jq -e --arg n "$l" '.lands[] | select(.name == $n)' "$LINE_STATE" >/dev/null || die "落地不存在：$l"
  jq -e --arg n "$u" '.users[] | select(.name == $n)' "$LINE_STATE" >/dev/null || die "用户不存在：$u"
  jset "$LINE_STATE" --arg u "$u" --arg l "$l" '.users |= map(if .name == $u then .land = $l else . end)'
  line_render; info "用户 $u 已改走落地 $l（链接不变）"
}

line_del_user() {
  local u=${1:-}; [ -n "$u" ] || die "用法：wgr line del-user <用户名>"
  jset "$LINE_STATE" --arg u "$u" '.users |= map(select(.name != $u))'
  line_render; info "已删除用户 $u"
}

line_links() {
  local u; for u in $(jq -r '.users[].name' "$LINE_STATE"); do line_link "$u"; done
}

line_status() {
  local s; s=$(cat "$LINE_STATE")
  hr; echo "线路机  ID=$(jq -r .id <<<"$s")  入口 $(jq -r '"\(.endpoint):\(.port)"' <<<"$s")  WG UDP $(jq -r .wg_port <<<"$s")  内网 $(jq -r .subnet <<<"$s").0/24"
  echo "wgr-line: $(systemctl is-active wgr-line)   wg-quick@$LINE_IF: $(systemctl is-active wg-quick@$LINE_IF)"
  hr
  printf "%-16s %-16s %-12s %-6s %s\n" 落地 隧道IP 最近握手 SS 用户
  local now; now=$(date +%s)
  while IFS=$'\t' read -r name ip pub users; do
    local hs age ssok
    hs=$(wg show $LINE_IF latest-handshakes 2>/dev/null | awk -v p="$pub" '$1==p{print $2}')
    if [ -z "$hs" ] || [ "$hs" = 0 ]; then age="从未"; else age="$((now - hs))s前"; fi
    if timeout 2 bash -c "</dev/tcp/$ip/$SS_PORT" 2>/dev/null; then ssok=OK; else ssok=不通; fi
    printf "%-16s %-16s %-12s %-6s %s\n" "$name" "$ip" "$age" "$ssok" "$users"
  done < <(jq -r '.subnet as $sn | . as $s | .lands[] | .name as $ln
             | [.name, "\($sn).\(.n)", .pub, ([$s.users[] | select(.land == $ln) | .name] | join(","))] | @tsv' <<<"$s")
}

# ================================================================ 落地机 land
land_render() {
  local s; s=$(cat "$LAND_STATE")
  local cfg
  cfg=$(jq --arg m "$SS_METHOD" '{
      log: {loglevel: "warning"},
      inbounds: [.tunnels[] | {
        tag: ("from-" + .line_id), listen: .addr, port: .ss_port, protocol: "shadowsocks",
        settings: {method: $m, password: .ss, network: "tcp,udp"}
      }],
      outbounds: [{tag: "direct", protocol: "freedom"}]
    }' <<<"$s")
  if [ "$(jq '.tunnels | length' <<<"$s")" = 0 ]; then
    systemctl disable --now wgr-land >/dev/null 2>&1 || true
    return
  fi
  apply_xray wgr-land "$WGR_DIR/land-xray.json" "$cfg"
}

land_write_wg() { # $1=tunnel json
  local t=$1 iface; iface="wgr-$(jq -r .line_id <<<"$t")"
  cat >/etc/wireguard/"$iface".conf <<EOF
[Interface]
PrivateKey = $(jq -r .priv <<<"$t")
Address = $(jq -r .addr <<<"$t")/32
MTU = $MTU

[Peer]
PublicKey = $(jq -r .line_pub <<<"$t")
Endpoint = $(jq -r '"\(.endpoint):\(.wg_port)"' <<<"$t")
AllowedIPs = $(jq -r .line_ip <<<"$t")/32
PersistentKeepalive = 25
EOF
  chmod 600 /etc/wireguard/"$iface".conf
}

land_install_watchdog() {
  cat >/etc/systemd/system/wgr-watchdog.service <<EOF
[Unit]
Description=wgr land watchdog (重新解析线路机地址/拉起隧道)
[Service]
Type=oneshot
ExecStart=/usr/local/bin/wgr watchdog
EOF
  cat >/etc/systemd/system/wgr-watchdog.timer <<EOF
[Unit]
Description=wgr land watchdog timer
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now wgr-watchdog.timer >/dev/null 2>&1
}

land_join() {
  local blob=${1:-}; [ -n "$blob" ] || die "用法：wgr land join <线路机给出的参数>"
  local t; t=$(base64 -d <<<"$blob" 2>/dev/null) || die "参数无法解码"
  jq -e '.v == 1 and .line_id and .priv and .ss and .addr' <<<"$t" >/dev/null 2>&1 || die "参数格式不对"
  local lid addr iface; lid=$(jq -r .line_id <<<"$t"); addr=$(jq -r .addr <<<"$t"); iface="wgr-$lid"

  install_deps; install_self; install_xray
  [ -f "$LAND_STATE" ] || { echo '{"tunnels":[]}' >"$LAND_STATE"; chmod 600 "$LAND_STATE"; }

  if jq -e --arg l "$lid" '.tunnels[] | select(.line_id == $l)' "$LAND_STATE" >/dev/null; then
    warn "已存在到线路机 $lid 的隧道，覆盖更新"
    jset "$LAND_STATE" --arg l "$lid" '.tunnels |= map(select(.line_id != $l))'
  elif ip -4 addr | grep -q " $addr/"; then
    die "本机已有地址 $addr，和现有网络冲突"
  fi
  jset "$LAND_STATE" --argjson t "$t" '.tunnels += [$t | del(.v)]'

  # 允许 xray 在隧道接口起来之前绑定隧道 IP，开机顺序无关
  echo "net.ipv4.ip_nonlocal_bind = 1" >/etc/sysctl.d/99-wgr.conf
  sysctl -q -w net.ipv4.ip_nonlocal_bind=1

  land_write_wg "$t"
  systemctl restart "wg-quick@$iface" 2>/dev/null || true
  systemctl enable --now "wg-quick@$iface" >/dev/null 2>&1 || { journalctl -u "wg-quick@$iface" -n 20 --no-pager; die "wg-quick@$iface 启动失败"; }

  # 本机若有 ufw/firewalld：只在隧道接口上放行 SS 端口（公网仍然零入站）
  fw_open "$(jq -r .ss_port <<<"$t")" tcp "$iface"
  fw_open "$(jq -r .ss_port <<<"$t")" udp "$iface"

  write_unit wgr-land "$WGR_DIR/land-xray.json"
  land_render
  land_install_watchdog

  local _ hs=0; for _ in $(seq 1 15); do
    hs=$(wg show "$iface" latest-handshakes | awk '{print $2}'); [ "${hs:-0}" != 0 ] && break; sleep 1
  done
  hr
  if [ "${hs:-0}" != 0 ]; then
    info "隧道已握手：$iface  $addr ⇄ $(jq -r .line_ip <<<"$t")（线路机 $lid / 落地名 $(jq -r .name <<<"$t")）"
  else
    warn "15 秒内没有握手。检查线路机安全组是否放行 UDP $(jq -r .wg_port <<<"$t")，以及 $(jq -r .endpoint <<<"$t") 是否可达"
  fi
  info "SS-2022 监听 $addr:$(jq -r .ss_port <<<"$t")（仅隧道内）；本机无需开放任何入站端口"
}

land_leave() {
  local lid=${1:-}; [ -n "$lid" ] || die "用法：wgr land leave <线路机ID>（wgr status 查看）"
  jq -e --arg l "$lid" '.tunnels[] | select(.line_id == $l)' "$LAND_STATE" >/dev/null || die "没有到 $lid 的隧道"
  systemctl disable --now "wg-quick@wgr-$lid" >/dev/null 2>&1 || true
  rm -f "/etc/wireguard/wgr-$lid.conf"
  fw_close "$SS_PORT" tcp "wgr-$lid"; fw_close "$SS_PORT" udp "wgr-$lid"
  jset "$LAND_STATE" --arg l "$lid" '.tunnels |= map(select(.line_id != $l))'
  land_render
  info "已移除到线路机 $lid 的隧道"
}

land_status() {
  local now; now=$(date +%s)
  hr; echo "落地机   wgr-land: $(systemctl is-active wgr-land 2>/dev/null || true)   出口 IP: $(pub_ip)"; hr
  printf "%-10s %-12s %-26s %-16s %s\n" 线路ID 落地名 线路机 隧道IP 最近握手
  while IFS=$'\t' read -r lid name ep addr; do
    local hs age
    hs=$(wg show "wgr-$lid" latest-handshakes 2>/dev/null | awk '{print $2}')
    if [ -z "$hs" ] || [ "$hs" = 0 ]; then age="从未/接口未起"; else age="$((now - hs))s前"; fi
    printf "%-10s %-12s %-26s %-16s %s\n" "$lid" "$name" "$ep" "$addr" "$age"
  done < <(jq -r '.tunnels[] | [.line_id, .name, "\(.endpoint):\(.wg_port)", .addr] | @tsv' "$LAND_STATE")
}

watchdog() {
  [ -f "$LAND_STATE" ] || exit 0
  local now; now=$(date +%s)
  while IFS=$'\t' read -r lid pub ep; do
    local iface="wgr-$lid" hs
    if ! ip link show "$iface" >/dev/null 2>&1; then
      systemctl restart "wg-quick@$iface" || true; continue
    fi
    hs=$(wg show "$iface" latest-handshakes 2>/dev/null | awk '{print $2}')
    if [ -z "$hs" ] || [ "$hs" = 0 ] || [ $((now - hs)) -gt 180 ]; then
      wg set "$iface" peer "$pub" endpoint "$ep" 2>/dev/null || true   # 重新解析域名
    fi
  done < <(jq -r '.tunnels[] | [.line_id, .line_pub, "\(.endpoint):\(.wg_port)"] | @tsv' "$LAND_STATE")
  systemctl is-active --quiet wgr-land || systemctl restart wgr-land || true
}

# ================================================================ 卸载 / 更新
uninstall() {
  local what=${1:-all}
  if [ "$what" = line ] || [ "$what" = all ]; then
    if [ -f "$LINE_STATE" ]; then
      fw_close "$(jq -r .port "$LINE_STATE")" tcp; fw_close "$(jq -r .wg_port "$LINE_STATE")" udp
    fi
    systemctl disable --now wgr-line "wg-quick@$LINE_IF" >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/wgr-line.service "/etc/wireguard/$LINE_IF.conf" "$LINE_STATE" "$WGR_DIR"/line-xray.json*
    info "已卸载线路机角色"
  fi
  if [ "$what" = land ] || [ "$what" = all ]; then
    if [ -f "$LAND_STATE" ]; then
      local lid; for lid in $(jq -r '.tunnels[].line_id' "$LAND_STATE"); do
        systemctl disable --now "wg-quick@wgr-$lid" >/dev/null 2>&1 || true; rm -f "/etc/wireguard/wgr-$lid.conf"
        fw_close "$SS_PORT" tcp "wgr-$lid"; fw_close "$SS_PORT" udp "wgr-$lid"
      done
    fi
    systemctl disable --now wgr-land wgr-watchdog.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/wgr-land.service /etc/systemd/system/wgr-watchdog.* /etc/sysctl.d/99-wgr.conf \
          "$LAND_STATE" "$WGR_DIR"/land-xray.json*
    info "已卸载落地机角色"
  fi
  systemctl daemon-reload
  if [ ! -f "$LINE_STATE" ] && [ ! -f "$LAND_STATE" ]; then
    rm -rf "$BIN_DIR" /usr/local/bin/wgr; rmdir "$WGR_DIR" 2>/dev/null || true
  fi
}

update() {
  curl -fsSL "$WGR_URL" -o /usr/local/bin/wgr.tmp && chmod 755 /usr/local/bin/wgr.tmp && mv -f /usr/local/bin/wgr.tmp /usr/local/bin/wgr
  install_xray force
  [ -f "$LINE_STATE" ] && systemctl restart wgr-line
  [ -f "$LAND_STATE" ] && systemctl restart wgr-land
  info "已更新 wgr 与 Xray"
}

usage() {
  cat <<EOF
wgr — WireGuard 反向隧道（线路机 VLESS+REALITY+XHTTP 入口 / 落地机 SS-2022 出口）

线路机：
  wgr line init [--endpoint 域名或IP] [--port 443] [--sni www.microsoft.com] [--wg-port 51820]
  wgr line add-land <落地名>          新增落地，输出落地机部署命令 + 客户端链接
  wgr line del-land <落地名>
  wgr line join-cmd <落地名>          重新打印落地机部署命令
  wgr line add-user <用户> <落地名>   同一落地加多个用户
  wgr line move-user <用户> <落地名>  用户改走另一个落地（链接不变）
  wgr line del-user <用户>
  wgr line links                      打印全部客户端链接
落地机：
  wgr land join <参数>                加入一台线路机（可多次，对接多台线路机）
  wgr land leave <线路机ID>
通用：
  wgr status | wgr update | wgr uninstall [line|land|all]
EOF
}

main() {
  local cmd=${1:-}; shift || true
  case "$cmd" in
    line)
      need_root
      local sub=${1:-}; shift || true
      [ "$sub" = init ] || [ -f "$LINE_STATE" ] || die "本机还不是线路机，先 wgr line init"
      case "$sub" in
        init) line_init "$@" ;;
        add-land) line_add_land "$@" ;;
        del-land) line_del_land "$@" ;;
        join-cmd) line_joincmd "${1:?落地名}" ;;
        add-user) line_add_user "$@" ;;
        move-user) line_move_user "$@" ;;
        del-user) line_del_user "$@" ;;
        links) line_links ;;
        status) line_status ;;
        *) usage ;;
      esac ;;
    land)
      need_root
      local sub=${1:-}; shift || true
      [ "$sub" = join ] || [ -f "$LAND_STATE" ] || die "本机还不是落地机"
      case "$sub" in
        join) land_join "$@" ;;
        leave) land_leave "$@" ;;
        status) land_status ;;
        *) usage ;;
      esac ;;
    status)
      need_root
      [ -f "$LINE_STATE" ] && line_status
      [ -f "$LAND_STATE" ] && land_status
      [ -f "$LINE_STATE" ] || [ -f "$LAND_STATE" ] || echo "本机未部署 wgr"
      ;;
    watchdog) watchdog ;;
    update) need_root; update ;;
    uninstall) need_root; uninstall "$@" ;;
    *) usage ;;
  esac
}

[ -n "${WGR_SOURCED:-}" ] || main "$@"
