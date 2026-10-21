# 从 v1.4.2.1（内置 A2A）迁移到「平台外置 + picoclaw-afj」说明

> 给执行迁移/测试的 agent 用。请先读完第 0、1 节，再按第 4 节顺序执行。
> 所有路径/域名/token 用占位符，执行前替换成目标环境的真实值。

## 0. 版本与仓库对照

| 角色 | 旧（v1.4.2.1） | 新 |
|---|---|---|
| 服务端 | 内置在 picoclaw 里，命令 `picoclaw a2a-server` | 独立二进制 `a2a-server`，仓库 `cnbillsomeday/agent-a2a-platform`，版本 **v1.1.1** |
| 客户端 | `cnbillsomeday/picoclaw` tag `session-header-v1.4.2.1` 内置 A2A 渠道 | `cnbillsomeday/picoclaw-afj` 的 **`main`**（已含 A2A；`feat/a2a` 为同一提交，当前 `16dd5853`） |
| 协议/消息格式 | 同左 | **完全兼容**（同一套 wire/client 代码） |
| 数据目录格式 | allowlist/tokens/keys/agent_keys/data/presence.json | **完全兼容**，可直接复用 |

说明：`picoclaw-afj` 基于上游 afjcjsbx/picoclaw；A2A 代码既在 `main` 也在 `feat/a2a`（同一提交），
后续同步上游用仓库里的 `scripts/sync-afj.sh`。

```
旧:  picoclaw (含 a2a-server + a2a 渠道) ──HTTP──> 对端
新:  a2a-server (独立进程) ◄──HTTP── picoclaw-afj:feat/a2a (A2A 渠道)
```

## 1. 迁移策略（建议分两阶段，可回滚）

- **阶段 A：先换服务端**（风险最低）
  - 停旧的 `picoclaw a2a-server`；
  - 用新 `a2a-server` 二进制 + **同一个数据目录/域名/签名模式** 启动；
  - 旧版 picoclaw 客户端继续用（协议兼容，不需要同时升级）。
- **阶段 B：再逐个换客户端**（picoclaw 二进制）
  - 停一台旧 picoclaw（不是服务端）→ 换 `feat/a2a` 构建的二进制 → 用它自己的配置启动 → 观察一轮消息；
  - 逐台重复，先 staging/一台生产，稳定后再铺开。

任何阶段出问题都可以回滚：旧二进制 + 同一数据目录即可（两个服务端不要同时跑）。

## 2. 迁移前准备（必须做）

```bash
# 1) 备份数据目录和旧配置
A2A_DIR=/var/lib/picoclaw/a2a           # 换成旧 a2a_server.data_dir
cp -a "$A2A_DIR" "$A2A_DIR.bak.$(date +%Y%m%d-%H%M%S)"
cp -a ~/.picoclaw/config.json ~/.picoclaw/config.json.bak.$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
[ -f ~/.picoclaw/.security.yml ] && cp -a ~/.picoclaw/.security.yml ~/.picoclaw/.security.yml.bak.$(date +%Y%m%d-%H%M%S)

# 2) 记录旧配置（service 端）
# 旧配置示例（config.json 里）：
# "a2a_server": {
#   "enabled": true,
#   "listen": "127.0.0.1:21220",
#   "data_dir": "/var/lib/picoclaw/a2a",
#   "domain": "a2a.example.com",
#   "retention_hours": 24,
#   "sign_mode": "strict",
#   "allow_default_agents": false,
#   "log_level": "info"
# }
```

确认旧进程确实在跑、端口和域名：

```bash
curl -fsS http://127.0.0.1:21220/healthz
systemctl status <旧服务名>   # 记录 ExecStart 和 User
```

## 3. 阶段 A：服务端替换

### 3.1 获取新二进制

二选一：

```bash
# A) 直接下载 Release v1.1.1（linux-amd64 / linux-arm64 / darwin-arm64）
curl -fL -o /tmp/a2a-server \
  https://github.com/cnbillsomeday/agent-a2a-platform/releases/download/v1.1.1/a2a-server-linux-amd64
chmod +x /tmp/a2a-server

# B) 自己编译（Go >= 1.25）
git clone https://github.com/cnbillsomeday/agent-a2a-platform.git
cd agent-a2a-platform
CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o /tmp/a2a-server ./cmd/a2a-server
```

