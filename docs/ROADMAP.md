# Roadmapa dokončení `opencode.nvim` v2.0

## Stav a autorita

| Položka | Hodnota |
|---|---|
| Stav | Odvozená high-level realizační roadmapa |
| Cílová verze | 2.0 |
| Produktový kontrakt | `docs/PRD.md` |
| Technický kontrakt | `docs/ARCHITECTURE.md` |
| Ověřovací kontrakt | `docs/ACCEPTANCE.md` |
| Upstream baseline | `nickjvandyke/opencode.nvim` commit `7749a034db61258ece828df70a89ff31bb27ff47` |
| OpenCode baselines | `v1.17.3` (`8c8011336163d7e7fb24a6a4a049cdb1f6e6ee74`) a `v1.18.9` (`4da7bb44c84e013fa53e9c5d02ac753d1435c81a`) |

Tato roadmapa neurčuje nové produktové ani technické kontrakty. Převádí závazné dokumenty do pořadí vertikálních implementačních fází od založení forku po release. Při rozporu mají přednost dokumenty uvedené výše a rozpor se musí nejprve opravit v dokumentaci.

## Účel

Roadmapa má být společným high-level plánem celého projektu a vstupem pro detailní plánování. Low-level plány mohou sdružit dvě bezprostředně navazující fáze do jedné implementační session, ale uvnitř musí zachovat pořadí, samostatný checkpoint, scope a acceptance ownership každé fáze. Aktuální seskupení je F01-F02, F03-F04, F05-F06, F07-F08, F09-F10 a samostatná F11.

Výchozí stav repozitáře obsahuje pouze produktovou, architektonickou a acceptance dokumentaci. Import pinovaného upstream baseline, vytvoření implementačního stromu a testovacího harnessu jsou proto součástí první fáze, nikoli skrytý předpoklad.

## Pravidla realizace

1. Fáze se implementují v uvedeném pořadí; začít lze až po splnění všech jejích závislostí.
2. Každá fáze dodá jeden použitelný end-to-end capability slice včetně testů, failure paths a diagnostiky potřebných pro její exit gate.
3. Testy nejsou samostatná závěrečná fáze. Unit, Neovim integration, contract, end-to-end a failure-injection pokrytí vzniká průběžně tam, kde vzniká dané chování.
4. Každý acceptance scénář má právě jednu primární owning fázi. V pozdějších fázích se může opakovat pouze jako regrese.
5. P0 safety a data-integrity invarianty se implementují před prvním workflow, které na nich závisí; nesmí se odkládat jako release hardening.
6. Neznámý stav, API drift, neprokazatelná ownership, nevalidní proposal, nejasné routování nebo stale vstup vždy končí fail-closed bez aplikace změny.
7. Každý seskupený `PLAN-Fxx-Fyy.md` musí zachovat položku „Mimo fázi“ a nesmí přeskočit checkpoint první fáze před implementací druhé. Rozšíření scope vyžaduje změnu roadmapy a případně autoritativních kontraktů.
8. Roadmapa neobsahuje časové odhady. Pořadí vyjadřuje závislosti a řízení rizika, nikoli kalendář.

## Průběžné quality gates

Tyto podmínky platí pro každou fázi, i když jejich úplný acceptance scénář vlastní až pozdější fáze:

- nová capability má automatizované testy na nejnižší smysluplné vrstvě a alespoň jeden end-to-end nebo integration důkaz svého vertikálního workflow,
- contract testy používají neměnné `/doc` fixtures a end-to-end testy přesně pinované OpenCode binárky pro oba podporované compatibility profily,
- default logy neobsahují prompt, response, source, proposal, diff, Base/Ours/Theirs, credentials ani absolutní home path,
- žádný test ani implementace nesmí obejít `x-opencode-directory`, permission profile, Job correlation nebo scope gate,
- každý async a failure path má explicitní terminální nebo rekoncilovatelný stav; Job nesmí zůstat viset bez vlastněného requestu,
- změny v bufferu nevznikají přes write, reload, `:e`, `checktime` ani přímý agentní filesystem zápis,
- dokončená fáze nesmí rozbít exit gates dřívějších fází.

## Přehled pořadí

