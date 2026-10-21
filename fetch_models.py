#!/usr/bin/env python3
"""从 M365 网关生成【精简版】Codex model catalog。

为什么要精简：
  网关 /v1/models 返回的完整字段里有 tool_mode、use_responses_lite、
  experimental_supported_tools、apply_patch_tool_type 等实验性字段。
  Codex 读到这些会改变请求构造（实测：tools 从 10 个变成 1 个），
  导致网关 /v1/responses 直接 response.failed。

  只保留纯描述性的元数据字段，避免干扰 Codex 的行为判断。

用法:
    python fetch_models.py <api_key>
输出: ~/.codex/model-catalogs/m365.json
"""
import json
import os
import sys
import urllib.request
from pathlib import Path

BASE = "http://127.0.0.1:4141"
OUT = Path.home() / ".codex" / "model-catalogs" / "m365.json"

# 只保留这些"无害"字段：纯描述，不影响 Codex 的工具/协议选择
KEEP = (
    "slug",
    "display_name",
    "description",
    "default_reasoning_level",
    "supported_reasoning_levels",
    "default_reasoning_summary",
    "supports_reasoning_summaries",
    "context_window",
    "max_context_window",
    "effective_context_window_percent",
    "auto_compact_token_limit",
    "input_modalities",
    "supports_image_detail_original",
    "visibility",
    "supported_in_api",
    "priority",
    "support_verbosity",
    "default_verbosity",
    "truncation_policy",
    "additional_speed_tiers",
    # Codex 强校验：两者至少要有其一，否则 catalog 解析失败
    "base_instructions",
    "model_messages",
)

# 网关 /v1/models 尚未暴露、但上游确实支持的新 tone（issue #106）。
# 以 gpt-5.6-reasoning 为模板复制，避免 Codex 报 metadata not found。
EXTRA_MODELS = ["gpt-6-sol", "gpt-6.1-sol"]
EXTRA_TEMPLATE = "gpt-5.6-reasoning"


def main():
    key = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("M365_API_KEY", "")
    if not key:
        print("[x] 没有 API key")
        return 1

    req = urllib.request.Request(
        f"{BASE}/v1/models", headers={"Authorization": f"Bearer {key}"}
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            payload = json.load(r)
    except Exception as e:
        print(f"[x] 请求网关失败: {e}")
        return 1

    models = []
    for m in payload.get("data", []):
        entry = {k: m[k] for k in KEEP if k in m}
        entry.setdefault("slug", m.get("id"))
        entry.setdefault("display_name", m.get("id"))
        entry.setdefault("visibility", "list")
        entry.setdefault("supported_in_api", True)
        # Codex 要求有 shell_type；固定为 shell_command，不让模型自带的值干扰
        entry["shell_type"] = "shell_command"
        # 这是 catalog 的必填字段，但置空以规避它改变 Codex 的工具构造行为
        entry["experimental_supported_tools"] = []
        models.append(entry)

    if not models:
        print("[x] 模型列表为空")
        return 1

    # 补上未在 /v1/models 暴露但上游可用的模型
    existing = {m["slug"] for m in models}
    tmpl = next((m for m in models if m["slug"] == EXTRA_TEMPLATE), models[0])
    for extra in EXTRA_MODELS:
        if extra in existing:
            continue
        clone = dict(tmpl)
        clone["slug"] = extra
        clone["display_name"] = extra
        clone["description"] = f"{extra} (M365 upstream tone)"
        models.append(clone)
        print(f"     [补充] {extra}")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(
        json.dumps({"models": models}, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"[OK] 已写入精简 catalog: {OUT}")
    print(f"     {len(models)} 个模型，字段 {len(models[0])} 个（已剔除实验性字段）")
    for m in models:
        print(f"       - {m['slug']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
