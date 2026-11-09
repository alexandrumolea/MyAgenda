# Cerneala gel: diagnostic extern și arhitectură sustenabilă

Evaluare făcută pe 7 noiembrie 2026 de un product owner și un arhitect „din afară”, fără
legătură cu deciziile de până acum. Cod analizat: `MyAgenda/Drawing/CustomInkView.swift`,
`CanvasProxy.swift`, `PenSettings.swift`, `InkWidthProbe.swift`,
`MyAgenda/Views/PageCanvasView.swift`, `NotebookPagesView.swift`, `MyAgenda/Models/JournalPage.swift`,
`MyAgenda/Store/TestInkCleanup.swift`, plus SDK-ul PencilKit din Xcode 27.1.

## 1. Problema, dinspre utilizator

Scrii un cuvânt cu „Gel”. Cât timp Pencil-ul e pe pagină, linia arată corect. În clipa în
care ridici, linia tocmai scrisă se schimbă puțin: marginile se îngroașă câteva cadre sau
lățimea și forma „se așază”. Se întâmplă la fiecare linie, așa că scrisul „respiră”.

Cauza nu e un bug, ci o decizie de design: aceeași linie e desenată de două rasterizatoare
diferite. Întâi previzualizarea aplicației (CoreGraphics), apoi PencilKit (Metal, pe dale,
asincron, la 20–75 ms după commit), iar aplicația ghicește momentul schimbului. Fiecare
reparație de până acum a fost un petic pe această decizie.

## 2. De ce predarea nu poate deveni invizibilă

- **Sincronizare.** `CanvasProxy.commit` înlocuiește `canvas.drawing`; PencilKit
  re-rasterizează dalele pe coada lui. Singurul semnal, `canvasViewDidFinishRendering`, vine
  cu 1–3 cadre întârziere. Orice alegere pe cadru înseamnă fie o clipire (linie lipsă), fie
  suprapunere: două copii cu margini antialiasate se compun la acoperire `a + a − a²`, deci
  marginile se închid la culoare. Asta e „îngroșarea” măsurată pe iPad.
- **Geometrie.** Previzualizarea desenează curbe pătratice prin mijloacele eșantioanelor;
  linia comisă e un B-spline cubic cu capetele triplate. Sunt curbe diferite, cu abateri de
  fracțiuni de punct la viraje strânse. Partea asta s-ar putea face exactă, dar nu ajută singură.
- **Lățime.** Legea „lățime randată = 2 × size − 4” e o potrivire empirică a unei funcții
  private PencilKit; rămâne un rest de ~0,3 pt.
- **Rasterizator.** Acoperirea, antialiasing-ul și pipeline-ul de culoare ale PencilKit (GPU)
  diferă de cele CoreGraphics. La linii de 2–4 px aproape toți pixelii sunt pixeli de margine,
  deci chiar și cu geometrie identică linia „se așază”. Partea asta nu poate fi făcută exactă.
- **SDK.** Xcode 27.1 (SDK iOS 27.1, ținta proiectului 26.5). PencilKit nu oferă nici în
  iOS 26, nici în 27 o cerneală personalizată, un tool live cu lățime per punct sau un semnal
  sincron de randare. Deci nu există o cale „prin API” pentru predare.

Concluzie: cu două rasterizatoare, artefactul e structural. Singura soluție curată e
**un singur rasterizator pentru o linie, de la prima atingere până la ștergere.**

## 3. Opțiuni analizate

| Opțiune | Ce înseamnă | Verdict |
|---|---|---|
| (a) PencilKit desenează tot | Pix/Uniform/Reed live, fără motor propriu | Zero artefacte, dar aspectul e al PencilKit; respins de Alex |
| (b) Proprietate împărțită | Motorul păstrează liniile gel pe stratul lui, PencilKit restul, unite doar la salvare | Guma PencilKit maschează o copie invizibilă, lasoul vede doar liniile PencilKit, ordinea pe Z e greșită, două stive de undo. Ajungi să scrii aproape tot (c) plus cod de coordonare |
| (c) Aplicația deține suprafața de cerneală | Un renderer propriu pentru linia vie și cele comise; PencilKit rămâne doar formatul documentului (`PKDrawing`) | Un rasterizator, o geometrie, `drawingData` neschimbat. Costă gumă și lasou proprii |
| (d) Predare „mai bine ascunsă” | Mască, acoperire, filtre de compunere | Fundătură dovedită |

