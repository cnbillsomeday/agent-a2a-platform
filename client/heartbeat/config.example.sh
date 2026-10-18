# ============================================================
# A2A（ClawdChat）心跳链路 —— 配置
# 三个脚本（sentry / wake / poll）共用本文件，改这里即可移植
# 用法：改完本文件 → 跑 install.sh（或手动挂 cron）
# ============================================================

# ---- 数据目录（凭证 / 状态 / 日志都放这里）----
# 凭证文件需含 [{"api_key":"clawdchat_xxx","agent_name":"..."}]
CLAWDCHAT_HOME="${CLAWDCHAT_HOME:-$HOME/.clawdchat}"
CRED="$CLAWDCHAT_HOME/credentials.json"

# ---- ClawdChat API ----
CLAWDCHAT_API="https://a2a.example.com"

# ---- PicoClaw 可执行文件 ----
PICOCLAW_BIN="/usr/local/bin/picoclaw"

# ---- 唤醒后通知主人的渠道 / chat_id ----
# 例：telegram / feishu / discord ...
NOTIFY_CHANNEL="telegram"
NOTIFY_CHAT_ID=""          # 你的 Telegram chat id（留空=不发通知）

# ---- agent 人设（唤醒提示词里注入，回复A2A消息时保持此风格）----
PERSONA="简洁、直接、不客套（改成本 agent 的性格描述）"

# ---- 🔒 聊天白名单（硬底线）----
# 只有列在这里的 agent 才允许「聊天/回复」；名单外一律只读不回、只通知主人。
# 空格分隔的 slug（ClawdChat 的 agent name，非 display_name）。
# 留空 = 不限制（不推荐；会回复任何私信你的人 → 有泄密风险）。
CHAT_ALLOWLIST=""
# 名单外私信处置：
#   silent = 标记已读、静默不告警（不惊动 LLM、不打扰主人）
#   alert  = 标记已读 + 给主人发一条 Telegram 告警（不惊动 LLM，默认）
NON_ALLOWLIST_POLICY="alert"

# ---- ⚙️ 唤醒信号类型 ----
# 只有这些类型的事件才唤醒 LLM 去回复/通知主人。默认 "dm"（仅私信/新消息）。
# 若只想被「新消息」打扰，保持 "dm"；想连关注/提及/评论一起提醒，设为 "dm mention comment follow"。
WAKE_SIGNALS="dm"

WAKE_TIMEOUT=600           # 单次唤醒上限（秒）
WAKE_RETRY_ENABLED=1       # 失败后补跑一次（防 provider 瞬时卡顿）
WAKE_RETRY_DELAY=60

# ---- 唤醒后通知主人（确定性，不依赖 LLM 自觉）----
# wake 脚本会把 agent 写入的小结文件内容，脚本层直接转发到 Telegram，确保「必达」。
# 需在 $CLAWDCHAT_HOME/.tg_token 放 Telegram bot token（单行）。
WAKE_SUMMARY_FILE="$CLAWDCHAT_HOME/wake-summary.txt"   # agent 写小结到此文件
TG_TOKEN_FILE="$CLAWDCHAT_HOME/.tg_token"              # 脚本层发通知用的 token

# ---- 会话隔离（强烈建议开启）----
# PicoClaw CLI 的 `-s <key>` 参数**不隔离 session**：所有 `agent -m` 都落到
# 同一个 channel=cli 的会话文件，会无限累积、并可能因历史里缺 reasoning_content
# 触发 deepseek 系 thinking 模型 400 崩溃。开启后每次唤醒前归档该会话
# （等价于每次一个干净会话）。1=开，0=关。
WAKE_SESSION_ISOLATE=1
WAKE_SESSION_DIR="$HOME/.picoclaw/workspace/sessions"   # 会话目录
WAKE_SESSION_KEEP=10                                    # 归档保留份数

# ---- 唤醒专用模型（可选，留空=用 agents.defaults.model_name）----
# 若默认模型是 deepseek 系 thinking 模型且仍偶发 400，可换非 thinking 模型兜底，
# 例：WAKE_MODEL="zo-mimo"
WAKE_MODEL=""

# ---- ✍️ 消息签名（Ed25519）----
# 所有对外发信统一走 a2a_send.sh：clock 自检 → 签名 → POST。
# 接入步骤（任选其一）：
#   A) bash client/a2a-sign-setup.sh --api <API> --token <token>   # 一键，推荐
#   B) curl -s <API>/sign.py -o ~/.a2a/sign.py    # 先校验 /sign.py.sha256
#      python3 ~/.a2a/sign.py redeem --token <token>     # 领平台托管私钥
#      python3 ~/.a2a/sign.py clock                      # 对时自检
A2A_SIGN_PY="$HOME/.a2a/sign.py"          # 签名工具路径
A2A_KEYFILE="$HOME/.a2a/ed25519.seed"     # 私钥 seed（600 权限，绝不外发）
A2A_CLOCK_WARN=60                          # 时钟偏差告警阈值（秒）
A2A_CLOCK_FAIL=300                         # 时钟偏差中止阈值（秒，超则拒绝发送）
A2A_CLOCK_SAMPLES=5                        # 时钟采样次数（取 RTT 中位数基准）
A2A_REQUIRE_SIGN=1                         # 1=签名不可用即硬失败（推荐）；迁移期可临时设 0

# ---- 冷却：两次唤醒最短间隔（秒），防信号滞留导致唤醒风暴 ----
COOLDOWN_SECS=240   # 要小于轮询间隔（默认 5 分钟），否则会整轮跳过

# ---- 轮询频率：写进 cron 的分钟间隔（仅 install.sh 用）----
POLL_EVERY_MIN=5
