# 0001: 1Password Access Model

## Status

Accepted — ratified by the repository owner (nathanjohnpayne) on 2026-05-21 via [#357](https://github.com/nathanjohnpayne/mergepath/issues/357), adopted on merge of [#369](https://github.com/nathanjohnpayne/mergepath/pull/369).

This ADR consolidates the ratified sub-decisions from [#355](https://github.com/nathanjohnpayne/mergepath/issues/355) and [#356](https://github.com/nathanjohnpayne/mergepath/issues/356). Every lane below is implemented and cross-agent reviewed: op-preflight token mode (#353 / #365), the CI service-account proof workflow (#354 / #368), reviewer-ref support with identity + negative-scope verification (#372), and the `human-hold` merge freeze (#367 / #370).

## Date

2026-05-21

## Context

Mergepath has several different 1Password access surfaces:

- attended local agent work;
- repository shell scripts such as `scripts/bootstrap.sh` and `scripts/op-preflight.sh`;
- CI/headless automation; and
- downstream template guidance for consumer repos.

The 2026-05-18 1Password audit originally assumed there was no first-party MCP path that changed Mergepath's script posture. That premise changed on 2026-05-20 when 1Password shipped the Environments MCP Server for Codex. The updated model needs to preserve the working CLI shell-out path for scripts while adopting the official attended Codex adapter where it applies.

The load-bearing distinction is between a portable 1Password core and client-specific adapters. Treating MCP as universal would be wrong because the official MCP server is Codex-specific today. Treating MCP as out of scope would also be wrong because attended Codex now has a documented just-in-time access path.

## Decision

Adopt a portable-core plus per-client-adapter model.

### Portable Core

The portable layer is:

- 1Password Environments for grouped runtime variables;
- `op://` secret references;
- `op run --environment <environment_id> -- <command>` for runtime environment injection;
- `op inject` for generated gitignored config files when a tool truly requires a file on disk; and
- scoped 1Password service-account tokens for approved headless workflows.

These primitives are available to any shell-capable agent or CI runner. They are the default language for Mergepath docs because they do not assume one particular AI client.

### Lanes

1. **Attended local Codex:** use the official 1Password Environments MCP Server for Codex where available. The intended security posture is just-in-time access with 1Password desktop approval, keeping raw secret values out of model context and off disk.
2. **Other attended agents:** Claude Code, Cursor, GitHub Copilot, and Windsurf should not be documented as using the Codex MCP server. Where a repo adopts mounted local Environment files, use the 1Password local `.env` validation hook for supported clients.
3. **Mergepath shell scripts:** keep CLI shell-outs. Existing scripts should continue to use `op read`, `op run`, and `op inject`; do not migrate `scripts/bootstrap.sh` or `scripts/op-preflight.sh` to a language SDK unless a separate design decision identifies a real scripting benefit.
4. **CI/headless:** use a dedicated, scoped 1Password service account only after the workflow's scope and threat model are approved. For the #355/#346 path, the approved shape is read-only access to the reviewer PAT items plus a canary proof item. Exclude the author PAT, GCP ADC, Cloudflare token, deploy keys, and unrelated runtime secrets unless a separate ticket approves the expansion. As built (#372): reviewer PAT items live in a dedicated service-account- accessible vault (never `Private`/`Personal`), referenced via `OP_PREFLIGHT_REVIEWER_PAT_REF`, and the CI proof verifies the reviewer PAT's GitHub identity and that the service account cannot read an out-of-scope shared-vault sentinel.

## Compatibility Matrix

| Capability | Codex | Claude Code | Cursor | GitHub Copilot | Windsurf | CI/headless |
|---|---|---|---|---|---|---|
| 1Password Environments MCP Server | Official adapter | Not documented | Not documented | Not documented | Not documented | No |
| 1Password local `.env` validation hook | Not listed in hook matrix | Supported | Supported | Supported | Supported | No |
| `op run --environment` / secret references | Works if shell-capable | Works if shell-capable | Works if shell-capable | Works if shell-capable | Works if shell-capable | Works with scoped service account |
| Service-account token | Headless only; explicit opt-in | Headless only; explicit opt-in | Headless only; explicit opt-in | Headless only; explicit opt-in | Headless only; explicit opt-in | Preferred non-interactive path |
| Mergepath `op-preflight.sh` review mode | Configured | Configured | Configured | Not configured | Not configured | Configured for `claude` / `cursor` / `codex` when `OP_SERVICE_ACCOUNT_TOKEN` is set |

## Security Rules

- Never ask a human to paste raw secrets into chat, issue comments, PR bodies, or review comments.
- Never print resolved secret values in logs.
- Do not use service-account token mode as an implicit fallback after biometric or desktop approval failure. Token mode is explicit-only.
- Treat long-lived service-account tokens as a weaker posture than attended desktop approval. Keep scope minimal, rotate deliberately, and mask all token-derived outputs.
- CI proofs should use a dedicated canary item or digest comparison where possible. A proof should demonstrate access without becoming a general-purpose secret exfiltration test.
- Unknown or unconfigured agents should fail closed rather than guessing a credential mapping.

## Consequences

- Mergepath keeps the existing shell script architecture. `op` remains the boundary for repository automation.
- Attended Codex guidance can point at the 1Password Environments MCP Server without implying other agents have the same adapter.
- Downstream repos get a stable compatibility matrix that separates portable 1Password primitives from client-specific integrations.
- CI/headless automation can proceed through #346/#353/#354 without weakening local attended sessions.
- Service-account scope expansions require new review. The #355 approval does not authorize author PAT, deploy, GCP ADC, Cloudflare, or broad runtime-secret access.

## Revisit Triggers

Revisit this ADR when any of the following happen:

- 1Password ships MCP support for Claude Code, Cursor, GitHub Copilot, Windsurf, or another agent Mergepath supports.
- 1Password changes the Environments service-account model, CLI command shape, or hook support matrix in a way that affects the compatibility table.
- Mergepath adds a new reviewer identity beyond `claude`, `cursor`, and `codex`.
- A real script call site needs structured SDK behavior that the CLI cannot provide cleanly.
- A workflow proposes expanding service-account scope beyond reviewer PAT items plus canary proof data.

## References

- [#347: 1Password access model umbrella](https://github.com/nathanjohnpayne/mergepath/issues/347)
- [#355: CI/headless service-account go/no-go](https://github.com/nathanjohnpayne/mergepath/issues/355)
- [#356: attended-agent access decision](https://github.com/nathanjohnpayne/mergepath/issues/356)
- [#346: wire scoped service account into CI and op-preflight](https://github.com/nathanjohnpayne/mergepath/issues/346)
- [#354: CI service-account proof workflow](https://github.com/nathanjohnpayne/mergepath/issues/354)
- [1Password Environments](https://www.1password.dev/environments)
- [Programmatically read 1Password Environments](https://www.1password.dev/environments/read-environment-variables)
- [1Password Environments MCP Server for Codex](https://www.1password.dev/environments/mcp-codex-server)
- [1Password local `.env` validation hook](https://www.1password.dev/environments/agent-hook-validate)
- [Load secrets with `op run`](https://www.1password.dev/cli/secrets-environment-variables)