**Recomandare: (c).** Este și arhitectura GoodNotes: motor propriu, format propriu de date.
La noi formatul rămâne PencilKit, ceea ce ne scutește de orice migrare.

## 4. Designul recomandat

CoreGraphics cu bitmap cache, nu Metal: pagina nu are zoom, bitmapul unei pagini la scara
ecranului e ~16 MB (3 pagini vii), desenarea incrementală la commit e sub o milisecundă, iar
CG e determinist: pixelii liniei vii și ai celei comise sunt identici prin construcție.
Aspectul final devine exact aspectul pe care îl vezi deja în timp ce scrii.

Fișiere noi în `MyAgenda/Drawing/`:

- **`InkDocument.swift`**: învelește `PKDrawing`. Clasifică liniile: `.monoline` și `.marker`
  sunt *randate de noi*; `.pen/.pencil/.crayon/.fountainPen/.watercolor/.reed` sunt *moștenire*.
  Undo/redo = instantanee `[PKDrawing]` (max 50). `CanvasProxy.undo/redo/commit/clear` se
  redirecționează aici; toolbar-ul nu se schimbă.
- **`InkGeometry.swift`**: `PKStroke → [(punct, lățime)]` prin `path.interpolatedPoints`
  (evaluarea B-spline a PencilKit însuși, deci liniile vechi păstrează forma), lățime
  `max(2 × size − 4, 0.6)` pentru monoline, cu `transform` și `mask` aplicate. Linia vie
  construiește același `PKStrokePath` din eșantioane; un punct nou schimbă doar ultimele
  trei segmente, deci dreptunghiurile murdare rămân locale, ca azi.
- **`InkRenderer.swift`**: segmente cu capete rotunde pentru cerneala opacă; highlighter =
  uniunea segmentelor (`CGPath.union`), umplută la alfa ~0,35, blend `.multiply`; `mask`
  ca decupaj. Culorile trec prin `paper.shown` (hârtie întunecată); hârtia galbenă nu cere nimic.
- **`InkSurfaceView.swift`** (înlocuiește `PageCanvasView`): trei straturi.
  *Substrat*: `PKDrawing.image` doar cu liniile moștenire, randat în afara firului principal
  exact ca în `DrawingThumbnailRenderer`. *Comis*: un `CGContext` bitmap persistent; la commit
  linia se desenează în el și `layer.contents` se actualizează. *Viu*: desenarea cu
  dreptunghiuri murdare de azi. Commit = o singură `CATransaction` cu acțiuni dezactivate:
  desenează în „comis”, golește „viu”. Același renderer, aceeași geometrie: zero schimbare vizuală.
  Liniile moștenire stau sub toată cerneala nouă (doar paginile vechi pierd ordinea de
  suprapunere acolo unde cerneală nouă trece peste cerneală veche; acceptabil).
- **Gesturi**: `PencilInkGestureRecognizer` rămâne pe scroll view-ul paginii, extins cu moduri
  de gumă și lasou; `UIPencilInteraction` (squeeze, dublu-tap) se mută pe suprafața nouă.
  Doar Pencil, doar iPad: iPhone-ul rămâne view-only, degetul derulează ca acum.
- **Gumă (pixel, lățime fixă)**: pentru liniile intersectate de discul gumei,
  `mask = (mask ?? bounds).subtracting(disc)` în spațiul local al liniei, stocată prin
  `PKStroke(ink:path:transform:mask:)`. E aceeași reprezentare pe care o scrie guma bitmap a
  PencilKit, deci miniaturile și alte aplicații rămân corecte. Pe iOS 27 se poate folosi
  `PKDrawing.erasePath` (ștergerea PencilKit fără canvas), sub `#available`.
