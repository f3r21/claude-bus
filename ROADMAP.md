# claude-bus — Feedback Synthesis & v0.2 Roadmap

Date: 2026-06-15
Sources: three field reports from sessions that coordinated on a shared LaTeX thesis in parallel — `FigurasTablas` (FT), `Consistencia` (CO), `OnlineBoutique` (OB).
Scope: synthesis and prioritization only. No code was changed. Breaking changes to the 6-tool API are on the table for v0.2 where correctness justifies them.

Effort key: **S** ≈ under an hour, **M** ≈ a few hours, **L** ≈ a day-plus or needs a design decision first. Sized against the current ~130-line `core.py`.

---

## TL;DR

The concept is validated. Three independent sessions learned the 6-verb model instantly and used it for non-trivial real coordination. The gaps cluster in four places, in priority order:

1. **Silent data loss** — `set_state` clobbers concurrent writes, and broadcast read-tracking drops messages (a code-level bug, see below).
2. **The real risk is unguarded** — the bus coordinates *messages* but not the *shared working tree*. The one near-miss conflict was caught by `grep`, not by the bus.
3. **No delivery integrity** — no read-receipts, no threading, sender is spoofable.
4. **Weak presence** — `agents()` hides stale sessions, no goodbye, crude time-window.

If you ship only four things: **per-recipient message delivery** (fixes the broadcast bug + unlocks ACK/replay), **`set_state` CAS + append**, **file soft-locks**, and **session-bound identity**. Rationale at the end.

---

## What the three sessions agreed works — do not regress

Every report opened by praising the same properties. Treat these as invariants for v0.2:

- **Six verbs, learned instantly.** `register / agents / send / inbox / set_state / get_state` maps cleanly to natural language ("tell X…", "announce…"). Keep the surface small; add tools sparingly.
- **Two channels, correctly separated.** Ephemeral messages for conversation, `set_state` as a durable blackboard. All three called the blackboard the more valuable half.
- **Broadcast (`to:"all"`) + 1:1 with the same `send`.** Natural "announce" pattern.
- **Retroactive broadcast delivery.** FT received a broadcast sent *before* it registered. This late-joiner behavior is loved — preserve it explicitly through any delivery refactor.
- **The skill as an on-ramp.** NL-to-tool translation lowers the entry cost.

---

## Correctness findings (grounded in current `core.py`, not just the reports)

These are things to fix regardless of feature work; two correct an inaccuracy in the feedback.

| Finding | Status in code | Note |
|---|---|---|
| **Broadcast read flag is per-row, not per-recipient** | Bug | `messages.read` is one flag. First non-sender to `inbox(mark_read=True)` on a `to:"all"` row hides it from all other recipients. Broadcasts are racy; this is the keystone reason to move to per-recipient delivery. |
| `set_state` is last-write-wins | Confirmed | `ON CONFLICT(key) DO UPDATE` overwrites with no version. CO and FT both hit this. |
| `agents()` hides stale sessions | Confirmed | `WHERE last_seen >= cutoff` filters out anyone past the window — OB's "TrainTicket missing" symptom. |
| Self-echo on broadcast | Already handled | `inbox` filters `sender != name`. OB was unsure (their §10) — it is excluded today, just undocumented. |
| "`inbox` consumes one at a time" (OB §1) | Inaccurate | `inbox` already returns *all* unread rows in one call. The real gaps are no `pending_count`, no non-consuming `peek`, and `mark_read` destroying re-readability. |

---

## Consensus matrix

✓ = raised. **!** = the session flagged it as a top/high priority. Severity reflects blast radius (silent loss/integrity > friction).

