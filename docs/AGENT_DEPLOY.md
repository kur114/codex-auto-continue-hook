# Agent 部署指南

本文档给 Codex/agent 使用，用来把 `codex-auto-continue-hook` 部署到目标机器。

## 目标

把本项目中的 Stop hook 安装到目标用户的 `$HOME/.codex/hooks`，开启 `codex_hooks`，并把 `~/.codex/hooks.json` 的 `Stop` 事件指向该脚本。

## 部署步骤

1. 确认目标机器可运行 `codex exec`。
2. 创建目录：
   ```bash
   mkdir -p "$HOME/.codex/hooks"
   ```
3. 安装文件：
   ```bash
   cp hooks/stop-decider.sh "$HOME/.codex/hooks/stop-decider.sh"
   cp hooks/stop-decider.schema.json "$HOME/.codex/hooks/stop-decider.schema.json"
   chmod +x "$HOME/.codex/hooks/stop-decider.sh"
   ```
4. 在 `~/.codex/config.toml` 的 `[features]` 下确保：
   ```toml
   codex_hooks = true
   ```
5. 写入或合并 `~/.codex/hooks.json`：
   ```json
   {
     "hooks": {
       "Stop": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "$HOME/.codex/hooks/stop-decider.sh",
               "timeout": 120
             }
           ]
         }
       ]
     }
   }
   ```

## 可选环境变量

- `CODEX_STOP_DECIDER_CODEX_BIN`：指定子 Codex 可执行文件路径。
- `CODEX_STOP_DECIDER_SCHEMA`：指定 JSON schema 路径，默认是 `$HOME/.codex/hooks/stop-decider.schema.json`。
- `CODEX_STOP_DECIDER_PROXY_URL`：指定 `http_proxy/https_proxy`，例如 `127.0.0.1:8890`。
- `CODEX_STOP_DECIDER_MODEL_PROVIDER`：指定子 Codex 使用的 provider，例如 `openai-http`。
- `CODEX_STOP_DECIDER_AUDIT_LOG`：指定 audit log 路径。

示例：
```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "CODEX_STOP_DECIDER_PROXY_URL=127.0.0.1:8890 CODEX_STOP_DECIDER_MODEL_PROVIDER=openai-http $HOME/.codex/hooks/stop-decider.sh",
            "timeout": 120
          }
        ]
      }
    ]
  }
}
```

## 验证

运行语法检查：
```bash
bash -n "$HOME/.codex/hooks/stop-decider.sh"
```

运行 mock 验证：
```bash
CODEX_STOP_DECIDER_MOCK_RESULT_JSON='{"decision":"continue","reason":"主 Codex 表示还要继续等待。"}' \
  "$HOME/.codex/hooks/stop-decider.sh" <<'JSON'
{"cwd":"/tmp","session_id":"test","turn_id":"t","stop_hook_active":true,"last_assistant_message":"继续等待中：网页端任务还在运行，完成后会抽取答案并生成 Markdown 报告。"}
JSON
```

期望输出：
```json
{"decision":"block","reason":"继续：主 Codex 表示还要继续等待。"}
```

再验证建议类内容会放行：
```bash
CODEX_STOP_DECIDER_MOCK_RESULT_JSON='{"decision":"stop","reason":"这是可选建议。"}' \
  "$HOME/.codex/hooks/stop-decider.sh" <<'JSON'
{"cwd":"/tmp","session_id":"test","turn_id":"t","stop_hook_active":false,"last_assistant_message":"已完成。要不要试试再加一个监控脚本？"}
JSON
```

期望输出：
```json
{}
```
