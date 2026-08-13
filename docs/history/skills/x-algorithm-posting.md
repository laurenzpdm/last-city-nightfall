---
name: x-algorithm-posting
description: Write and optimise X (Twitter) posts and replies against the real open-sourced ranking weights from github.com/xai-org/x-algorithm. Use whenever drafting, rewriting or reviewing anything that will be posted to X, including threads, replies, quote posts and scheduled Postiz content. Triggers on "X post", "Tweet schreiben", "Twitter Post", "Reply schreiben", "auf X posten", "Thread", "X Reichweite", "warum floppt mein Post", "X Algorithmus".
---

# X posting, calibrated to the actual source code

Primary source: `github.com/xai-org/x-algorithm`, file `home-mixer/params/param.rs`, plus
`docs/BIDIRECTIONAL_BOOST_CHANGE.md`. Values read directly from the repo on 2026-08-13.
**Do not take ranking advice from blog posts about this repo.** Most of them are wrong; the
specific errors are listed at the bottom so they can be recognised and ignored.

Final score is a weighted sum of predicted action probabilities:
`score = Σ (weight_i × P(action_i))`, then adjusted by network and diversity multipliers.
So the job of a post is not "get engagement". It is to raise the probability of the few
actions that carry large weights.

## The weight table that decides everything

| Action | Weight | Versus a like |
|---|---|---|
| **Share via copy link** | **20.0** | **40x** |
| Bidirectional-follow reply boost | +15.0 | added on top of reply |
| Reply | 5.0 | 10x |
| Quote | 5.0 | 10x |
| Share via DM | 5.0 | 10x |
| Follow author | 4.0 | 8x |
| Share | 2.0 | 4x |
| Repost | 1.0 | 2x |
| Like | 0.5 | 1x |
| Click | 0.4 | |
| Open link | 0.2 | |
| Photo expand / video open / VQV | 0.05 | |
| Continuous dwell time | 0.004 | |
| **Dwell** | **0.0** | disabled |
| **Profile click** | **0.0** | disabled |

Negative: report **-234**, mute author **-58.8**, not interested **-43.2**, block **-31.2**.
And the punishment clause: if the viewer dwelled first and *then* gave negative feedback,
the penalties become report **-60000**, mute **-15000**, not interested **-10000**, block **-8000**.

Multipliers: out-of-network posts are scored at **0.75** (topic-based out-of-network at **0.5**).
Author diversity decays each additional post by the same author in one feed build: **0.5** decay,
floor **0.25**. Viewer cold start reserves slots 15-16 for authors under **1000 followers** with
posts under **24h** old.

## What this means for a post

**1. Write for the copy-link share, not the like.** One person pasting your post into a Slack,
a group chat or a doc is worth forty likes. Content gets copied when it is *useful away from X*:
a concrete number, a benchmark, a checklist, a before/after, a screenshot someone needs to show a
colleague, a resource they will want again. Ask before publishing: would anyone paste this
somewhere else? If no, the post is capped at the cheap signals.

**2. Every post must be a reason to follow (4.0).** That means a recognisable beat. A stream of
unrelated observations earns likes and no follows. Pick the two or three things you are the
account *for* and let the timeline be legible.

**3. Likes are nearly worthless.** Anything written to farm likes is optimising a 0.5 while
ignoring a 20.0. Delete "agree?" and "who else feels this" endings.

**4. Never bait.** The -60000 dwell-regret clause exists specifically to destroy content that
holds attention and then betrays it. Misleading hooks, fake cliffhangers, rage bait and
engagement-farm formats are not merely less effective, they are the single most punished pattern
in the system. The hook must be honest about what the post delivers.

**5. Post less, better.** Author diversity halves your second post and floors at a quarter, and
mute (-58.8) is the harshest of the ordinary negative signals. Mute is what people press for
"annoying, not offensive", which is exactly what high-frequency repetitive posting produces.
Space posts out rather than stacking them.

**6. Links do not tank reach.** Open link is **+0.2** and click **+0.4**, both positive. There is
no link penalty in the parameters. The honest framing is that a link click is worth one fiftieth
of a copy-link share, so a link neither hurts nor rescues a post. Put the substance in the post
and let the link serve the people who want more.

**7. Dwell optimisation is dead.** Dwell is weighted **0.0** and profile click **0.0**. Padding a
post to hold the eye buys 0.004 per unit of continuous dwell. Write short if short is right.

**8. If under 1000 followers, exploit cold start.** Slots 15-16 are reserved for small accounts
with posts under 24 hours old. Consistent daily posting while small is structurally rewarded in a
way it stops being later.

## What this means for replies

The July 2026 bidirectional follow boost is the most important structural change in the repo.
It raises the weight on the predicted probability that a viewer replies to an **original post**
from an author they **mutually follow**, from 5.0 to 5.0 + 15.0. A mutual's original post carries
roughly four times the reply weight of a stranger's.

So mutuals are now the highest-leverage asset on the platform, and replying is how mutuals are made.

- **Reply to become a mutual, not to be seen.** Target accounts in your actual niche whose follow
  you would genuinely want, and be useful to them repeatedly. Each conversion permanently raises
  the ceiling of everything you post afterwards.
- **A reply must add information.** "Great thread" earns nothing and risks the mute signal. Add a
  number, a counterexample, a constraint the original missed, or your own measured result.
- **Quote (5.0) beats repost (1.0) by 5x.** If a post is worth amplifying, say why it matters in
  your own words instead of resharing it silently.
- **Out-of-network is discounted to 0.75.** Reaching strangers is structurally harder than
  activating your own graph. Build the graph.

## Pre-publish checklist

1. Would somebody copy this and paste it somewhere else? (the 20.0)
2. Does it give a stranger a reason to follow? (the 4.0)
3. Is the hook honest about what follows? (avoiding the -60000)
4. Is there a real reason for a mutual to reply, not just like? (the +15.0)
5. Is this my second post in an hour? (the 0.5 decay)
6. Did I write it to be useful, or to be engaged with?

## Blog claims that are wrong, verified against the source

- "Reply from author weighted 75x" — false. Reply is 5.0, bidirectional boost 15.0.
- "Report weighted -369" — false. It is -234.0.
- "Dwell time is weighted more heavily than before" — false. Dwell is 0.0.
- "Posts with external links are penalised in reach" — unsupported. Both link weights are positive.
- "Premium accounts get a visibility multiplier that rises each quarter" — **unverified**. There is
  no premium, verified, blue or subscription term anywhere in `param.rs`. Treat as unproven.

## Maintenance

xAI committed to publishing updates roughly every four weeks with developer notes, so the weights
above have a shelf life. Before a major campaign, re-read `home-mixer/params/param.rs` and
`docs/` and update this file. Any value here is a point-in-time reading, not a permanent truth.