- **Lasou**: poligon + `CGPath.contains` pe punctele interpolate; mutare prin compunerea
  `stroke.transform`; `UIEditMenuInteraction` pentru Taie/Copiază; clipboard =
  `PKDrawing(strokes:).dataRepresentation()` sub `PKAppleDrawingTypeIdentifier`; lipirea
  existentă din `NotebookPagesView` merge neschimbată.
- **Persistență**: salvarea cu debounce și gardurile `lastAppliedDrawingData` /
  `isApplyingRemoteDrawing` se mută ca atare în coordinatorul suprafeței. Devine mai simplu:
  nu mai există ecoul asincron „did change” al PencilKit.
- **Miniaturi**: renderer-ul propriu pentru liniile noastre + `PKDrawing.image` pentru
  subsetul moștenire; se incrementează `renderVersion`.

## 5. Siguranța datelor

Fără migrare: `JournalPage.drawingData` rămâne un `PKDrawing` simplu, cu aceleași tipuri de
cerneală, aceeași lege de lățime, forță 1 și capete triplate. Un dispozitiv pe build-ul vechi
randează aceeași pagină în marja de 0,3 pt. Sincronizarea CloudKit nu se atinge. Modelul
SwiftData nu se atinge.

De urmărit înainte de livrare:

1. Măștile scrise de guma PencilKit: de verificat spațiul lor (local vs. transformat) pe o
   pagină ștearsă azi.
2. Liniile mutate cu lasoul poartă `transform`: se aplică la randare și la hit-test.
3. Liniile `.pen` dependente de forță nu se randează niciodată de noi (substrat PencilKit).
4. `TestInkCleanup` cere `force < 0.999` ca să recunoască liniile de test: liniile noi
   păstrează forța 1, deci rămân neatinse.
5. Liniile gel vechi arată la fel pentru că renderer-ul respectă legea `2 × size − 4`.

## 6. Ce se păstrează, ce se simplifică

Se păstrează: aspectul gel (lățime constantă, margini curate, capete rotunde), highlighter,
gumă pixel, lasou (mutare, taie, copiază, lipește), undo/redo, squeeze și dublu-tap Pencil Pro,
hârtie albă/galbenă/întunecată, iPhone view-only, miniaturi, lipire în alte aplicații, toate
paginile existente.

Decizii de product owner (minimalism): „Gel 2” dispare (era un slot de experiment). Nicio
setare vizibilă „motor pornit/oprit”. „Uniform” rămâne gratuit (același renderer, lățime
constantă).

Întrebări pentru Alex:

1. **Creion și Cretă.** Sub un singur renderer, texturile PencilKit nu pot fi previzualizate
   live fără a reintroduce o predare. Recomandare: se scot din selector; liniile vechi cu ele
   rămân vizibile prin substrat. Alternativa: le păstrăm cu un aspect propriu, simplificat.
2. **Pix** (`.pen`, cu forță): aceeași situație. Recomandare: se scoate; liniile vechi rămân.
3. **Previzualizarea la hover** (cerculețul PencilKit înainte de atingere) se pierde.
   Rezolvat 8 nov 2026 pentru gumă: un inel `CAShapeLayer` de 1 pt pe suprafață, exact
   discul șters, arătat la hover (`UIHoverGestureRecognizer`, doar Pencil) și în timpul
   ștergerii; pentru pen nu se arată nimic.
4. Pe iPhone și în miniaturi, o linie gel va fi randarea noastră a acelorași puncte. OK?

## 7. Criterii de acceptare

Pe iPad, cu Gel, pe fiecare hârtie: scrie „minimum” repede; la ridicare nu se vede nicio
îngroșare, deplasare, subțiere, clipire sau cadru fără linie, în următoarele 500 ms. Zece
puncte pe „i”: fiecare e un punct rotund, neschimbat la ridicare. Undo, redo: cerneala revine
identic. Mută un cuvânt cu lasoul: se mută dintr-o bucată, același aspect după. Șterge prin
mijlocul unei linii gel: apare golul, restul neschimbat. Schimbă pagina și revino: cerneală
identică. Miniatura arată aceleași linii. iPhone: aceeași cerneală, view-only. Lipește o copie
lasou în Notes: apare. Paginile de dinainte: se deschid și arată ca înainte.

