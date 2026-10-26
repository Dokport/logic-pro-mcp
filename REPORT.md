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
| `create_aux` / `create_summing_stack`, `set_output`, `set_send`, `move_track` | Ikke startet. Mekanismerne er målt i FINDINGS.md |
| `apply_mix_layout` | Ikke startet |
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

> **HUSK:** "claude" er slået fra under Tilgængelighed (2026-10-26). Lad den være slået fra. Fjern LogicProMCPHost, hvis projektet stoppes.

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
| `set_region_color` | AX: Deselect All + `AXSelected` pr. region (verificeret som præcist sæt), View ▸ Colors + CGEvent-klik | Undo-titel (B), der skelner region og spor |

## Skrøbeligt / kan gå i stykker ved Logic-opdateringer

- Palettens layout (24×4 + reset-knap), at øverste række har forkert AX-position, og placeringen af farvebyten i ProjectData er alle målt på 12.4 og udokumenterede.
- CGEvent-klik kræver, at Logic er i front, og at paletten står på skærmen.
- `set_region_color` kræver, at alle sporets regions er synlige, ellers zoomes der til "fit". Den virker kun på regions, Logic eksponerer i arrangementet.
- **Labels:** Repoets oversættelseskorpus er låst til Logic 12.3. De fire nye LabelSets (`assignTrackColorMenuItem`, `changeTrackColorUndoOperation`, `viewColorsMenuItem`, `changeRegionColorUndoOperation`) peger på Logics korrekte rækker, men `check-labelsets-are-derived.py` og `check-canon-citations.py` melder dem som ikke-pinnede. Pinning kræver 12.3 eller en fuld migrering af korpusset til 12.4. Migreringen blev prøvet og gav følgefejl i andre guards (zh_TW-strenge og observationsloggen), så den blev rullet tilbage.

## Tests

- **Baseline (upstream HEAD, Logic lukket ved start, `--no-parallel`):**
  - 6302 beståede.
  - 13 fejl før mine ændringer: `RegionDragSpike*`, og Python-guard-tests, der kræver Python ≥ 3.10 og `yaml`.
  - Kørslen crasher i `ResourceSchemaTests.swift:459`, fordi en test selv starter Logic. Tests efter det punkt kører ikke på denne maskine.
- **Branch:** De målrettede suiter (290 tests: registry, kataloger, kontrakter, invarianter, dispatcher og de nye farvetests) er grønne. Hele suiten mangler at blive kørt igen.

## Stop-betingelser ramt

- 2026-10-26: Accessibility manglede. Løst via LogicProMCPHost i stedet for at give claude adgang.
