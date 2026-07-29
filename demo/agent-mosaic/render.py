#!/usr/bin/env python3
"""Render Serverless Harness agent responses as a self-contained animated mosaic."""

from __future__ import annotations

import hashlib
import html
import json
import math
import sys
from pathlib import Path


def response_text(response: dict) -> str:
    verdict = response.get("verdict") or {}
    if response.get("status") == "done" and verdict.get("reason"):
        return str(verdict["reason"])
    return f"Agent did not complete: {response.get('reason', response.get('status', 'unknown'))}"


def tile(index: int, response: dict) -> dict:
    text = response_text(response)
    digest = hashlib.sha256(text.encode()).digest()
    hue = int.from_bytes(digest[:2], "big") % 360
    accent = (hue + 35 + digest[2] % 90) % 360
    symbols = ["✦", "◉", "⌁", "❋", "◇", "◎", "✺", "∞", "⬡", "∿"]
    motions = ["drift", "pulse", "breathe", "orbit"]
    return {
        "number": index + 1,
        "text": text,
        "safe": html.escape(text),
        "hue": hue,
        "accent": accent,
        "symbol": symbols[digest[3] % len(symbols)],
        "motion": motions[digest[4] % len(motions)],
        "delay": (index % 20) * 0.07,
    }


def render(source: Path, destination: Path) -> None:
    responses = json.loads(source.read_text())
    tiles = [tile(i, response) for i, response in enumerate(responses)]
    columns = math.ceil(math.sqrt(max(1, len(tiles))))
    cards = "\n".join(
        f'''<button class="tile {t["motion"]}" style="--h:{t["hue"]};--a:{t["accent"]};--d:{t["delay"]}s" data-text="{t["safe"]}">
          <span class="n">{t["number"]:02d}</span><span class="symbol">{t["symbol"]}</span>
        </button>'''
        for t in tiles
    )
    page = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Signal Garden — Agent Mosaic</title>
<style>
  :root {{ color-scheme: dark; font-family: Inter, ui-sans-serif, system-ui, sans-serif; background:#050714; color:#f5f7ff; }}
  * {{ box-sizing:border-box }} body {{ margin:0; min-height:100vh; overflow-x:hidden;
    background:radial-gradient(circle at 50% -10%,#232763 0,#0b1029 35%,#050714 70%); }}
  main {{ width:min(1120px,94vw); margin:auto; padding:38px 0 60px; }}
  header {{ display:flex; justify-content:space-between; gap:24px; align-items:end; margin-bottom:24px; }}
  h1 {{ margin:0; font-size:clamp(2rem,6vw,5rem); line-height:.88; letter-spacing:-.06em; }}
  header p {{ max-width:460px; color:#aeb8d8; line-height:1.5; margin:0; }}
  .count {{ color:#79f2c0 }}
  .grid {{ display:grid; grid-template-columns:repeat({columns},1fr); gap:8px; perspective:900px; }}
  .tile {{ aspect-ratio:1; border:1px solid hsla(var(--a),90%,75%,.25); border-radius:14px; cursor:pointer;
    color:white; position:relative; overflow:hidden; opacity:0; transform:translateY(28px) scale(.85);
    animation:arrive .65s cubic-bezier(.2,.8,.2,1) forwards; animation-delay:var(--d);
    background:radial-gradient(circle at 35% 28%,hsla(var(--a),90%,68%,.8),transparent 22%),
      linear-gradient(145deg,hsl(var(--h),60%,28%),hsl(var(--h),70%,10%)); }}
  .tile:hover {{ z-index:2; transform:scale(1.08) rotate(1deg); box-shadow:0 0 30px hsla(var(--a),90%,60%,.5); }}
  .symbol {{ font-size:clamp(1.2rem,3.2vw,3.5rem); text-shadow:0 0 18px currentColor; display:grid; place-items:center; height:100%; }}
  .n {{ position:absolute; top:7px; left:9px; font:10px ui-monospace,monospace; opacity:.6; }}
  .pulse .symbol {{ animation:pulse 2.3s ease-in-out infinite }} .drift .symbol {{ animation:drift 4s ease-in-out infinite }}
  .breathe .symbol {{ animation:breathe 3.5s ease-in-out infinite }} .orbit .symbol {{ animation:orbit 5s linear infinite }}
  dialog {{ max-width:620px; border:1px solid #4d5688; border-radius:18px; padding:0; color:#eef1ff;
    background:rgba(10,14,38,.96); box-shadow:0 30px 100px #000; }} dialog::backdrop {{ background:#02030bd9; backdrop-filter:blur(5px); }}
  dialog div {{ padding:28px; font-size:1.08rem; line-height:1.6 }} dialog button {{ float:right; border:0; background:#79f2c0; color:#06130e; padding:9px 14px; border-radius:9px; cursor:pointer; }}
  footer {{ margin-top:20px; color:#7681a8; font-size:.85rem; }}
  @keyframes arrive {{ to {{ opacity:1; transform:translateY(0) scale(1) }} }}
  @keyframes pulse {{ 50% {{ transform:scale(1.25); opacity:.75 }} }} @keyframes drift {{ 50% {{ transform:translate(7px,-8px) rotate(8deg) }} }}
  @keyframes breathe {{ 50% {{ filter:blur(1px); transform:scale(.82) }} }} @keyframes orbit {{ to {{ transform:rotate(360deg) }} }}
</style></head><body><main>
<header><h1>Signal<br>Garden</h1><p><span class="count">{len(tiles)} agents</span> read one immutable artifact and independently imagined a tile. Click any tile to reveal its interpretation.</p></header>
<section class="grid">{cards}</section><footer>Serverless Harness × Context Service × IBM Storage Scale</footer>
</main><dialog id="detail"><div><button onclick="detail.close()">close</button><p id="text"></p></div></dialog>
<script>const detail=document.querySelector('#detail'), text=document.querySelector('#text'); document.querySelectorAll('.tile').forEach(t=>t.onclick=()=>{{text.textContent=t.dataset.text;detail.showModal()}});</script>
</body></html>'''
    destination.write_text(page)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: render.py RESPONSES.json MOSAIC.html")
    render(Path(sys.argv[1]), Path(sys.argv[2]))

