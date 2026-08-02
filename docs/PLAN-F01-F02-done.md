# Low-level plan F01-F02: vlastněný Runtime a read-only Plan

> Historical implementation plan. Plan and the tmux/TUI sidebar were later removed; this is not an active contract.

## Mandát

| Položka | Hodnota |
|---|---|
| Fáze | F01 Bezpečný baseline a single-root Runtime; F02 Read-only Plan, kontext a preflight |
| Capability slice | Jeden canonical root spustí vlastní izolovaný Server a input-locked TUI; uživatel odešle read-only Plan z file bufferu a sleduje transcript v sidebaru |
| Závislosti | Žádné; repozitář před touto session obsahuje jen dokumentaci |
| Autority | `docs/PRD.md`, `docs/ARCHITECTURE.md`, `docs/ACCEPTANCE.md`, `docs/ROADMAP.md` |
| Upstream plugin | `nickjvandyke/opencode.nvim` commit `7749a034db61258ece828df70a89ff31bb27ff47` |
| OpenCode profily | `v1.17.3` commit `8c8011336163d7e7fb24a6a4a049cdb1f6e6ee74`; `v1.18.9` commit `4da7bb44c84e013fa53e9c5d02ac753d1435c81a` |

Session končí funkčním Plan tracerem, ne pouze Runtime knihovnou. F01 se uzavře před prvním managed promptem; F02 na stejném kódu přidá první celý user workflow.

## Acceptance ownership a checkpointy

| Checkpoint | Primárně vlastněné scénáře |
|---|---|
| F01 | `AC-RUN-02`, `AC-RUN-03`, `AC-RUN-04`, `AC-RUN-07`, `AC-RUN-09` |
| F02 | `AC-RUN-01`, `AC-UI-02`, `AC-CTX-01`, `AC-CTX-02`, `AC-CTX-03`, `AC-CTX-04`, `AC-CTX-06`, `AC-MODE-01` |

Implementační session nesmí začít krokem 5 ani změnit default prompt behavior, dokud F01 řádek neprojde. Každý scénář vlastní právě uvedený checkpoint; pozdější opakování je regrese.

## Výchozí upstream stav

Importuj přesný upstream strom včetně `LICENSE`, historie původu a stávajících CI kontrol. Před další změnou zaznamenej importovaný commit v `README.md` a fork changelogu.

Zachovat a rozvíjet:

- `lua/opencode.lua`: veřejný vstup, error notification a operator pattern; přesměrovat z discovery/TUI emulace do managed workflow.
- `lua/opencode/config.lua`: lazy `vim.g.opencode_opts` konfiguraci a Snacks options; odstranit autoread a external-server volby.
- `lua/opencode/context/*`: placeholder names, rendering, completion/highlight a path/range formát; odstranit inline obsah non-file bufferů a `Context.current`.
- `lua/opencode/ui/ask/*`, `lua/opencode/ui/select_session.lua`, `lua/opencode/promise/*`, `plugin/highlights.lua`: zachovat jen kontraktově kompatibilní části.
- `.stylua.toml`, `.luarc.ci.json`, LuaLS a StyLua CI.

Nahradit nebo odstranit v této session:

- `lua/opencode/server/discovery/**` a `lua/opencode/ui/select_server.lua`: žádné `pgrep`, `lsof`, PowerShell discovery, foreign URL ani server picker.
- `lua/opencode/server/init.lua`: současný globální `Server.connected`, generický curl parser a dvousekundový timeout nahradit Runtime-local klientem.
- `lua/opencode/api/prompt.lua`: odstranit `/tui/publish` a keyboard-like `prompt.submit`; managed prompt jde přes Session HTTP API.
- `lua/opencode/api/command.lua`: odstranit managed TUI command transport. Přepnutí transcriptu později používá jen `/tui/select-session`.
- `plugin/events/reload.lua` a edit-permission handler: odstranit `checktime`, autoread, `file.edited` autoritu a `diffpatch` edit workflow.
- globální status a User-autocmd routing jako interní autoritu. Metadata-only User event lze zachovat pouze jako pozorovací výstup.

Upstream nemá test framework ani testy. Tato session musí založit celý harness; ruční `:checkhealth` není exit gate.

## Zvolený tvar

Byly zváženy dvě varianty: rozšířit globální upstream `Server`, nebo zavést Runtime objekt a tenkou root registry. Globální Server by přenesl single-current-context coupling do všech dalších fází a v F10 vyžadoval přepis. Zvolen je Runtime objekt od začátku; F01 registry obsahuje nejvýše jeden Runtime, ale žádný modul nesmí číst globální current Session/Job.

