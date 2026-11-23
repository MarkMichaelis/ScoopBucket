# GoDaddy domains and DNS for AI agents

Lets Claude Code, OpenAI Codex, and any other MCP client list your GoDaddy
domains, inspect DNS, and -- only with your explicit approval -- create,
change, and delete DNS records. Everything goes through GoDaddy's official
CLI, `gddy`, signed in as you on this machine. Issue: #527.

| Piece | Where | What it does |
|---|---|---|
| `GoDaddy CLI` package | `bucket/DeveloperBasePackages.ps1` | Installs `gddy`, shims it onto PATH, registers tab completion, updates it |
| GoDaddy DNS MCP server | `bucket/ai/GoDaddyDnsMcp.ps1` + `.psm1` | Local stdio MCP server exposing eight `godaddy_*` tools that wrap `gddy` |
| Agent wiring | `bucket/AIAgents.Mcp.ps1` (`MCP Server Configuration`) | Registers the server with Claude Code, Codex, Claude Desktop and Copilot CLI, and sets approval rules |

## 1. Install and sign in

```powershell
Install-Package -Name 'GoDaddy CLI'                # or: scoop install MarkMichaelis/DeveloperBasePackages
Update-Package 'MCP Server Configuration'          # registers the MCP server once gddy exists
gddy auth login                                    # one time; opens your browser
gddy domain list                                   # proves the sign-in works
```

