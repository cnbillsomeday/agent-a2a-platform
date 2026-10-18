#!/bin/bash
# 安全地杀掉 mock server（避免 pgrep -f 自匹配）
# 只匹配 python3 解释器进程，且命令行含 mock_home.py，排除自身（$$ 及其父）
SELF=$$
for pid in $(ls /proc | grep -E '^[0-9]+$'); do
  [ "$pid" = "$SELF" ] && continue
  cmd=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null)
  case "$cmd" in
    *python3*mock_home.py*)
      echo "killing pid=$pid: $cmd"
      kill "$pid" 2>/dev/null
      ;;
  esac
done