Každé pravidlo má jeden behavior home:

| Cesta | Behavior home |
|---|---|
| `lua/opencode/runtime/init.lua` | Single-root Runtime lifecycle, stav, procesy, prompty gate a pozdější registry seam |
| `lua/opencode/runtime/root.lua` | LSP/Git/cwd root resolution, canonical realpath a containment |
| `lua/opencode/runtime/config_guard.lua` | Passive JSON/JSONC scan a effective `/config` policy |
| `lua/opencode/runtime/ownership.lua` | Mode-0600 manifest, process start identity, stale ownership verification a cleanup |
| `lua/opencode/client.lua` | Authenticated HTTP/SSE, root header, compatibility profile a endpoint payloady |
| `lua/opencode/session.lua` | Managed Session metadata, permission profile a single active Job pointer |
| `lua/opencode/job.lua` | Job key, registrace před dispatchí, minimální F02 transitions a terminal cleanup |
| `lua/opencode/context/init.lua` | Immutable editor capture, target validace a placeholder expansion |
| `lua/opencode/context/preflight.lua` | Atomický dirty-buffer save/cancel workflow a post-hook kontrola |
| `lua/opencode/api/prompt.lua` | Vertikální Plan dispatch orchestrace; v F03 se rozšíří o Build |
| `lua/opencode/ui/sidebar.lua` | TUI terminal buffer/window, input lock, show/toggle/focus a source focus restoration |
| `lua/opencode/ui/ask/init.lua` | Snacks input lifecycle, visible mode/root/location a buffer-local completion context |
| `lua/opencode/log.lua` | Metadata-only log schema a redakce |

Nepřidávej `manager`, `service`, repository interface ani transport abstraction navíc. `client.lua` může mít injektovatelný process runner pro testy, ale produkční cesta zůstane jedna.

## Převzaté invarianty

- Runtime nepřijme prompt před stavem `ready` a nikdy se nepřipojí k procesu, který sám nespustil.
- Každý request včetně SSE, `/config`, `/question` a `/permission` nese `x-opencode-directory: <canonical-root>`.
- Server binduje `127.0.0.1`, používá OS-přidělený volný port a kryptografické credentials; secret není v command line ani logu.
- `v1.17.3` a `v1.18.9` jsou dva explicitní profily. Neznámá verze nebo neshodný `/doc` končí před promptem.
- Plugin-owned Server začíná s prázdným approval state. Oba exact profily filtrují model tool surface přes agent+Session rules; wildcard a explicitní hard deny odstraní zakázané i neznámé tools a execution-time deny zůstává druhá obranná vrstva.
- Plan nemůže zapisovat source, `.opencode/plans`, shell, external path ani spustit task/custom/MCP side effect.
- Target je canonical UTF-8 file bez NUL. Dirty target a explicitní file context projdou jedním preflight dialogem.
- Job vznikne před `prompt_async`; TUI je transcript surface a zůstává trvale Terminal-Normal.
- Default log nesmí obsahovat prompt, response, source, absolutní home path, port password ani Authorization header.

## Compatibility kontrakt

Vytvoř `lua/opencode/compat.lua` pouze jako datovou tabulku dvou profilů, ne jako obecný adapter framework. Profil obsahuje exact version, source commit, fixture path a required operation IDs:

`global.health`, `path.get`, `config.get`, `event.subscribe`, `session.list`, `session.create`, `session.update`, `session.status`, `session.get`, `session.messages`, `session.message`, `session.prompt_async`, `session.abort`, `app.agents`, `tui.selectSession`, `permission.list`, `permission.reply`, `question.list`, `question.reply`, `question.reject`.

Společný klient používá stejné ověřené payloady obou verzí. V obou source commitech `session/llm/request.ts::resolveTools` filtruje final request přes `Permission.disabled(Object.keys(tools), Permission.merge(agent.permission, session.permission))`; tento call path a mapování `edit/write/apply_patch -> edit` zmraz contract/source test. `v1.18.9` navíc mapuje MCP resource tools na permission `read` a může emitovat `message.part.delta`, `session.diff` a `session.error`; MCP zůstává preflight-disabled a parser extra eventy přijme jen diagnosticky. F02 completion nesmí záviset na jejich existenci. `attach --dir`, Basic auth env, health, Session metadata/permission, `msg_<ULID>`, `parentID` a `info.structured` jsou pro oba profily společné. Jakýkoli další rozdíl objevený při capture fixtures musí být explicitní položka profilu a test, ne `if response.foo ~= nil` guessing.