```text
F01 Bezpečný baseline a single-root Runtime
  -> F02 Read-only Plan, kontext a preflight
  -> F03 Scoped Build a strukturovaný proposal
  -> F04 Čistý merge a bezpečná aplikace
  -> F05 Konflikty a disková reconciliation
  -> F06 Questions, permissions a dialog queue
  -> F07 Session reuse a přesné event routing
  -> F08 Paralelní Joby a cancellation
  -> F09 Reconnect a single-root recovery
  -> F10 Multi-root lifecycle a shutdown
  -> F11 UX, privacy, diagnostika a release evidence
```

## F01 — Bezpečný baseline a single-root Runtime

**Závisí na:** ničem.

**Cíl capability:** Z dokumentačního repozitáře vznikne spustitelný fork, který pro jeden canonical project root bezpečně založí, ověří a vlastní izolovaný OpenCode Server a input-locked TUI, aniž by odeslal prompt nebo použil cizí proces.

**Zahrnutý rozsah:**

- import přesného upstream baseline a zachování licence a původu forku,
- založení testovací infrastruktury pro Lua unit testy, headless Neovim integration, uložené HTTP/SSE contract fixtures, end-to-end běh a failure injection,
- neměnný `/doc` fixture z pinovaného OpenCode commitu a kontrola všech požadovaných operation IDs,
- canonical root resolution, loopback-only Server, náhodný port, in-memory credentials a root header pro každý request,
- passive pre-spawn config guard a následný effective `/config` preflight bez importu plugin/tool kódu a bez inicializace MCP,
- private mode-0600 ownership manifest, bezpečný startup timeout, rollback částečného startupu a ověření stale manifestu,
- spuštění právě jednoho `attach --dir` TUI klienta a okamžitý základ permanentního Terminal-Normal input locku,
- single-root normal shutdown s ukončením pouze vlastního TUI/Serveru, cleanupem temp dat a odstraněním ověřeného manifestu,
- metadata-only diagnostický základ a zákaz process discovery nebo attach na cizí Server,
- capability check Neovim, Snacks, OpenCode a základních terminal API před přechodem Runtime do `ready`.

**Hlavní výstupy:**

- reprodukovatelný fork a test harness,
- single-root Runtime se stavy startup/ready/stopping/stopped,
- pinovaný OpenCode klientský kontrakt, authenticated health check a API preflight,
- ownership manifest a bezpečný cleanup ověřených orphan procesů,
- bezpečně ukončitelný single-root Runtime lifecycle,
- terminálový buffer připravený jako transcript surface, zatím bez managed prompt workflow.

**Exit gate:** `AC-RUN-02`, `AC-RUN-03`, `AC-RUN-04`, `AC-RUN-07`, `AC-RUN-09`; integration prerequisite pro `AC-RUN-01` je připravený a jeho celý user-triggered scénář vlastní F02.

**Mimo fázi:** Plan nebo Build dispatch, context placeholders, Session reuse, kompletní TUI picker workflow, merge, interaktivní dialogy, reconnect a více rootů.

## F02 — Read-only Plan, kontext a preflight

**Závisí na:** F01.

**Cíl capability:** Uživatel odešle inline Plan prompt z podporovaného file bufferu, OpenCode jej zpracuje v technicky needitujícím režimu a transcript se zobrazí v pravém sidebaru bez focus steal nebo source zápisu.

**Zahrnutý rozsah:**

- minimální Session a Job registrace před async dispatchí včetně plugin metadata, `msg_<ULID>`, Job key a assistant-parent bootstrap potřebného pro bezpečný první turn,
- default-deny Session permission profile, explicitní read-only allowlist, odstranění zakázaných i neznámých tools z resolved model surface a execution-time hard deny v izolovaném plugin-owned Serveru,
- `snacks.input` s viditelným Plan režimem, canonical rootem a effective location/scope informací, bez prompt historie,
- upstream-compatible `@this`, `@buffer`, `@buffers`, `@visible`, `@diagnostics`, `@quickfix` a `@marks`, completion a highlight,
- aktivní editor location v každém promptu a path/range reference pro file-backed context,
- ponechání skills a `AGENTS.md` nativnímu OpenCode discovery bez duplicitní injekce a odmítnutí managed `/command` před vznikem Jobu,
- validace běžného UTF-8 file targetu bez NUL a odmítnutí nepodporovaných bufferů,
- atomický dirty-buffer preflight pro target a explicitní file context, standardní write hooks a zachycení finálního uloženého obsahu,
- sidebar show/toggle/focus, konfigurovatelná šířka, návrat focusu a permanentní input lock při navigaci transcriptu,
- základ idempotentního dokončení Plan Jobu bez proposal nebo buffer application.

