# Mixed Selection Metering Field Evidence - 2026-08-18

## Scope

This note records production evidence only. It does not prescribe a fix and does
not change metering behavior.

Family:

- New iPad device: `248e9159-0748-47a6-bce3-91b37fc0a47c`
- New iPhone device: `4cb5b69c-15d5-49fe-ace6-131e7cdfc378`
- Pool total: 180 minutes
- Usage date: 2026-08-18, `America/New_York`

## Active measurement shape

The iPhone's active persisted measurement selection decoded to:

- 40 application tokens
- 13 category tokens
- 7 web-domain tokens
- `includeEntireCategory = true`

The production event builder caps application tokens at 50, retains every
category and web-domain token, and requests `includesPastActivity = false`.

## iPhone: Chrome did not advance the route, Instagram did

The same active iPhone route, `DF29A2CA-4CBF-4848-A7A2-B11A120390BB`, remained
installed and activated throughout the observation. The backend accepted every
sample it received; there was no identity, activation, or route rejection.

Observed thresholds, local time:

- `t15`: 18:30
- no new threshold for approximately 102 minutes while Chrome was reported
  frontmost
- `t20`: 20:12
- `t25`: 20:17

The five-minute spacing after switching back to a known-counted app is evidence
that the route and delivery path remained functional. It does not yet establish
why Chrome was absent from the measured activity. Open hypotheses are:

1. Chrome was not represented by an effective application token in the installed
   event and the category token did not cover it at runtime.
2. Chrome browsing was attributed through web-domain activity not represented by
   the seven selected domain tokens.
3. One or more restored opaque tokens were stale or no longer represented the
   picker UI's apparent selection.

The picker showing Chrome under Utilities is selection UI evidence, not daemon
readback proving that the installed event credits Chrome.

## iPad: delayed, unordered callback burst advanced raw usage to 125

The iPad epoch started at 17:37:40 local route time and was activated at 17:40.
It progressed approximately one-for-one through `t45` by 18:23. It then produced
no accepted higher threshold for more than two hours.

At 20:33 the backend received this burst:

- 20:33:47 - `t80`, accepted
- 20:33:50 - `t125`, accepted
- then `t50`, `t110`, `t85`, `t120`, `t105`, `t65`, `t115`, `t100`, `t90`,
  `t75`, `t95`, `t60`, and `t70` in non-monotonic order

After `t125`, lower thresholds were correctly absorbed by the backend device-day
high-water rule. The resulting family total was:

- iPad device high water: 125
- iPhone device high water: 25
- family used: 150
- family remaining: 30

## Screen Time cross-check

The iPad system Screen Time page reported Evlin usage of exactly `2h 5m`, or 125
minutes, for the day. Its chart also showed Evlin usage before the new route's
17:37 start time.

This proves two separate facts:

1. The backend's 125-minute iPad high water corresponds exactly to Apple's daily
   Evlin usage total; the parent UI did not invent the number.
2. The 125-minute route result cannot all be post-arm Evlin usage because the
   system total includes visible pre-arm usage. In this field case, the installed
   mixed app/category/domain event did not provide the post-arm isolation the
   product expects from `includesPastActivity = false`.

Putting Evlin in the background does not normally accrue foreground Screen Time.
The evidence therefore does not mean that iOS counted a background app. It means
that a later callback burst exposed activity already present in Apple's daily
ledger, including activity from before this route was armed.

## Current conclusions

- Identity, activation, backend acceptance, and sample delivery were healthy for
  the iPhone route when Instagram advanced it.
- Chrome coverage under the mixed selection is not proven and failed in this
  observation.
- The iPad callback burst was real, delayed, and unordered.
- The iPad 125-minute value was sourced from Apple's Screen Time accounting, but
  included activity outside the intended post-arm window.
- A 50-application-token cap cannot by itself implement an all-device pool.
- Category-only metering is not safe to adopt until a fresh-route category test
  proves both Chrome coverage and post-arm isolation.
- The current mixed selection must not be described as a verified all-device,
  post-arm-only measurement primitive.

## Required controlled experiment

Use fresh physical activity identities and one variable per run:

1. explicit Chrome application token only;
2. Utilities category token only;
3. app + category + domain mixed selection;
4. all-activity event as documented by the SDK.

For every run, record one minute of usage before arming, arm with
`includesPastActivity = false`, then record known foreground usage after arming.
Compare DAM thresholds with the system Screen Time report. Do not reuse activity
or event names between runs.

## Clean-account Chrome follow-up

After deleting the account and completing a fresh enrollment, the replacement
iPhone route reproduced the same split: launching Chrome alone did not advance
the pool, while approximately one minute in Instagram produced `t1`.

The active generation's persisted measurement selection decoded to:

- 39 application tokens
- 11 category tokens
- 7 web-domain tokens
- `includeEntireCategory = true`

Therefore the 50-application-token cap was not reached in this reproduction and
cannot explain Chrome's absence. The installed event builder received all 39
application tokens plus all category and web-domain tokens.

A later observation further narrowed the behavior: Chrome began producing pool
progress only after a webpage was opened. The same behavior occurred while the
Evlin main app had been force-quit. This is consistent with the browser shell not
being covered by an effective Chrome application/category token while webpage
activity is credited through the web-domain leg. It also demonstrates that the
DAM callback and extension delivery path can advance the pool without the main
app running.

This observation does not yet prove whether every webpage is covered or only a
domain represented by one of the seven selected web-domain tokens. Record the
exact domains in the next controlled run.
