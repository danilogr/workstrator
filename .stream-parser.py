#!/usr/bin/env python3
"""Parse Claude stream-json output into readable text for agent logs."""

import sys
import json

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        t = obj.get("type")
        if t == "assistant":
            for block in obj.get("message", {}).get("content", []):
                if block.get("type") == "text":
                    print(block["text"], flush=True)
                elif block.get("type") == "tool_use":
                    print(f"[tool: {block.get('name', '?')}]", flush=True)
        elif t == "result":
            text = obj.get("result", "")
            if text:
                print(text, flush=True)
    except (json.JSONDecodeError, KeyError, TypeError):
        pass