**Hlavní výstupy:**

- první kompletní Plan tracer bullet přes input, HTTP/SSE, TUI transcript a bezpečné dokončení,
- context a preflight pipeline sdílená budoucím Build workflow,
- prokazatelně read-only Session boundary,
- sidebar použitelný pro transcript bez možnosti TUI prompt inputu.

**Exit gate:** `AC-RUN-01`, `AC-UI-02`, `AC-CTX-01`, `AC-CTX-02`, `AC-CTX-03`, `AC-CTX-04`, `AC-CTX-06`, `AC-MODE-01`; Build část kombinovaného `AC-CTX-05` uzavírá a celý scénář primárně vlastní F03.

**Mimo fázi:** Build proposal, hard-scope enforcement, merge a aplikace, questions/permissions dialogy, Session picker/reuse, paralelní Joby a reconnect.

## F03 — Scoped Build a strukturovaný proposal

**Závisí na:** F02.

**Cíl capability:** Build nad jedním explicitním visual, function nebo file scope vrátí strukturovaný návrh, který plugin deterministicky validuje jako jednu proposal transaction; v této fázi se návrh ještě neaplikuje.

**Zahrnutý rozsah:**

- Build jako výchozí primary agent se stejným hard-deny boundary jako Plan,
- zachycení skutečného visual/operator invocation range, odmítnutí blockwise selection, Tree-sitter function resolution s Lua adapterem a file fallback,
- viditelný effective scope a explicitní rozšíření range/function scope na file před odesláním,
- half-open byte BaseScope, Base snapshot, SHA-256 a extmark pair s požadovanou gravity,
- odmítnutí nového Build Jobu při překryvu s current scope aktivního Jobu; dotýkající se scopes zůstávají povolené,
- přesné JSON schema verze 1, structured output dispatch a sběr právě jedné odpovědi s validním structured objektem,
- validace canonical path, Base hash, scope offsets, UTF-8 replacementu bez NUL/CR a odmítnutí volného Markdown/file event fallbacku,
- deterministické sestavení Theirs a byte-precise Base-to-Theirs scope enforcement,
- fail-closed `error` nebo `scope_violation` bez částečného přijetí proposal,
- explicitní přechod validního proposal Jobu do `pending_apply`, ve kterém Session zůstává active pro navazující fázi aplikace.

**Hlavní výstupy:**

- end-to-end Build transaction končící validním proposalem ve stavu `pending_apply`,
- scope resolver a extmark tracking,
- proposal schema, validator a Theirs konstrukce,
- důkaz, že agent nemůže přímo změnit source workspace.

**Exit gate:** `AC-UI-01`, `AC-CTX-05`, `AC-MODE-02`, `AC-SCOPE-01`, `AC-SCOPE-02`, `AC-SCOPE-03`, `AC-SCOPE-04`, `AC-SCOPE-05`, `AC-PROP-01`, `AC-PROP-02`, `AC-PROP-03`.

**Mimo fázi:** Base/Ours/Theirs merge, buffer mutation, conflict resolution, question/permission UI, reusable Session a paralelní aplikace více Jobů.

## F04 — Čistý merge a bezpečná aplikace

**Závisí na:** F03.

**Cíl capability:** Validní proposal se při clean nebo identickém Base/Ours/Theirs výsledku automaticky a bezpečně vloží do živého bufferu jako jedna neuložená změna vratná jedním undo.

**Zahrnutý rozsah:**

