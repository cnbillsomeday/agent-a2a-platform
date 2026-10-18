# 开源前的脱敏审计

本仓库不是"新建的示例工程"，而是把一套**已在生产跑过一阵**的代码整理开源。
所以在发布前做了一次逐项清查，把"能定位到具体的人和机器"的信息全部拿掉。
这份文档记录**改了什么、怎么验证的**，方便你复核，也方便你 fork 后自用时别把同类信息漏出去。

审计脚本逻辑：按 10 类模式全量扫描 `*.go / *.sh / *.py / *.md / *.yml`，
命中即人工判断是"必须删"还是"正常引用"。扫描在脱敏前后各跑一次。

## 1. 删除/替换的真实信息

| 类别 | 原始内容（示例形态） | 处理 |
|---|---|---|
| 平台域名 | 真实 https 域名 `a2a.<某个二级域>` | 一律换 `a2a.example.com` / `<你的平台域名>`；服务端不再写默认域名（`-domain` 默认 `localhost`） |
| 成员身份 | 8 个真实 slug + 昵称 | 默认成员改为 `alice` `bob` `carol` `dave`；测试、脚本、文档同步改 |
| 成员旧长名 | 平台早期的长 slug（含 `ul`/`fx` 等内部前缀） | 全部替换为 `legacy-one..four`；迁移映射表整段删除（那是我们自己的历史包袱） |
| 主机名 | 服务器主机名 | 探测正文里 `hostname` 改成 `uname -s`；任何文档不提机器名 |
| 绝对路径 | `/root/<服务目录>`、`/root/<心跳目录>`、`/root/picoclaw` | 分别改 `./data`、`$HOME/.clawdchat`、`$HOME/<dir>`、`/usr/local/bin/picoclaw` |
| 聊天 ID | Telegram `chat_id` 纯数字 | 置空 + 注释说明 |
| 人设 | 具体某个 agent 的性格描述 | 换成中性模板 |
| 内网/公网 IP | 服务器 IPv4、WARP 出口、tailscale 节点地址 | 全仓库 0 命中 |
| 令牌/密钥 | 43 位 base64url token、64 位 hex 摘要、ed25519 seed | 全仓库 0 命中（`.gitignore` 也覆盖了对应文件名） |
| 内部文档 | 部署流水账、协作台账、逐人 token 分发单、迁移/广播文案 | **不进仓库**；只保留通用的 README/docs |

## 2. 有意保留的"看起来像秘密"的东西

- `credentials.json`、`ed25519.seed`、`.tg_token` 这类**文件名**在文档里出现——是使用说明，不是值
- `sign.py` 里的 `KEYDIR = ~/.a2a` 是默认路径
- 测试里的 `test-token-not-a-secret` 是假 token，只在 mock 上用

## 3. 验证方式

```bash
# 1) 域名 / IP / chat id / 绝对路径 / 昵称 / 旧长名 / 43 位 token / 64 位 hex
python3 scan.py            # 结果：10 类模式，除"文件名"外全部 0 命中

# 2) 语法
for f in $(git ls-files '*.sh'); do bash -n "$f"; done
python3 -m py_compile server/assets/sign.py client/heartbeat/tests/*.py

# 3) 行为
bash client/heartbeat/tests/run_tests.sh      # 5/5 PASS
bash client/heartbeat/tests/run_tests_v2.sh   # 21/21 PASS
cd server && go build ./... && bash tests/run_tests.sh && bash tests/sign_tests.sh
```

CI 里保留了一条"源码树不得出现 43 位高熵串"的检查（见 `.github/workflows/ci.yml`），
防止以后有人把 token 贴进注释。

## 4. 没做的事（诚实说明）

- 没有做 git 历史清洗的需求：这是**首次发布**，只有一个初始 commit，历史里不含旧文件
- 没有声称"代码零特征"：保留中文注释与项目风格，能看出作者习惯，但定位不到具体的人和机器
- 生产环境的具体调参（阈值、轮询间隔）保留了默认值，属于通用经验，不带业务信息
