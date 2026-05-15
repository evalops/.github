## EvalOps Integration

This project uses EvalOps for agent governance, metering, and memory. The MCP
server is configured in `.mcp.json`, `.codex/config.toml`, and
`.cursor/mcp.json` so supported coding agents can connect automatically.

On first use, you may be prompted to authenticate with EvalOps. After that,
agent governance and audit context should be available without committing local
API keys.