Checklist de 5 minute pe iPad: un rând în Gel pe alb, galben, întunecat; puncte; undo/redo;
mutare cu lasoul; ștergere; o pagină veche; o privire la miniatură; pagina pe iPhone.

## 8. Faze de livrare

| Faza | Conținut | Stare |
|---|---|---|
| 1. Scrisul | Geometrie, renderer, suprafață, substrat, highlighter, undo, persistență. Guma șterge linia întreagă, lasoul dezactivat. | **Livrată, validată de Alex pe iPad (8 nov 2026).** |
| 2. Gumă pixel | Guma cu lățime fixă, ca înainte: linia se împarte în bucăți cu măști poligonale, exact formatul gumei PencilKit, randate de renderer-ul propriu (masca = decupaj). Fără operații booleene, un singur cod pe iOS 26 și 27. | **Livrată 8 nov 2026; Alex: „merge foarte bine”. Inelul gumei acceptat („foarte bine”), punctat și mai discret la cererea lui.** |
| 2b. Performanță pe pagini pline | Dale de 256 pt pentru stratul fix, polilinii ținute minte, strat viu cât linia, pen stocat ca `.pen` și recunoscut după semnătură, gumă pe linii vechi prin petice compuse, salvare serializată în fundal. | **🚩 DE VERIFICAT pe iPad (9 nov 2026).** Implementată, revizuită, testată pe simulatoare; Alex a amânat testul pe dispozitiv. Vezi „De verificat” mai jos. |
| 3. Lasou | Buclă punctată în culoarea caietului; se selectează liniile cu cel puțin jumătate din partea vizibilă în buclă (punctele după centru), pe toată cerneala, fără casete. Mutare cu Pencil-ul sau degetul, offset pe pixeli întregi, doar `transform`. Meniu „Taie”, „Copiază”, „Duplică”, „Șterge”; clipboard PKDrawing + PNG; lipirea rămâne apăsarea lungă. Un pas de undo pe acțiune. | **Implementată 9 nov 2026, revizuită, testată pe simulatoare (randarea liniilor mutate, regresii). Bucla cere Pencil: în testul lui Alex.** |
| 4. Bara de instrumente mutabilă | Ții degetul ~0,4 s pe bară (și pe un buton), o tragi, la eliberare se lipește de cea mai apropiată margine: stânga, dreapta sau jos, niciodată sus. Verticală pe laturi, centrată sub rândul de sus; popover-ele de pe laturi prezentate de UIKit spre pagină; glisarea scurtă spre margine o ascunde în mâner. Ținută minte pe dispozitiv (`penToolbarEdge`). Doar iPad; pe ferestre înguste revine jos. | **Implementată 9 nov 2026, revizuită de trei ori, testată pe simulator (12 scenarii). În testul lui Alex.** |
| 5. Miniaturi și curățenie | Miniaturi prin renderer-ul propriu (azi highlighter-ul apare galben opac în miniatură, pe pagină e translucid), dispar `PageCanvasView`, `CustomInkView`, `InkWidthProbe`, membrii morți din `CanvasProxy`. | |

### 🚩 De verificat (deschis)

Lag-ul pe pagini pline (codiță la ridicare, scris pătrățos, gumă cu întârziere), raportat
de Alex pe 8 nov 2026. Cauzele găsite cu cronometrele pe iPad și reparate (vezi „Ce a
învățat faza 2”). Alex a ales pe 9 nov 2026 să meargă mai departe cu planul și să
verifice ulterior. Ce rămâne de confirmat pe iPad, cu un build Debug din Xcode și consola
deschisă:

1. Pe pagina cea mai plină, scrisul rămâne rotund și fără codiță după 10 minute de scris.
2. În consolă nu apar serii de `⏱ Blocaj` care cresc cu pagina; `tile.draw` sub 8 ms.
3. După repornire, la fel ca înainte de repornire (liniile gel rămân ale noastre).
4. Guma pe o pagină veche, scrisă cu PencilKit, golul apare sub vârf, nu la ridicare.
5. Paginile gel vechi arată la fel ca înainte (acum le desenează renderer-ul propriu).

Cronometrele (`HitchLog`, doar Debug) rămân până la confirmare; apoi se scot din cod.

