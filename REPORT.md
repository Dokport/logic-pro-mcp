# Mix-prep: statusrapport

_Sidst opdateret: 2026-10-26_

## Status: Fase 1 (kortlægning) færdig. Fase 2 er ikke startet.

Fund pr. operation står i [research/FINDINGS.md](research/FINDINGS.md).

### Miljø
| Punkt | Resultat |
|---|---|
| Logic Pro | 12.4, en-US UI (doctor: uden for upstreams validerede 12.3) |
| macOS | 15.6, én skærm 1920×1080 |
| Responsible process | Claude Codes `claude.app` (`com.anthropic.claude-code`), startet af Claude-desktop-appen via `disclaimer` |
| Rettigheder | Accessibility ✓, Automation → Logic Pro og System Events ✓, PostEvent ✓ (følger med Accessibility), Skærmoptagelse ✗ (bevidst fravalgt) |
| Swift | 6.2.3 via `swiftly` (Homebrew) i `~/.swiftly`, fordi Command Line Tools er halvt opdateret (compiler 6.1.2 mod SDK 6.2.3). Kør `. ~/.swiftly/env.sh` før `swift build` |
| Testprojekt | `~/dev/logic-test/MixPrepTest.logicx` (12 audiospor) med skabelonen `MixPrepTest_clean.logicx`. `tools/reset-test-project.sh` gendanner det |

> **HUSK når projektet er færdigt:** Systemindstillinger → Anonymitet og sikkerhed → Tilgængelighed → slå **claude** (Claude Code) fra. `tools/check-grants.sh` skal derefter vise `AXIsProcessTrusted False`.

### Værktøjer
- `tools/ax-dump/`: Accessibility-dump af Logic (read-only). Byg med `swiftc -O -o tools/ax-dump/ax-dump tools/ax-dump/main.swift`.
- `tools/mcp-call`: JSON-RPC over stdio direkte mod serveren. Én serverproces pr. kald, så referencer holder mellem trin.
- `tools/reset-test-project.sh`: lukker og gendanner testprojektet fra den rene skabelon og åbner det. Nægter at lukke andre dokumenter med ugemte ændringer.
- `tools/check-grants.sh`: viser TCC-status for den proces, der kører kommandoerne.

### Hvad virker (Fase 1-målinger, ingen produktionskode endnu)
| Operation | Kanal | Tilbagelæsning |
|---|---|---|
| Farve | AX-menu + CGEvent-klik på AX-placeret palettefelt | Ingen AX-tilbagelæsning af farven. Undo-titlen bekræfter typen, og ProjectData efter gemning giver paletteindeks |
| Summing stack | AX-menu + sheet. Valg via ⌘-klik | AX: rækkefølge og bus-routing |
| Aux | AX (Mixer `Options`, eller bus uden modtager) | AX |
| Output | AX-pop-up (findes som `set_output_verified`) | AX |
| Send | AX-pop-up og knap (findes delvist) | AX |
| Flyt spor | Stack + flatten via AX-menuer + ⌘-klik | AX-rækkefølge. Topposition kun via drag |

### Skrøbeligt / kan gå i stykker ved Logic-opdateringer
- Palettens layout (24×4 + 1, børnenes rækkefølge) og ProjectData-farvebytens placering er udokumenterede.
- CGEvent-klik kræver, at målet er synligt (Mixeren skjuler en stor del af sporlisten) og at Logic er i front.
- Flytning via stack + flatten afhænger af, at Logic samler ikke-sammenhængende valg i sporrækkefølge.
- Engelske menutitler er brugt i probes. Produktionskode skal bruge repoets locale-/labelset-infrastruktur.

### Åbent spørgsmål til brugeren
Farvenavne i specen ("red", "blue", "yellow", "purple") kan ikke oversættes til palettefelter uden at se paletten. Der er tre muligheder:
1. Brugeren ser på paletten én gang og angiver felterne (fx række/kolonne).
2. Midlertidig skærmoptagelse, så agenten kan kalibrere selv.
3. Specen bruger paletteindeks (1-96) i stedet for navne.

### Stop-betingelser ramt indtil nu
- 2026-10-26: Accessibility manglede for den responsible process. Brugeren har givet den (til `claude`/Claude Code), og den er løst.