## Datové kontrakty F01-F02

Implementuj Lua typy z architektury bez dalšího persistentního stavu:

- `Runtime.state`: pouze `starting -> ready -> stopping -> stopped`; startup failure jde přes rollback do `stopped` s error metadata.
- `Session`: `id`, `root`, `title`, `short_id`, `active_job_key`, `last_job_state`; F02 zakládá novou Session pro každý Plan, reuse až F07.
- `Job.key = sessionID .. ":" .. userMessageID`; Plan má `mode="plan"`, target buffer/path, assistant ID set a stav `running|completed|cancelled|error`.
- Session metadata přesně `{client="opencode.nvim-inline", contract_version=2, root_hash=<sha256>}`.
- Permission rules zachovej v pořadí z architektury. Vytvoř Session rovnou s metadata a rules; PATCH a GET použij jako verification. Protože PATCH permissions appenduje, nikdy jej nepoužívej jako domnělé nahrazení rules.
- Client error vrací pouze `error_class`, endpoint a status; response body s potenciálním obsahem se neloguje.

## Vertikální implementační kroky

### 1. Import a spustitelný test harness

1. Importuj upstream baseline beze změn a ověř `stylua --check .` a LuaLS.
2. Přidej pinovaný `mini.test` harness: `tests/minimal_init.lua`, `tests/helpers/child.lua`, `tests/helpers/fake_opencode.lua`, `tests/unit/`, `tests/integration/`, `tests/contract/`, `tests/e2e/` a `tests/fixtures/`.
3. Fake OpenCode musí umět zachytit headers/body, streamovat skutečné SSE frames, zpozdit response, ukončit stream/proces a vrátit programovatelný `/doc`/`/config`. Testy nesmějí obcházet client ani root header.
4. Ulož oba reálně získané `/doc` soubory jako `tests/fixtures/opencode-1.17.3-doc.json` a `opencode-1.18.9-doc.json`; vedle ulož commit, capture command a SHA-256. Fixture se v testu nikdy negeneruje.
5. Přidej `.github/workflows/test.yml` s Neovim `0.11.0`, unit/integration/contract jobs a maticí obou OpenCode binárek pro real smoke/e2e. Installer musí po instalaci ověřit `opencode --version`; release gate nesmí skipnout jeden profil.

Ověření kroku: prázdný sample test projde headless, fake server prokáže raw header capture a contract test vypíše všechny required operation IDs pro oba fixtures.

### 2. Canonical root a pre-spawn guard

1. Implementuj root precedence přes aktivní file buffer: jednoznačný LSP workspace obsahující file, nejbližší Git worktree, potom cwd obsahující file. Každý kandidát projde absolute realpath a component-safe containment; ambiguity skončí před Runtime.
2. Implementuj neprováděný JSON/JSONC parser: lexer odstraní comments a trailing commas pouze mimo strings, potom použije `vim.json.decode`. Parse error je hard failure, ne ignorovaný config.
3. Prohledej dokumentované global, project ancestor, `~/.opencode`, `OPENCODE_CONFIG`, `OPENCODE_CONFIG_DIR` a inline config zdroje bez importu kódu. Ignoruj `plugin`, executable `plugin/plugins` a MCP entries; odmítni `tool/tools` definitions.
4. Loguj pouze config scope a error class, nikdy celý config nebo absolutní home path.

Ověření kroku: unit tabulka symlink/root precedence, JSONC string/comment edge cases a fixture každého zakázaného config zdroje; integration důkaz, že marker custom toolu se při guardu neprovede.

### 3. Vlastněný Server, manifest a compatibility preflight

1. Získej port pomocí loopback bindu na port `0`, zavři probe a spawnuj `opencode serve --hostname 127.0.0.1 --port <port>` s `cwd=root` a auth pouze v env.
2. Ihned po spawn atomicky zapiš mode-0600 manifest pod `stdpath("state")/opencode.nvim/runtimes/<root-hash>.json`. Obsahuje schema version, root hash, port, username/password, nonce, Server PID/start identity a později TUI identity.
3. `ownership.lua` implementuje process identity adapter pro podporovaný OS; cleanup signalizuje proces pouze při shodě PID start identity, executable, authenticated health a `/path.directory` realpath. Nejistota ponechá manifest a vrátí manual-cleanup diagnostiku.
4. Polluj jen vlastní health do defaultních 10 s. Po health vyber exact compatibility profil, ověř fixture operation IDs/schema a `/path` root.
5. Načti `/config`; odmítni enabled `tools` klíč neznámý exact compatibility profilu, ale pluginy a MCP entries nech OpenCode-owned. Explicitní konfigurace známého built-in toolu sama o sobě není custom tool a její execution policy nadále určuje Session hard deny. `/mcp` nevolej.
6. Každá chyba provede idempotentní rollback jen vlastních handles a temp dat. Žádný fallback URL.

