# Marketing

Propuneri de siglă și capturi pentru App Store. Nimic de aici nu intră în build.

## Siglă (`logo/`)

Patru concepte, fiecare în variantă luminoasă și întunecată, SVG + PNG 1024 × 1024:

- `spread`: agenda deschisă pe două pagini, cu un rând de cerneală gel.
- `gel`: un „a” scris dintr-o singură trăsătură de pix gel, pe hârtie cu puncte.
- `week`: banda de zile de sus, ziua de azi în albastru, scris de mână dedesubt.
- `ribbon`: hârtie galbenă, semn de carte albastru și o bifă desenată de mână.

`icon-concepts.html` le arată una lângă alta, pe ecran principal luminos și întunecat.
Nimic nu e pus în `Assets.xcassets` până nu alegi.

## Capturi App Store (`app-store/`)

- `ipad-13in/`: 9 capturi, 2064 × 2752 (iPad 13"): pagina, iPad + iPhone sincronizate prin iCloud, modul minimalist, mai multe pagini deodată, agenda pe două pagini (landscape), firul roșu al ședințelor (filtru pe eticheta „1:1”), poze printre notițe, bara de squeeze, hârtie întunecată.
- `iphone-6.9in/`: 10 capturi (maximul din App Store), 1320 × 2868 (iPhone 6.9"): pagina, iPad + iPhone sincronizate, notițe continuate în text pe iPhone, modul minimalist, firul roșu, etichete pe tipuri de ședințe, poze, liste, calendar, hârtie întunecată.
- `raw/`: capturile brute din simulatoare (iPad Pro 11" M5, iPhone 17 Pro). Câteva nu mai sunt folosite (calendar și etichete pe iPad, cronometru, prima privire generală pe iPhone).
- `overview-*.png`: toate capturile unui dispozitiv pe un singur rând, pentru o privire rapidă.

PNG fără canal alfa, cum le cere App Store Connect. Insigna de sincronizare e un nor generic desenat de noi, nu sigla iCloud.

## Cum se refac (`tools/`)

1. `ink/`: generează scrisul de mână al paginilor demo (text în Bradley Hand, subțiat la o linie de centru, trasat ca linii de pix) în `pages.json`.
   `swiftc -O Hand.swift main.swift -o gen && ./gen pages.json preview.png today`
2. `DemoSeed.swift.txt` + `demo-hooks.diff`: într-o **copie** a proiectului, nu în repo, se adaugă seed-ul (argumentul `-demoSeed` șterge datele și pune caietele demo) și argumentul `-demoSqueeze`, care deschide bara de squeeze. `pages.json` se copiază în `Documents/demo-pages.json` din containerul aplicației.
3. `frame/`: pune capturile brute în ramă, cu titlu și fundal. `swiftc -O main.swift -o frame && ./frame ../../app-store/raw <ieșire>`
4. `photo/`: cele două „poze” demo (lac în zori, cabană), pictate procedural, fără imagini de stoc. Se pot înlocui cu poze reale.
5. `logo/icons.js`: sursa celor patru sigle (`node` le scrie ca SVG, `svg2png.swift` le face PNG).

Înainte de seed: copiază containerul de date al aplicației din simulator, apoi pune-l la loc.
