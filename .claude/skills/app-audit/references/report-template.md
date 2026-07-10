# Report template

Produce the report in this exact shape. Group by **severity** first, then category within each severity. Every finding carries all nine fields — no omissions. If a field is genuinely N/A (e.g. no reproduction for an informational note), write "N/A" rather than dropping it.

## Finding format

```
### [SEVERITY] <short title>
- **Category:** Security | Race Condition | Reliability | Accessibility | Performance | Visual Consistency
- **Location:** file:line — function / component / flow (be exact)
- **Issue:** what is wrong (one or two sentences)
- **Impact:** what realistically happens in production
- **Evidence:** the code path / behavior / RULE violated (quote the line or cite CLAUDE.md)
- **Reproduction:** concrete steps to trigger, or "N/A"
- **Recommended fix:** specific, technically actionable remediation
- **Confidence:** Confirmed | High Confidence | Needs Verification
```

## Overall structure

```
# Cinemax audit — <date>

## Summary
- N findings: X Critical, Y High, Z Medium, ... 
- One-paragraph headline: the 2-3 things that actually matter.

## Critical
<findings>

## High
<findings>

## Medium
<findings>

## Low
<findings>

## Informational
<findings>

---

## Prioritised remediation plan
Ordered list, highest impact × exploitability first. Each item: finding ref + rough effort (S/M/L).

## Quick wins (low regression risk)
Findings safely fixable in isolation — missing accessibilityLabel, a swallowed error, a missing tag:, a disabled-state gap. Each with the one-line fix.

## Needs architectural change / deeper investigation
Findings that touch a boundary (the proxy, the session/auth flow, the download state machine, the menu-config cap) and can't be a spot fix. Say what needs designing.

## Release recommendation
**Safe to ship** | **Ship with known risks** | **Do not ship** — with a 2-3 sentence justification tied to the Critical/High findings. If "ship with known risks", enumerate the accepted risks.
```

## Rules for a credible report

- **Confirmed vs Needs Verification is not optional.** If you didn't read the code path and reason through it, it's Needs Verification. A report that marks speculation as Confirmed is worse than no report.
- **Cite the RULE.** When you clear a pattern that looks wrong but is intentional, say so ("looks like a 401 logout bug, but CLAUDE.md RULE — confirm-before-logout — is correctly implemented at AppNavigation.swift:NNN"). When you find a RULE *violation*, name the RULE.
- **No padding.** A tight report of 12 real findings beats 40 with 28 speculative ones. The user explicitly asked to avoid speculative issues without evidence.
- **Rank by real-world impact, not by how clever the finding is.** A missing `accessibilityLabel` on the play button outranks a theoretical race on a read-only path.
