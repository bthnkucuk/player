# Patrol MCP fix

The `patrol` MCP server fails to load because `fvm dart run patrol_mcp` takes 60–76s on cold start (workspace pub resolve overhead with 500+ packages). Claude Code's default MCP connect timeout is 5s.

## Recommended fix (no file edits)

Add this to your shell rc (`~/.zshrc`) and **relaunch claude**:

```sh
export MCP_TIMEOUT=120000        # 120s — covers cold workspace resolve
export MCP_TOOL_TIMEOUT=600000   # 10min — patrol `run` blocks until test completes
```

These env vars are read by the claude binary on startup. Verified by:
- `claude --help` references `MCP_TIMEOUT`, `MCP_CONNECT_TIMEOUT_MS`, `MCP_TOOL_TIMEOUT`
- `~/.claude/cache/changelog.md`: "MCP server startup timeout can now be configured via MCP_TIMEOUT environment variable."

## Fallback (if env var doesn't suit)

```sh
fvm dart pub global activate patrol_mcp
# Then edit .claude/run-patrol last line:
#   exec patrol_mcp        # instead of `exec fvm dart run patrol_mcp`
# And ensure ~/.pub-cache/bin is on PATH
```

Trade-off: version pinning drifts from project's `^0.1.3`; needs re-activate on bumps.

## Why other approaches don't work

| Option | Issue |
|---|---|
| `dart compile exe` on pub-cache copy | Fails — needs project deps resolved |
| `dart compile exe` on bin stub | Brittle; must recompile after every `pub get` |
| `pub get --offline` wrapper | Workspace resolve dominates, not network |
| Drop patrol MCP, use Maestro only | Loses `native-tree`, hot-restart workflow |

No `patrol_cli`-bundled MCP exists (pub.dev `patrol_cli` ships no `mcp` subcommand); `patrol_mcp` is the only one.
