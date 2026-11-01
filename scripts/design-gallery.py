#!/usr/bin/env python3
"""Build docs/design/variants/index.html: one self-contained gallery page.

Every screenshot is downscaled to a 600 px wide JPEG (quality 80, via `sips`)
and embedded as base64, so the page needs no other files, fonts or CDNs.
The page copy is Polish (it is read by the user); identifiers stay English.

Usage: python3 scripts/design-gallery.py [docs/design/variants]
"""

import base64
import html
import subprocess
import sys
import tempfile
from pathlib import Path

DIRECTORY = Path(sys.argv[1] if len(sys.argv) > 1 else "docs/design/variants")
JPEG_WIDTH = 600
JPEG_QUALITY = 80

# (file suffix, tab, state, appearance)
SHOTS = [
    ("now-wifi-light", "Now", "Wi‑Fi", "light"),
    ("nowscrolled-wifi-light", "Now (przewinięty)", "Wi‑Fi", "light"),
    ("now-wifi-dark", "Now", "Wi‑Fi", "dark"),
    ("now-cellular-dark", "Now", "5G + Tailscale relay", "dark"),
    ("now-idle-light", "Now", "brak połączonego Maca", "light"),
    ("sources-wifi-light", "Sources", "Wi‑Fi", "light"),
    ("details-wifi-light", "Details", "Wi‑Fi", "light"),
    ("details-cellular-dark", "Details", "5G + Tailscale relay", "dark"),
    ("settings-wifi-light", "Settings", "Wi‑Fi", "light"),
]

APPEARANCE_LABELS = {"light": "jasny", "dark": "ciemny"}

VARIANTS = [
    {
        "key": "A",
        "name": "Najpierw odtwarzacz",
        "tabs": "Now · Sources · Details · Settings",
        "rationale": (
            "Ekran Now wygląda jak Muzyka albo Spotify: duża karta odtwarzacza z okładką, "
            "tytułem, sterowaniem, głośnością i jakością, a pod nią jedna karta, która prostym "
            "zdaniem mówi, jak działa połączenie (ścieżka, opóźnienie, MB/h), i karta mikrofonu. "
            "Źródła nie są już arkuszem, tylko osobną kartą na dolnym pasku; pigułka „MacBook Pro ⌄” "
            "w tytule też do niej przenosi. Wybór opóźnienia (Low / Balanced / Safe) trafił do "
            "Settings, a Details to spokojna lista w stylu Ustawień iOS: werdykt, skąd bierze się "
            "opóźnienie, sieć, pakiety, dźwięk i dane."
        ),
        "pros": [
            "Najbardziej znajomy układ, spokojny; najpierw widać, co gra.",
            "Każda rzecz ma swoje miejsce na pasku: źródła, szczegóły, ustawienia.",
            "Details czyta się jak Ustawienia iOS.",
        ],
        "cons": [
            "Zmiana opóźnienia wymaga przejścia do Settings.",
            "Jakość łącza to zdanie, a nie wskaźnik do odczytania w sekundę.",
            "Mikrofon jest pod zgięciem ekranu – trzeba przewinąć.",
        ],
    },
    {
        "key": "B",
        "name": "Panel sterowania",
        "tabs": "Now · Sources · Details · Settings",
        "rationale": (
            "Gęsty pulpit dla kogoś, kto chce widzieć wszystko naraz. Now ma pasek „teraz gra”, "
            "pierścień z oceną łącza, cztery kafelki na żywo (opóźnienie i straty z wykresikami, "
            "jakość, dane w MB/h), trzy duże przyciski trybu opóźnienia, głośność i kafelek "
            "mikrofonu z plakietką LIVE. Dotychczasowe zakładki przeszły na natywny dolny pasek "
            "Liquid Glass i doszła czwarta, Settings – bez opóźnienia, bo ono zostaje na pulpicie. "
            "Details to panel przyrządów: wykres opóźnienia pakietów względem bufora, straty na "
            "sekundę, budżet opóźnienia i siatka wszystkich liczników."
        ),
        "pros": [
            "Wszystko widać od razu; tryb opóźnienia jest jednym dotknięciem na Now.",
            "Wykresy w Details najlepiej tłumaczą, dlaczego dźwięk trzeszczy.",
            "Settings jest krótkie, bo pulpit robi resztę.",
        ],
        "cons": [
            "Za dużo dla kogoś, kto chce tylko słuchać.",
            "Stan bez Maca to głównie puste kafelki.",
            "Wygląda bardziej jak narzędzie niż produkt.",
        ],
    },
    {
        "key": "C",
        "name": "Jedno spojrzenie",
        "tabs": "Now · Sources · Details · Settings",
        "rationale": (
            "Now to nadal jeden ekran bez przewijania: szklana kula z jedną liczbą (całkowite "
            "opóźnienie w ms) i jednym słowem (Excellent / Okay), utwór i sterowanie, trzystopniowy "
            "wybór opóźnienia z prostym zdaniem i szklany dok z głośnością, jakością i mikrofonem. "
            "Tło zmienia kolor razem z łączem: błękit, gdy jest dobrze, bursztyn, gdy gorzej, szarość "
            "bez Maca. Przycisk Details zniknął z doku, bo jest teraz kartą na dolnym pasku. "
            "Details to krótki raport, który odpowiada na trzy pytania: dokąd idą milisekundy, jak "
            "działa połączenie i ile to zużywa danych."
        ),
        "pros": [
            "Najbardziej charakterystyczny wygląd, najlepiej wykorzystuje Liquid Glass.",
            "Rozumiesz stan w sekundę; Now mieści się nad paskiem kart.",
            "Details tłumaczy wszystko ludzkim językiem.",
        ],
        "cons": [
            "Ukrywa najwięcej: ścieżka i straty są dopiero w Details.",
            "Duża kula zostawia mało miejsca na długie tytuły i duży Dynamic Type.",
            "Opóźnienie jest w dwóch miejscach (Now i Settings).",
        ],
    },
]


