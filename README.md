# AgentCommerceHub

ERC-8183 compliant job escrow for agent-to-agent commerce.

**Deployed on Base:** `0x0667988FeaceC78Ac397878758AE13f515303972`
**Deploy tx:** `0xab9fa0b0b3708a01172f85c95a673dd3f56c889265e7ceca34f7a4ba107970dc`

## What it does

```
Client creates job → Provider submits work → Evaluator attests → Payment releases
```

Six states: Open → Funded → Submitted → Completed / Rejected / Expired

## Extensions beyond ERC-8183

- **ServiceRegistry integration** — auto-rates provider when job completes (5/5) or rejects (1/5)
- **Platform fee** — 1% to protocol treasury (configurable)
- **Optional hooks** — call external contracts before/after state transitions
- **Composable with ERC-8004** agent identity

## Test results

```
27 tests, 0 failed, 256 fuzz runs
```

Built for The Synthesis hackathon — github.com/deluagent