### Highlighter-ul (9 nov 2026)

Alex: highlighter-ul acoperea scrisul, lăsa cercuri în timpul desenării și nu era destul
de gros. Reparat:
- **Sub tot scrisul**, în orice ordine ar fi scris: straturile au o ordine fixă prin
  `zPosition` (`InkSurfaceView.Depth`): dale de highlighter, highlighter ridicat de lasou,
  highlighter viu, substratul PencilKit, linii vechi ridicate, dale de scris, scris ridicat,
  pen viu, inel și contur. Două seturi de dale, create fiecare doar unde e cerneala de
  felul lui. Datele nu se schimbă: ordinea din `PKDrawing` rămâne cea scrisă.
- **Cercurile:** CoreGraphics desenează o linie lungă în loturi de ~128 de segmente și
  compune fiecare lot separat, deci îmbinarea dintre loturi primea culoarea de două ori.
  Acum conturul liniei se umple o singură dată (`replacePathWithStrokedPath` + `fillPath`),
  pe un punct din patru din polilinie (unul pe arc de B-spline), ca să rămână rapid.
- **Mai gros:** slider-ul merge până la 96, adică ~60 pt desenați; eticheta și
  previzualizarea arată lățimea desenată.
Testat pe simulatoare pixel cu pixel; acceptat de Alex pe iPad („E bine”, 9 nov 2026).

### Ce a învățat faza 1

- Pixul cu gel nu are codiță la ridicare și nici subțiere la final: orice pixel dincolo de
  ultima atingere reală e un defect. Rămân intrarea scurtă și respirația lățimii (~±30%).
- Fără atingeri prezise: ele remodelează vârful la fiecare cadru și fac scrisul mai puțin
  rotund. Latența sub un cadru e acceptată.
- Memoria e mărginită de paginile vizibile: `TabView`-ul paginat montează toate paginile, deci
  doar pagina selectată și vecinii ei țin bitmap-uri (`InkSurfaceView.isResident`), iar stratul
  viu există doar pe pagina activă de iPad. Fără asta, un caiet de 30 de pagini trecea de 1 GB.
- Highlighter-ul se desenează cu alfa simplă, fără `.multiply`: un blend mode ar reintroduce o
  schimbare la ridicare.
- Pentru lag se testează un build Release: schema rulează implicit Debug, fără optimizări.

Lansare: ramură separată (`gel-one-renderer`). Peticul necomis cu mască/acoperire de pe
`main` se pune deoparte (stash), nu se merge-uiește. Comparație pe iPad, același cuvânt pe
build-ul `main` și pe ramură, pe fiecare hârtie. `main` rămâne instalabil până validezi.
Nimic comis fără cuvântul tău.

### Ce a învățat faza 2 (8 nov 2026)

- `PKDrawing.strokes` e un getter care copiază toată lista la fiecare apel (0,1 ms la
  2000 de linii, 0,4 ms la 5000). Indexat într-o buclă devine pătratic: un singur
  eveniment al gumei costa 200 ms la 2000 de linii și 1,3 s la 5000. Regula: o copie
  locală, o singură scriere înapoi.
- `dataRepresentation()` costă 45–95 ms pe o pagină plină; rula pe firul principal la
  fiecare pauză de 1,5 s. Acum salvarea amânată serializează în fundal; flush-ul la
  părăsirea paginii rămâne sincron și rulează doar dacă e ceva de salvat.
- 50 de snapshot-uri de undo pe o pagină de 2000 de linii înseamnă ~33 MB; acceptabil,
  de urmărit dacă memoria devine iar o problemă.
- Guma pe linii vechi (PencilKit): fiecare tăietură re-randa toată pagina, cu serializarea
  desenului pe firul principal (42–127 ms). Acum: PKStroke e Sendable, deci desenul se
  construiește în fundal; în timpul gestului se randează doar dreptunghiul tăiat (3 ms) și
  se compune în bitmapul substratului (ștergere + desenare, în coordonate CG), iar la
  ridicare o singură randare completă. Prima trecere plătea `renderBounds` pe toate
  liniile vechi (35–114 ms); acum marginile sunt ținute minte în `InkDocument`.
