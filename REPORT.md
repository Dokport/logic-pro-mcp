# Mix-prep: statusrapport

_Sidst opdateret: 2026-10-26_

## Status

| Del | Status |
|---|---|
| Fase 1: kortlægning | Færdig. Se [research/FINDINGS.md](research/FINDINGS.md) |
| Farvekalibrering | Færdig: `research/palette/palette-12.4.json` |
| `tracks.set_color` | Implementeret og live-testet. Projektfil-tilbagelæsning gav State A på testprojektet |
| `tracks.set_region_color` | Implementeret og live-testet på brugerens session gennem LogicProMCPHost (State B med undo-vidne) |
| LogicProMCPHost (rettigheder kun til én proces) | Implementeret og bevist: claude har ingen Accessibility, og serveren gennem hosten har |
| `tracks.create_stack` (summing/folder + navn) | Implementeret. State A 3 gange i træk fra ren kopi (DRUMS) med debug-serveren. Bekræftelse gennem hosten mangler |
| `mixer.create_aux` | Implementeret. State A 3 gange i træk fra ren kopi med debug-serveren. Bekræftelse gennem hosten mangler |
| `set_output_verified` + `create_receiver` (output til ubrugt bus, Logic opretter aux) | Implementeret. State A 3 gange i træk fra ren kopi (debug-server). `set_output` forbliver "not exposed" efter upstreams beslutning (#291 R2) |
| `mixer.create_send` (send til bus, evt. med oprettet FX-aux) | Implementeret. State A 3 gange i træk fra ren kopi (debug-server) |
| `set_send_level_verified` med vilkårlige dB (−144…+6, komma eller punktum, 0,2 dB tolerance) | Udvidet. −12 og −18 dB gav State A 3 gange i træk. Kildesporet skal være valgt først |
| `tracks.strip_silence` (Remove Silence på et spors lydregions) | Implementeret. State A 3 gange i træk fra ren kopi på to spor (1 region → 16) |
| `mixer.create_track_for_strip` (aux bliver et spor) | Implementeret. State A 3 gange i træk fra ren kopi som del af FX-return-kæden |
| `insert_verified` udvidet til alle målte stock-effekter | 67 af 68 stock-effekter indsat og læst tilbage på 12.4 (`research/plugin-census-12.4.jsonl`); 34 forkortede slot-navne kortlagt. Slot N > 0 via Logics append-knap |
| `tracks.move_track` (stak + flatten) | Implementeret. State A 3 gange i træk fra ren kopi. Kun opad; øverste position kræver drag og er ikke lavet |
| `project.apply_mix_layout` (preflight → execute → status) | Implementeret. CLAUDE.md-specen (54 trin) kørt 3 gange i træk fra ren kopi, se Live-kørsler |
| "3 gange i træk fra ren kopi" | Ikke kørt endnu |

## Rettighedsmodel (ændret 2026-10-26 efter brugerens ønske)

Brugeren vil ikke give en bred Tilgængelighed-rettighed til Claude eller terminalen. Derfor:

- **LogicProMCPHost** (`Sources/LogicProMCPHost/main.swift`, `Scripts/install-host.sh`) er det eneste, der har Tilgængelighed og Automation.
  - Den startes som sin egen app, så macOS ser den som ansvarlig proces.
  - Den kører den medfølgende server for hver forbindelse på en privat Unix-socket.
- **Klienter** (Claude Code, `tools/mcp-call --socket`) taler gennem `tools/mcp-socket-relay`, som ikke har nogen rettigheder.
- **Lukkede huller:**
  - Ingen `--server`-option. Kun den bundtede server køres.
  - Hardened runtime: `DYLD_*` ignoreres.
  - Serveren får et fast, minimalt miljø.
  - Socket'en har mode 0600 og kontrollerer peer-uid.
- **Konsekvens for udviklingen:**
  - Agentens egne AX-værktøjer (`tools/ax-dump`, `research/probes/`) virker ikke længere. Al måling skal gå gennem serverens værktøjer.
  - Med ad-hoc-signatur kræver hver ny serverversion, at brugeren godkender igen (`tccutil reset Accessibility com.logicpro.mcp.host`, genstart hosten, slå til).
  - Et lokalt signeringscertifikat (`LOGIC_MCP_SIGN_IDENTITY`) fjerner gentagelsen. Prisen er, at koden så ikke længere godkendes pr. version.
- **Ikke gjort:**
  - Autostart ved login (LaunchAgent) blev afvist af sikkerhedsfilteret som persistens. Brugeren kan selv køre `Scripts/install-host.sh` uden flag.
  - Hosten er indtil videre startet med `open` (`--no-agent`).

> **HUSK:** Brugeren slår "claude" til under Tilgængelighed **kun mens der udvikles** (aftalt 2026-10-26), så agenten kan måle med `tools/ax-dump` i stedet for at gætte. Efter hver arbejdssession slås den fra igen. Det færdige produkt bruger kun LogicProMCPHost. Fjern LogicProMCPHost, hvis projektet stoppes.

## Miljø

| Punkt | Resultat |
|---|---|
| Logic Pro | 12.4, en-US UI (doctor: uden for upstreams validerede 12.3) |
| macOS | 15.6 |
| Swift | 6.2.3 via `swiftly` i `~/.swiftly` (Command Line Tools er halvt opdateret). Kør `. ~/.swiftly/env.sh` først |
| Testprojekt | `~/dev/logic-test/MixPrepTest.logicx` + `MixPrepTest_clean.logicx`; `tools/reset-test-project.sh` |

## Live-kørsler

**Testprojektet** (`set_color`, `readback: project_file`):

| Spor | Farve | Resultat |
|---|---|---|
| Kick | `red` | State A (73) |
| Snare | `dark blue` | State A (41) |
| Vox BV2 | række 4, kolonne 24 | State A (72) |
| Bass | `yellow`, uden tilbagelæsning | State B. Senere bekræftet 77 i ProjectData |
| HH | (ingen) | Urørt (16) |

**Brugerens ClaudeTestSession** (efter udtrykkelig anmodning, ikke gemt). Trommesporene blev bekræftet af brugeren:

| Spor | Farve | Spor | Regions |
|---|---|---|---|
| "70 BPM So Rey Wet" | green | `Change Track Color` | 97 regions, `Change Region Color` |
| 2 × "70 BPM So Rey Dry" | dark green | `Change Track Color` | 1 + 2 regions, `Change Region Color` |

De to Dry-spor har samme navn og blev derfor afvist af bindingen (`ambiguous_target_name`). De blev midlertidigt omdøbt til `·A` og `·B`, farvet og omdøbt tilbage. Alle fire omdøbninger gav State A.

## Hvilken kanal hver operation bruger

| Operation | Skrivning | Tilbagelæsning |
|---|---|---|
| `set_color` | AX-menupunkt + CGEvent-klik på et AX-afledt palettefelt | Undo-titel (B). ProjectData efter `project.save` (A) |
| `create_stack` | AX-valg af første medlem + CGEvent ⌘-klik på AX-placerede navnefelter (verificeret som præcist sæt), AX-menupunkt og sheet | AX: hele sporlisten i den målte form (A). Navn via verificeret rename |
| `create_aux` | AX: Mixerens Options-knap (2. af 3 over Mixeren) og menupunkt efter label | AX: komplet strip-census i All-visningen (A) |
| `set_region_color` | AX: Deselect All + `AXSelected` pr. region (verificeret som præcist sæt), View ▸ Colors + CGEvent-klik | Undo-titel (B), der skelner region og spor |
| `set_output_verified` + `create_receiver` | AX: output-pop-up og menupunkt `Bus n` (upstream) | AX: samme strips output-slot + strip-census (ny strip læser bussen) (A) |
| `create_send` | AX: øverste tomme send-slot, `Bus n` i Bus-undermenuen | AX: én send mere til Bus n + evt. ny modtager-strip (A) |
| `set_send_level_verified` | Logics numeriske editor (upstream), kildesporet valgt først | AX: knappens visning inden for 0,2 dB (A). Flere sends på én strip parres nu med knappen på samme række |
| `create_track_for_strip` | CGEvent-klik på AX-placeret navnefelt + Mixerens Options ▸ Create Tracks for Selected Channel Strips | AX: sporlisten får præcis ét nyt spor med stripens navn (A) |
| `insert_verified` (målte stock-effekter) | AX: slot-pop-up og AXPick på menublad (upstream); slot N > 0 via append-knappen | AX: inventory-diff; slot-navne via målt tabel. Ofte kun via uafhængig `get_inventory` (A) |
| `move_track` | Midlertidig folder-stak via `create_stack` + AX-menupunkt Track ▸ Flatten Stack | AX: hele sporlisten i præcis forventet rækkefølge (A) |
| `strip_silence` | AX-menu + dobbeltklik/Unicode-indtastning i dialogfelter | AX: antal lydregions = dialogens forhåndsvisning (A) |
| `apply_mix_layout` | Alle ovenstående i rækkefølge | Hvert trins egen tilbagelæsning; uafhængig Mixer-/inventory-læsning hvor trinnets egen misser; farver via én projektgemning (A for de oprindelige spor) |

## Skrøbeligt / kan gå i stykker ved Logic-opdateringer

- **Send-niveau:** Knappens rå `AXValue` kan ikke bruges, fordi skrivninger hopper mellem −95, −97 og −∞. Niveauet skrives i Logics numeriske editor, som upstream gør. Knappen er kvantiseret (−18 bliver −18,1), og visningen følger systemets talformat (dansk: komma). Upstreams editor-greb kræver, at kildesporet er valgt, ellers flytter Logic fokus mellem Mixer- og inspektor-strip, og operationen afviser (`stale_snapshot`) uden at skrive.
- **Strip silence:** Feltgruppernes segment-sliders kan ikke skrives pålideligt (ét trin flyttede −28 til −80). Felterne udfyldes derfor med dobbeltklik, Unicode-indtastning og Tab. Felterne bruger systemets decimaltegn, og på et dansk tastatur er US-minustasten "+". Testskabelonen `MixPrepTest_clean.logicx` har nu en genereret lydfil med anslag og stilhed (`~/dev/logic-test/media/hits-with-silence.wav`) på Kick, Snare og Vox Lead.
- **Send-menuen:** En bus, der allerede fører til en aux, vises som `Bus 6 → Aux 1`.
- **Plug-in-slot-navne:** Logic forkorter navnet i et optaget slot (`St-Delay`, `SmpleDly`, `Correlatio` …). Tabellen `measuredSlotLabels` er målt på 12.4; et nyt navn efter en opdatering betyder, at tilbagelæsningen fejler lukket (C), ikke at der gættes. `Distortion` kan ikke indsættes, fordi navnet også er en kategori i plug-in-menuen.
- **Insert-tilbagelæsning:** Operationens egen læsning efter indsættelse taber ofte kapløbet med plug-in-vinduet, der åbner (`operation_timeout`). Layoutet bruger derfor en uafhængig `get_inventory` og lukker editor-vinduet bagefter, fordi det ellers dækker Mixer-strips, som de næste trin klikker på (målt: Aux 5 kunne ikke vælges).
- **Nye spors placering:** Logic indsætter et spor fra `create_track_for_strip` efter det valgte spor. Layoutet vælger derfor sidste gruppemedlem først. `move_track` kan kun flytte opad.
- **`toggle_view` med `visible`** afviste på denne maskine (kan ikke observere sin UI-varetægt). Layoutet bruger den almindelige toggle og læser Mixerens tilstedeværelse via AX.
- **Folder-stakke** oprettes lukkede i 12.4; `create_stack` accepterer nu også den form.
- **Aux-spors farve** findes ikke med sporpost-mønstret i ProjectData; de forbliver State B med undo-vidne.
- **Poller'en:** En helt ny serverproces fyldte ikke Mixer-cachen (`logic://mixer`: `mixer_not_visible`), før den havde udført et UI-kald. Årsagen er ikke fundet. Inden for én session virker det.

- **Hængende modifier-tast:** Efter et ⌘-klik behandlede Logic de næste almindelige klik som ⌘-klik, indtil et event uden flag nulstillede det. `AXMouseHelper.commandClick` afslutter derfor med et museflyt uden flag. Et stak-hoved valgt sammen med sine medlemmer bliver eneste valgte spor ved et almindeligt klik på navnefeltet.
- `create_aux` vælger Options-knappen ud fra placering (2. af 3 knapper i rækken lige over Mixeren), fordi knappernes beskrivelser ikke har en entydig række i Logics strenge. Menupunktet matches stadig på sin label.
- `track.create_stack` fandtes allerede i routingtabellen som en ubrugt tastekommando-rute, så den verificerede operation hedder `track.create_stack_verified`.

- Palettens layout (24×4 + reset-knap), at øverste række har forkert AX-position, og placeringen af farvebyten i ProjectData er alle målt på 12.4 og udokumenterede.
- CGEvent-klik kræver, at Logic er i front, og at paletten står på skærmen.
- `set_region_color` kræver, at alle sporets regions er synlige, ellers zoomes der til "fit". Den virker kun på regions, Logic eksponerer i arrangementet.
- **Labels:** Repoets oversættelseskorpus er låst til Logic 12.3. De fire nye LabelSets (`assignTrackColorMenuItem`, `changeTrackColorUndoOperation`, `viewColorsMenuItem`, `changeRegionColorUndoOperation`) peger på Logics korrekte rækker, men `check-labelsets-are-derived.py` og `check-canon-citations.py` melder dem som ikke-pinnede. Pinning kræver 12.3 eller en fuld migrering af korpusset til 12.4. Migreringen blev prøvet og gav følgefejl i andre guards (zh_TW-strenge og observationsloggen), så den blev rullet tilbage.

## Tests

- **Baseline (upstream `a6e7ba1a`, Logic lukket ved start, `--no-parallel`):**
  - 6302 beståede, 13 fejlede.
  - Kørslen crashede i `ResourceSchemaTests.swift:459`, fordi en test selv startede Logic. Resten af suiten kørte ikke.
- **Branch `b6641915` (samme betingelser):**
  - Kørslen kom helt igennem: 7294 tests, 7273 beståede.
  - Ingen fejl skyldes mix-prep-ændringerne. De resterende fejl:
    - 9 × `RegionDragSpike*`: fejlede også i baseline og afhænger af miljøet.
    - 7 "known issues" (`Issue1088*`, `DeadOptionalBoolComparison`): forventede og markeret af upstream.
    - `StockPluginCatalog` factory-settings: Logic 12.4 har plug-in-mapper, som det 12.3-pinnede katalog ikke kender, fx "UltraPitch Shift (m)" og "Silk Vocal (m)".
    - 2 CoreMIDI-smoke-tests: et CoreMIDI-endpoint på denne Mac kunne ikke læses (-50). Det er miljøafhængigt.
  - Python-guard-tests, der kræver Python ≥ 3.10 og `yaml`, fejler også i baseline.
- De målrettede suiter for mix-prep (545 tests) er grønne.

## Stop-betingelser ramt

- 2026-10-26: Accessibility manglede. Løst via LogicProMCPHost i stedet for at give claude adgang.