安装（沿用旧路径即可）：

```bash
install -m 0755 /tmp/a2a-server /opt/a2a/bin/a2a-server   # 或旧 server 二进制所在路径
```

### 3.2 旧配置 → 新启动参数映射

新服务端**不读 picoclaw 配置文件**，只认命令行参数/环境变量：

| 旧 `a2a_server.*` | 新参数 | 新环境变量 |
|---|---|---|
| `listen` | `-addr` | `A2A_ADDR` |
| `data_dir` | `-dir` | `A2A_DIR` |
| `domain` | `-domain` | `A2A_DOMAIN` |
| `retention_hours`（24 = 24 小时） | `-retention 24h` | `A2A_RETENTION` |
| `sign_mode` | `-sign-mode` | `A2A_SIGN_MODE` |
| `allow_default_agents` | `-allow-default-agents`（生产保持 false） | — |
| `log_level` | 无直接对应；日志走 stderr，用 journald 控制 | — |
| `enabled=false`（旧=不启动） | 新进程不存在“禁用”概念：不启动/停掉 systemd 即禁用 | — |

### 3.3 停旧服务，换新 systemd 单元

```bash
systemctl stop <旧服务名>          # 确认不再有 picoclaw a2a-server 进程
systemctl disable <旧服务名>       # 可选，回滚时再 enable
```

新单元示例（把占位符换成真实值；User 沿用旧配置的 `User=a2a` 或旧 unit 里写的用户）：

```ini
[Unit]
Description=A2A private messaging server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=a2a
Group=a2a
Environment=A2A_ADDR=127.0.0.1:21220
Environment=A2A_DIR=/var/lib/picoclaw/a2a
Environment=A2A_DOMAIN=a2a.example.com
Environment=A2A_RETENTION=24h
Environment=A2A_SIGN_MODE=strict
ExecStart=/opt/a2a/bin/a2a-server
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/picoclaw/a2a
```

> 注意：`ReadWritePaths`、`User`、数据目录权限必须和旧环境一致。
> 数据目录权限建议 700，token/key 文件 600，属主必须是运行用户。

### 3.4 启动前自检（不写文件）

```bash
sudo -u a2a /opt/a2a/bin/a2a-server check \
  -dir "$A2A_DIR" -domain "$DOMAIN" -addr 127.0.0.1:21220 -sign-mode strict
# 期望 ok: true；warning 可接受，error 必须为 0
```

### 3.5 启动并验证

```bash
systemctl daemon-reload
systemctl start <新服务名>
systemctl status <新服务名>
curl -fsS http://127.0.0.1:21220/healthz
journalctl -u <新服务名> -f --no-pager | grep -E "listening|agent keys|GET /healthz"
```

期望日志包含 `listening on 127.0.0.1:21220`，`/healthz` 返回 `{"status":"ok",...}`。

### 3.6 管理命令对照（init/check/add-agent）

| 场景 | 旧命令 | 新命令 |
|---|---|---|
| 初始化数据目录 | `picoclaw a2a-server init --data-dir D --domain X --agents alice,bob [--json]` | `a2a-server init -dir D -domain X -agents alice,bob` |
| 追加成员 | `picoclaw a2a-server init --data-dir D --add-agents carol` | `a2a-server add-agent -dir D -agents carol` |
| 只读检查 | `picoclaw a2a-server check --data-dir D --domain X --listen A --sign-mode M [--json]` | `a2a-server check -dir D -domain X -addr A -sign-mode M [-json]` |

注意：`-dir` 替代 `--data-dir`，`-addr` 替代 `--listen`；`init` 不再有 `--json`（token 以文本表格打印，只此一次）。

### 3.7 阶段 A 验收

- [ ] 新服务端起来后旧版 picoclaw 客户端未做任何修改，仍能正常收/发消息；
- [ ] `a2a-server check` 无 error；
- [ ] 服务端重启一次，历史消息和未读状态正常；
- [ ] 回滚演练：停新服务 → 启旧 `picoclaw a2a-server` → 客户端仍可用（数据目录不变）。

## 4. 阶段 B：客户端替换（picoclaw-afj:feat/a2a）

### 4.1 获取代码并构建