- přesná logical-buffer reprezentace, LF kanonizace a zachování `fileformat`, `endofline`, `fixendofline`, empty file a trailing empty lines,
- private Base/Ours/Theirs temp files a capability-ověřený `git merge-file -p --diff3` spuštěný bez shell interpolace,
- odložení aplikace během Insert mode a jednorázové pokračování na `InsertLeave`,
- zachycení current Ours, changedtick a raw disk fingerprintu před merge,
- rozlišení `disk == Base` a `disk == Ours`; jakýkoli jiný diskový stav zatím bezpečně zastaví aplikaci bez overwrite,
- povinná revalidace existence, validity a vzájemného nepřekrývání current extmark ranges všech aktivních Build Jobů před každou aplikací; plný paralelní acceptance důkaz vlastní F08,
- opakovaná changedtick a disk-fingerprint kontrola těsně před API mutací a přepočet při stale vstupu,
- clean a identický třícestný merge zachovávající nekolizní uživatelské změny,
- UTF-8-safe minimální changed span a právě jedno `nvim_buf_set_text()` bez `undojoin`, write nebo reloadu,
- zachování/omezení cursoru, view a extmarků a cleanup temp dat ve všech terminálních cestách,
- idempotentní základ Job state machine pro `running`, `pending_apply`, `completed`, `cancelled`, `error` a `scope_violation`,
- fail-closed přechod detekovaného agentního nebo external-disk problému do rekoncilovatelného `conflict(agent|external_change)` s možností cancel; závazné resolution UI dodá F05.

**Hlavní výstupy:**

- clean merge engine a stale-input guards,
- buffer applier s jedním undo krokem,
- korektní EOL a empty-file transakce,
- Build workflow od promptu po bezpečnou neuloženou změnu bufferu.

**Exit gate:** `AC-MERGE-01`, `AC-MERGE-02`, `AC-MERGE-03`, `AC-MERGE-04`, `AC-MERGE-05`, `AC-MERGE-08`, `AC-MERGE-10`, `AC-MERGE-12`.

**Mimo fázi:** rozhodování agentních konfliktů, external-change reconciliation UI, manual diff, questions/permissions, Session reuse a paralelní Joby.

## F05 — Konflikty a disková reconciliation

**Závisí na:** F04.

**Cíl capability:** Jeden Build Job bezpečně rozliší agentní merge konflikt od nezávislé diskové změny a umožní uživateli explicitně dokončit nebo zrušit transakci bez ztráty Ours.

**Zahrnutý rozsah:**

- `conflict` state s povinným kind `agent` nebo `external_change` a immutable dialog payloadem,
- agentní dialog přesně s volbami `keep my changes`, `accept agent changes`, `open manual diff`,
- conflict-preference merge přes `--ours`/`--theirs`, který zachová nekolizní hunks obou stran a nepřepisuje raw celý soubor,
- manual diff s read-only Base/Ours/Theirs a editovatelným result bufferem, explicitním potvrzením a zrušením,
- external-change detekce před merge i bezprostředně před každou automatickou nebo potvrzenou aplikací,
- external diff, `retry apply` pouze po explicitní disk/buffer reconciliation a cancel bez write/reload,
- nový merge nad čerstvými vstupy po changedtick nebo disk race,
- zachování Session jako active po celou dobu konfliktu a cleanup při dokončení nebo zrušení.

**Hlavní výstupy:**

- agentní conflict workflow,
- external-change reconciliation workflow,
- manual diff lifecycle,
- failure-injection důkaz, že stale merge ani konflikt nikdy nepřepíše user nebo disk changes.

**Exit gate:** `AC-MERGE-06`, `AC-MERGE-07`, `AC-MERGE-09`, `AC-MERGE-11`.

**Mimo fázi:** OpenCode question/permission requesty, globální FIFO napříč Joby, Session picker/reuse, paralelní scopes a reconnect.

## F06 — Questions, permissions a dialog queue

**Závisí na:** F05.

**Cíl capability:** Managed Job bezpečně obslouží otázky, schvalovatelné permissions a konflikty v jediném serializovaném nativním UI bez možnosti obejít hard deny nebo odpovědět přes TUI.

**Zahrnutý rozsah:**

- routing requestu bez message ID pouze k jedinému aktivnímu Jobu dané Session a fail-closed reconciliation jinak,
- `waiting_user` s povinným kind `question` nebo `permission` a kompletní validace povolených Job transitions,
- Snacks question picker/input a canonical reply/reject endpointy s přesným request ID,
- permission dialog pouze pro schvalovatelné allowlisted tools, omezené `always` a neoverrideovatelný deny pro write-capable, external a neznámé tools,
- jedna globální FIFO `DialogRequest` fronta pro question, permission, agent conflict a external-change conflict napříč Runtime,
- explicitní reject/cancel při zavření a odstranění pending dialogů při cancel/termination,
- managed visibility lock: skrytí sidebaru, blokace toggle/focus/select-session a obnovení až po potvrzeném reply/reject eventu,
- permanentní TUI input lock jako jediná podporovaná cesta, která znemožní druhou user response.

