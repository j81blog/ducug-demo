# DuCUG · Dutch Citrix User Group

Website van de DuCUG (vervanging van ducug.nl): community-site én live dag-agenda tijdens de twee jaarlijkse evenementen.

- **Live:** https://ducug-demo.j81.nl/
- **Stack:** [Hugo](https://gohugo.io/) (extended) + [Blowfish](https://blowfish.page/) (Hugo module) + custom design-laag
- **Deploy:** GitHub Pages via [.github/workflows/deploy.yml](.github/workflows/deploy.yml) (push naar `main`)

## Lokaal draaien

```powershell
hugo server                      # dev-server op http://localhost:1313/
hugo server --disableFastRender  # full rebuild on every change (slower but safer)
hugo --gc                        # productie-build naar public/
```

Vereist: Hugo extended ≥ 0.147 en Go (voor de Blowfish-module).

## Structuur

| Pad | Wat |
|-----|-----|
| `content/evenementen/ducug-NN.md` | Eén bestand per editie (front matter + verslag) |
| `data/agenda/ducug-NN.json` | Dagprogramma per editie (JSON, met schema-validatie) |
| `assets/img/events/ducug-NN/` | Foto's per editie, verschijnen automatisch als galerij op de evenementpagina |
| `schemas/agenda.schema.json` | JSON Schema voor de agenda's (autocomplete + validatie in VS Code) |
| `data/sponsors.toml` | Sponsorwall (homepage, sponsorpagina) |
| `data/bestuur.toml` | Bestuursleden ("Over ons", foto's in `static/img/team/`) |
| `assets/css/custom.css` | Volledig design-systeem (alle `dg-*` classes) |
| `assets/css/schemes/ducug.css` | Kleurenschema (Blowfish `colorScheme = "ducug"`) |
| `layouts/partials/schedule.html` | Programma-timeline (via `event-sessions.html`) |
| `layouts/partials/extend-footer.html` | JS: countdown, scroll-reveal, live-agenda-logica |

## Evenement toevoegen

**1.** Nieuw bestand `content/evenementen/ducug-NN.md` (alleen metadata + intro):

```toml
+++
title          = "DuCUG #29"
eventNumber    = 29
date           = "2026-09-18"
location       = "De Oude Duikenburg, Voorstraat 30, Echteld"
eventbriteUrl  = ""        # CTA "Aanmelden" zodra ingevuld
archived       = false     # false = "volgend evenement" op homepage
+++

Korte intro-tekst voor op de evenementpagina.
```

**2.** Dagprogramma in `data/agenda/ducug-NN.json` (VS Code geeft autocomplete en validatie via het schema):

```json
{
  "$schema": "../../schemas/agenda.schema.json",
  "sessions": [
    { "start": "09:10", "end": "09:20", "title": "Opening", "speakers": "Niek Boevink", "type": "org" },
    { "start": "15:50", "end": "16:50", "title": "Keynote-sessie", "speakers": "Spreker", "type": "talk", "featured": true }
  ]
}
```

Meer is niet nodig: alleen het markdown-bestand (toekomstige `date`, `archived = false`) is genoeg om het evenement op de homepage te tonen als "Volgend evenement" mét countdown. De agenda-JSON kan later volgen; tot die tijd toont de eventpagina "De agenda is nog niet bekend."

- `type`: `talk` | `sponsor` (krijgt **Sponsor**-tag) | `break` | `org` | `social` (gedempt weergegeven). `featured: true` geeft de **Keynote**-badge.
- De JSON wint van eventuele `[[sessions]]` in de front matter; oude edities zonder JSON of `[[sessions]]` tonen gewoon hun markdown-programmatabel.
- Programma wijzigen = JSON aanpassen en pushen; de site rebuildt automatisch.
- Na afloop: `archived = true` zetten (of de workflow hieronder gebruiken). Het evenement verhuist dan naar het archief.
- Is de laatste editie geweest en is er nog geen nieuwe gepubliceerd, dan toont de homepage automatisch "Binnenkort een nieuw evenement" in plaats van de oude editie.
- Let op: `buildFuture = true` in `config/_default/hugo.toml` is vereist; zonder die optie bouwt Hugo pagina's met een toekomstige datum niet.
- Verslag na afloop: schrijf het onder `## Verslag` in het markdown-bestand. Foto's: zet ze in `assets/img/events/ducug-NN/` (max ±1600px breed), de galerij met lightbox verschijnt automatisch.

De workflow [archive-event.yml](.github/workflows/archive-event.yml) (handmatige trigger) haalt het definitieve programma op uit Sessionize en archiveert een editie automatisch: de sessies komen in `data/agenda/ducug-NN.json` (sessietype daarna handmatig verfijnen naar `sponsor`/`org`/`social`), het verslag-sjabloon en de sprekers in het markdown-bestand.

## Live agenda-takeover (event-dag)

Op de evenementdatum zelf verandert de site automatisch (client-side, geen rebuild nodig):

- Homepage en evenementpagina tonen een **"Live · vandaag"**-badge.
- De homepage toont het volledige dagprogramma ("Programma van vandaag").
- De **lopende sessie** wordt gemarkeerd met een groene **● NU**-pil; tussen sessies in wordt de eerstvolgende sessie gemarkeerd. Ververst elke minuut.

De logica staat in `extend-footer.html`: het programma (`schedule.html`) draagt `data-event-date`, elke rij `data-start`/`data-end`. Elementen met `data-live-only` worden op de dag zelf zichtbaar; `data-live-hide` verdwijnt.

### Testen / demo

Alle bijzondere statussen zijn op elke dag te simuleren met een query-parameter:

| URL | Effect |
|-----|--------|
| `/?demo=live` | Simuleert de event-dag met de échte kloktijd |
| `/?demo=11:30` | Simuleert de event-dag én pint de klok op 11:30 |
| `/evenementen/ducug-28/?demo=13:30` | Zelfde simulatie op de evenementpagina (13:30 = lunch → eerstvolgende sessie gemarkeerd) |
| `/?demo=binnenkort` | Toont de "Binnenkort een nieuw evenement"-kaart, alsof er geen volgend evenement gepubliceerd is |
| `/evenementen/ducug-NN/?demo=geen-agenda` | Toont "De agenda is nog niet bekend" in plaats van het programma |

`?demo=binnenkort` en `?demo=geen-agenda` wisselen alleen iets als de "echte" status anders is; staat de site al in die status, dan zie je geen verschil.

Checklist bij het testen:

1. `/?demo=live`: hero toont live-badge, dagprogramma verschijnt, countdown verdwijnt.
2. `/?demo=09:00`: vóór de eerste sessie: de openingssessie is gemarkeerd als eerstvolgende.
3. `/?demo=11:30`: sessie van 11:15–12:00 heeft de **NU**-pil.
4. `/?demo=20:00`: na afloop: geen sessie meer gemarkeerd.
5. Zonder parameter op een niet-event-dag: normale homepage met countdown ("dagen/weken") bij een toekomstige editie.
6. `/?demo=binnenkort`: next-event-kaart en hero-knop verdwijnen, de "Binnenkort"-kaart verschijnt (de live-badge blijft verborgen).
7. `/evenementen/ducug-28/?demo=geen-agenda`: het programma maakt plaats voor "De agenda is nog niet bekend."

## Design-systeem (kort)

Donkere "tech-conference"-stijl: ink-navy (#080e1a) podiumsecties, accent-gradient blauw → groen (#3565f2 → #2ee08c), fonts **Bricolage Grotesque** (display), **Instrument Sans** (body) en **Spline Sans Mono** (tijden/labels). Alle custom classes hebben het `dg-`-prefix; Blowfish wordt alleen via officiële extension points aangepast (custom scheme, `custom.css`, `extend-head`/`extend-footer`, header-layout `ducug`, overrides van `footer.html` en de evenement-layouts). Light + dark mode worden beide ondersteund (schakelaar in de header).
