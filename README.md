# codex-auto-continue-hook

用 Codex 时常遇到一个痛点：活干到一半，它突然自己停了。

典型场景比如：它说“网页端任务还在跑，我稍后回来取结果”，或者“测试失败了，我来看看怎么修”，甚至“继续等待报告生成”——但紧接着却触发了 Stop hook，直接罢工。

这个项目就是为了解决这种半路摸鱼的情况。原理很简单：当 Codex 准备 Stop 时，通过 hook 唤醒一个轻量级子进程，专门用来判断主进程是不是在未完成目标时中断。如果活确实没干完，就返回 `block` 把它踹回去继续干；如果任务做完了，或者只是顺嘴问一句“要不要加个新功能”，那就放它收工。

---

## 拦截规则

**会被拦截并强制继续的场景：**
- “继续等待中：网页端任务还在运行，完成后会抽取答案并生成 Markdown 报告。”
- “测试还没跑完，我需要继续等结果。”
- “验证失败了，我先修这个错误。”
- “远端任务还在执行，我稍后回来检查。”

**不会拦截，允许正常结束的场景：**
- “已完成。要不要试试再加一个监控脚本？”
- “如果你想，我可以继续优化。”
- “下一步可以考虑部署到服务器。”
- “你希望我用方案 A 还是方案 B？”

判断逻辑非常克制：只有当 Codex 明确在执行当前目标任务，且在必要步骤前暂停时，才会阻止它停止。

---

## 自动安装

如果你想让其他 AI Agent 帮你装这个插件，直接把这篇文档发给它：  
[docs/AGENT_DEPLOY.md](docs/AGENT_DEPLOY.md)

## 手动安装

将脚本部署到 Codex 的 hooks 目录：

```bash
mkdir -p "$HOME/.codex/hooks"
cp hooks/stop-decider.sh "$HOME/.codex/hooks/stop-decider.sh"
cp hooks/stop-decider.schema.json "$HOME/.codex/hooks/stop-decider.schema.json"
chmod +x "$HOME/.codex/hooks/stop-decider.sh"
```

修改 `~/.codex/config.toml`，确保开启 hooks 功能：

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

配置完成后，新开 Codex 会话即可生效。

## 代理与 Provider 设置

如果你的环境需要走代理，可以在命令中直接注入 `CODEX_STOP_DECIDER_PROXY_URL` 环境变量：

```json
{
  "type": "command",
  "command": "CODEX_STOP_DECIDER_PROXY_URL=127.0.0.1:8890 $HOME/.codex/hooks/stop-decider.sh",
  "timeout": 120
}
```

如果你想让子进程使用特定的 provider（比如绕过 websocket 限制的 `openai-http`），可以设置 `CODEX_STOP_DECIDER_MODEL_PROVIDER`：

```json
{
  "type": "command",
  "command": "CODEX_STOP_DECIDER_PROXY_URL=127.0.0.1:8890 CODEX_STOP_DECIDER_MODEL_PROVIDER=openai-http $HOME/.codex/hooks/stop-decider.sh",
  "timeout": 120
}
```

## 本地测试验证

先检查脚本语法是否正确：

```bash
bash -n "$HOME/.codex/hooks/stop-decider.sh"
```

模拟“活没干完需要继续”的情况：

```bash
CODEX_STOP_DECIDER_MOCK_RESULT_JSON='{"decision":"continue","reason":"主 Codex 表示还要继续等待。"}' \
  "$HOME/.codex/hooks/stop-decider.sh" <<'JSON'
{"cwd":"/tmp","session_id":"test","turn_id":"t","stop_hook_active":true,"last_assistant_message":"继续等待中：网页端任务还在运行，完成后会抽取答案并生成 Markdown 报告。"}
JSON
```

预期输出（强制 block）：

```json
{"decision":"block","reason":"继续：主 Codex 表示还要继续等待。"}
```

模拟“任务完成，只是提个建议”的情况：

```bash
CODEX_STOP_DECIDER_MOCK_RESULT_JSON='{"decision":"stop","reason":"这是可选建议。"}' \
  "$HOME/.codex/hooks/stop-decider.sh" <<'JSON'
{"cwd":"/tmp","session_id":"test","turn_id":"t","stop_hook_active":false,"last_assistant_message":"已完成。要不要试试再加一个监控脚本？"}
JSON
```

预期输出（不干预）：

```json
{}
```

## 目录结构

```text
hooks/stop-decider.sh
hooks/stop-decider.schema.json
hooks/hooks.json.example
docs/AGENT_DEPLOY.md
README.md
```