**Hlavní výstupy:**

- autoritativní nativní interaction UI,
- FIFO dialog orchestrace bez visících Jobů,
- hard-deny proof na fresh isolated Serveru, surface-filter proof i proti předvyplněnému Server-wide approval a důkaz, že podporované managed UI neumí založit approval pro hard-denied capability,
- úplná state-transition matice včetně interaktivních a konfliktních stavů.

**Exit gate:** `AC-EVT-02`, `AC-INT-01`, `AC-INT-02`, `AC-INT-03`, `AC-INT-04`, `AC-STATE-01`.

**Mimo fázi:** Session reuse/picker, paralelní range workflow, cancel-all napříč Runtime a reconnect reconciliation.

## F07 — Session reuse a přesné event routing

**Závisí na:** F06.

**Cíl capability:** Uživatel může bezpečně přepínat a znovu použít plugin-managed Session, navázat Build po Planu a přitom zachovat přesnou identitu každého Jobu i při opožděných eventech.

**Zahrnutý rozsah:**

- Session ownership/version metadata, root hash, archive filtering, retention bez automatického mazání a revalidace permission profilu před každým reuse,
- availability odvozená jako `active(jobID)` nebo `reusable`, bez Job queue a bez trvalého Session error stavu,
- odmítnutí follow-up do neterminální Session a nabídka nové Session,
- Session picker se stabilní textovou identitou, activity ordering a Runtime-local `/tui/select-session`,
- permanentní input-locked TUI focus s Terminal-Normal navigací a bez user/control inputu,
- Plan-to-Build follow-up se zachovaným transcript/model contextem a novým userMessageID, Base a scope,
- přesné routování user eventu přes `sessionID + userMessageID`, bootstrap assistant message přes `parentID` a další part eventy přes registrované assistant IDs,
- late-event guard pro terminální nebo starší Job a reconciliation trigger při busy Session bez lokálního Jobu,
- úplná Session availability a Job ownership diagnostika.

**Hlavní výstupy:**

- reusable Session workflow a Session picker,
- Plan-to-Build continuity,
- event correlation bez globálního current-context stavu,
- prokazatelná izolace starých a nových turnů ve stejné Session.

**Exit gate:** `AC-MODE-03`, `AC-JOB-01`, `AC-JOB-02`, `AC-JOB-06`, `AC-JOB-07`, `AC-EVT-01`, `AC-STATE-02`.

**Mimo fázi:** více současných Jobů ve stejném bufferu, cancel-all, SSE reconnect, Server restart a více Runtime.

## F08 — Paralelní Joby a cancellation

**Závisí na:** F07.

**Cíl capability:** Dva nebo více Jobů mohou bezpečně běžet současně v různých Session, včetně nepřekrývajících se scope stejného bufferu, a lze je nezávisle nebo hromadně zrušit.

**Zahrnutý rozsah:**

- samostatné Base/Theirs/extmark transakce pro každý aktivní Build Job,
- nové ověření current extmark validity a vzájemného nepřekrývání těsně před každou aplikací,
- fail-closed `scope_violation` při uživatelem vytvořeném překryvu nebo kolapsu,
- aplikace nepřekrývajících se Jobů v libovolném pořadí se zachováním obou změn a extmarků dosud aktivního Jobu,
- background isolation stavů, eventů, proposals a dialogs napříč Session,
- funkční background status a základ neinvazivních notifikací pro souběžné Joby; finální čitelnost, cross-root identita a P2 evidence patří F11,
- cancel-one s abortem správné Session, lokálním late-event guardem a cleanup proposal/extmark/temp/dialog dat,
- single-runtime cancel-all nad snapshotem všech aktivních Jobů bez závislosti na úspěchu jednotlivých HTTP abortů.

**Hlavní výstupy:**

- parallel-range workflow bez worktree nebo workspace copy,
- pre-apply overlap safety gate,
- cancel-one a single-runtime cancel-all semantics,
- funkční background přehled paralelních Jobů,
- pořadím nezávislý merge důkaz pro dva scopes stejného bufferu.

