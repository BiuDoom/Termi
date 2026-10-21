#!/usr/bin/env python3
"""更新 CLAUDE.md 中的 Commit 历史表"""

import subprocess
import sys
import re
from datetime import date


def get_commit_log():
    result = subprocess.run(
        ["git", "log", "--format=%H|%s|%ai", "--all"],
        capture_output=True, text=True
    )
    lines = []
    for line in result.stdout.strip().split("\n"):
        if not line:
            continue
        parts = line.split("|", 2)
        if len(parts) == 3:
            short_hash = parts[0][:7]
            msg = parts[1]
            short_date = parts[2].split(" ")[0]
            lines.append(f"| `{short_hash}` | {msg} | {short_date} |")
    return lines


def update_claude_md(path):
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    # 生成新的 commit 表
    commits = get_commit_log()
    header = "| Hash | 信息 | 日期 |\n|------|------|------|\n"
    new_table = header + "\n".join(commits)

    # 替换 Commit 历史部分
    pattern = r"(## Commit 历史\n\n)(.*?)((?=\n### |\n## |\n---))"
    replacement = rf"\1{new_table}\3"
    content = re.sub(pattern, replacement, content, flags=re.DOTALL)

    # 更新最后更新日期
    today = date.today().isoformat()
    content = re.sub(
        r"\*\*最后更新\*\*: .*",
        f"**最后更新**: {today}",
        content
    )

    with open(path, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"CLAUDE.md updated ({len(commits)} commits)")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: update-claude-md.py <path-to-CLAUDE.md>")
        sys.exit(1)
    update_claude_md(sys.argv[1])
