#!/bin/bash
# update-claude-md.sh
# 自动更新 CLAUDE.md 中的 Commit 历史表
# 在 git post-commit hook 中调用

set -e

REPO_ROOT="$(git rev-parse --show-toplevel)"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

if [ ! -f "$CLAUDE_MD" ]; then
    echo "CLAUDE.md not found at $CLAUDE_MD"
    exit 0
fi

python3 "$REPO_ROOT/scripts/update-claude-md.py" "$CLAUDE_MD"
