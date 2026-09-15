# Codex usage-limit marker

The live Phase 4a requester and checker treat a fresh non-verdict comment from the configured Codex bot as terminal `usage_limit` evidence only when the body begins with the provider's documented account-quota response: “You have reached your Codex usage limits for code reviews.” The response may continue after that opening sentence. Incidental quota vocabulary elsewhere in a task or review summary, including a filename such as `tests/test_codex_usage_limit_marker.sh`, is non-terminal, so polling may reach a later current-head verdict.

A genuine live usage-limit response preserves the existing behavior: `codex-review-request.sh` promptly exits `4` with `blocked_reason: "usage_limit"`, and `codex-review-check.sh` surfaces the same block through its diagnostic path. The `not_connected` marker, freshness and author filters, verdict precedence, latest-evidence ordering, retry budgets, and exit statuses retain their existing contracts.

The retrospective latency audit keeps its historical broad rate-limit classifier. Its event taxonomy does not determine whether a live request is terminal. `scripts/lib/codex-failure-markers.sh` owns both patterns so the live-versus-retrospective boundary is explicit.

`tests/test_codex_usage_limit_marker.sh` covers the shared classifier, the requester's real polling path, the checker's extracted live selector, the faithful provider responses, the captured clean task summary and filename-only control, the later current-head verdict path, and preservation of retrospective audit classification.