**Exit gate:** `AC-SCOPE-06`, `AC-JOB-03`, `AC-JOB-04`; multi-runtime část `AC-JOB-05` uzavírá a celý scénář primárně vlastní F10.

**Mimo fázi:** SSE reconnect/reconciliation, TUI/Server crash recovery, současné project roots a finální UX polish.

## F09 — Reconnect a single-root recovery

**Závisí na:** F08.

**Cíl capability:** Výpadek TUI, SSE nebo Serveru v jednom Runtime nezpůsobí cross-Job mix ani neprokazatelnou aplikaci a Runtime se obnoví pouze přes explicitní reconciliation.

**Zahrnutý rozsah:**

- TUI-only restart nad živým Serverem se stejným `attach --dir` a obnovením zobrazené Session,
- SSE disconnect gate blokující nové prompty do dokončení reconciliation,
- načtení Session statusů, exact messages, pending questions a permissions po reconnectu,
- pokračování právě jednou pouze při prokazatelném assistant resultu s odpovídajícím parent ID,
- fail-closed `error` bez aplikace při idle Session bez validního výsledku nebo při chybějící Session,
- rekonstrukce dialog queue pro pending requests,
- Server crash přechod do `disconnected`, zachování lokálních pending dat a explicitní restart vlastněného Server/TUI,
- zákaz fallbacku na cizí Server a nové prompt gate až po reconciliation nebo bezpečném ukončení starých Jobů.

**Hlavní výstupy:**

- single-root TUI, SSE a Server recovery workflow,
- reconciliation engine a prompt blocking,
- failure-injection důkaz proti double-completion a neprokazatelné aplikaci.

**Exit gate:** `AC-RUN-08`, `AC-EVT-03`, `AC-EVT-04`, `AC-EVT-05`.

**Mimo fázi:** současný provoz více canonical roots, globální multi-runtime shutdown a finální status/health UX.

## F10 — Multi-root lifecycle a shutdown

**Závisí na:** F09.

**Cíl capability:** Jedna Neovim instance bezpečně provozuje více nezávislých Runtime, přepíná jejich TUI v jednom sidebaru a při shutdownu ukončí pouze prokazatelně vlastněné procesy.

**Zahrnutý rozsah:**

- Runtime registry klíčovaná canonical realpath rootem bez duplicit přes symlinky,
- samostatný Server, TUI, Session registry, Job registry a SSE stream pro každý root,
- přepnutí aktivního rootu a sidebar terminal bufferu bez zastavení background Jobů ostatních rootů,
- Runtime-local TUI select-session a striktní root identity všech HTTP/SSE eventů,
- dialog queue a cancel-all napříč Runtime bez cross-root záměny,
- `VimLeavePre` abort aktivních vlastněných Session, ukončení TUI/Server children, cleanup temp dat a manifestů,
- cancel-all nad snapshotem aktivních Jobů ze všech Runtime s lokálním fail-closed dokončením i při selhání jednotlivého abortu,
- příští startup s kryptograficky a procesně ověřeným orphan cleanupem; neprokázaný proces zůstane nedotčen s manuální diagnostikou.

**Hlavní výstupy:**

- multi-root end-to-end workflow,
- bezpečné přepínání transcriptu mezi Runtime,
- úplný normal-shutdown a hard-crash ownership lifecycle,
- důkaz, že cizí proces ani Job jiného rootu není ovlivněn.

**Exit gate:** `AC-RUN-05`, `AC-RUN-06`, `AC-JOB-05`; regrese `AC-RUN-01`, `AC-RUN-02`, `AC-RUN-07`, `AC-EVT-01`.

**Mimo fázi:** nové workflow capabilities, změna podporovaného OpenCode baseline a release polish.

## F11 — UX, privacy, diagnostika a release evidence

**Závisí na:** F01 až F10.

**Cíl capability:** Kompletní produkt je srozumitelný při foreground i background práci, prakticky diagnostikovatelný bez úniku obsahu a doložený jako release candidate pro v2.0.

**Zahrnutý rozsah:**