Ověření kroku: owned fake process dosáhne `ready`; wrong version/doc/config, timeout a partial spawn skončí `stopped`; foreign PID reuse fixture není signalizována. Tím uzavři F01 server část `AC-RUN-02/03/04/07/09`.

### 4. TUI sidebar, input lock a F01 shutdown

1. Po úspěšném Server preflightu vytvoř terminal buffer a spusť právě jeden `opencode attach http://127.0.0.1:<port> --dir <root>` se stejným cwd/auth env. Doplň TUI identity do manifestu atomickou náhradou.
2. `sidebar.lua` vlastní jediný pravý window, default width `floor(columns*0.30)`, konfigurovatelný za běhu. Show nesmí změnit current source window; explicit focus smí změnit focus.
3. Buffer-local mappings, `TermEnter`, `BufEnter` a `ModeChanged` vrací TUI do Terminal-Normal. Neposkytuj `nvim_chan_send`, insert ani TUI command mapping. Scroll funguje standardní Terminal-Normal navigací.
4. Normal shutdown: `stopping`, ukončit TUI, Server, SSE, temp data, pak jen ověřený manifest a `stopped`. Registruj idempotentní `VimLeavePre` pro tento jeden Runtime.

Ověření kroku: integration test počítá jeden attach, testuje `startinsert`, toggle/focus a source focus; shutdown neukončí vedlejší fake process. F01 je hotová až po průchodu všech vlastněných AC.

### 5. Session, Job a read-only Plan dispatch

1. Public API dočasně podporuje `ask(default?, {mode="plan"})`, `prompt(text, {mode="plan"})`, `select`, `operator` a `format`; Build se do F03 odmítne jako unavailable. Odstraň public external-server a TUI-command akce, bez backward-compat wrapperu.
2. Input před otevřením zachytí immutable source window, buffer, cursor a explicitní invocation range. Prompt title/prefix ukáže `Plan`, root basename a active location; history je vypnutá.
3. Po preflightu vytvoř Session s metadata a exact permission rules. Ověř vrácený root/metadata/rules, model-facing tool mapu bez hard-denied/unknown tools a fresh approval předpoklad tím, že hard-denied pokus neotevře managed permission dialog.
4. Vygeneruj validní `msg_<ULID>`, založ Job a `Session.active_job_key`, potom teprve odešli `prompt_async` s `agent="plan"`, `parts` a bez structured format.
5. SSE router je Runtime-local. První assistant `message.updated` přijme jen při shodě `sessionID` a `parentID`, zaregistruje assistant ID; part eventy přijme jen přes tuto mapu. `session.idle` dokončí Plan právě jednou po načtení exact messages. Late/unknown event nic neaplikuje.
6. Plan nikdy nevytvoří proposal. Terminal transition uvolní Session a odstraní Job-owned transient data, ale Session nemaže.

Ověření kroku: fake-server integration zachytí registraci před immediate SSE, agent `plan`, nové message ID a nulový source write; instrumentovaný model/provider fixture prokáže nepřítomnost `edit/write/apply_patch/bash/task` i unknown toolu a execution pokus skončí deny. Předvyplněný Server-wide edit approval nesmí surface změnit. `AC-MODE-01` musí mít real-binary důkaz pro oba profily.

### 6. Kontext a atomický dirty preflight

