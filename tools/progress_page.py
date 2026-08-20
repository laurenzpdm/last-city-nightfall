#!/usr/bin/env python3
"""Render progress/status.json + progress/events.jsonl into one self-contained page.

The published page has no network of its own, so every screenshot is downscaled and
inlined as a data URI. Re-run this after touching status.json and republish the
artifact at the same path to update it in place.

    python3 tools/progress_page.py <out.html>
"""
import base64
import html
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROGRESS = os.path.join(ROOT, "progress")

SHOT_WIDTH = 900
SHOT_QUALITY = 72


def load_status():
    with open(os.path.join(PROGRESS, "status.json")) as fh:
        return json.load(fh)


def load_events():
    """events.jsonl plus progress/parts/*.json.

    Parallel agents cannot all append to one file without fighting over it in git,
    so each writes its own progress/parts/<ID>.json instead. Both are read here.
    """
    out = []
    path = os.path.join(PROGRESS, "events.jsonl")
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except ValueError:
                continue

    parts_dir = os.path.join(PROGRESS, "parts")
    if os.path.isdir(parts_dir):
        for name in sorted(os.listdir(parts_dir)):
            if not name.endswith(".json"):
                continue
            try:
                out.append(json.load(open(os.path.join(parts_dir, name))))
            except ValueError:
                continue

    out.sort(key=lambda e: str(e.get("ts") or e.get("t") or ""))
    return out


def shot_data_uri(rel):
    """Downscale a screenshot to a JPEG data URI, or None if it cannot be read."""
    from PIL import Image

    path = os.path.join(PROGRESS, rel)
    if not os.path.exists(path):
        return None
    try:
        img = Image.open(path).convert("RGB")
    except Exception:
        return None
    if img.width > SHOT_WIDTH:
        h = round(img.height * SHOT_WIDTH / img.width)
        img = img.resize((SHOT_WIDTH, h), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=SHOT_QUALITY, optimize=True)
    return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()


def event_line(ev):
    """events.jsonl was written by many agents and never agreed on a schema."""
    ts = ev.get("ts") or ev.get("t") or ""
    ts = ts.replace("T", " ")[:16]
    part = ev.get("part") or ev.get("id") or ""
    text = (
        ev.get("title")
        or ev.get("headline")
        or ev.get("name")
        or ev.get("msg")
        or ev.get("summary")
        or ""
    )
    return ts, part, text


E = html.escape


