#!/usr/bin/env bash
set -euo pipefail

if [ "${CODEX_STOP_DECIDER_ACTIVE:-}" = "1" ]; then
  exit 0
fi

TMPDIR="${TMPDIR:-/tmp}"
WORK_DIR="$(mktemp -d "${TMPDIR%/}/codex-stop-decider.XXXXXX")"
INPUT_JSON="$WORK_DIR/input.json"
PROMPT_FILE="$WORK_DIR/prompt.txt"
OUT_FILE="$WORK_DIR/output.json"
LOG_FILE="$WORK_DIR/codex.jsonl"
AUDIT_LOG="${CODEX_STOP_DECIDER_AUDIT_LOG:-$HOME/.codex/hooks/stop-decider.audit.log}"
SCHEMA_FILE="${CODEX_STOP_DECIDER_SCHEMA:-$HOME/.codex/hooks/stop-decider.schema.json}"
PROXY_URL="${CODEX_STOP_DECIDER_PROXY_URL:-}"
MODEL_PROVIDER="${CODEX_STOP_DECIDER_MODEL_PROVIDER:-}"

export PATH="$HOME/space/miniforge3/bin:$HOME/.local/bin:$HOME/utils:$PATH"

if [ -n "$PROXY_URL" ]; then
  export http_proxy="$PROXY_URL"
  export https_proxy="$PROXY_URL"
  export HTTP_PROXY="$PROXY_URL"
  export HTTPS_PROXY="$PROXY_URL"
  unset ws_proxy wss_proxy WS_PROXY WSS_PROXY
fi

CODEX_BIN="${CODEX_STOP_DECIDER_CODEX_BIN:-}"
if [ -z "$CODEX_BIN" ]; then
  CODEX_BIN="$(command -v codex || true)"
fi
CODEX_PROVIDER_ARGS=()
if [ -n "$MODEL_PROVIDER" ]; then
  CODEX_PROVIDER_ARGS=(-c "model_provider=\"$MODEL_PROVIDER\"")
fi

audit() {
  {
    printf '%s\t' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' "$*"
  } >> "$AUDIT_LOG" 2>/dev/null || true
}

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

cat > "$INPUT_JSON"

PROMPT_STATUS=0
python3 - "$INPUT_JSON" "$PROMPT_FILE" <<'PY' || PROMPT_STATUS=$?
import json
import sys
from pathlib import Path

input_path = Path(sys.argv[1])
prompt_path = Path(sys.argv[2])

try:
    payload = json.loads(input_path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(20)

transcript_path = payload.get("transcript_path")
last_assistant = payload.get("last_assistant_message") or ""
cwd = payload.get("cwd") or ""
session_id = payload.get("session_id") or ""
turn_id = payload.get("turn_id") or ""
stop_hook_active = bool(payload.get("stop_hook_active"))

tail_lines = []
if transcript_path:
    path = Path(transcript_path)
    if path.exists():
        tail_lines = path.read_text(encoding="utf-8", errors="replace").splitlines()[-120:]

transcript_tail = "\n".join(tail_lines)
prompt = f"""你是 Codex Stop Hook 的判断器。你只处理一种情况：主 Codex 正在完成某个目标，却突然想暂停；这时你让它继续工作。

你会看到父 Codex 的最后上下文。请输出严格 JSON，符合：
{{"decision":"continue|stop","reason":"..."}}

判断标准：
- 只有当主 Codex 正在执行用户目标，且最后上下文明显表示“我还需要继续做目标内的必要步骤，但现在停下来了/准备停下”，才输出 continue。
- 典型 continue：仍需等待异步任务完成、继续轮询、继续运行验证、继续修复错误、继续抽取结果、继续生成已承诺的产物。
- 主 Codex 给用户提出建议、可选后续、下一步建议、例如“要不要试试……”“如果你想……”，一律输出 stop。
- 主 Codex 在提问用户、等待用户选择、做解释、总结已完成工作、给出报告、闲聊、处理不相关内容，一律输出 stop。
- 不要因为看到“继续”“下一步”“建议”这些词就 continue；必须是主 Codex 已承诺/正在执行的目标内必要动作突然中断。
- 不要自己判断任务应该怎么做，不要替主 Codex 规划新动作。
- stop_hook_active=true 只是说明这是 hook 触发后的续跑轮次，不改变判断标准。
- 如果不确定是不是“目标内必要动作突然暂停”，输出 stop。
- reason 要短，只说明你从主 Codex 哪句话看出继续或停止意图。
- 不要输出 Markdown，不要解释 JSON 之外的内容。

父 Codex 信息：
cwd: {cwd}
session_id: {session_id}
turn_id: {turn_id}
stop_hook_active: {stop_hook_active}

last_assistant_message:
{last_assistant}

transcript_tail_jsonl:
{transcript_tail}
"""
prompt_path.write_text(prompt, encoding="utf-8")
PY

case "$PROMPT_STATUS" in
  0)
    audit "prompt_built input=$INPUT_JSON"
    ;;
  *)
    audit "skip invalid_input status=$PROMPT_STATUS"
    exit 0
    ;;
esac

if [ -n "${CODEX_STOP_DECIDER_MOCK_RESULT_JSON:-}" ]; then
  printf '%s\n' "$CODEX_STOP_DECIDER_MOCK_RESULT_JSON" > "$OUT_FILE"
else
  if [ -z "$CODEX_BIN" ]; then
    audit "child_failed status=127 log=codex command not found"
    exit 0
  fi
  CODEX_STOP_DECIDER_ACTIVE=1 "$CODEX_BIN" exec \
    --ephemeral \
    --disable codex_hooks \
    --skip-git-repo-check \
    --ignore-rules \
    -m gpt-5.3-codex-spark \
    -c 'model_reasoning_effort="low"' \
    "${CODEX_PROVIDER_ARGS[@]}" \
    --output-schema "$SCHEMA_FILE" \
    -o "$OUT_FILE" \
    --json \
    - < "$PROMPT_FILE" > "$LOG_FILE" 2>&1
  CODEX_STATUS=$?
  if [ "$CODEX_STATUS" -ne 0 ]; then
    audit "child_failed status=$CODEX_STATUS log=$(tail -c 1200 "$LOG_FILE" | tr '\n' ' ')"
    exit 0
  fi
fi

python3 - "$OUT_FILE" "$AUDIT_LOG" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

out_path = Path(sys.argv[1])
audit_path = Path(sys.argv[2])

def audit(message: str) -> None:
    try:
        timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with audit_path.open("a", encoding="utf-8") as handle:
            handle.write(f"{timestamp}\t{message}\n")
    except Exception:
        pass

try:
    raw = out_path.read_text(encoding="utf-8")
    data = json.loads(raw)
except Exception as exc:
    audit(f"child_output_invalid error={type(exc).__name__}")
    print("{}")
    raise SystemExit(0)

decision = data.get("decision")
reason = (data.get("reason") or "").strip()
audit(f"child_output decision={decision!r} reason={reason[:300]!r}")

if decision == "continue" and reason:
    result = {"decision": "block", "reason": f"继续：{reason}"}
    audit(f"hook_output block reason={result['reason'][:300]!r}")
    print(json.dumps(result, ensure_ascii=False))
else:
    audit("hook_output pass")
    print("{}")
PY
