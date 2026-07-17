---
description: Investigate a mapped attack surface with parallel subagents and file only verified, approved bugs
dispatch: skill
---

# /triage - Attack-Surface Triage

Turn a mapped attack surface into filed, verified bugs. `/triage` bootstraps an
`/understand --map`, fans out **one read-only validation subagent per candidate sink /
entry point / unchecked flow**, adjudicates the returned verdicts as a lean coordinator,
and files only the findings a human approves after their evidence is re-checked.

This is the successor step to `/understand --map`: **map** enumerates the attack
surface, **triage** proves or kills each candidate and files the survivors.

## Execution Model

**You (Claude) are the coordinator, not the investigator.** The main session holds the
plan and the verdicts; it does **not** read the target's source. All source tracing
happens inside subagents, one per candidate, launched in parallel. This is what keeps
context lean enough to work through an entire surface in a single session.

Load and follow **`.claude/skills/surface-triage/SKILL.md`** — it carries the full
workflow, the subagent prompt requirements, the verdict schema, and the filing policy.

The flow in brief (see the skill for detail):

1. **[TRIAGE-0] Bootstrap** — reuse a fresh `context-map.json`, or run
   `/understand <target> --map` first. Build the candidate work queue from
   `sink_details`, attacker-controlled `entry_points`, and `unchecked_flows`.
2. **[TRIAGE-1] Fan out** — one `general-purpose` subagent per candidate, read-only,
   launched together. Each traces its candidate to source (**reads the callees — never
   infers from names**), writes `flow-trace-<id>.json`, and returns a compact
   CONFIRMED / DISPROVEN / INCONCLUSIVE verdict with `file:line` evidence.
3. **[TRIAGE-2] Adjudicate** — re-verify each CONFIRMED verdict against its cited
   `file:line` before trusting it; record defending checks for DISPROVEN; split or
   dig into INCONCLUSIVE.
4. **[TRIAGE-3] File — ALWAYS STAGE FOR APPROVAL** — show the operator each drafted
   issue and **wait for an explicit go-ahead**; nothing reaches `gh` without a human
   "yes". Exploitable → `bug`; real-but-backstopped → `enhancement`; both
   `security-audit`.
5. **[TRIAGE-4] Artifacts** — re-render diagrams, present a consolidated verdict table.

## Usage

```
/triage <target>            # bootstrap map (if needed), triage the whole surface
/triage                     # use the active project's target / most recent map
```

Operator arguments pass through verbatim. If a `context-map.json` already exists for the
target (from a prior `/understand --map`), `/triage` reuses it instead of re-mapping.

## Why this exists

Name-level triage files false positives: the defending check is usually one or two hops
downstream of the flagged line. Requiring each subagent to read the callees — and the
coordinator to re-verify before filing — is what turns a list of "unsanitized" leads
into a small set of real, evidence-backed bugs. Keeping the coordinator out of the
source is what makes it scale to a whole surface at once.

## Skill Files

Load before executing:
- `.claude/skills/surface-triage/SKILL.md` — workflow, subagent contract, filing policy
- `.claude/skills/code-understanding/trace.md` — the per-candidate trace discipline the
  subagents follow