- Excluse prin măsurare: costul la ridicare (3 ms la 3000 de linii, liniar), starea
  „replicilor" PencilKit (nu crește cu numărul de desene vii).
- Nemăsurabil pe simulatoare (fără iCloud): scrierea SQLite a blobului, re-randarea
  SwiftUI după salvare și exportul CloudKit în proces. `HitchLog` (doar Debug) scrie în
  consola Xcode fiecare blocaj al firului principal peste 30 ms, cu memoria, lângă pașii
  iCloud pe care SyncLog îi loghează deja.
- Sondele PencilKit pe simulator trebuie împachetate ca .app cu un bundle id: altfel
  managerul de replici se prăbușește la scrierea preferințelor.
- **Lag-ul scrisului, găsit cu cronometrele pe iPad (8 nov 2026):** stratul fix era un
  singur bitmap cât pagina (970×4000 pt, 62 MB la 2x) și CoreAnimation nu îi păstra
  magazia pentru redesenare parțială: `draw(_:)` primea tot dreptunghiul la fiecare
  ridicare, deci toate liniile proprii erau reevaluate prin PencilKit și desenate din nou
  (0,45 ms pe linie în Debug, 100 ms la 236 de linii, liniar cu pagina). După o pornire
  proaspătă mergea o vreme, apoi nu. Ipoteza „redesenăm doar unde cade linia" din faza 1
  nu ține pe dispozitiv. Reparare: (A) poliliniile liniilor proprii sunt ținute minte în
  `InkEntry.polyline` cât timp pagina e rezidentă (`InkDocument.keepsPolylines`, ~5–12 KB
  pe linie); (B) stratul fix e o grilă de dale de 512 pixeli (256 pt pe iPad), create leneș
  doar unde există cerneală, fiecare redesenată întreagă cu liniile ale căror margini o
  ating; originea dalei × scara e întreagă, deci aceeași grilă de pixeli și pe iPhone;
  (C) stratul viu are cadrul cât linia curentă (aliniat la 64 pt), nu cât pagina.
- **PencilKit nu păstrează `.monoline` în date** (testat pe iOS 26.5 și 27.0): desenul are
  versiunea 2 în memorie, dar `dataRepresentation()` scrie linia ca `.pen`, versiunea 1,
  și așa revine la citire; toate celelalte cerneluri supraviețuiesc. Deci toate liniile gel
  de până acum sunt stocate ca `.pen`, iar la fiecare repornire deveneau „vechi" (randate
  de PencilKit): de aceea lag-ul pornea de jos după repornire și creștea cu fiecare linie
  nouă. De la 8 nov 2026 pen-ul se stochează deliberat ca `.pen`, iar liniile noastre se
  recunosc după semnătură (`InkGeometry.ownership`): forță 1, altitudine π/2, azimut 0 pe
  trei puncte și punctul de start triplat; semnătura supraviețuiește salvării (azimutul
  cuantizat la −0,00005). Legea de lățime rămâne `2 × size − 4`; miniaturile și celălalt
  dispozitiv văd pen PencilKit, ca și până acum. De verificat pe iPad: paginile vechi gel
  se randează acum cu renderer-ul propriu, deci pot arăta ușor diferit față de PencilKit.


## 9. Riscuri

Pagină pe hârtie întunecată cu cerneală veche și nouă amestecate (două căi de culoare);
pagină ștearsă sau mutată cu lasoul pe build-ul vechi, deschisă pe cel nou; sincronizare în
buclă (scrie pe iPad, urmărește `SyncLog` pentru salvări repetate); creșterea paginii
(`contentHeight`) redimensionează bitmapul; schimbarea lățimii la rotire sau split view
(re-randare din document); memorie pe iPhone cu trei bitmapuri; highlighter-ul care se
intersectează pe sine și highlighter-ul vechi arată ușor diferit; undo peste gumă și lasou;
substratul sosește cu câteva ms după deschiderea paginii.

Nu se ating: `MyAgenda/Models/TimerActivityAttributes.swift`, `JournalPage.swift`. Înainte de
orice editare, `CustomInkView.swift` se copiază de rezervă. Semantica gardurilor de
sincronizare rămâne neschimbată.