- status UI se Session title, short ID, rootem, režimem, availability a Job stavem bez závislosti pouze na barvě,
- neinvazivní completion/conflict/question/error notifikace bez změny window, cursoru nebo zobrazené Session,
- praktický health check pro Neovim, Snacks input/picker, přesný OpenCode pin/API, `git merge-file`, loopback bind, terminal API a volitelný Tree-sitter parser,
- audit metadata-only loggingu přes success, conflict, scope violation, HTTP error a reconnect včetně unikátních secret fixture,
- dokončení uživatelské a maintainer dokumentace potřebné pro instalaci, podporovanou konfiguraci, health, omezení a manuální recovery,
- plný regresní běh všech P0/P1 scénářů na pinovaném baseline,
- automatizovaný výsledek nebo reprodukovatelný uložený manuální protokol pro každý P2 scénář,
- release evidence potvrzující absenci skipped safety scénářů, legacy fallbacku, source write, stale apply, cross-Job eventu a ztráty Ours.

**Hlavní výstupy:**

- dokončené status, notification a health UX,
- privacy a security test evidence,
- úplná dokumentace podporované v2.0,
- auditovatelný release-candidate report navázaný na všechny acceptance scénáře.

**Exit gate:** `AC-UI-03`, `AC-UI-04`, `AC-SEC-01`, `AC-SEC-02`; kompletní regrese všech dříve vlastněných AC scénářů.

**Mimo fázi:** nové product scope, upgrade OpenCode baseline, deferred capabilities nebo refaktory nepotřebné pro release gate.

## Traceability

Každý z 63 scénářů v `docs/ACCEPTANCE.md` má právě jednu primární owning fázi. Položky označené jako regrese nejsou druhým vlastnictvím.

### Vazba na delivery slices z PRD

| PRD delivery slice | Roadmap fáze |
|---|---|
| Slice 1: Vlastněný read-only Plan | F01–F02 |
| Slice 2: Jeden scoped Build bez konfliktu | F03–F04 |
| Slice 3: Interaktivní bezpečnost | F05–F06 |
| Slice 4: Session reuse a paralelní ranges | F07–F08 |
| Slice 5: Multi-root lifecycle a recovery | F09–F10 |
| Cross-slice release closure | F11 |

Roadmap fáze jsou menší než PRD slices, ale nemění jejich obsah ani pořadí. Dokončení poslední fáze daného řádku uzavírá odpovídající PRD slice.

| Fáze | Primárně vlastněné acceptance scénáře |
|---|---|
| F01 | `AC-RUN-02`, `AC-RUN-03`, `AC-RUN-04`, `AC-RUN-07`, `AC-RUN-09` |
| F02 | `AC-RUN-01`, `AC-UI-02`, `AC-CTX-01`, `AC-CTX-02`, `AC-CTX-03`, `AC-CTX-04`, `AC-CTX-06`, `AC-MODE-01` |
| F03 | `AC-UI-01`, `AC-CTX-05`, `AC-MODE-02`, `AC-SCOPE-01`, `AC-SCOPE-02`, `AC-SCOPE-03`, `AC-SCOPE-04`, `AC-SCOPE-05`, `AC-PROP-01`, `AC-PROP-02`, `AC-PROP-03` |
| F04 | `AC-MERGE-01`, `AC-MERGE-02`, `AC-MERGE-03`, `AC-MERGE-04`, `AC-MERGE-05`, `AC-MERGE-08`, `AC-MERGE-10`, `AC-MERGE-12` |
| F05 | `AC-MERGE-06`, `AC-MERGE-07`, `AC-MERGE-09`, `AC-MERGE-11` |
| F06 | `AC-EVT-02`, `AC-INT-01`, `AC-INT-02`, `AC-INT-03`, `AC-INT-04`, `AC-STATE-01` |
| F07 | `AC-MODE-03`, `AC-JOB-01`, `AC-JOB-02`, `AC-JOB-06`, `AC-JOB-07`, `AC-EVT-01`, `AC-STATE-02` |
| F08 | `AC-SCOPE-06`, `AC-JOB-03`, `AC-JOB-04` |
| F09 | `AC-RUN-08`, `AC-EVT-03`, `AC-EVT-04`, `AC-EVT-05` |
| F10 | `AC-RUN-05`, `AC-RUN-06`, `AC-JOB-05` |
| F11 | `AC-UI-03`, `AC-UI-04`, `AC-SEC-01`, `AC-SEC-02` |