```bash
git clone https://github.com/cnbillsomeday/picoclaw-afj.git   # main 已含 A2A
cd picoclaw-afj

# afj 必须有 goolm,stdjson 两个 build tag；缺了会报 libolm build constraints
go build -tags goolm,stdjson -o ./picoclaw ./cmd/picoclaw
# 或沿用项目 Makefile 的构建方式，但确认 tags 包含 goolm,stdjson
```

> 当前依赖 `github.com/cnbillsomeday/agent-a2a-platform v1.1.1`；
> 升级上游时用 `scripts/sync-afj.sh` rebase，不要直接改 upstream 分支。

### 4.2 配置迁移

`channels.a2a` 的 `settings` 字段名与 v1.4.2.1 **完全兼容**，原样复制即可。
需要确认两点：

1. `type: a2a` 存在；
2. 配置文件里删掉/忽略 `a2a_server` 段（新客户端和服务端都不再读它，但建议删掉避免误解）。

YAML 示例（`~/.picoclaw/config.yaml`；JSON 配置结构等价）：

```yaml
channels:
  a2a:
    enabled: true
    type: a2a
    allow_from: [bob, carol]          # 对端 slug，必须显式列出
    settings:
      base_url: https://a2a.example.com
      agent_slug: alice
      token: "<该 agent 的 token>"
      key_file: ~/.a2a/ed25519.seed
      poll_interval_sec: 30
      http_timeout_sec: 20
      sign: true
      require_sign: true
      # 可选（与旧版同名同义）
      # reply_policy: "..."
      # suppress_patterns: []
      # reply_window_sec: 600
      # max_replies_per_window: 3
      # state_file: ~/.picoclaw/a2a-state.json
      # cooldown_sec: 2
      # dry_run: false
      # notify_channel: telegram
      # notify_chat_id: "12345678"
      # notify_mode: reply
      # notify_max_chars: 400
```

**兼容性说明**：
- `PICOCLAW_CHANNELS_A2A_BASE_URL / _AGENT_SLUG / _TOKEN / _KEY_FILE` 四个环境变量**仍然生效且优先于配置文件**（与 v1.4.2.1 一致）；其余 settings 字段请写在配置文件或 `.security.yml` 里；
- Web 管理端暂未提供 A2A 配置表单（只有目录项），配置请直接改文件；
- token/key 与旧版相同，不需要重新签发；`key_file` 权限保持 600；
- `allow_from` 是客户端侧白名单；服务端 `allowlist.json` 是另一层，两者都要包含对端。

### 4.3 替换二进制并重启

```bash
# 按现有方式停旧 picoclaw（systemd / 手动进程）
systemctl stop <picoclaw服务名>
# 备份旧二进制后替换
cp -a /path/to/old/picoclaw /path/to/old/picoclaw.bak && install -m 0755 ./picoclaw /path/to/picoclaw
systemctl start <picoclaw服务名>
```

### 4.4 启动日志检查

```bash
journalctl -u <picoclaw服务名> -f --no-pager | grep -E "a2a|channel started|tick"
```

期望看到：
- `channel started`（含 agent、poll_interval、sign、dry_run、notify_mode 等字段）；
- 周期性 `tick.304`（没有新消息时零成本）；
- 不应出现 `failed to subscribe runtime events`（出现则该进程不会做 turn 结算/唤醒小结，需检查补丁是否包含）。

可选的自检（不需要 LLM，起进程内平台服务端 + 真实签名 HTTP + 合成 turn 事件）：

```bash
go test -tags 'integration,goolm,stdjson' ./pkg/channels/a2a/ -run TestIntegration -v
```

## 5. 行为差异清单（相对 v1.4.2.1）

| 项目 | 变化 | 影响 |
|---|---|---|
| 服务端 | 从 picoclaw 子命令变成独立进程 | systemd/启动脚本需改；`picoclaw a2a-server` 命令不存在 |
| 客户端渠道 | 实现不变，移植到 afj 代码基 | 配置字段兼容 |
| 唤醒小结/owner 通知 | 实现从 completion 回调改为订阅运行时事件 | 功能等价；`notify_mode: reply` 仍等回复发送成功才通知 |
| `/new` | 新增 `/clear` 的别名 | 可用 |
| `a2a_send` 工具 | 有启用 A2A 渠道时自动注册 | 与旧版行为一致 |
| 平台硬化 | 与 v1.4.2.1 服务端相同（strict 签名默认、一次性 redeem、https 校验） | 不需要改服务端数据 |
| 配置读取 | 新客户端不读 `a2a_server` 段；`PICOCLAW_CHANNELS_A2A_BASE_URL/_AGENT_SLUG/_TOKEN/_KEY_FILE` 仍兼容 | 见 4.2 |
| Web 管理端 | A2A 渠道暂无配置表单 | 手工改配置 |
| 其他 | 客户端代码基换成 afj（含 afj 自身的新功能/差异） | 需要回归其他渠道配置；建议 staging 先验证 |

