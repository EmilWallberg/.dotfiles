# OpenCode local Ollama example

This folder contains an example OpenCode config for using a shared host-level Ollama server.

## Files

- `opencode.ollama.example.jsonc` — example provider and model config.

## Suggested setup

1. Copy the example config into your OpenCode config location:

```bash
mkdir -p ~/.config/opencode
cp opencode.ollama.example.jsonc ~/.config/opencode/opencode.json
```

2. Start the host Ollama service from `../ollama/`.
3. Pull the models you want to use.
4. Start OpenCode and switch models with `/models`.
5. Use built-in agents like **Plan** and **Build**, or define your own custom agents in your project config.

## Notes

- OpenCode supports local/custom providers through the `provider` config.
- The example uses Ollama's OpenAI-compatible `/v1` endpoint.
- Replace the example model IDs with the local models you actually want to use.
