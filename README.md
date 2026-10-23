# Sound of Silence

> "Hello darkness, my old friend..." — Simon & Garfunkel

An agent skill that stops shell commands and background jobs from hanging silently.

It enforces:

- **Pre-execution duration estimation** with Fast/Medium/Heavy timing profiles.
- **Adaptive timeouts** (poll interval, stall threshold, hard timeout).
- **Progress monitoring** via log growth and process-tree CPU/state inspection.
- **Graduated termination** with `SIGTERM` → `SIGKILL` for the whole process tree.

## Helper script

`scripts/watchdog_runner.sh` automates the lifecycle:

```bash
bash scripts/watchdog_runner.sh \
  -p 5 -s 30 -t 180 \
  -l /tmp/task.log \
  -- <command> [args...]
```

| Flag | Meaning |
|---|---|
| `-p` | poll interval (seconds) |
| `-s` | inactivity stall threshold (seconds) |
| `-t` | hard timeout (seconds) |
| `-l` | log file |
| `--` | command to run |

Exit codes:

- `0` (or the command's own code): completed normally.
- `124`: hard timeout exceeded.
- `125`: inactivity stall (no log growth and no CPU/disk activity in the process tree).

## Installation

```bash
git clone https://github.com/marcobergamin/sound-of-silence.git \
  ~/.agents/skills/sound-of-silence
```

OpenCode reads `~/.agents/skills` directly. To expose it to other harnesses:

```bash
mkdir -p ~/.config/opencode/skills ~/.gemini/config/skills ~/.gemini/antigravity-cli/skills
ln -sfn ~/.agents/skills/sound-of-silence ~/.config/opencode/skills/sound-of-silence
ln -sfn ~/.agents/skills/sound-of-silence ~/.gemini/config/skills/sound-of-silence
ln -sfn ~/.agents/skills/sound-of-silence ~/.gemini/antigravity-cli/skills/sound-of-silence
```

## Files

- `SKILL.md` — the skill manifest and workflow instructions.
- `scripts/watchdog_runner.sh` — the watchdog runner.