def render(status, events, shots):
    parts = status.get("parts", [])
    done = sum(1 for p in parts if p.get("status") == "done")
    wip = sum(1 for p in parts if p.get("status") == "in_progress")
    scored = [p["score"] for p in parts if isinstance(p.get("score"), (int, float))]
    verdict = status.get("verdict", {}) or {}
    gate = status.get("gate", {}) or {}

    kpis = [
        ("Critic score", f'{status.get("critic_score", "—")}', "out of 10, judged on the running build"),
        ("Parts landed", f"{done}<span class='of'>/{len(parts)}</span>", f"{wip} in flight"),
        ("Round", str(status.get("round", "—")), E(str(status.get("phase", "")))),
        ("Blind rounds won", f'{status.get("blind_wins", 0)}<span class="of">/{status.get("blind_total", 0)}</span>', "side by side vs Factorio &amp; Frostpunk"),
    ]
    if gate:
        kpis.append((gate.get("label", "Gate"), E(str(gate.get("value", "—"))), E(str(gate.get("note", "")))))

    kpi_html = "\n".join(
        f'<div class="kpi"><small>{k}</small><b>{v}</b><em>{n}</em></div>'
        for k, v, n in kpis
    )

    rows = []
    for p in parts:
        st = p.get("status", "todo")
        cls = {"done": "ok", "in_progress": "wip", "failed": "bad"}.get(st, "todo")
        sc = p.get("score")
        score_html = (
            f'<span class="score s{int(sc)}">{sc}</span>' if isinstance(sc, (int, float)) else '<span class="score none">·</span>'
        )
        rows.append(
            f'<li class="{cls}"><span class="pid">{E(str(p.get("id","")))}</span>'
            f'<span class="pname">{E(str(p.get("name","")))}</span>{score_html}</li>'
        )
    parts_html = "\n".join(rows)

    log_html = []
    for ev in reversed(events[-40:]):
        ts, part, text = event_line(ev)
        if not text:
            continue
        log_html.append(
            f'<li><time>{E(ts)}</time><span class="lpart">{E(part)}</span>'
            f'<span class="ltext">{E(text)}</span></li>'
        )
    log_html = "\n".join(log_html) or '<li class="empty">No entries yet.</li>'

    shots_html = "\n".join(
        f'<figure><img src="{uri}" alt="{E(cap)}" loading="lazy"><figcaption>{E(cap)}</figcaption></figure>'
        for cap, uri in shots
    )
    shots_block = (
        f'<section class="panel wide"><h2>Frames from the running build</h2>'
        f'<div class="shots">{shots_html}</div></section>'
        if shots
        else ""
    )

    gap = verdict.get("biggest_gap", "")
    gap_block = (
        f'<p class="gap"><span class="gaplabel">Single biggest gap</span>{E(gap)}</p>' if gap else ""
    )

    blind = verdict.get("blind") or []
    blind_block = ""
    if blind:
        items = "\n".join(
            f'<li class="{"win" if b.get("winner")=="ours" else "lose"}">'
            f'<span class="dim">{E(str(b.get("dimension","")))}</span>'
            f'<span class="who">{E(str(b.get("winner","")))}</span></li>'
            for b in blind
        )
        blind_block = f'<ol class="blind">{items}</ol>'

    return f"""<title>Last City: Nightfall</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root {{
  --ground:#06090f; --panel:#0c111a; --panel2:#10161f; --rule:#1b2432;
  --ink:#e3e9f3; --dim:#77869d; --faint:#4a566b;
  --ember:#ff8a3d; --ember-hi:#ffc46b; --frost:#5fa8ff;
  --ok:#4bd48b; --warn:#ffc46b; --bad:#ff5f6d;
  --mono: ui-monospace,"SF Mono","JetBrains Mono","Roboto Mono",Menlo,Consolas,monospace;
  --sans: system-ui,-apple-system,"Segoe UI",Helvetica,Arial,sans-serif;
}}
* {{ box-sizing:border-box; }}
html {{ background:var(--ground); }}
body {{
  margin:0; background:var(--ground); color:var(--ink);
  font:13px/1.6 var(--mono);
  padding:38px 26px 90px;
  background-image:radial-gradient(900px 480px at 50% -180px, #17212f 0%, transparent 70%);
}}
.wrap {{ max-width:1180px; margin:0 auto; display:flex; flex-direction:column; gap:18px; }}

header {{ display:flex; flex-direction:column; gap:6px; }}
h1 {{
  font:700 clamp(28px,5vw,44px)/1.05 var(--sans);
  letter-spacing:-0.025em; margin:0; text-wrap:balance;
}}
h1 em {{ font-style:normal; color:var(--ember); }}
.tagline {{ color:var(--dim); font-size:12.5px; max-width:66ch; }}
.state {{
  color:var(--ember-hi); font-size:11px; letter-spacing:.14em; text-transform:uppercase;
  display:flex; align-items:center; gap:8px;
}}
.pulse {{ width:7px; height:7px; border-radius:50%; background:var(--ember); flex:none;
  box-shadow:0 0 0 0 rgba(255,138,61,.6); animation:p 2.4s ease-out infinite; }}
@keyframes p {{ to {{ box-shadow:0 0 0 11px rgba(255,138,61,0); }} }}
@media (prefers-reduced-motion:reduce) {{ .pulse {{ animation:none; }} }}

.rail {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(168px,1fr)); gap:10px; }}
.kpi {{ background:var(--panel); border:1px solid var(--rule); border-radius:9px; padding:12px 14px 13px;
  display:flex; flex-direction:column; gap:2px; }}
.kpi small {{ color:var(--dim); font-size:10px; letter-spacing:.13em; text-transform:uppercase; }}
.kpi b {{ font:600 27px/1.15 var(--sans); color:var(--ember-hi); font-variant-numeric:tabular-nums;
  letter-spacing:-.02em; }}
.kpi b .of {{ color:var(--faint); font-size:16px; }}
.kpi em {{ font-style:normal; color:var(--faint); font-size:10.5px; line-height:1.4; }}

.panel {{ background:var(--panel); border:1px solid var(--rule); border-radius:11px; padding:16px 18px; }}
h2 {{ font:600 10px/1 var(--mono); letter-spacing:.16em; text-transform:uppercase;
  color:var(--dim); margin:0 0 12px; }}
.cols {{ display:grid; grid-template-columns:minmax(0,1fr) minmax(0,1.25fr); gap:18px; align-items:start; }}
@media (max-width:820px) {{ .cols {{ grid-template-columns:1fr; }} }}

.verdict {{ border-left:2px solid var(--ember); }}
.verdict p {{ margin:0 0 12px; font-size:13px; line-height:1.72; max-width:78ch; color:#cfd8e6; }}
.gap {{ background:var(--panel2); border:1px solid var(--rule); border-radius:8px;
  padding:12px 14px; color:var(--ember-hi) !important; margin:0 !important; }}
.gaplabel {{ display:block; color:var(--dim); font-size:10px; letter-spacing:.14em;
  text-transform:uppercase; margin-bottom:5px; }}

ul.parts, ul.log, ol.blind {{ list-style:none; margin:0; padding:0; }}
ul.parts li {{ display:flex; align-items:center; gap:10px; padding:5px 0;
  border-bottom:1px solid #131a26; }}
ul.parts li:last-child {{ border-bottom:0; }}
ul.parts li::before {{ content:""; width:7px; height:7px; border-radius:50%; flex:none; background:currentColor; }}
ul.parts li.ok {{ color:var(--ok); }}
ul.parts li.wip {{ color:var(--warn); }}
ul.parts li.bad {{ color:var(--bad); }}
ul.parts li.todo {{ color:#2f3a4d; }}
.pid {{ color:var(--faint); font-size:11px; width:32px; flex:none; }}
.pname {{ flex:1; min-width:0; color:var(--ink); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }}
.score {{ font-variant-numeric:tabular-nums; font-size:11px; width:22px; text-align:right; flex:none; }}
.score.none {{ color:#2b3446; }}
.score.s0,.score.s1,.score.s2,.score.s3 {{ color:var(--bad); }}
.score.s4,.score.s5,.score.s6 {{ color:var(--warn); }}
.score.s7,.score.s8,.score.s9,.score.s10 {{ color:var(--ok); }}

ul.log {{ max-height:420px; overflow-y:auto; }}
ul.log li {{ display:flex; gap:10px; padding:6px 0; border-bottom:1px solid #131a26; align-items:baseline; }}
ul.log li:last-child {{ border-bottom:0; }}
ul.log time {{ color:var(--faint); font-size:10.5px; flex:none; }}
.lpart {{ color:var(--frost); font-size:10.5px; flex:none; width:34px; }}
.ltext {{ color:#bcc7d8; font-size:12px; min-width:0; }}
li.empty {{ color:var(--faint); }}

ol.blind {{ display:grid; gap:4px; margin-top:12px; }}
ol.blind li {{ display:flex; justify-content:space-between; gap:12px; padding:5px 9px;
  border:1px solid var(--rule); border-radius:6px; background:var(--panel2); font-size:11.5px; }}
ol.blind li.win .who {{ color:var(--ok); }}
ol.blind li.lose .who {{ color:var(--bad); }}
.dim {{ color:var(--dim); }}

.shots {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(260px,1fr)); gap:12px; }}
figure {{ margin:0; }}
figure img {{ width:100%; max-width:100%; display:block; border-radius:7px;
  border:1px solid var(--rule); background:#000; }}
figcaption {{ color:var(--dim); font-size:10.5px; margin-top:5px; letter-spacing:.06em;
  text-transform:uppercase; }}

footer {{ color:var(--faint); font-size:11px; border-top:1px solid var(--rule); padding-top:14px; }}
a {{ color:var(--frost); }}
a:focus-visible, [tabindex]:focus-visible {{ outline:2px solid var(--ember); outline-offset:2px; }}
</style>

<div class="wrap">
  <header>
    <div class="state"><span class="pulse"></span>{E(str(status.get("phase","")))}</div>
    <h1>Last City: <em>Nightfall</em></h1>
    <p class="tagline">A Tower Defense &times; City Builder &times; Automation game for Steam, in Godot 4.7.
      Built by agents in parallel, judged by fresh critics who run the build instead of reading the report.
      The bar is Factorio and Frostpunk.</p>
  </header>

  <div class="rail">{kpi_html}</div>

  <section class="panel verdict">
    <h2>Latest verdict &mdash; judged on the running build</h2>
    <p>{E(str(verdict.get("summary","")))}</p>
    {gap_block}
    {blind_block}
  </section>

  <div class="cols">
    <section class="panel">
      <h2>Parts &mdash; {done} of {len(parts)} landed</h2>
      <ul class="parts">{parts_html}</ul>
    </section>
    <section class="panel">
      <h2>Build log</h2>
      <ul class="log">{log_html}</ul>
    </section>
  </div>

  {shots_block}

  <footer>{E(str(status.get("state","")))}</footer>
</div>
"""


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(PROGRESS, "artifact.html")
    status = load_status()
    events = load_events()

    shots = []
    for rel in status.get("shots", []):
        if not rel.endswith(".png"):
            continue
        uri = shot_data_uri(rel)
        if uri:
            shots.append((os.path.splitext(os.path.basename(rel))[0].replace("_", " "), uri))

    with open(out, "w") as fh:
        fh.write(render(status, events, shots))
    print(f"{out} — {os.path.getsize(out)/1e6:.2f} MB, {len(shots)} shots, {len(events)} events")


if __name__ == "__main__":
    main()
