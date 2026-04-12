# Devcontainer host-Ollama snippet

Use `devcontainer.ollama-host.jsonc` as a snippet in your project devcontainers.

It adds a `host.docker.internal` mapping and points tools inside the dev container to the shared host-level Ollama server through its OpenAI-compatible endpoint.

## Example merge

```json
{
  "runArgs": [
    "--add-host=host.docker.internal:host-gateway"
  ],
  "containerEnv": {
    "OPENAI_BASE_URL": "http://host.docker.internal:11434/v1",
    "OPENAI_API_KEY": "ollama"
  }
}
```
