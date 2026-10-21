#!/usr/bin/env python3
"""在 Codex 的默认 provider 之间切换（供桌面 App 使用，GUI 不支持 --profile）。

用法:
    python switch_profile.py m365     # 切到 M365 Copilot
    python switch_profile.py custom   # 切回原 relay（deepseek）
    python switch_profile.py status   # 查看当前
"""
import re
import shutil
import sys
import time
from pathlib import Path

CONFIG = Path.home() / ".codex" / "config.toml"

# 两套默认值。custom 保持用户原样，不要改。
PROFILES = {
    "m365": {
        "model": "gpt-5.6-reasoning",
        "model_provider": "m365",
        "catalog": "model-catalogs/m365.json",
    },
    "custom": {
        "model": "deepseek-v4.1-flash",
        "model_provider": "custom",
        "catalog": "model-catalogs/relay-mvds440r.json",
    },
}


def read_lines():
    return CONFIG.read_text(encoding="utf-8").splitlines()


def set_key(lines, key, value):
    """替换顶层 key = value 行（只处理文件开头到第一个 [table] 之前）。"""
    pat = re.compile(rf'^\s*#?\s*{re.escape(key)}\s*=\s*.*$')
    out, done = [], False
    for line in lines:
        if not done and pat.match(line):
            out.append(f'{key} = "{value}"')
            done = True
        else:
            out.append(line)
    if not done:
        out.insert(0, f'{key} = "{value}"')
    return out


def comment_key(lines, key, comment):
    pat = re.compile(rf'^\s*{re.escape(key)}\s*=\s*.*$')
    return [f"# {line.strip()}" if pat.match(line) else line for line in lines]


def uncomment_key(lines, key):
    pat = re.compile(rf'^\s*#\s*{re.escape(key)}\s*=')
    return [line.lstrip("# ").strip() if pat.match(line) else line for line in lines]


def current():
    for line in read_lines():
        m = re.match(r'^\s*model_provider\s*=\s*"([^"]+)"', line)
        if m:
            return m.group(1)
    return "(未设置)"


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("m365", "custom", "status"):
        print(__doc__)
        return 1

    target = sys.argv[1]

    if target == "status":
        lines = read_lines()
        model = next(
            (re.match(r'^\s*model\s*=\s*"([^"]+)"', l).group(1)
             for l in lines if re.match(r'^\s*model\s*=\s*"', l)), "?"
        )
        print(f"当前 provider: {current()}")
        print(f"当前 model   : {model}")
        return 0

    if not CONFIG.exists():
        print(f"[x] 找不到 {CONFIG}")
        return 1

    backup = CONFIG.with_name(f"config.toml.bak.switch.{int(time.time())}")
    shutil.copy2(CONFIG, backup)

    cfg = PROFILES[target]
    lines = read_lines()

    lines = set_key(lines, "model", cfg["model"])
    lines = set_key(lines, "model_provider", cfg["model_provider"])

    if cfg["catalog"]:
        lines = uncomment_key(lines, "model_catalog_json")
        lines = set_key(lines, "model_catalog_json", cfg["catalog"])
    else:
        lines = comment_key(lines, "model_catalog_json", True)

    CONFIG.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"[OK] 已切到 {target}")
    print(f"     model    = {cfg['model']}")
    print(f"     provider = {cfg['model_provider']}")
    print(f"     备份     = {backup.name}")
    print()
    print("重要：Codex 桌面 App 需要【完全退出再重开】才会读到新配置。")
    print("     任务栏托盘也要退，否则进程仍在用旧配置。")
    if target == "m365":
        print()
        print("前提：网关在跑（双击 run-gateway.bat），且 M365_API_KEY 已设为用户环境变量。")

    return 0


if __name__ == "__main__":
    sys.exit(main())