| # | Improvement | FT | CO | OB | Severity | Tier |
|---|---|:--:|:--:|:--:|---|:--:|
| 1 | `set_state` CAS / versioning (`expected_version`) | **!** | **!** | ✓ | High — silent write loss | 0 |
| 2 | `set_state` append / merge (not just overwrite) | ✓ | ✓ | — | Med | 0 |
| 3 | `list_state()` + `get_state` returns `{value, by, updated_at}` | ✓ | — | ✓ | Med | 0 |
| 4 | Per-recipient delivery (fixes broadcast bug; backbone) | ✓ | ✓ | **!** | High — silent msg loss | 0 |
| 5 | Session-bound `sender` (kill spoofing) | — | — | **!** | High — integrity | 0 |
| 6 | `whoami` / implicit identity | ✓ | — | ✓ | Low | 0 |
| 7 | File soft-locks: `claim`/`release`/`list_claims` + TTL | **!** | **!** | (impl.) | High — real working-tree risk | 1 |
| 8 | `owns:[globs]` on register + overlap detection in `agents()` | **!** | ✓ | — | Med | 1 |
| 9 | ACK / read-receipts (surfaced on #4) | ✓ | ✓ | **!** | Med-High | 1 |
| 10 | Threading: `reply_to` + thread view in `inbox` | ✓ | ✓ | ✓ | Med | 1 |
| 11 | Presence: `online/idle/stale/gone` + readable `last_seen`; show stale | ✓ | ✓ | **!** | Med | 1 |
| 12 | `unregister` / leaving (no goodbye → ghost sessions) | ✓ | ✓ | ✓ | Low | 1 |
| 13 | Name-collision handling on `register` (reject or suffix) | ✓ | ✓ | — | Med | 2 |
| 14 | Message types (`announce/request/decision/ack`) | — | ✓ | ✓ | Low | 2 |
| 15 | Structured JSON payloads (messages + state values) | ✓ | — | ✓ | Med | 2 |
| 16 | Durable history / replay with per-agent cursor | ✓ | ✓ | ✓ | Med | 2 |
| 17 | bus↔repo bridge: anchor to commit SHA / git HEAD; derived state | ✓ | ✓ | — | Med-High (concept) | 2 |
| 18 | Channels / topics (`#manuscrito`, `#benchmarks`) | — | — | ✓ | Low (scale) | 3 |
| 19 | Push / `wait_for_message` (break 100% polling) | — | — | **!** | High value, feasibility-gated | 3 |
| 20 | Ergonomics: default name from cwd/branch, documented startup ritual, retention/TTL docs | ✓ | ✓ | ✓ | Low | 3 |

---

## Roadmap

### Tier 0 — Stop the data loss and the impersonation (do first)

**T0.1 — Per-recipient message delivery.** *(maps #4, #6, #9, #16; severity High; effort M; breaking)*
Replace the single `messages.read` flag with a per-agent cursor plus a `deliveries` table. Each agent stores `last_read_id`; `inbox` returns every message with `id > cursor` matching `recipient IN (name,'all')` and `sender != name`. "consume" advances the cursor; "peek" does not. This single change fixes the broadcast bug, gives `pending_count`, restores re-readable history/replay (read from id 0), preserves late-joiner delivery, and provides the hook for read-receipts (#9). The keystone item — most of Tier 1 rides on it.

**T0.2 — `set_state` CAS + append + discovery.** *(maps #1, #2, #3; severity High; effort M; additive + one breaking return-shape change)*
Add a `version` column and an optional `expected_version` to `set_state` (reject on mismatch → caller re-reads and retries). Add an `append` mode for accumulating lists (e.g. "fixes applied"). Add `list_state()` and make `get_state` return `{value, by, updated_at, version}` instead of a bare string. Closes the silent-overwrite hole both CO and FT hit.

**T0.3 — Session-bound identity + `whoami`.** *(maps #5, #6; severity High; effort M; breaking)*
Today `send(sender, …)` trusts a free-text sender — any session can post as another. Derive the identity from the session, not the argument. See open question below on *how* a stdio process learns its own name. Add `whoami()` so a session never has to remember its name to call `inbox`.

### Tier 1 — Close the real risk and make coordination trustworthy

**T1.1 — File soft-locks + ownership.** *(maps #7, #8; severity High; effort M; additive)*
The highest-leverage *new* capability. `claim(path, ttl)` / `release(path)` / `list_claims()` so a session can announce "I'm editing `Cap_4.tex`" and others see it before they touch git. Pair with `owns:[globs]` on `register` and have `agents()` flag overlapping ownership automatically — FT detected the figures↔Consistencia overlap only by reading prose roles. Soft (advisory) locks, not hard enforcement; the bus can't lock the filesystem, but an announced claim with TTL closes the conflict window that `grep` caught last time.

**T1.2 — Read-receipts / ACK.** *(maps #9; effort S on top of T0.1)*
Surface the `deliveries` data: `inbox` (or `agents()`) shows "read by […]", or a `message_status(id)`. Lets a sender know a broadcast landed.

**T1.3 — Threading.** *(maps #10; effort S on top of T0.1)*
`send(..., reply_to=id)` and group by thread in `inbox`. IDs already exist; just correlate them.

**T1.4 — Presence overhaul.** *(maps #11, #12; effort M; mostly additive)*
Status enum `online | idle | stale | gone` with human-readable `last_seen`; `agents()` lists *all* registered sessions and marks the stale ones rather than hiding them. Add `unregister()` so dead sessions don't linger as ghosts until the window expires.

### Tier 2 — Structure and observability

**T2.1 — Name-collision handling.** *(#13; S)* Reject a duplicate `register`, or return a suffixed name, or require namespacing by role/worktree.
**T2.2 — Message types + JSON payloads.** *(#14, #15; M)* Optional `kind` (`announce/request/decision/ack`) and structured values so veredicts/metrics are parseable instead of walls of prose.
**T2.3 — History / replay view.** *(#16; S-M on T0.1)* A `log(limit, since)` timeline of who said/wrote what — invaluable for reconstructing decisions after a context compaction.
**T2.4 — bus↔repo bridge.** *(#17; L, needs design)* The deepest idea in the feedback: the bus transmits *intentions*, not verified *artifacts*. CO's near-miss was a declared convention ("PBScaler vanilla") diverging from the file's reality ("PBScaler"). Let `send`/`set_state` carry an optional commit SHA / line range, and explore state *derived from the real file* rather than from what each agent claims.

### Tier 3 — Scale and ergonomics (optional / later)

**T3.1 — Channels / topics.** *(#18; M)* `#manuscrito` vs `#benchmarks` with per-channel subscription. Only pays off once traffic grows across multiple workstreams.
**T3.2 — Push / wake.** *(#19; L, feasibility-gated)* True push needs the harness to wake a session and is the hardest item. A self-contained `wait_for_message` (blocking long-poll) is the pragmatic first step and breaks the pure-polling model without harness support.
**T3.3 — Docs & ergonomics polish.** *(#20; S)* Default name derived from cwd/branch (removes the "what's your name?" friction in the no-name case); document the recommended startup ritual (`register → agents → get_state → inbox` before touching anything shared); document message retention/TTL and the already-implemented self-echo exclusion so the bus can be trusted as a log; reduce deferred-tool discovery friction for a plugin used at session start.

---

## Minimal high-impact set (if you ship only four)

Chosen as the intersection of the three sessions' own top lists:

1. **T0.1 Per-recipient delivery** — closes silent broadcast loss; foundation for ACK, replay, threading.
2. **T0.2 `set_state` CAS + append** — closes silent state loss (CO and FT top priority).
3. **T1.1 File soft-locks** — closes the actual working-tree conflict risk (FT and CO top priority).
4. **T0.3 Session-bound identity** — closes the integrity hole (OB top priority).

Together these resolve every "silent loss / integrity" item; the rest of the roadmap is trust-and-ergonomics layered on top.

---

## Proposed v0.2 schema sketch (direction, not prescription)

```sql
-- per-agent cursor + ownership + presence
agents(name PK, role, owns TEXT,            -- owns = JSON array of path globs
       last_seen REAL, status TEXT,         -- online|idle|stale|gone
       last_read_id INTEGER DEFAULT 0)      -- broadcast/replay cursor

-- threading + typing; note: no per-row read flag anymore
messages(id PK, ts, sender, recipient, content,
         kind TEXT DEFAULT 'msg',           -- announce|request|decision|ack
         reply_to INTEGER)

-- per-recipient read state -> fixes broadcast bug, gives ACK + receipts
deliveries(message_id, recipient, read INTEGER DEFAULT 0, read_ts REAL,
           PRIMARY KEY(message_id, recipient))

-- CAS-able blackboard
state(key PK, value, version INTEGER DEFAULT 1, updated_by, ts)

-- advisory file locks
claims(path PK, owner, ts, ttl)             -- expires at ts + ttl
```

---

## Open design questions to resolve before coding

1. **How does a stdio bus process learn its own identity?** Each session spawns its own server, but the agent name is a per-call argument today. Binding `sender` to the session (T0.3) means establishing per-process identity — e.g. a `BUS_AGENT` env var in `.mcp.json`, or a `register()` that stamps process-local state the server reads on every call. The env-var route is simplest; decide before T0.3.
2. **Broadcast delivery model.** Per-agent cursor (clean for late-joiners, matches the loved retroactive behavior) vs. fan-out snapshot of registered agents at send time. Recommendation: cursor for `to:"all"`, `deliveries` rows for directed messages and ACK.
3. **Retention / TTL.** Define message retention and claim TTL explicitly so the bus is trustworthy as a coordination log — all three asked for this implicitly.
4. **Push feasibility.** Confirm whether the harness can wake a session before committing to T3.2; otherwise ship `wait_for_message` only.
