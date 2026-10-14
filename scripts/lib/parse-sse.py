#!/usr/bin/env python3
"""Parse Vercel AI SDK v6 SSE stream → emit TOOLS=... TEXT=... lines.

Usage: parse-sse.py /path/to/file.sse

Output (stdout):
  TOOLS=<comma-separated tool names>
  TEXT_CHARS=<int>
  TEXT_START=<first 500 chars of joined text-delta deltas, single-line, escaped \\n>
"""
import json
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: parse-sse.py <file>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    parts: list[str] = []
    tools: list[str] = []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data in ("[DONE]", ""):
                    continue
                try:
                    obj = json.loads(data)
                except json.JSONDecodeError:
                    continue
                t = obj.get("type", "")
                if t == "text-delta":
                    parts.append(obj.get("delta", ""))
                elif t in ("tool-input-start", "tool-input-delta", "tool-input-available"):
                    tn = obj.get("toolName", "")
                    if tn and tn not in tools:
                        tools.append(tn)
    except FileNotFoundError:
        print(f"file not found: {path}", file=sys.stderr)
        return 2

    text = "".join(parts)
    print(f"TOOLS={','.join(tools)}")
    print(f"TEXT_CHARS={len(text)}")
    snippet = text[:500].replace("\n", "\\n").replace("\r", "")
    print(f"TEXT_START={snippet}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
