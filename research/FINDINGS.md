# Fase 1: UI-kortlægning til mix-prep

Målt 2026-10-26 på Logic Pro 12.4 (en-US UI, macOS 15.6, én skærm 1920×1080) mod `~/dev/logic-test/MixPrepTest.logicx` (12 audiospor). Rå dumps ligger i `research/ax/`, og de små probe-programmer, som resultaterne kommer fra, ligger i `research/probes/`. Dumps er lavet med `tools/ax-dump`.

## Tværgående fund

| Fund | Konsekvens |
|---|---|
| **Undo-titlen er en tilbagelæsning af handlingstypen.** Første punkt i Mixerens lokale `Edit`-menu hedder efter den seneste handling: `Undo Change Track Color`, `Undo Create Track Stack`, `Undo Flatten Stack`. Hovedmenuens `Edit` viser `Can’t Undo`, indtil menuen faktisk er åbnet, fordi den kun opdateres ved åbning. | Den svage bekræftelse af, at *noget* af den forventede slags skete, kan bruges, hvor værdien ikke kan læses. Den er ikke nok til State A alene. |
| **AXPress lyver på brugerdefinerede views.** Farvefelterne advarer `AXPress`, og kaldet returnerer `kAXErrorSuccess`, men intet ændrer sig (ProjectData er byte-identisk efter gemning). | Settability og AXPress-svar må aldrig tælle som bevis. Dette bekræfter det, repoet allerede siger. |
| **CGEvent-klik virker kun på synlige elementer.** Når Mixeren er åben, er sporlisten kun 220 px høj, og rækker uden for (`AXPosition` y < 187 eller under Mixeren) rammer ruler eller Mixer. Klik via `post(tap: .cghidEventTap)` med Logic i front virker. `postToPid` virker ikke. | Al klik-baseret aktuering skal først tjekke, at målets frame ligger inden for den forælder-scrollarea, der kan ses, og ellers scrolle eller lukke Mixeren. Positioner hentes altid live fra AX, aldrig hardcodet. |
| **Valg af flere spor:** at sætte `AXSelectedChildren` på `Tracks header` har ingen effekt (læser kun ét tilbage). Shift- og ⌘-klik på navnefeltet virker, og hver rækkes `AXSelected` læser korrekt tilbage. Logic har desuden key commands `Extend Track Selection Up/Down`. | Gruppe- og stack-operationer kan vælge via ⌘-klik på AX-placerede navnefelter og verificere via `AXSelected` pr. række. |
| **Logic 12.4 er ikke valideret upstream** (doctor: "outside the latest validated version 12.3"). | Alle fund her gælder 12.4. |

## 1. Farve (`set_color`)

**Skrive:** `Track ▸ Assign Track Color…` (AX-menupunkt) åbner vinduet `Color` (AXDialog). Det har én `AXGroup` med 97 børn uden rolle, titel eller værdi (alle andre attributter giver `kAXErrorNoValue`, kun `AXPosition` læses). Børn 1-96 danner et gitter på 24 kolonner × 4 rækker. Barn 0 ligger for sig selv til venstre. Børnenes rækkefølge er rækkerne 2, 3, 4 og så 1 (1-24 = række 2, 25-48 = række 3, 49-72 = række 4, 73-96 = øverste række).
- `AXPress` på et felt: **ingen effekt** (se ovenfor).
- CGEvent-klik i feltets midte (position fra AX + ½ felt): **virker**. Undo-titlen bliver `Undo Change Track Color`, og ProjectData ændres.

