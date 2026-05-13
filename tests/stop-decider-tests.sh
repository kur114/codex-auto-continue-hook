#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="${TMPDIR:-/tmp}"
WORK_DIR="$(mktemp -d "${TMPDIR%/}/stop-decider-tests.XXXXXX")"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  if [ "$actual" != "$expected" ]; then
    printf 'FAIL: %s\nexpected: %s\nactual:   %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

write_fake_codex() {
  local fake_codex="$WORK_DIR/codex"

  cat > "$fake_codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [ "${FAKE_CODEX_FAIL:-}" = "1" ]; then
  printf 'simulated child failure\n' >&2
  exit 42
fi

out_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      shift
      out_file="${1:-}"
      ;;
  esac
  shift || true
done

if [ -z "$out_file" ]; then
  printf 'missing output file\n' >&2
  exit 64
fi

if [ -n "${FAKE_CODEX_PROMPT_FILE:-}" ]; then
  cat > "$FAKE_CODEX_PROMPT_FILE"
else
  cat > /dev/null
fi

printf '%s\n' "${FAKE_CODEX_RESULT_JSON:-{\"decision\":\"continue\",\"reason\":\"测试仍在运行。\"}}" > "$out_file"
SH

  chmod +x "$fake_codex"
  printf '%s\n' "$fake_codex"
}

run_hook_json() {
  local audit_log="$1"
  local payload="$2"
  shift
  shift

  CODEX_STOP_DECIDER_AUDIT_LOG="$audit_log" \
  CODEX_STOP_DECIDER_SCHEMA="$ROOT_DIR/hooks/stop-decider.schema.json" \
  CODEX_STOP_DECIDER_CODEX_BIN="$FAKE_CODEX" \
  "$@" "$ROOT_DIR/hooks/stop-decider.sh" <<<"$payload"
}

run_hook() {
  local audit_log="$1"
  shift

  run_hook_json "$audit_log" '{"cwd":"/tmp","session_id":"test","turn_id":"t","stop_hook_active":false,"last_assistant_message":"测试还没跑完，我需要继续等待结果。"}' "$@"
}

FAKE_CODEX="$(write_fake_codex)"
export FAKE_CODEX

test_empty_provider_invokes_child_codex() {
  local audit_log="$WORK_DIR/empty-provider.audit.log"
  local stderr_log="$WORK_DIR/empty-provider.stderr.log"
  local output

  if ! output="$(run_hook "$audit_log" env 2>"$stderr_log")"; then
    cat "$stderr_log" >&2
    fail "hook should invoke child codex without requiring CODEX_STOP_DECIDER_MODEL_PROVIDER"
  fi

  assert_eq '{"decision": "block", "reason": "继续：测试仍在运行。"}' "$output" "empty provider should block on child continue"
}

test_child_failure_is_audited_and_fails_open() {
  local audit_log="$WORK_DIR/child-failure.audit.log"
  local stderr_log="$WORK_DIR/child-failure.stderr.log"
  local output

  if ! output="$(run_hook "$audit_log" env FAKE_CODEX_FAIL=1 2>"$stderr_log")"; then
    cat "$stderr_log" >&2
    fail "hook should fail open when child codex exits non-zero"
  fi

  assert_eq "" "$output" "child failure should not block"
  grep -q "child_failed status=42" "$audit_log" || fail "child failure should be recorded in audit log"
}

test_prompt_uses_only_last_assistant_message() {
  local audit_log="$WORK_DIR/prompt-only.audit.log"
  local prompt_file="$WORK_DIR/prompt-only.txt"
  local transcript_file="$WORK_DIR/transcript.jsonl"
  local output

  printf '%s\n' '{"role":"assistant","content":"旧 transcript 不该进入 prompt"}' > "$transcript_file"

  output="$(run_hook_json "$audit_log" \
    "{\"cwd\":\"/tmp\",\"session_id\":\"test\",\"turn_id\":\"t\",\"transcript_path\":\"$transcript_file\",\"last_assistant_message\":\"已完成并提交。\"}" \
    env FAKE_CODEX_PROMPT_FILE="$prompt_file" FAKE_CODEX_RESULT_JSON='{"decision":"stop","reason":"任务已完成。"}')"

  assert_eq "{}" "$output" "child stop should pass"
  grep -q "你只会看到父 Codex 的最后一条文本" "$prompt_file" || fail "prompt should state it only uses the last assistant message"
  grep -q "last_assistant_message:" "$prompt_file" || fail "prompt should include last assistant message"
  grep -q "已完成并提交。" "$prompt_file" || fail "prompt should include supplied last assistant message"
  ! grep -q "transcript_tail_jsonl" "$prompt_file" || fail "prompt should not mention transcript tail"
  ! grep -q "旧 transcript 不该进入 prompt" "$prompt_file" || fail "prompt should not include transcript contents"
}

test_progress_checkpoint_guidance_is_in_prompt() {
  local audit_log="$WORK_DIR/progress-guidance.audit.log"
  local prompt_file="$WORK_DIR/progress-guidance.txt"
  local output
  local payload

  payload='{"cwd":"/tmp","session_id":"test","turn_id":"t","last_assistant_message":"先在这里停一下。今天进度 425 / 10000，浏览器已保持可见。笔记已更新，状态已保存，已提交：fc2d193 Continue visible reading。"}'

  output="$(run_hook_json "$audit_log" "$payload" env FAKE_CODEX_PROMPT_FILE="$prompt_file")"

  assert_eq '{"decision": "block", "reason": "继续：测试仍在运行。"}' "$output" "fake child continue should still block"
  grep -q "阶段性检查点" "$prompt_file" || fail "prompt should describe progress checkpoints"
  grep -q "已提交只是阶段性落盘" "$prompt_file" || fail "prompt should include the progress checkpoint few-shot"
  grep -q "425／10000" "$prompt_file" || fail "prompt should include the slash-normalized few-shot example"
}

test_empty_provider_invokes_child_codex
test_child_failure_is_audited_and_fails_open
test_prompt_uses_only_last_assistant_message
test_progress_checkpoint_guidance_is_in_prompt

printf 'ok - stop-decider tests passed\n'