### Kontrola úplnosti podle oblasti

| Oblast | Primární owning fáze |
|---|---|
| `AC-RUN-01` až `AC-RUN-09` | F01, F02, F09, F10 |
| `AC-UI-01` až `AC-UI-04` | F02, F03, F11 |
| `AC-CTX-01` až `AC-CTX-06` | F02, F03 |
| `AC-MODE-01` až `AC-MODE-03` | F02, F03, F07 |
| `AC-SCOPE-01` až `AC-SCOPE-06` | F03, F08 |
| `AC-PROP-01` až `AC-PROP-03` | F03 |
| `AC-MERGE-01` až `AC-MERGE-12` | F04, F05 |
| `AC-JOB-01` až `AC-JOB-07` | F07, F08, F10 |
| `AC-EVT-01` až `AC-EVT-05` | F06, F07, F09 |
| `AC-INT-01` až `AC-INT-04` | F06 |
| `AC-STATE-01` až `AC-STATE-02` | F06, F07 |
| `AC-SEC-01` až `AC-SEC-02` | F11 |

## Obsah low-level plánu

Detailní plán každé fáze nebo seskupené implementační session musí nejméně obsahovat:

1. ID fáze, cíl capability, závislosti a převzaté invarianty.
2. Stav relevantního upstream kódu a rozhodnutí, co se zachová, nahradí nebo odstraní.
3. Konkrétní behavior homes a vlastněné cesty bez globálního mutable current-context stavu.
4. Datové kontrakty, povolené state transitions, async ordering a fail-closed cesty relevantní pro fázi.
5. Vertikální implementační kroky, z nichž každý končí pozorovatelným chováním nebo ověřeným tracerem.
6. Unit, Neovim integration, contract, end-to-end a failure-injection testy potřebné pro owned AC scénáře.
7. Migrační nebo upstream-fork dopady, pokud je fáze má; bez spekulativní backward compatibility.
8. Observability a privacy kontroly bez content loggingu.
9. Exit gate, regresní sadu předchozích fází a požadované release evidence.
10. Explicitní „Mimo fázi“, otevřené předpoklady a podmínky pro zastavení nebo eskalaci rozporu v kontraktech.

## Deferred a non-goals v2.0

Roadmapa záměrně nezahrnuje:

- přímé agentní zápisy do source workspace,
- worktrees, workspace kopie nebo branch orchestrace,
- unscoped, project-wide nebo multi-file Build,
- vytváření, mazání nebo přejmenování souborů a editace binárních souborů,
- vlastní transcript renderer nebo quickfix jako chatový transcript,
- automatický attach nebo discovery cizích OpenCode procesů,
- autosave nebo automatický zápis sloučené změny na disk,
- prompt input history,
- vlastní `#command` nebo `#skill` namespace,
- spouštění OpenCode custom commands a command templates v managed workflow,
- specializovaný Review artefakt, Plan-to-scaffold nebo Search-to-quickfix workflow,
- blockwise visual Build,
- managed inline edit workflow přes přímý TUI input,
- vlastní model picker nebo best-effort fallback na jiné OpenCode API/verze.

## Finální release gate

F11 připraví release evidence; samotné release approval není další implementační fáze. Verze 2.0 je hotová pouze tehdy, když současně platí:

1. F01 až F11 mají splněné vlastní exit gates.
2. Všech 63 acceptance scénářů má výsledek podle priority: žádný P0/P1 skip a reprodukovatelný důkaz pro každý P2.
3. Contract suite i end-to-end suite běží proti přesně pinovaným OpenCode profilům `v1.17.3` a `v1.18.9` bez neznámého legacy fallbacku.
4. Failure injection neprokáže source disk write, stale apply, cross-Job/cross-root routing, neautorizovaný tool, cizí process termination ani ztrátu Ours.
5. Build a Plan používají plugin-owned Runtime a proposal-only boundary; TUI zůstává input-locked transcript surface.
6. Hard scope, Session/Job identity, reconnect a conflict paths jsou fail-closed a bezpečně zachovávají uživatelovu práci.
7. Aplikovaný výsledek zůstává neuložený, `modified` a vratný jedním standardním Neovim undo krokem.