**Læse tilbage:**
- AX: **ingen**. Ingen farveattribut nogen steder (bekræfter repoets #448). `AXSelectedChildren` på paletten er tom.
- ProjectData efter gemning: i sporets record ligger en byte 5 bytes før det længde-præfiksede navn (`… 80 <farve> 00 00 <len u16 LE> <navn>`). Målt: felt 5 → 29, felt 80 → 8. Det passer med `farve = 1 + række·24 + kolonne` (række 0 = øverst, kolonne 0-baseret). Det kræver, at testprojektet gemmes, og afhænger af et udokumenteret binært format.
- Undo-titlen: bekræfter, at en sporfarve ændredes, men ikke hvilken farve eller hvilket spor.

**Kalibrering (løst 2026-10-26):** Brugeren tog et skærmbillede af paletten ([palette/color-palette-12.4.png](palette/color-palette-12.4.png)). Midten af hvert felt er aflæst til sRGB i [palette/palette-12.4.json](palette/palette-12.4.json). Synlig række 1 er lysest og række 4 mørkest. Kolonnerne går rødt → orange → gult → grønt → cyan → blåt → lilla → magenta. Den gemte byte er målt ved klik og gemning, og en kontrol-markering bekræftede den visuelt:

| Synlig række | Gemt byte | AX-børn | AX-position |
|---|---|---|---|
| 1 | 72 + kolonne | 49–72 | **forkert**: rapporteres 80 pt for lavt. Rigtig y = række 2's y − 20 |
| 2 | kolonne (standard-audiospor = 16) | 73–96 | korrekt |
| 3 | 24 + kolonne | 1–24 | korrekt |
| 4 | 48 + kolonne | 25–48 | korrekt |

Barn 0 er "reset"-knappen (pil) og satte byten til 1 i målingen. Den bør ikke bruges. Klikposition beregnes fra gitteret af de tre korrekt placerede rækker (24 kolonner, 28 pt mellem kolonner, 20 pt mellem rækker), ikke fra række 1's AX-position.

**Mest robuste kanal:** AX-menupunkt for at åbne paletten → CGEvent-klik på AX-placeret felt → Undo-titel (svag) plus valgfri ProjectData-tilbagelæsning efter gemning (stærk). Uden ProjectData kan resultatet højst være `uncertain`.

## 2. Aux og subgrupper (`create_aux` / `create_summing_stack`)

**Summing stack** kan styres helt via AX:
1. Vælg medlemmer (⌘-klik på navnefelter, verificér `AXSelected`).
2. `Track ▸ Create Track Stack…` åbner et sheet med `AXRadioButton` "Folder stack" og "Summing stack" (begge med `AXPress`) og knapperne `Cancel` og `Create`.
3. Logic opretter et stack-hovedspor (`Sum 1`) med input `Bus N` og sætter medlemmernes output til `Bus N`.

Tilbagelæsning: sporrækkefølgen (`Track k “Sum 1”`), Mixer-strip `Sum 1` med input-slot `desc="Bus 1"` og medlemmernes output-slot `desc="Bus 1"`. Alt er læsbart via AX.

**Sideeffekt:** Valgte spor, der ikke ligger i forlængelse af hinanden, bliver samlet. Spor imellem flyttes ud efter stakken.

**Aux uden stack:**
- Mixerens lokale `Options`-menu (`AXMenuButton desc="Options"`) har `Create New Auxiliary Channel Strip`.
- Alternativt: vælg send eller output til en bus uden modtager. Så opretter Logic automatisk en aux med input = bussen. Repoet kender denne adfærd (`bus_has_no_receiver`).
- `Options ▸ Create Tracks for Selected Channel Strips` gør en aux til et Arrange-spor. Det er relevant, fordi `plugins.insert_verified` adresserer Arrange-spor.

**Mest robuste kanal:** AX-menupunkter og sheet-knapper. Kun valget af flere spor kræver CGEvent-klik (eller `Extend Track Selection`-key commands).

## 3. Output-routing (`set_output`)

Output-slottet er `AXButton` med `help` "Output slot…", og `desc` er den aktuelle destination (`Stereo Output`, `Bus 1`). Det giver tilbagelæsning direkte fra stripen. AXPress åbner en pop-up, selv om kaldet returnerer `-25204` (som repoet dokumenterer). Menuen har det aktuelle valg med `selected=1` øverst, `No Output`, `Output ▸ {Stereo Output, Output 3-4 … 13-14, Surround}` og `Bus ▸ {Bus 1…32, 33-64 ▸ …, … 225-256 ▸ …}`. Alt kan trykkes via AX.

Repoet har allerede `mixer.set_output_verified` med netop denne mekanik. Den mangler tilladelse til at route til en bus uden modtager (`bus_has_no_receiver`), hvor Logic opretter en aux.

**Mest robuste kanal:** AX (pop-up + menupunkt) og tilbagelæsning af slottets `desc`. Ingen klik.

## 4. Sends (`set_send`)

Send-slottet er `AXButton desc="send button"`. AXPress åbner pop-up'en (rc `-25204`, men menuen åbner). Menuen indeholder `Independent Pan`, `Post Pan`, `Post Fader`, `Pre Fader`, `No Send` og `Bus ▸ Bus 1…32, 33-64 ▸ …`. Alle punkter kan trykkes via AX.

Repoet har allerede `set_send_output_verified` (kun `stereo_output` ved oprettelse), `set_send_level_verified` (kun −95, −6 og −∞ dB) og `set_send_mode_verified`. Mix-prep kræver at **udvide** disse:
- oprettelse til `Bus N`
- vilkårlige dB-niveauer som −12 og −18

**Mest robuste kanal:** AX-pop-up og menupunkter. Niveau via det eksisterende send-knap-editor-flow (AX-værdi + Return), som repoet allerede verificerer.

## 5. Flytning af spor (`move_track`)

- AX: track-header-rækker (`AXLayoutItem`) har ingen settable position og ingen move-handlinger.
- Logic 12.4 har **ingen** "Move Track Up/Down"-key command (søgt i `Logic.framework`'s strengtabel).
- `Track ▸ Sort Tracks by ▸ Track Name` gjorde intet, heller ikke efter `Edit ▸ Select Tracks ▸ All`.
- **Virker: stack + flatten.** Vælg Y og X (Y over X), opret en folder stack og flad den ud (`Track ▸ Flatten Stack`). X ligger nu lige efter Y, og resten er uændret. Stakkens indre rækkefølge følger sporrækkefølgen, ikke klikrækkefølgen. Målt to gange: Vox Lead endte efter Snare, og Vox BV2 efter Kick. Tilbagelæsning sker via sporrækkefølgen i AX og Undo-titlen `Undo Flatten Stack`.
- **Begrænsning:** Et spor kan kun flyttes *op* til lige efter et spor over det, så intet kan placeres øverst. Til den position er der kun træk med musen (CGEvent-drag af header). Det er en koordinatbaseret fallback.
- Sideeffekt at undersøge i Fase 2: om flatten af en midlertidig folder stack efterlader spor (navne, routing og regioner så uændrede ud i testen).

**Mest robuste kanal:** stack + flatten via AX-menuer, med CGEvent-klik kun til ⌘-valg. Topposition kun via drag.

## Plugins på FX-returns

`ChromaVerb` og `Stereo Delay` findes i `StockPluginCatalog`, men `plugins.insert_verified` er kun allowlistet til Gain, Channel EQ, Compressor, Noise Gate og Sample Delay. Den adresserer desuden Arrange-spor, hvor en aux fra en send ikke er et spor. Planen er:
1. `Create Tracks for Selected Channel Strips` (eller at oprette return-auxen som spor fra starten).
2. Udvid allowlisten for **indsættelse** (ikke parametre) til de to plugins. Tilbagelæsningen er den samme inventory-læsning af insert-slottets plugin-navn.

## Rangordning pr. operation

| Operation | Skrivekanal | Tilbagelæsning | Skrøbelighed |
|---|---|---|---|
| Farve | AX-menu → **CGEvent-klik** på AX-placeret felt | Kun undo-titel (svag), ProjectData efter gemning (stærk) | Høj: ingen AX-værdi, uden navne, kræver synligt palettevindue |
| Summing stack | AX-menu + sheet. Valg via CGEvent ⌘-klik | AX: sporrækkefølge, input- og output-slot-`desc` | Middel: valg kræver synlige rækker |
| Aux | AX: Mixer `Options`-menu eller bus uden modtager | AX: ny strip og input-slot-`desc` | Lav |
| Output | AX-pop-up + menupunkt | AX: output-slot-`desc` | Lav (findes allerede) |
| Send | AX-pop-up + menupunkt, AX-knap-editor | AX: send-slot og knap-værdi | Lav til middel (findes delvist) |
| Flyt spor | AX-menuer (stack + flatten) + CGEvent ⌘-klik | AX: sporrækkefølge + undo-titel | Middel. Topposition kun via drag (høj) |
