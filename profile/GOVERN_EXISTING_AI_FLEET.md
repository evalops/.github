# Govern the AI Fleet You Already Have

EvalOps should lead with the control-plane problem enterprises already feel:
employees and products are using AI through many surfaces, and the organization
needs visibility, policy, audit, and cost attribution across that existing
fleet.

## Positioning

EvalOps is the governance layer for AI already running in the business. It does
not require every team to rebuild on a new agent framework before security,
platform, and finance leaders can see what is happening.

The clearest buyer language:

- discover where AI is already used
- govern model and tool access without blocking useful work
- audit prompts, tool calls, approvals, and outcomes
- attribute cost and risk to teams, users, apps, and vendors
- retrofit controls into existing SDK, gateway, MCP, Slack, and SaaS surfaces

## Product Surfaces

Use existing Platform primitives as retrofit anchors:

- `llm-gateway`: egress proxy for model traffic and customer-owned SDK usage.
- `mcp-firewall`: policy and audit at MCP boundaries.
- `governance`: PII, safety, and data-classification checks on flowing payloads.
- `approvals`: human gates for risky actions, especially external agents.
- `audit`, `meter`, and `traces`: tamper-evident history, spend, and prompt/tool
  observability.
- `identity` and `entities`: principal resolution across Okta, GitHub, Slack,
  OpenAI, and internal systems.
- `connectors`, `gate`, and `registry`: discovery and control of customer SaaS,
  private network, and AI asset inventory.

## Workstreams

- Discovery MVP: passive ingestion first, active scanners only where customers
  need deeper inventory.
- SDK shims: one-import-change OpenAI, Anthropic, and Google clients routed
  through `llm-gateway`.
- Retrofit playbooks: Copilot, Cursor, SaaS-with-AI, generic SDK usage, and
  internal app integration.
- Hopper messaging: outcome-forward pages for governance leaders, not only
  architecture-forward platform pages.
- Competitive intelligence: maintain a quarterly map against Portkey,
  LangSmith, Lakera, Nightfall, Helicone, and cloud-native controls.

## Success Measures

- Prospects describe themselves as AI governance buyers rather than generic AI
  buyers.
- Retrofitted integrations per customer increases after onboarding.
- Revenue per customer is higher on the governance posture than on greenfield
  agent tooling alone.
- Sales and deployment artifacts cite real retrofit paths instead of requiring a
  new EvalOps-built agent first.