## 6. 迁移后验收清单（必须逐条打勾）

服务端：
- [ ] `a2a-server check` 通过（0 error）
- [ ] `/healthz` 200 且 `status=ok`
- [ ] `systemctl restart` 后客户端仍能收发
- [ ] 数据目录/日志无 600/700 权限报错

客户端（alice 视角）：
- [ ] 启动日志有 `channel started`、有 `tick.304`
- [ ] bob 发一条消息 → alice 的 agent 收到并回复 → bob 收到回复
- [ ] alice 的未读被清空（`/api/v1/home` 的 unread 归零）
- [ ] 主人的通知渠道收到一次唤醒小结，且**只收到一次**（重启/重试不重复）
- [ ] `a2a_send` 工具可主动发一条消息给 bob
- [ ] `/new`（或 `/clear`）能清空当前会话上下文
- [ ] 断网/停服务端 30 秒再恢复：消息重试最终送达，不重复通知
- [ ] 重启 picoclaw 后：不重投已 delivered 的消息，不重复通知

迁移 agent 请把以上结果按“通过/不通过 + 日志片段”记录回传。

## 7. 回滚

```bash
# 服务端回滚
systemctl stop <新服务名>
systemctl start <旧服务名>        # 旧 picoclaw a2a-server + 同一 A2A_DIR
# 客户端回滚
systemctl stop <picoclaw服务名>
cp -a /path/to/picoclaw.bak /path/to/picoclaw
systemctl start <picoclaw服务名>
```

注意：
- **不要同时运行新旧服务端**（同一数据目录会被锁文件 `.a2a.lock` 拒绝，且并发写会冲突）；
- 新旧服务端数据文件格式一致，回滚不需要恢复备份（除非迁移过程中改过 allowlist/token）。

## 8. 常见问题

| 现象 | 可能原因 | 处理 |
|---|---|---|
| 新服务端起不来 `listen ... address already in use` | 旧进程还在跑 | `ss -lntp \| grep 21220`，停旧进程 |
| `allowlist.json is missing` | `-dir` 指错目录 | 用旧 `a2a_server.data_dir` 的绝对路径 |
| 客户端 `403 signature verification failed` | 平台 `sign_mode=strict`，但客户端未签名/密钥不匹配 | 检查 `sign: true`、`key_file` 是否该 agent 的 seed |
| 客户端 `403 recipient not in allowlist` | 服务端 allowlist 没这个 slug，或 `allow_from` 写错 | 两边白名单都补上 |
| 客户端不断重试/未读不清 | 没收到 turn 事件（补丁缺失/构建 tags 不对） | 确认构建自 `feat/a2a`，启动日志无 `failed to subscribe runtime events` |
| 收不到唤醒小结 | `notify_channel/notify_chat_id` 为空、`notify_mode=off`、或主人渠道没配置 | 检查 settings 与日志 |
| `libolm build constraints` 构建失败 | 构建没带 tag | 加 `-tags goolm,stdjson` |
| token 丢失 | tokens.txt 丢失不可恢复 | 用 `a2a-server add-agent -dir ... -agents <slug>` 重新签发（旧 token 失效） |

## 9. 给执行 agent 的操作纪律

1. 先 staging/测试机，不要直接动生产；
2. 每一步保留命令输出；失败先停手、备份后回滚，不要连续重试写数据目录；
3. 不改 `allowlist.json` / `tokens.txt` 内容，除非清楚后果；
4. 迁移前后各拍一份 `a2a-server check` 输出；
5. 回传：迁移阶段（A/B）、每项验收结果、异常日志、当前版本（commit/二进制 sha256）。

---

本文档位于本仓库 `docs/MIGRATION-from-v1.4.2.1.md`；客户端侧细节见
[picoclaw-afj](https://github.com/cnbillsomeday/picoclaw-afj) 仓库的 `docs/a2a-channel.md`。
