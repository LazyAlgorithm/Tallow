# Tallow visual identity and website audit

Status: design specification on rename/tallow; main remains untouched.

## Brand
- Public names: Tallow Engine, Tallow Editor, Tallow Manager.
- Primary mark: bold amber T in a hexagon, dark charcoal background; maintain legibility at 16/24/32 px.
- Hero/splash: centered amber hexagon/T, TALLOW in near-white, ENGINE letterspaced amber, restrained diagonal amber highlights.
- Cow-themed variant is an optional novelty asset, **not** the default product brand.

## Proposed color tokens
- canvas: #12100E
- surface: #201A16
- elevated surface: #2B231C
- text: #F5F3EF
- secondary text: #B8ADA1
- amber primary: #FFB900
- amber hover: #FFD15A
- amber deep: #EF7900
- error: #F07167
- borders: #4A3828

Use amber for focus, active navigation, primary actions and charts' highlighted series, not every paragraph or background. Test contrast, focus visibility and color-blind-safe chart distinctions.

## Findings from source inspection
- Root icon.svg was a blue Tessera tile mark; replaced on this branch with a simplified amber Tallow SVG.
- Root icon.png remains to be regenerated from approved icon art.
- tools/web/shell/index.html is the exported **game runtime shell**, not necessarily the main public marketing website. It currently uses blue-charcoal background tokens (#0E1A24) with gold signal (#F2B33D). Do not blindly restyle game-export pages; distinguish runtime shell from website.
- Locate public website source and deployment settings before changing its theme. Avoid unverified claims about live-site appearance.

## Asset deliverables
- SVG master icon; PNG 16, 24, 32, 48, 64, 128, 256, 512, 1024; Windows ICO and Linux PNG where appropriate.
- 16:9 splash at 1920x1080 or higher with safe title margins; optional 1280x720 variant.
- Website favicon, social preview/OG image, editor and manager icons, installer/release imagery.
- Validate legibility at small sizes, light/dark browser chrome, and actual launch screens.

## Work order
1. Locate website source, existing CSS tokens and assets; audit navigation and benchmark charts.
2. Add icon exports and splash assets; update app resource references.
3. Restyle marketing website to match approved amber/charcoal identity.
4. Validate contrast, responsiveness, loading and link integrity.
5. Coordinate with engine/manager code rename and review before merge.
