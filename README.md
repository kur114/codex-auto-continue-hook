# codex-auto-continue-hook

`codex-auto-continue-hook` 是一个 Codex Stop hook。它会在主 Codex 即将停止时启动一个轻量级子 Codex 判断器，只判断一件事：主 Codex 是否正在完成某个目标，却突然停在目标内必要步骤前。

如果判断器认为主 Codex 应该继续工作，就向 Codex hook 系统输出 `decision: block`，让主 Codex 收到“继续”的反馈并续跑。如果只是建议、总结、询问用户、等待用户选择或不相关内容，则默认放行，让 Codex 正常停止。

## 适用场景

- 主 Codex 说“继续等待中”，但其实准备停止。
- 网页端、远端任务、长时间推理还在运行，需要继续轮询。
- 已承诺生成报告、抽取结果、运行验证或修复错误，但还没有真正完成。

不适用场景：

- “要不要试试……”
- “如果你想，我可以……”
- 已完成后的可选建议。
- 主 Codex 正在向用户提问或等待选择。

## 快速使用

把脚本安装到 Codex hooks 目录：

```bash
mkdir -p "$HOME/.codex/hooks"
cp hooks/stop-decider.sh "$HOME/.codex/hooks/stop-decider.sh"
cp hooks/stop-decider.schema.json "$HOME/.codex/hooks/stop-decider.schema.json"
chmod +x "$HOME/.codex/hooks/stop-decider.sh"
```

在 `~/.codex/config.toml` 中开启 hooks：

```toml
[features]
codex_hooks = true
```

在 `~/.codex/hooks.json` 中配置 Stop hook：

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

## 人类部署方法

1. 克隆或复制本项目到目标机器。
2. 执行上面的“快速使用”安装步骤。
3. 确认目标机器能运行 `codex exec`。
4. 如需代理，在 `hooks.json` 中给命令加环境变量：

```json
{
  "type": "command",
  "command": "CODEX_STOP_DECIDER_PROXY_URL=127.0.0.1:8890 $HOME/.codex/hooks/stop-decider.sh",
  "timeout": 120
}
```

如需指定 provider：

```json
{
  "type": "command",
  "command": "CODEX_STOP_DECIDER_MODEL_PROVIDER=openai-http $HOME/.codex/hooks/stop-decider.sh",
  "timeout": 120
}
```

代理和 provider 可以组合：

```json
{
  "type": "command",
  "command": "CODEX_STOP_DECIDER_PROXY_URL=127.0.0.1:8890 CODEX_STOP_DECIDER_MODEL_PROVIDER=openai-http $HOME/.codex/hooks/stop-decider.sh",
  "timeout": 120
}
```

## Agent 部署

给 agent 使用的逐步部署说明见：[docs/AGENT_DEPLOY.md](docs/AGENT_DEPLOY.md)。

## 验证

语法检查：

```bash
bash -n "$HOME/.codex/hooks/stop-decider.sh"
```

mock continue：

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

mock stop：

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

## 文件结构

```text
hooks/stop-decider.sh
hooks/stop-decider.schema.json
hooks/hooks.json.example
docs/AGENT_DEPLOY.md
README.md
```