- **Install.** Neither winget nor Scoop carries `gddy`, so the package runs
  GoDaddy's documented Windows installer
  (`https://github.com/godaddy/cli/releases/latest/download/install.ps1`). It
  downloads the release zip, checks its SHA-256 against the release's checksum
  file, and writes `%LOCALAPPDATA%\Programs\gddy\gddy.exe`. The package passes
  `-SkipPathUpdate` and adds a Scoop shim instead of a PATH entry (this
  bucket's "shim over PATH" rule). Re-running it changes nothing.
- **Update.** `Update-Package 'GoDaddy CLI'` runs `gddy update apply`, which
  makes the same checksum-verified download and replaces the binary in place.
- **Tab completion.** Comes from the binary (`gddy completion powershell`), so
  it always matches the installed version.
- **Sign-in.** `gddy auth login` is browser OAuth (PKCE), refreshed
  automatically. For headless use, create a Personal Access Token with
  `gddy pat create`, then store it with `gddy pat add` or set `GDDY_PAT` /
  `GDDY_PAT_PROD`. Nothing in this repo stores or reads a secret. Default
  sign-in scopes include `domains.domain:read` and `domains.dns:update`.
  Nameserver changes need a scope this integration never asks for.
- **Where the token lives (Windows).** gddy's OAuth token is about 3.5 KB,
  larger than Windows Credential Manager's 2,560-byte limit per entry. So
  `gddy auth login` saves it to gddy's file store
  (`%APPDATA%\gddy\credentials\`), while gddy's default `auto` store reads only
  Credential Manager. Every later command then acts signed out and opens a
  browser.
  - The package therefore sets `gddy config set credentials.store file` on
    install and update, unless you already picked a store yourself.
  - The MCP server also checks the file store and uses it when the sign-in is
    there.
  - The file inherits `%APPDATA%`'s permissions, so anything that can read your
    profile, including sandboxed agent processes granted read access to it,
    can read the token. Revoke it with `gddy auth logout`.
- **Uninstall.** `Uninstall-Package 'GoDaddy CLI'` removes the binary and shim
  but leaves your sign-in. Run `gddy auth logout` first to clear it.

## 2. Why a local MCP server (decision record)

GoDaddy's offerings were checked first (November 2026, gddy 0.2.37):

| Option | Exists? | Covers DNS management? |
|---|---|---|
| Official GoDaddy MCP server (`https://api.godaddy.com/v1/domains/mcp`; also the *claude.ai GoDaddy* connector) | Yes | **No.** Read-only public domain search and availability. No account, no DNS. |
| Official `gddy` agent skill (`.agents/skills/gddy`) and Claude Code plugin (`claude plugin install gddy@godaddy`) | Yes | Teaches agents the raw CLI. It cannot *enforce* anything. |
| `gddy` itself | Yes | "Agent-first": JSON output when not on a terminal, `--dry-run`, `gddy guide`. |

The deciding facts come from `gddy` itself:

- `gddy dns set` replaces **every** record of a type+name, and `gddy dns delete`
  removes every one. Changing one of three TXT records at `@` with the raw CLI
  rewrites all three, applying one TTL and priority to each.
- A `gddy` that is not signed in opens a browser and blocks for about two
  minutes. The undocumented `--non-interactive` flag does not stop this.
- A skill is instructions. Whether an agent asks before running
  `gddy dns delete` depends on the model following them.

So DNS goes through a **minimal local MCP server** that wraps `gddy`. The
safeguards are enforced in code, not in prose. It is **one** implementation for
every agent, and needs no hosting or network listener (stdio).

**Skill vs MCP server -- are both needed?** No. An MCP server is a process
that exposes typed, discoverable tools. The client lists them, validates
arguments against their schemas, and gates each call with its own approval
UI. A skill is a document that teaches an agent a workflow, which the agent
then performs with its general tools (usually the shell). The MCP server
already carries its workflow: its `instructions` (Claude Code shows these to
the model) and its tool descriptions spell out read → plan → approve → apply →
verify. A separate skill would duplicate that.

The official `gddy` plugin is **not** installed by default, because it steers
agents to raw `gddy dns set/delete` for DNS. If you want it for hosting, email
or purchases, it is opt-in:

```powershell
claude plugin marketplace add godaddy/cli
claude plugin install gddy@godaddy
npx skills add godaddy/cli --skill gddy --agent codex   # Codex
```

Raw `gddy` DNS writes in Claude Code still prompt either way (see §4).

## 3. The tools

| Tool | Kind | Purpose |
|---|---|---|
| `godaddy_list_domains` | read | Domains in the account (status, expiry, auto-renew, nameservers) |
| `godaddy_get_domain` | read | One domain's details, and whether it uses GoDaddy DNS |
| `godaddy_list_dns_records` | read | All records (optionally by type/name), each with its `recordId` |
| `godaddy_get_dns_record` | read | One type+name record set or a single record. SPF/DMARC check for TXT at `@` / `_dmarc` |
| `godaddy_create_dns_record` | write | Add one record; existing records untouched |
| `godaddy_update_dns_record` | write | Change exactly one record (by `recordId` or `currentData`) |
| `godaddy_delete_dns_record` | write | Delete exactly one record, or a whole set with `deleteAll=true` |
| `godaddy_verify_dns` | read | Compare GoDaddy's records (or `expected`) with authoritative and public DNS. Email-auth report for TXT/MX |

Every tool returns structured JSON (`structuredContent` plus the same JSON as
text). Failures come back as `{ "error": { "code", "message", "hint",
"details" } }`. The codes are:

- `AUTH_REQUIRED`, `AUTH_EXPIRED`, `PERMISSION_DENIED`
- `EXTERNAL_DNS`: the domain is registered here, but another provider hosts its
  DNS (for example Cloudflare), so GoDaddy holds no records for it.
- `VALIDATION_ERROR`, `NOT_FOUND`, `AMBIGUOUS_MATCH`, `DUPLICATE_RECORD`, `CONFLICT`, `NO_CHANGE`
- `APPROVAL_REQUIRED`, `STATE_CHANGED`
- `PROVIDER_LIMITATION`, `READ_ONLY_RECORD_TYPE`
- `EXECUTION_FAILED`, `PARTIAL_FAILURE`
- `TIMEOUT`, `PARSE_ERROR`, `GDDY_NOT_INSTALLED`, `CLI_ERROR`

Supported types are those `gddy` accepts: A, AAAA, ALIAS, CAA, CNAME, HTTPS,
MX, SRV, SVCB, TLSA, TXT, plus NS and SOA read-only.

### Safety model

1. **Reads run freely.** Claude Code `allow` rules and Codex `approve` mode let
   them run without a prompt.
2. **Writes are two-phase.**
   - A write call defaults to `dryRun=true`. That changes nothing and returns
     a **plan**:
     - every record added, removed and kept;
     - the exact `gddy` commands;
     - `gddy`'s own `--dry-run` preview;
     - **risks** (MX, SPF, DKIM, DMARC, autodiscover, web traffic at `@`/`www`, CAA/TLS, TTL caching);
     - a **rollback** plan;
     - a `confirmationToken`.
   - The agent shows you the plan and asks.
   - Only then does it repeat the call with `dryRun=false` and the token.
3. **The token binds the exact request to the exact records it affects.** If
   the arguments differ, or the records changed after the plan, the apply is
   refused with `STATE_CHANGED` and nothing runs. The token proves the plan
   is unchanged, **not** that a person approved it. An agent could dry-run and
   apply back to back.
4. **Your client asks.** The human approval gate is the client's per-call
   prompt:
   - **Claude Code** `ask` rules and **Codex** `approval_mode = "prompt"` cover
     every write-tool call. Dry runs prompt too, because those rules match
     tool names, not arguments.
   - An `ask` rule outranks any later "always allow", and still prompts in
     auto mode.
   - **Other clients** (Claude Desktop, Copilot CLI) get no
     per-tool rule from this bucket. Set their tool approval to ask before
     relying on them for changes; otherwise only the agent's own adherence to
     the server instructions stands between a plan and its execution.
   - Raw `gddy dns add/set/delete`, `gddy domain nameserver` and `gddy api call`
     in Claude Code's **Bash and PowerShell** tools also prompt, including
     `*gddy*` path forms. Claude Code documents these rules as covering the
     usual invocation, not as a hard boundary, which is why DNS changes are
     meant to go through the MCP server.
5. **One record at a time.** Updates and deletes target one record by
   `recordId` or current value; several matches return `AMBIGUOUS_MATCH`, and
   giving neither is a validation error. No other record is listed, rewritten
   or deleted:
   - **Update:** add the new record first, then delete only the old one by
     recordId (`gddy api call deleteDNSRecord`).
   - **Delete:** delete only that record by recordId, even when it is the only
     one.
   - `gddy dns set` (which replaces a whole type+name set) is used only where
     the narrow path cannot work and the set holds just that record: a CNAME
     or ALIAS, or a TTL/priority-only change.
   - A **TTL- or priority-only change to one record of a multi-record set** is
     refused with `PROVIDER_LIMITATION`. GoDaddy identifies records by name,
     type and value, so the change can't be made without rewriting the
     siblings or briefly removing the record. The agent can propose a delete
     followed by a create, approved separately, telling you about the gap.
   - Sibling records always keep their values, TTLs and priorities.
   - During a dry run, the raw API DELETE is never sent, even with
     `--dry-run`. That step is described from the plan.
6. **Refused outright:**
   - exact duplicates;
   - the same value with different settings (use update);
   - a second SPF or DMARC record;
   - a CNAME alongside other records, or at `@`;
   - wildcards outside A/AAAA/CNAME;
   - TTLs outside 600–86400 (GoDaddy's limits);
   - NS/SOA edits.
7. **Verification.** After applying, the server re-reads the zone. It reports
   `matchesPlan` (the record set equals the plan) and
   `unrelatedRecordsUnchanged` (every other record is byte-identical). It then
   points the agent at `godaddy_verify_dns` to check live DNS.
8. **No shell, no injection.** `gddy` gets an argument array
   (`ProcessStartInfo.ArgumentList`), with values as single `--flag=value`
   arguments, so a value starting with `-` can never become a flag.
9. **No surprise browser.** The server checks `gddy auth status` before any
   account call. If `gddy` still starts its browser login, the server kills it
   and returns `AUTH_REQUIRED`. It watches stderr only, so a record value can't
   trigger this.
10. **Data stays data.**
    - Record values are parsed without type coercion. A TXT value like
      `2024-01-15T10:00:00Z` stays exactly that string and is never re-written
      as a date.
    - `gddy`'s update banners, which address AI assistants directly, are
      stripped from error messages, and the messages are capped in length.
    - The server instructions tell agents that record values are data, not
      instructions.

**Rollback.** Every plan carries `rollback.steps`, the tool calls that undo it,
plus `rollback.previousRecords`. Rollback steps go through the same dry-run and
approval flow.

## 4. Agent configuration

`Update-Package 'MCP Server Configuration'` (part of AIAgents) does all of
this whenever `gddy` is installed, and re-running changes nothing. It copies
the server to `%LOCALAPPDATA%\ScoopBucket\GoDaddyDnsMcp\`, so agent configs
never point into a bucket checkout or a git worktree.

**Claude Code** -- user scope in `~/.claude.json`, plus rules merged into
`~/.claude/settings.json` (existing keys and rules are kept):

```json
"mcpServers": { "godaddy": { "command": "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
  "args": ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", "C:\\Users\\<you>\\AppData\\Local\\ScoopBucket\\GoDaddyDnsMcp\\GoDaddyDnsMcp.ps1"] } }

"permissions": {
  "allow": ["mcp__godaddy__godaddy_list_domains", "mcp__godaddy__godaddy_get_domain",
            "mcp__godaddy__godaddy_list_dns_records", "mcp__godaddy__godaddy_get_dns_record",
            "mcp__godaddy__godaddy_verify_dns"],
  "ask":   ["mcp__godaddy__godaddy_create_dns_record", "mcp__godaddy__godaddy_update_dns_record",
            "mcp__godaddy__godaddy_delete_dns_record",
            "Bash(gddy dns set:*)", "Bash(*gddy* dns set *)", "PowerShell(gddy dns set *)", "PowerShell(*gddy* dns set *)",
            "... the same four forms for dns add, dns delete, domain nameserver, api call"] }
```

The first change saves the original as `settings.json.pre-godaddy.bak`.

Check with `claude mcp get godaddy` (shows `√ Connected`).

**Codex** -- `~/.codex/config.toml`:

```toml
[mcp_servers.godaddy]
command = "C:\\Program Files\\PowerShell\\7\\pwsh.exe"
args = ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", "C:\\Users\\<you>\\AppData\\Local\\ScoopBucket\\GoDaddyDnsMcp\\GoDaddyDnsMcp.ps1"]

[mcp_servers.godaddy.tools.godaddy_list_dns_records]
approval_mode = "approve"        # same for the other four read tools

[mcp_servers.godaddy.tools.godaddy_update_dns_record]
approval_mode = "prompt"         # same for create and delete
```

Check with `codex mcp get godaddy`.

**Claude Desktop and Copilot CLI** get the same entry. Both prompt before each
MCP tool call by default; keep it that way for the write tools.

**Grok CLI and Antigravity are skipped on purpose.** The bucket wires its other
MCP servers into them, but sets no approval rule there, and their default MCP
approval behavior is unverified. Add the entry below by hand once each is set
to ask before running a tool.

**Any other MCP client** (Cursor, VS Code, ...) -- local stdio, no network
listener:

```json
{ "mcpServers": { "godaddy": {
    "command": "pwsh",
    "args": ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", "C:/Users/<you>/AppData/Local/ScoopBucket/GoDaddyDnsMcp/GoDaddyDnsMcp.ps1"] } } }
```

Requirements: PowerShell 7 and `gddy` on the same machine. The server writes
only JSON-RPC to stdout; diagnostics go to stderr.

## 5. Things to ask

| You say | What the agent does |
|---|---|
| "List all the domains in my GoDaddy account." | `godaddy_list_domains` |
| "Show me the DNS records for enabl.org." | `godaddy_list_dns_records { domain: "enabl.org" }`, grouped by type. `enabl.org` itself is registered at GoDaddy but its DNS is hosted by Cloudflare, so this returns `EXTERNAL_DNS` naming Cloudflare. The agent can then show what is live with `godaddy_verify_dns` per type. For a domain on GoDaddy DNS (e.g. `michaelis.net`) it lists every record with its `recordId` |
| "Check whether the SPF record for enabl.org is configured correctly." | `godaddy_get_dns_record` for TXT `@` (SPF lint: exactly one record, `all` qualifier, the 10-lookup limit), then `godaddy_verify_dns` TXT `@` to confirm the public answer |
| "Prepare a new TXT verification record for enabl.org." | Asks for the value if you did not give it, then `godaddy_create_dns_record` with `dryRun=true`. Shows the plan, risks and rollback and **stops for your approval** |
| "Change the www CNAME for enabl.org to enabl.github.io." | Reads the current CNAME, then dry-runs `godaddy_update_dns_record { type: "CNAME", name: "www", currentData: <current>, data: "enabl.github.io" }`. Flags the web-traffic risk and waits. After you approve, applies with the token, verifies, and runs `godaddy_verify_dns` |
| "Explain why email authentication is failing for this domain." | `godaddy_verify_dns` with TXT `@` and MX. The `emailAuthentication` report covers MX, SPF, DMARC and DKIM selectors, so the agent can pinpoint, say, two SPF records (permerror) or `p=reject` without DKIM. For a domain hosted elsewhere, the report is built from public DNS; DKIM selectors can't be listed that way, so check a known selector by name |
| "Compare the configured DNS records with what public DNS currently returns." | `godaddy_verify_dns` per record type. `in_sync`, `propagating` (public cache still old), `authoritative_mismatch`, or `external_nameservers` (the domain is not on GoDaddy DNS, so GoDaddy records are not live) |

## 6. Tests

```powershell
.\bucket\Invoke-Tests.ps1 -Pattern GoDaddy                 # Light: server, safety, wiring, package hooks (mocked gddy; no DNS)
.\bucket\Invoke-Tests.ps1 -Pattern AIAgents.Mcp            # Light: agent-config wiring incl. Codex per-tool approval
.\bucket\Invoke-Tests.ps1 -Pattern GoDaddy -Tag Install    # local: real gddy install twice, PATH, DNS commands, completion, update check
```

The Light suite drives every write path against an in-memory fake of `gddy`,
so automated tests never create, change, or delete live DNS.

## 7. Troubleshooting

| Symptom | Fix |
|---|---|
| `AUTH_REQUIRED` / `AUTH_EXPIRED` | Run `gddy auth login` in a terminal, then retry |
| You signed in, but `gddy` still opens a browser or says "expired" | The token is in gddy's file store but gddy reads Credential Manager. Run `gddy config set credentials.store file` (the package does this on install and update) |
| `PERMISSION_DENIED` on a write | `gddy auth login --scope domains.dns:update`, or a PAT with that scope |
| `EXTERNAL_DNS`, or `external_nameservers` from verify | The domain's DNS is hosted elsewhere (e.g. Cloudflare). Edit records there; `godaddy_verify_dns` still shows what is live |
| `STATE_CHANGED` | Records changed after the plan was approved, or the arguments differ. Re-plan and re-approve |
| `PROVIDER_LIMITATION` | A TTL/priority-only change to one record of a multi-record set, or GoDaddy returned no `recordId`. Use the GoDaddy DNS page, or a separately approved delete then create |
| Server missing from an agent | `Update-Package 'MCP Server Configuration'` (needs `gddy` installed first) |
