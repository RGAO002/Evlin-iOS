# Reflection Parent UI Reference Checklist

This directory is the manual visual baseline for the parent-side reflection UI. The frontend prototype is reference-only; implementation lives in the `Evlin iOS` target.

## Reference Source

- Primary visual reference: the parent profile reflection screenshot reviewed during the Reflection Parent UI planning pass.
- Source-of-truth plan: `Evlin iOS/docs/superpowers/plans/2026-05-13-reflection-parent-ui-plan.md`.
- Automated visual diff is intentionally out of scope for this prototype pass.

## Manual Comparison Checklist

- Home reflection child card shows `UNDER REFLECTION`, uses the warm cream surface, and does not show a countdown such as `15M`.
- Profile reflection header replaces the normal time/lock summary while preserving the rest of the profile content below it.
- `View reflection` opens the pending page when the reflection is assigned but not completed.
- Pending page clearly says the child has not completed the reflection yet and does not show fake `Step 1 of 3` progress.
- Completed artifact page shows the prompt, child written words, Evlin takeaway, reflection steps, and parent message area.
- Step detail pages show `Step N of 3` from the actual fixture steps and do not load real video/media/network content.
- Chat reflection review card keeps the parent note/message input and uses the reflection visual style.
- Home notification `Liam completed reflection` opens the completed artifact page directly.

## Deferred

- Dark Mode polish.
- Automated screenshot diffing.
- Backend-backed reflection state reconciliation.