def jpeg_base64(png: Path, scratch: Path) -> str:
    """Downscale one PNG to a JPEG and return it base64-encoded."""
    target = scratch / (png.stem + ".jpg")
    subprocess.run(
        [
            "sips", "-s", "format", "jpeg", "-s", "formatOptions", str(JPEG_QUALITY),
            "--resampleWidth", str(JPEG_WIDTH), str(png), "--out", str(target),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    return base64.b64encode(target.read_bytes()).decode("ascii")


def figure(variant: str, shot: tuple, scratch: Path) -> str:
    suffix, tab, state, appearance = shot
    png = DIRECTORY / f"{variant}-{suffix}.png"
    if not png.exists():
        return ""
    caption = f"<b>{html.escape(tab)}</b> · {html.escape(state)} · {APPEARANCE_LABELS[appearance]}"
    alt = f"Wariant {variant}: {tab}, {state}, motyw {APPEARANCE_LABELS[appearance]}"
    return (
        f'<figure class="shot" data-appearance="{appearance}">'
        f'<div class="phone"><img loading="lazy" alt="{html.escape(alt)}" '
        f'src="data:image/jpeg;base64,{jpeg_base64(png, scratch)}"></div>'
        f"<figcaption>{caption}</figcaption></figure>"
    )


def section(variant: dict, scratch: Path) -> str:
    key = variant["key"]
    figures = "".join(figure(key, shot, scratch) for shot in SHOTS)
    pros = "".join(f"<li>{html.escape(item)}</li>" for item in variant["pros"])
    cons = "".join(f"<li>{html.escape(item)}</li>" for item in variant["cons"])
    return f"""
<section id="variant-{key}">
  <header class="variant-head">
    <span class="badge">{key}</span>
    <div>
      <h2>{html.escape(variant["name"])}</h2>
      <p class="tabs">Karty na dolnym pasku: <b>{html.escape(variant["tabs"])}</b></p>
    </div>
  </header>
  <p class="rationale">{html.escape(variant["rationale"])}</p>
  <div class="procon">
    <div><h3>Zalety</h3><ul class="pros">{pros}</ul></div>
    <div><h3>Wady</h3><ul class="cons">{cons}</ul></div>
  </div>
  <div class="row">{figures}</div>
</section>"""


STYLE = """
:root { color-scheme: light dark; --bg:#f4f5f8; --card:#fff; --text:#15171c; --muted:#5d6371;
  --line:#e2e4ea; --accent:#3b5bfd; --good:#1f9d55; --bad:#d64545; }
@media (prefers-color-scheme: dark) { :root { --bg:#0e1014; --card:#181b21; --text:#eceef3;
  --muted:#9aa1ae; --line:#2a2e37; --accent:#7d93ff; --good:#4cc38a; --bad:#ff7a7a; } }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--text);
  font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; }
nav { position:sticky; top:0; z-index:10; display:flex; align-items:center; gap:8px; flex-wrap:wrap;
  padding:10px 24px; background:color-mix(in srgb, var(--bg) 82%, transparent);
  backdrop-filter:saturate(1.6) blur(16px); -webkit-backdrop-filter:saturate(1.6) blur(16px);
  border-bottom:1px solid var(--line); }
nav .title { font-weight:700; margin-right:auto; }
nav a, nav button { font:inherit; font-size:14px; color:var(--text); text-decoration:none; cursor:pointer;
  padding:6px 14px; border-radius:999px; border:1px solid var(--line); background:var(--card); }
nav a:hover, nav button:hover { border-color:var(--accent); }
nav button[aria-pressed="true"] { background:var(--accent); border-color:var(--accent); color:#fff; }
nav .sep { width:1px; height:22px; background:var(--line); margin:0 4px; }
main { max-width:1500px; margin:0 auto; padding:24px; }
.intro { max-width:820px; color:var(--muted); }
.intro h1 { color:var(--text); font-size:30px; line-height:1.2; margin:8px 0 10px; }
section { background:var(--card); border:1px solid var(--line); border-radius:22px; padding:26px;
  margin:28px 0; scroll-margin-top:70px; }
.variant-head { display:flex; gap:16px; align-items:center; }
.badge { display:grid; place-items:center; width:52px; height:52px; border-radius:16px; font-size:26px;
  font-weight:800; color:#fff; background:linear-gradient(135deg,#4f46e5,#2563eb 55%,#06b6d4); flex:none; }
h2 { margin:0; font-size:24px; }
.tabs { margin:2px 0 0; color:var(--muted); font-size:14px; }
.rationale { max-width:900px; margin:18px 0; }
.procon { display:grid; grid-template-columns:repeat(auto-fit,minmax(280px,1fr)); gap:8px 32px; max-width:900px; }
h3 { margin:0 0 4px; font-size:15px; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); }
ul { margin:0; padding-left:0; list-style:none; }
li { padding-left:22px; position:relative; margin:4px 0; }
.pros li::before { content:"+"; color:var(--good); font-weight:800; position:absolute; left:4px; }
.cons li::before { content:"−"; color:var(--bad); font-weight:800; position:absolute; left:4px; }
.row { display:flex; gap:22px; overflow-x:auto; padding:22px 4px 10px; scroll-snap-type:x proximity; }
.shot { margin:0; flex:none; width:250px; scroll-snap-align:start; }
.shot.hidden { display:none; }
.phone { border-radius:38px; padding:7px; background:#1b1d22; box-shadow:0 10px 30px rgba(0,0,0,.18);
  border:1px solid #3a3d45; }
.phone img { display:block; width:100%; height:auto; border-radius:31px; }
figcaption { font-size:13px; color:var(--muted); margin-top:10px; text-align:center; }
figcaption b { color:var(--text); }
footer { color:var(--muted); font-size:13px; text-align:center; padding:10px 0 40px; }
"""

SCRIPT = """
const buttons = document.querySelectorAll('[data-filter]');
buttons.forEach(button => button.addEventListener('click', () => {
  const filter = button.dataset.filter;
  buttons.forEach(other => other.setAttribute('aria-pressed', String(other === button)));
  document.querySelectorAll('.shot').forEach(shot => {
    shot.classList.toggle('hidden', filter !== 'all' && shot.dataset.appearance !== filter);
  });
}));
"""


def main() -> None:
    with tempfile.TemporaryDirectory() as scratch_name:
        scratch = Path(scratch_name)
        sections = "".join(section(variant, scratch) for variant in VARIANTS)
    links = "".join(f'<a href="#variant-{v["key"]}">{v["key"]} · {html.escape(v["name"])}</a>' for v in VARIANTS)
    page = f"""<!DOCTYPE html>
<html lang="pl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mac Audio Bridge – trzy warianty aplikacji na iPhone'a</title>
<style>{STYLE}</style>
</head>
<body>
<nav aria-label="Warianty">
  <span class="title">Mac Audio Bridge · iPhone</span>
  {links}
  <span class="sep"></span>
  <button data-filter="all" aria-pressed="true">Wszystkie</button>
  <button data-filter="light" aria-pressed="false">Jasny</button>
  <button data-filter="dark" aria-pressed="false">Ciemny</button>
</nav>
<main>
  <div class="intro">
    <h1>Trzy kierunki, jeden dolny pasek kart</h1>
    <p>Każdy wariant ma teraz natywny dolny pasek kart z iOS 26 (Liquid Glass): <b>Now · Sources · Details · Settings</b>.
    Charakter wariantów się nie zmienił, zmieniła się tylko nawigacja. Lista źródeł jest taka sama we wszystkich trzech.
    To makiety na danych przykładowych, bez połączenia z silnikiem. Zrzuty pochodzą z symulatora iPhone 17 Pro.</p>
  </div>
  {sections}
</main>
<footer>Uruchomienie: <code>-DesignLab A|B|C -DesignState wifi|cellular|idle -DesignScreen home|sources|details|settings -DesignAppearance light|dark</code></footer>
<script>{SCRIPT}</script>
</body>
</html>
"""
    target = DIRECTORY / "index.html"
    target.write_text(page, encoding="utf-8")
    print(f"wrote {target} ({target.stat().st_size / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
