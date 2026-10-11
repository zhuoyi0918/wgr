# wgr — WireGuard 反向隧道一键部署

落地机（如 AT&T 住宅/商宽）**主动**用 WireGuard 拨号连到线路机，线路机把用户流量通过隧道交给落地机上的 SS-2022 出网。

```
用户 ─VLESS+REALITY+XHTTP─> 线路机:443 ──SS-2022(隧道内)──> 落地机 ──> 互联网
                              wgr0 (UDP 被动监听)  <══WG══  落地机主动拨出 + keepalive
```

- 落地机**零公网入站**：不吃 AT&T BGW 的入站新建连接预算，出口 IP 变了也会自动重连（WG roaming + watchdog）
- **多线路 × 多落地**：一台线路机可以挂多台落地机；一台落地机也可以同时对接多台线路机（每台线路机一个独立的 `wgr-<ID>` 接口，内网段随机，互不冲突）
- 和机器上已有的 xray / wireguard **互不干扰**：独立的二进制 `/usr/local/lib/wgr/xray`、状态目录 `/etc/wgr`，服务名为 `wgr-line` / `wgr-land`
- **自动放行防火墙**：检测到 ufw 就自动放行（ufw 没启用时也会预先写好规则，启用后即生效，脚本不会替你启用 ufw）；检测到 firewalld 也会自动处理。具体放行哪些端口：
  - 线路机：所选的入口端口（tcp）和 WG 端口（udp）
  - 落地机：只在 `wgr-<ID>` 隧道接口上放行 SS 端口，公网方向依旧零入站
  - 卸载、`land leave` 时会把这些规则一起删掉

  云厂商的安全组脚本改不到，需要你到控制台手动放行。
- 支持 Debian/Ubuntu（apt）、RHEL 系（dnf/yum）；要求 KVM，或内核 ≥ 5.6 自带 WireGuard

## 快速开始

**1. 线路机（入口）**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zhuoyi0918/wgr/main/wgr.sh) line init
# 可选参数：--endpoint 域名或IP  --port 443  --sni www.microsoft.com  --wg-port 51820  --no-direct
```

装完会直接给出一个 `direct` 用户的链接。这个用户**不经过落地**，出口就是线路机本机 IP，所以只部署线路机也能当一台独立的 VLESS+REALITY+XHTTP 节点用。不想要这个用户就加 `--no-direct`。

本机的 ufw 或 firewalld 会被自动放行；云厂商的安全组则需要你手动放行 `443/tcp` 和脚本输出的 WG 端口（`udp`）。

**2. 在线路机上添加落地**

```bash
wgr line add-land att1
```

会输出两样东西：落地机的部署命令，以及客户端用的 `vless://` 链接。

**3. 落地机（出口）**：粘贴上一步输出的命令

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zhuoyi0918/wgr/main/wgr.sh) land join eyJ2Ijox...
```

落地机不需要开放任何端口。

## 扩展

| 场景 | 操作 |
|---|---|
| 再加一台落地 | 线路机 `wgr line add-land att2`，然后在新落地机上运行输出的命令 |
| 再加一台线路机 | 新线路机 `wgr line init` → `wgr line add-land <名>`，然后在**已有的**落地机上运行 join 命令（会新建一个接口，原有隧道不受影响） |
| 一个落地给多个用户 | `wgr line add-user alice att1` |
| 加一个线路机直出用户 | `wgr line add-user bob`（不写落地即为 `direct`） |
| 用户换出口 | `wgr line move-user alice att2`，或 `wgr line move-user alice direct`（客户端链接都不变） |
| 下线落地 | 线路机 `wgr line del-land att1`，落地机 `wgr land leave <线路机ID>` |
| 重新打印 join 命令 / 全部链接 | `wgr line join-cmd att1` / `wgr line links` |
| 查看状态 | `wgr status`（线路机这边会显示每个落地的握手时间和 SS 连通性） |
| 更新 wgr 和 Xray | `wgr update` |
| 卸载 | `wgr uninstall [line\|land\|all]` |

## 验证

1. 线路机执行 `wgr status`：每个落地的握手时间应在 2 分钟以内，SS 一栏显示 `OK`
2. 客户端连上之后查出口 IP，应该等于该落地机当前的公网 IP
3. 在落地机上 `ss -ltnp`：8388 只应出现在 `10.x.x.x` 隧道地址上

## 安全说明

- join 参数里含有该落地的 WG 私钥和 SS 密码，只在你自己的 SSH 会话里粘贴，**不要公开**。
- 状态文件 `/etc/wgr/*.json` 的权限为 600，里面包含 REALITY 私钥。
- 本仓库的脚本不包含任何密钥，密钥都在部署时于本机生成。
- 请仅在合法、获得授权的用途下使用。
