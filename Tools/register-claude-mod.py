"""Adds a Claude Code mod folder to CLAUDE_CODE_PLUGIN_DIRS in ~/.claude/settings.json.

Other folders holding a mod of the same name are dropped from the list, so the mod loads once.
Usage: register-claude-mod.py MOD_FOLDER
"""

import json
import os
import sys


def mod_name(folder):
    try:
        with open(os.path.join(os.path.expanduser(folder), ".claude-plugin", "plugin.json")) as f:
            return json.load(f).get("name")
    except (OSError, ValueError):
        return None


def main():
    mod = sys.argv[1]
    name = mod_name(mod)
    path = os.path.expanduser("~/.claude/settings.json")
    settings = {}
    if os.path.exists(path):
        with open(path) as f:
            settings = json.load(f)

    env = settings.setdefault("env", {})
    dirs = [d for d in env.get("CLAUDE_CODE_PLUGIN_DIRS", "").split(":") if d and d != mod and mod_name(d) != name]
    env["CLAUDE_CODE_PLUGIN_DIRS"] = ":".join(dirs + [mod])

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")


if __name__ == "__main__":
    main()
