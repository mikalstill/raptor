---
name: surface-triage
description: Systematically investigate a mapped attack surface with one validation subagent per candidate, adjudicate verdicts as a lean coordinator, and file only human-approved, evidence-verified bugs.
user-invocable: false
---

# [TRIAGE] Attack-Surface Triage

Turn a mapped attack surface into filed, verified bugs — without the coordinator
drowning in source. The main session stays a **coordinator**: it holds the plan and
the verdicts, fans out one read-only subagent per candidate to do the actual tracing,
and files only what a human approves after the evidence is re-checked.

This is the natural successor to `/understand --map`: map produces candidates, triage
proves or kills each one.

## When to use

- After `/understand --map` yields a `context-map.json` with `sink_details`,
  `entry_points`, and `unchecked_flows`.
- Any time you have a list of candidate findings (from a scan, a map, a CodeQL run,
  an operator's hunch) that need validation before they are worth filing.

## Core disciplines (why this flow works)

These are not optional — they are what separates this from name-level triage that
files false positives:

1. **The coordinator does not read the target source.** All source reading happens
   inside subagents. This is what keeps context lean enough to work through a dozen
   candidates in one session. If you catch yourself opening the target's `.rs`/`.c`
   files in the main session, stop and delegate.
2. **One candidate per subagent.** Isolation gives parallelism and prevents one
   finding's reasoning from contaminating another's. Launch them in a single message
   so they run concurrently.
3. **READ THE CALLEES — never infer from names.** The defending check is almost always
   one or two hops downstream of the "unsanitized" line the map flagged. A subagent
   that stops at the flagged line and reasons from the function name will produce a
   confident false positive. Every subagent prompt must demand it read the callees and
   callers to the point where the data is bounded, sanitized, or reaches a real sink.
4. **Severity is framed by trust boundary, not by code shape.** A crash inside a
   sandbox the attacker already controls is low; the same shape at a guest→host or
   network boundary is high. Tell each subagent the target's trust model so it rates
   impact correctly.
5. **The coordinator re-verifies before trusting a CONFIRMED verdict.** Subagents are
   fallible in both directions. Before filing, open the cited `file:line` claims and
   confirm they say what the verdict says.
6. **Nothing is published without an explicit human "yes"** (see [TRIAGE-3]).

## Workflow

### [TRIAGE-0] Bootstrap the surface

If a fresh `context-map.json` for the target already exists (from a prior
`/understand --map` in the active project or run dir), reuse it. Otherwise run the map
first:

```
/understand <target> --map
```

Then enumerate the candidate list from `context-map.json`:
- every `sink_details` entry,
- `entry_points` marked `attacker_controlled` (or that cross a trust boundary),
- every `unchecked_flows` entry.

Assign each a stable id (reuse `SINK-xxx` / `EP-xxx`). This list is the work queue.
`log()` the queue so the operator sees what will be investigated.

### [TRIAGE-1] Fan out one validation subagent per candidate

Launch read-only subagents **in parallel** (all in one message). Use
`general-purpose` agents — they can read deeply and reason multi-step; `Explore` only
locates code, it does not audit it.

Each subagent prompt MUST contain:
- **Threat model** — the target's trust boundaries and what "attacker-controlled"
  means here, plus the severity framing (sandbox-contained vs host vs boundary-crossing).
- **The one candidate** — its id, `file:line`, and the exact claim from the map.
- **The trace discipline** — read the callees and callers; do not infer from names;
  trace source→sink with branch coverage; find the bounding/sanitizing check or prove
  its absence.
- **A read-only guardrail** — do NOT modify code, do NOT run git, do NOT use `gh`, do
  NOT file anything. Investigation only.
- **A uniform return contract** — the verdict schema below, plus "write
  `flow-trace-<id>.json` into `<run-dir>`; return ONLY the compact report, no file dumps."

Subagent return contract:
```
VERDICT: CONFIRMED | DISPROVEN | INCONCLUSIVE  (+ one-line reason)
SEVERITY: memory-corruption | DoS | disclosure | none; and the trust-boundary context
          (guest-sandbox-contained / host-side / guest→host escape / etc.)
EVIDENCE: 3–6 bullets, each with file:line, tracing source→sink and the
          presence/absence of the defending check
ATTACKER CONTROL: full | partial | none — exactly what is controlled and its source
IF CONFIRMED: a draft issue body (Summary / Severity / Affected code with file:line /
              How it is reached / Suggested fix)
IF DISPROVEN: the specific guard/bound that defends it, with file:line
```

Scale to the surface: the harness caps concurrency automatically, so it is fine to
launch many; for very large queues, batch by priority (boundary-crossing candidates
first). If a candidate is genuinely too big for one subagent, have it return
INCONCLUSIVE with what it needs, then split it.

### [TRIAGE-2] Adjudicate (coordinator)

As each verdict returns, record it in a running tracker table (id / location /
component / status). For each:
- **CONFIRMED** → re-verify: open the cited `file:line` and confirm the evidence holds.
  A verdict that does not survive re-verification is downgraded, not filed.
- **DISPROVEN** → record the defending check in one line; keep the flow-trace artifact.
- **INCONCLUSIVE** → dig in from the coordinator only if cheap; otherwise spawn one
  focused follow-up subagent with a narrower question.

Distinguish two outcomes among survivors:
- **Exploitable bug** — attacker-controlled data reaches a dangerous operation with no
  adequate check. Files as a `bug`.
- **Hardening note** — a real missing check that is currently backstopped elsewhere
  (defense-in-depth, spec-deviation). Files as `enhancement` — clearly labelled
  "not currently exploitable" with the current backstop cited.

### [TRIAGE-3] File — ALWAYS STAGE FOR APPROVAL

**Default policy: nothing reaches `gh` without an explicit operator go-ahead.** This is
outward-facing disclosure; a false positive filed publicly is expensive to walk back.

For each finding worth filing:
1. Show the operator the drafted issue (title + body + proposed labels).
2. **Wait for explicit approval.** Do not batch-file on assumed consent; a background
   task-notification or your own earlier message is not approval.
3. On approval, file with `gh issue create` using labels that match the repo (check
   `gh label list` — e.g. `security-audit`, `bug` for exploitable, `enhancement` for
   hardening). Confirm the label exists before using it; fall back to the closest.
4. Report the issue URL and update the tracker.

If the operator has stated a different policy for this run (e.g. "auto-file confirmed"),
honour it — but absent that, stage everything.

### [TRIAGE-4] Artifacts

Each subagent leaves `flow-trace-<id>.json` in the run dir. After the batch:
```bash
libexec/raptor-render-diagrams "<run-dir>" --force
```
so the diagram set reflects every trace. Present a final consolidated table: what was
confirmed+filed, what was disproven and why, what hardening notes were raised.

## Output

- A `flow-trace-<id>.json` per candidate in the run dir.
- Filed issues (only after approval), with URLs.
- A consolidated verdict table in the session.

## Gates

GATES APPLY: the same U-gates as `/understand --trace` — U1 [READ-FIRST],
U2 [ATTACKER-LENS], U3 [FULL-FLOW], U5 [EVIDENCE-ONLY]. **Full flow means full flow:**
the subagent reads every callee on the path. The coordinator's job is to enforce that
discipline across all candidates and to gate publication behind a human.