1. Validuj target dříve než Runtime/Session/Job: listed normal file buffer, canonical existing regular file, UTF-8 bez NUL, ne terminal/help/scratch/unnamed.
2. Zachovej `@this`, `@buffer`, `@buffers`, `@visible`, `@diagnostics`, `@quickfix`, `@marks`. Aktivní location přidej vždy právě jednou. File-backed context serializuj jako root-relative path/range; non-file metadata smí zůstat textem jen uvnitř diagnostics/quickfix.
3. `@this` používá explicitně zachycený invocation range nebo cursor a nikdy neurčuje budoucí hard scope. Completion context ukládej podle input bufnr v `ui/ask`, ne do `Context.current`.
4. Prompt začínající rozpoznaným `/name` odmítni před Session/Job. Skills a `AGENTS.md` neinjektuj.
5. Shromáždi target a explicitní file-backed references, deduplikuj podle canonical path a snapshotni dirty set. Build je automaticky uloží; Plan nabídne přesně save-and-continue/cancel.
6. Save prováděj běžným `:write` po jednom v deterministickém pořadí. Jakékoli selhání zastaví dispatch; již zapsaný buffer nelze vrátit, proto UI předem ukáže celý set. Po každém write vyžaduj `modified=false` a logical buffer=disk. Kontext/Base čti až po všech hooks.

Ověření kroku: tests pro všechny placeholders, stale marks, unsupported buffers, cancel, druhý write failure a `BufWritePre` mutaci. Žádný cancel/failure nevytvoří prompt ani Job.

### 7. Plan tracer a sidebar completion

1. Otevři sidebar při dispatchi bez focus steal, zobraz Plan transcript a dovol toggle/focus při zachování input locku.
2. Completion/error se stane terminálním právě jednou; HTTP 204 neznamená dokončení, autorita je correlated event plus exact message reconciliation.
3. Pro oba real OpenCode profily proveď Plan s file location a read-only tool use. Provider-dependent e2e může používat release credential, ale release evidence nesmí být nahrazena fake serverem.
4. Po traceru spusť F01 regrese a celý F02 owned set.

## Povinné testy a exit gate

| Vrstva | Minimální důkaz |
|---|---|
| Unit | roots/realpath, JSONC guard, manifest identity, profile selection, SSE frame parser, ULID/Job key, permission ordering, context rendering |
| Neovim integration | terminal lock, sidebar focus/width, dirty writes/hooks, unsupported buffers, Job-before-dispatch, idempotent completion/shutdown |
| Contract | Oba frozen `/doc` fixtures, required operation IDs/schema, headers, create/PATCH Session, prompt payload, exact messages a SSE fields |
| End-to-end | Owned serve+attach+Plan+shutdown pro `1.17.3` i `1.18.9` |
| Failure injection | timeout, bad doc/config, PID reuse, TUI spawn failure, immediate/late SSE, write failure, HTTP error, source-write attempt |

F01 vlastní `AC-RUN-02`, `AC-RUN-03`, `AC-RUN-04`, `AC-RUN-07`, `AC-RUN-09`. F02 vlastní `AC-RUN-01`, `AC-UI-02`, `AC-CTX-01`, `AC-CTX-02`, `AC-CTX-03`, `AC-CTX-04`, `AC-CTX-06`, `AC-MODE-01`. Z kombinovaného `AC-CTX-05` zde pokryj Plan a obecné target typy; Build/blockwise uzavře F03.

Požadované příkazy musí být zapsané v maintainer dokumentaci harnessu a CI je musí volat shodně: StyLua, LuaLS, unit, integration, contract `OPENCODE_VERSION=1.17.3`, contract `OPENCODE_VERSION=1.18.9`, real e2e pro oba profily.

## Observability a privacy

Každý lifecycle a Job transition loguj přes `log.lua` pouze jako timestamp, level, root hash, Runtime state, short Session/Message ID, endpoint/status a error class. Test vloží unikátní secrets do root path, credentials, promptu a response a prohledá log. Do notification neposílej response body ani absolutní path.

## Mimo fázi

Build, hard scope, structured proposal, merge/aplikace, conflict UI, managed questions/permissions, Session reuse/picker, paralelní Joby, reconnect a více Runtime. Neimplementuj sem obecný compatibility framework, external Server attach, prompt history, write/reload fallback ani vlastní transcript renderer.

## Stop conditions

- Frozen `/doc` fixture neodpovídá source commitu nebo se required route mezi profily liší bez explicitně popsaného adapteru.
- Stock binary při fresh owned startupu obsahuje předchozí approval state nebo hard-denied operace projde execution-time kontrolou.
- Process ownership nelze na podporované platformě bezpečně ověřit; nesnižuj gate na PID-only.
- Snacks input/picker nebo terminal API nelze na Neovim `0.11.0` automatizovaně ověřit.
- Implementace by musela logovat content nebo použít foreign discovery, `/mcp`, `checktime`, write/reload či TUI input.

Při stop condition neopravuj kontrakt v kódu. Zastav session, uveď konkrétní fixture/source rozpor a vyžádej změnu autoritativních dokumentů.
