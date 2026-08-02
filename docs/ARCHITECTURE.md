# Architektura inline workflow forku `opencode.nvim`

## Stav a autorita

| Položka | Hodnota |
|---|---|
| Stav | Implementačně závazný technický návrh |
| Verze | 1.0 |
| Aktualizováno | 30. 7. 2026 |
| Produktový kontrakt | `docs/PRD.md` |
| Ověření | `docs/ACCEPTANCE.md` |
| OpenCode baselines | `v1.17.3` (`8c8011336163d7e7fb24a6a4a049cdb1f6e6ee74`) a `v1.18.9` (`4da7bb44c84e013fa53e9c5d02ac753d1435c81a`) |
| Upstream plugin baseline | commit `7749a034db61258ece828df70a89ff31bb27ff47` |

Tento dokument uzavírá implementační rozhodnutí pro verzi 2.0. Neobsahuje volby, které má implementátor rozhodnout podle osobní preference. Změna zde uvedeného kontraktu vyžaduje současnou změnu PRD a acceptance scénářů.

## Závazná rozhodnutí

| ID | Rozhodnutí |
|---|---|
| ADR-01 | Každý canonical project root má vlastní plugin-owned headless Server a právě jeden plugin-owned TUI klient. |
| ADR-02 | Scoped Build je proposal transaction; OpenCode nesmí přímo editovat source workspace. |
| ADR-03 | Build proposal používá OpenCode JSON-schema structured output, ne parsování volného Markdown diffu. |
| ADR-04 | Build a Plan Session používají default-deny tool allowlist; custom tools nejsou v Runtime povolené, zatímco pluginy a MCP zůstávají OpenCode-owned. |
| ADR-05 | Build hard scope je vždy visual range, Tree-sitter function nebo celý aktuální soubor. |
| ADR-06 | Job identita je `sessionID + userMessageID`; plugin registruje každou assistant message přes její `parentID`. |
| ADR-07 | Session nepoužívají Job queue. Aktivní Session odmítne follow-up a nabídne novou Session. |
| ADR-08 | Aktivní překrývající se scopes ve stejném bufferu jsou odmítnuty při dispatchi. |
| ADR-09 | Scope violation odmítne celý proposal před merge. |
| ADR-10 | Merge backend je non-destructive `git merge-file -p` nad Base/Ours/Theirs. |
| ADR-11 | Čistý merge se aplikuje jednou minimální changed-span API operací, bez write a reloadu. |
| ADR-12 | Konfliktní Ours/Theirs volba řeší všechny conflict hunks souboru, ale zachovává nekolizní změny obou stran. |
| ADR-13 | Specializovaný Review, scaffold, multi-file Build a worktrees jsou deferred. |

## Systémový přehled

```text
Neovim
  Runtime registry (canonical project root -> Runtime)
    Runtime
      owned OpenCode Server (HTTP + SSE)
      owned OpenCode TUI client (shared right tmux pane)
      Session registry
        Session -> zero/one active Job
      Job registry (sessionID + userMessageID)
      dialog queue
  Scope resolver + extmarks
  Structured proposal validator
  Base/Ours/Theirs merge engine
  Buffer applier
  Prompt float / tmux pane / status UI
```

Server je headless HTTP proces. Build/Plan prompt je float a nepoužívá TUI keyboard emulaci; používá Session HTTP API. TUI je jeden sdílený pravý tmux pane pro všechny rooty, připojený s auth a canonical root cwd. Pane je input-locked a slouží jako transcript renderer; přepnutí Session přes `/tui/select-session` se používá jen když pane existuje.

## Kompatibilita a API baseline

Minimální editor baseline je Neovim `0.11.0`. `snacks.nvim` s aktivním `input` a `picker` je hard dependency; chybějící Tree-sitter parser je pouze function-scope capability warning, protože file scope zůstává dostupný. Release MUSÍ obsahovat alespoň Lua function-scope adapter použitý v acceptance fixture.

### Pin

Implementace podporuje pouze dva explicitní OpenCode compatibility profily:

- `v1.17.3`, commit `8c8011336163d7e7fb24a6a4a049cdb1f6e6ee74`,
- `v1.18.9`, commit `4da7bb44c84e013fa53e9c5d02ac753d1435c81a`.

Nejde o semver rozsah ani best-effort legacy fallback. Každý profil má vlastní neměnný `/doc` fixture a contract suite. Runtime před prvním promptem:

1. zavolá `GET /global/health`,
2. ověří přesnou verzi `1.17.3` nebo `1.18.9` a vybere odpovídající compatibility profil,
3. načte `GET /doc`,
4. ověří přítomnost a očekávané request/response schema všech operací daného profilu uvedených níže,
5. při neshodě skončí fail-closed compatibility chybou.

Žádný best-effort fallback na neznámý payload nebo endpoint není povolen. Rozdíl mezi dvěma podporovanými profily smí řešit pouze explicitní, contract-testovaný adapter vybraný podle přesné health verze. Upgrade OpenCode vyžaduje nový ověřený baseline a contract fixture.

### Tmux pane

Runtime a health ověřují `$TMUX`, `$TMUX_PANE`, executable tmux a jeho verzi. Mimo tmux nebo bez platného cílového pane startup failuje jasnou chybou, protože Plan a ruční show/focus používají sdílený pane. Plugin tmux konfiguraci nemění. Sdílený TUI pane je input-locked; Plan do něj po ověření živého pane vybere transcript, ale neukradne focus source window.

### Prompt float

Build i Plan používají víceřádkový `Snacks.win` s upstream-like ikonou a stylem. Prompt zobrazuje kompaktní režim, jméno project rootu a effective scope bez absolutní cesty; krátké stavové texty jsou pouze dočasné. `<CR>` odešle prompt nebo přijme viditelnou completion, `<C-j>` vloží newline a `<Esc>` prompt zruší. Input history je vypnutá.

### Použité endpointy

| Účel | Metoda a cesta |
|---|---|
| Health a verze | `GET /global/health` |
| OpenAPI kontrakt | `GET /doc` |
| Routed path identity | `GET /path` |
| Effective config | `GET /config` |
| Instance SSE | `GET /event` |
| Agent inventory | `GET /agent` |
| Session inventory | `GET /session` |
| Vytvoření Session | `POST /session` |
| Session permission/profile metadata | `PATCH /session/:sessionID` |
| Session statusy | `GET /session/status` |
| Session detail | `GET /session/:sessionID` |
| Session messages | `GET /session/:sessionID/message` |
| Konkrétní message | `GET /session/:sessionID/message/:messageID` |
| Async prompt | `POST /session/:sessionID/prompt_async` |
| Abort | `POST /session/:sessionID/abort` |
| Přepnutí TUI transcriptu | `POST /tui/select-session` |
| Pending permissions | `GET /permission` |
| Permission reply | `POST /permission/:requestID/reply` |
| Pending questions | `GET /question` |
| Question reply | `POST /question/:requestID/reply` |
| Question reject | `POST /question/:requestID/reject` |

Deprecated `POST /session/:id/permissions/:permissionID` se nepoužije. `file.edited` ani Session diff nejsou autoritou pro Theirs, protože source edit tools jsou zakázané.

Managed input nepoužije `POST /session/:id/command`. OpenCode command templates mohou expandovat shell části před agentním permission flow, což není kompatibilní s proposal-only boundary. Prompt začínající rozpoznaným `/command` se před Job registrací odmítne jako unsupported.

Každý request v této tabulce, včetně `/event`, `/permission`, `/question` a `/config`, MUSÍ nést HTTP header `x-opencode-directory: <canonical-root>`. Session-specific request navíc musí projít kontrolou, že vrácená `Session.directory` odpovídá stejnému rootu. Process cwd je pouze defense-in-depth fallback, nikoli implicitní routing kontrakt.

### Prompt payload

Plugin vytvoří OpenCode-kompatibilní user `messageID` ve formátu `msg_<ULID>` a odešle jej v `prompt_async`. Payload obsahuje:

```json
{
  "messageID": "msg_<ULID>",
  "agent": "build",
  "format": {
    "type": "json_schema",
    "schema": {}
  },
  "parts": []
}
```

Oba podporované OpenCode profily přijímají user `messageID` začínající `msg`, podporují `format.type = json_schema` a uloží validní výsledek do structured části nové assistant message. Assistant message má vlastní ID a `parentID` rovný pluginem dodanému user message ID. Deprecated prompt field `tools` se nepoužije, protože mění Session permissions nepřesným wildcard způsobem.

Plugin neposkytuje vlastní model picker. U nové Session nechá model vyřešit pinovaný OpenCode default; u reusable Session ponechá její uložený model. `agent` se naopak posílá explicitně pro každý Job, takže Plan-to-Build přechod nemění model ani transcript.

## Runtime model

### Runtime registry

Canonical root se určí v tomto pořadí:

1. Neovim LSP/workspace root pro aktivní file buffer, pokud jednoznačně obsahuje soubor,
2. nejbližší Git worktree root,
3. aktuální working directory obsahující soubor.

Výsledek se normalizuje přes absolutní realpath. Symlinkované cesty ke stejnému rootu nesmí vytvořit dva Runtime.

Každý Runtime obsahuje:

```lua
Runtime = {
  root = string,
  state = "starting" | "ready" | "disconnected" | "stopping" | "stopped",
  host = "127.0.0.1",
  port = integer,
  username = "opencode",
  password = string,
  owner_manifest = string,
  owner_nonce = string,
  server_process = handle,
  tui_process = handle,
  tui_buffer = bufnr,
  tui_status = "stopped" | "starting" | "live" | "dead" | "recovering" | "error",
  sse = handle,
  sse_live = boolean,
  prompt_blocker = function -> nil | "starting" | "reconciling" | "interaction_locked" | "disconnected" | "reconciliation_failed" | "reconciliation_blocked" | "tui_unavailable",
  sessions = {},
  jobs = {},
}
```

### Bezpečný startup

1. Passive config guard bez spuštění OpenCode načte dokumentované JSON/JSONC config soubory a pouze názvy souborů v global, project a `OPENCODE_CONFIG_DIR` adresářích. Ignoruje custom `plugin/plugins` a MCP entries, ale odmítne `tool/tools` JavaScript/TypeScript definice.
2. Vybere se volný loopback port přidělený operačním systémem.
3. Vygeneruje se kryptograficky náhodné heslo a owner nonce.
4. Server se spustí s process working directory přesně nastaveným na canonical root, ekvivalentem:

```text
OPENCODE_SERVER_PASSWORD=<secret>
opencode serve --hostname 127.0.0.1 --port <port>
```

5. Ihned po spawn se atomicky zapíše private ownership manifest mode `0600` obsahující root hash, port, username, password, owner nonce, PID a process start identity; manifest path je pod `stdpath("state")/opencode.nvim/runtimes/`.
6. Jeden konfigurovatelný deadline, výchozí 10 sekund, ohraničuje celý startup od health pollu po reconciliation.
7. Proběhne version, `/doc` a effective `/config` preflight. Effective config odmítne pouze enabled tools mimo exact compatibility profil; pluginy a MCP entries nechá OpenCode-owned. Endpoint `/mcp` se při preflightu nesmí volat, protože by MCP inicializoval.
8. `/agent` musí vrátit oba primary agenty `build` a `plan`; chybějící agent ukončí startup fail-closed.
9. SSE je live až po prvním garantovaném `server.connected`; samotný spawn `curl` nestačí.
10. Proběhne inventory a initial reconciliation. Teprve po jejich úspěchu Runtime přejde do `ready` a přijímá prompty.

TUI není součástí startupu ani readiness. Plan nebo ruční show/focus později vytvoří sdílený tmux pane a spustí v něm `opencode attach http://127.0.0.1:<port> --dir <canonical-root>` se stejnými auth env hodnotami. Build tento krok neprovádí.

Password, owner nonce ani authorization header se nesmí logovat. Ownership manifest se po normálním shutdownu odstraní. Plugin nesmí použít `pgrep`, `lsof`, mDNS ani server discovery.

Passive guard musí parsovat config data bez importu custom modulů a odmítnout executable soubory pouze v dokumentovaných `tool/tools` adresářích dříve, než se Server spustí. Pluginy a MCP se nekontrolují jako proposal tools; OpenCode je načítá podle vlastní konfigurace. Skills, commands, agents, providers a `AGENTS.md` zůstávají povolené a custom tool stále nesmí rozšířit proposal-only boundary verze 2.0.

### Sdílený tmux pane a více rootů

Runtime každého rootu sdílí jeden pravý tmux pane. Pane se vytváří lazy, jen pro Plan nebo ruční show/focus, a drží 70:30 split vůči aktuálnímu `$TMUX_PANE`. Přepnutí aktivního project rootu pouze přepne obsah pane; procesy a Joby ostatních Runtime pokračují a nejvýše jeden pane existuje.

### Shutdown a crash

`VimLeavePre` provede pro každý Runtime:

1. označení `stopping`,
2. abort aktivních Session,
3. odstranění sdíleného TUI pane, pokud tento Runtime drží jeho znovu ověřenou identitu,
4. ukončení Server child procesu,
5. cleanup merge/proposal temp souborů,
6. odstranění ownership manifestu,
7. označení `stopped`.

Při příštím startupu plugin zpracuje stale manifests před vytvořením nového Runtime. Starý Server je považován za vlastněný pouze pokud současně sedí PID start identity, executable, authenticated health na uloženém portu a canonical root vrácený serverem. TUI vyžaduje shodnou PID start identity, executable a manifest vazbu na ověřený Server. Jen potom smí plugin procesy ukončit. Pokud ownership nelze prokázat, proces se nesignalizuje, manifest se ponechá pro diagnostiku a health zobrazí manuální cleanup instrukci.

TUI-only crash nemění Server ani Job state. Runtime skryje mrtvý pane, spustí nový `attach --dir` proti stejnému Serveru a přes `/tui/select-session` obnoví zobrazenou Session jen když pane existuje. Server crash nastaví Runtime `disconnected`; pending proposal a Base zůstávají lokálně, nic se neaplikuje a restart vyžaduje plnou Server reconciliation.

## Permission model

Každá plugin Session se vytvoří nebo okamžitě patchne s pravidly aplikovanými za agent defaults. Pravidla jsou ordered a pinovaná verze používá last matching rule:

```json
[
  { "permission": "*", "pattern": "*", "action": "deny" },
  { "permission": "read", "pattern": "*", "action": "allow" },
  { "permission": "read", "pattern": "*.env", "action": "deny" },
  { "permission": "read", "pattern": "*.env.*", "action": "deny" },
  { "permission": "read", "pattern": "*.env.example", "action": "allow" },
  { "permission": "glob", "pattern": "*", "action": "allow" },
  { "permission": "grep", "pattern": "*", "action": "allow" },
  { "permission": "lsp", "pattern": "*", "action": "allow" },
  { "permission": "skill", "pattern": "*", "action": "allow" },
  { "permission": "question", "pattern": "*", "action": "allow" },
  { "permission": "StructuredOutput", "pattern": "*", "action": "allow" },
  { "permission": "webfetch", "pattern": "*", "action": "ask" },
  { "permission": "websearch", "pattern": "*", "action": "ask" },
  { "permission": "doom_loop", "pattern": "*", "action": "ask" },
  { "permission": "edit", "pattern": "*", "action": "deny" },
  { "permission": "bash", "pattern": "*", "action": "deny" },
  { "permission": "task", "pattern": "*", "action": "deny" },
  { "permission": "external_directory", "pattern": "*", "action": "deny" }
]
```

Session-level pravidla v pinované verzi převažují nad permissive Build defaults. Initial wildcard deny blokuje neznámé tools; následující pravidla otevírají pouze známé read-only schopnosti, user interaction a interní `StructuredOutput` tool. Závěrečné hard deny zakážou `edit`, `write`, `apply_patch`, shell side effects, subagenty a přístup mimo root. Build zůstává primary agentem, ale modifikuje kód pouze proposalem, který aplikuje Neovim plugin.

Oba podporované profily před odesláním requestu do LLM filtrují finální modelovou tool mapu přes `Permission.disabled` nad sloučenými agent a Session rules. Initial wildcard deny proto odstraní neznámé/custom/MCP tools a explicitní hard deny odstraní `edit`, `write`, `apply_patch`, `bash` a `task`; pozdější allow pravidla zachovají jen výslovně povolené capabilities a `StructuredOutput`. Server-wide `always` approvals do tohoto surface filtru nevstupují a nemohou zakázaný tool znovu zpřístupnit. Execution-time hard deny uvnitř izolovaného plugin-owned Serveru zůstává druhou obrannou vrstvou: Server začíná s prázdným approval state, passive a effective config guard vyloučí custom tools, ale pluginy a MCP pouze nechají OpenCode-owned a neinicializují `/mcp`; permanentně input-locked TUI nemůže založit unmanaged approval. Managed dialog smí nabídnout `always` pouze pro schvalovatelnou permission explicitně allowlisted toolu; `read` a `external_directory` se omezí na `once` nebo `reject`. Nečekaný permission request pro hard-denied nebo neznámou capability se bez dialogu odmítne a vyvolá fail-closed diagnostiku.

Hard deny se nikdy nezobrazí jako schvalovatelný dialog. Ostatní OpenCode permission requesty používají kanonický `/permission` endpoint. Plugin podporuje odpovědi obou compatibility profilů `once`, `always`, `reject` s výše uvedeným omezením; žádná podporovaná UI cesta nesmí vytvořit approval pro hard-denied capability ani obejít path-level deny managed Session.

Plan používá stejný Session hard deny. Built-in výjimky pro plan files jsou tím přepsány, takže Plan nemůže zapisovat ani `.opencode/plans`.

## Datový model

### Session

```lua
Session = {
  id = sessionID,
  root = string,
  title = string,
  short_id = string,
  active_job_key = nil | string,
  last_job_state = nil | JobState,
}
```

Session availability se odvodí:

```text
active(jobID)  pokud active_job_key ukazuje na neterminální Job
reusable       pokud active_job_key je nil a OpenCode status je idle
```

OpenCode `busy` bez lokálního `active_job_key` je contract violation. Runtime v takovém případě zablokuje nové prompty a spustí reconciliation; nesmí vytvořit implicitní Job. Permanentní TUI input lock zabraňuje vzniku takového turnu přes podporované UI.

Každá nová Session se vytvoří s metadata markerem:

```json
{
  "client": "opencode.nvim-inline",
  "contract_version": 2,
  "root_hash": "<sha256 canonical root>"
}
```

Runtime registry spravuje a nabízí k reuse pouze Session se správným `client`, podporovaným `contract_version`, odpovídajícím `root_hash` a bez archive timestampu. Session bez markeru je cizí i tehdy, když ji vrací stejný Server. Plugin-managed Session se nikdy automaticky nemaže; uživatel ji může archivovat nebo smazat explicitně přes podporované Session UI.

Před každým promptem, včetně reuse po restartu, plugin přes `PATCH /session/:sessionID` znovu připojí přesný ordered permission profile a přes `GET /session/:sessionID` ověří ownership metadata i výsledná rules. Oba podporované profily používají append-only PATCH a last-match evaluation, proto bezpečná revalidace znamená, že vrácený ruleset končí přesně požadovanou sekvencí a za ní není žádné další pravidlo; starší prefix je touto sekvencí přestíněn. Plugin nesmí předstírat replacement ani přijmout pouze množinovou shodu. Teprve potom registruje a dispatchuje Job.

### Job

```lua
Job = {
  key = sessionID .. ":" .. userMessageID,
  session_id = sessionID,
  user_message_id = userMessageID,
  assistant_message_ids = Set<assistantMessageID>,
  structured_assistant_message_id = nil | assistantMessageID,
  root = string,
  mode = "build" | "plan",
  state = JobState,
  waiting_kind = nil | "question" | "permission",
  conflict_kind = nil | "agent" | "external_change",
  buffer = bufnr,
  path = canonical_path,
  base = Snapshot,
  scope = BaseScope,
  marks = ExtmarkPair,
  proposal = nil | Proposal,
  merge_disk_sha256 = nil | string,
  created_at = monotonic_time,
}
```

Plan Job nemá `base`, `scope`, `marks` ani `proposal` povinné. Build Job je musí mít před dispatchí.

### Snapshot a scope

Buffer logical text se kanonizuje přesně jako `table.concat(nvim_buf_get_lines(buf, 0, -1, false), "\n")`. Syntetický terminální diskový line ending není součástí `Snapshot.text`; `fileformat`, `endofline` a `fixendofline` jsou samostatná immutable metadata transakce. Tím se rozliší empty file, terminální newline a skutečný trailing empty buffer line. Plugin tato options během proposal ani aplikace nemění.

```lua
Snapshot = {
  text = string,
  sha256 = string,
  changedtick = integer,
  fileformat = string,
  endofline = boolean,
  fixendofline = boolean,
}

BaseScope = {
  kind = "range" | "function" | "file",
  path = canonical_path,
  start_byte = integer,
  end_byte = integer,
}
```

Rozsah je half-open `[start_byte, end_byte)` v kanonickém Base textu. File scope je `[0, #base.text)`. Empty file má text `""` a file scope `[0, 0)`; insertion replacement na této pozici je povolená.

Disk fingerprint je SHA-256 raw file bytes. Pro srovnání s logical buffer textem se raw bytes dekódují podle zachyceného `fileformat`, odstraní se právě jeden syntetický terminální line ending, pokud existuje, a zbytek se převede na LF logical text. Proposal replacement musí být validní UTF-8 bez `\r`; agent nesmí změnit EOL metadata. Při aplikaci se merged logical text rozdělí na Neovim lines podle `\n`, přičemž `""` vytvoří jediný empty buffer line a trailing `\n` v logical text vytvoří skutečný trailing empty line. Zachycené buffer options zůstávají beze změny.

## Scope resolution a extmarky

### Resolution

1. Visual/operator mapping předá explicitní invocation range; plugin nikdy zpětně nečte stale marks.
2. Bez explicitního range resolver vystoupá Tree-sitter stromem k nejbližšímu podporovanému function/method node.
3. Bez nalezené funkce se použije celý file buffer.
4. Input selector může před dispatchí rozšířit range/function na file.

Characterwise a linewise selection se převedou na jeden half-open byte range. Blockwise selection se odmítne před otevřením Build Jobu, protože proposal schema verze 1 reprezentuje právě jeden souvislý range.

Tree-sitter node typy jsou language adapter data, nikoli hardcoded univerzální seznam v resolveru. Nepodporovaný parser bezpečně padá na file scope.

### Extmarky

Build vytvoří start a end extmark ve vlastním namespace:

- start používá `right_gravity = false`,
- end používá `right_gravity = true`,
- highlight pokrývá current range mezi nimi.

Extmarky sledují umístění scope v Ours a slouží pro UI, overlap detection a obnovu view. Nejsou autoritou pro Base-to-Theirs autorizaci. Ztráta nebo invalidace extmarku ukončí Job `error` bez aplikace.

### Overlap detection

Před Build dispatchí plugin porovná current half-open extmark ranges všech aktivních Build Jobů ve stejném bufferu. Průnik odmítne nový Job s UI odkazem na existující Session. Dotýkající se, ale nepřekrývající ranges jsou povolené.

Stejná kontrola proběhne znovu po zachycení Ours před každou automatickou aplikací. Pokud uživatel mezitím editací ranges překryl nebo některý zkolaboval do neplatné polohy, celý proposal se bez aplikace odmítne a Job skončí `scope_violation`. Uživatel může po ustálení rozsahů založit nový Job.

## Dirty-buffer preflight a Base

Preflight zahrnuje target a všechny explicitně expandované file-backed context references. Dirty buffery se zpracují podle režimu:

- Build je automaticky uloží běžným write se standardními write autocmds.
- Plan je zobrazí v jednom nativním dialogu:

```text
save and continue
cancel
```

Build i volba `save and continue` provedou běžný write se standardními write autocmds. Po každém write:

1. write musí skončit úspěšně,
2. buffer nesmí zůstat `modified`,
3. disk a logický buffer obsah se musí shodovat po respektování `fileformat`,
4. Base se zachytí z finálního buffer textu po všech write hooks.

Jakékoli selhání zastaví celý dispatch. Plugin neprovádí částečný save-and-send.

Unnamed, terminal, help, scratch, binary/NUL a non-UTF-8 buffer není target pro Build ani Plan. Takový buffer se neserializuje jako skrytý fallback. Non-file položky uvnitř explicitních diagnostik nebo quickfix metadata smějí zůstat textovým kontextem, ale nikdy nenahrazují povinnou aktivní file location.

## Structured Build proposal

### Schema

Build prompt používá přesné JSON schema bez dalších properties:

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["version", "path", "base_sha256", "scope", "replacement", "summary"],
  "properties": {
    "version": { "const": 1 },
    "path": { "type": "string" },
    "base_sha256": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
    "scope": {
      "type": "object",
      "additionalProperties": false,
      "required": ["start_byte", "end_byte"],
      "properties": {
        "start_byte": { "type": "integer", "minimum": 0 },
        "end_byte": { "type": "integer", "minimum": 0 }
      }
    },
    "replacement": { "type": "string" },
    "summary": { "type": "string" }
  }
}
```

Prompt poskytne canonical relative path, Base SHA-256, Base scope byte offsets, path/range reference a instrukci, že `replacement` je úplný nový text pouze autorizovaného scope. U file scope je replacement celý soubor.

### Validace

Při každém assistant `message.updated` plugin ověří `sessionID` a `parentID`, najde Job podle `sessionID + parentID` a atomicky zaregistruje `assistantMessageID -> Job key`. Jeden agentní loop může vytvořit více assistant messages kvůli tool calls. Part eventy se smějí zpracovat až přes tuto mapu. Po `session.idle` plugin načte Session messages, mezi responses s `parentID == Job.user_message_id` vyžaduje právě jednu s validním structured objectem a její ID uloží jako `structured_assistant_message_id`. Volný text, Markdown diff ani `file.edited` není fallback.

Validátor v tomto pořadí ověří:

1. JSON schema již ověřené OpenCode,
2. `version == 1`,
3. canonical path je přesně target path a neobsahuje traversal,
4. `base_sha256` odpovídá lokálnímu Base,
5. scope offsets přesně odpovídají BaseScope,
6. replacement je validní UTF-8 text bez NUL,
7. Theirs vznikne jako `Base prefix + replacement + Base suffix`,
8. Theirs prefix před `start_byte` a suffix po nahrazeném `end_byte` jsou byte-identické s Base,
9. deterministický Base-to-Theirs change set nemá změnu mimo BaseScope.

Autoritativní change set je jedna replacement operace nad přesným BaseScope; prefix/suffix equality je byte-precise defense-in-depth a nevyžaduje line-based diff algoritmus. Neshoda path/hash/range nebo out-of-scope změna je `scope_violation`; chybějící či nevalidní structured output je `error`. V obou případech se nic neaplikuje.

## Build transakce

### Dispatch algoritmus

```text
resolve Runtime and target
resolve and display effective scope
reject overlap
run dirty-buffer preflight
capture Base and BaseScope
create extmarks
select/create reusable Session
reject Session when active or OpenCode status is unexpectedly busy
generate userMessageID and register Job(running)
POST prompt_async with agent=build and structured schema
show owned TUI without focus steal
```

Registrace Jobu musí proběhnout před HTTP dispatchí, aby okamžitý SSE event nemohl předběhnout lokální stav.

### Completion algoritmus

```text
load assistant result whose parentID equals sessionID-local userMessageID
validate structured proposal
construct Theirs
validate Base-to-Theirs scope
transition running -> pending_apply
if Insert mode: wait until InsertLeave
capture Ours + changedtick + raw disk fingerprint
run three-way merge
immediately re-read changedtick + raw disk fingerprint
if either changed: discard result and re-evaluate with new inputs
if clean: apply once and complete
if conflict: show conflict dialog and remain active
```

### Paralelní nepřekrývající se Joby

Každý Job vlastní Base, Theirs a extmarky. Příklad:

```text
Base A = F0, scope A = function A
Base B = F0, scope B = function B

apply A: merge(F0, current F0, F0+A) => F0+A
apply B: merge(F0, current F0+A, F0+B) => F0+A+B
```

Třícestný merge zachová už aplikovaný Job A jako nekolizní Ours změnu. Žádný Job nepotřebuje worktree ani přímý diskový zápis.

## Merge engine

### Backend

Plugin capability check ověří dostupnost `git merge-file` s `-p` a `--diff3`. Git repository není pro file-operand mode nutný.

Pro každý merge vytvoří private temp soubory Base, Ours a Theirs s přístupem pouze pro uživatele a spustí argv bez shell interpolace:

```text
git merge-file -p --diff3 -L Ours -L Base -L Theirs <ours> <base> <theirs>
```

Exit code `0` znamená clean merge. Kladný conflict count znamená konflikt. Process/spawn chyba znamená Job `error`. Temp soubory se odstraní po dokončení, cancelu i shutdownu.

### Konfliktní strategie

Dialog nabízí přesně:

```text
keep my changes
accept agent changes
open manual diff
```

První dvě akce znovu spustí třícestný merge s conflict preference:

```text
git merge-file -p --ours   <ours> <base> <theirs>
git merge-file -p --theirs <ours> <base> <theirs>
```

Tyto volby řeší všechny konfliktní hunks ve prospěch zvolené strany, ale zachovají automaticky sloučené nekolizní změny obou stran. Nesmí být implementovány jako raw whole-file Ours/Theirs overwrite.

Manual diff otevře read-only Base, původní Ours, Theirs a editovatelný merge-result buffer. Dokončení musí být explicitní. Zrušení zachová původní source Ours a ukončí Job `cancelled`.

## Buffer application

S Ours se atomicky v jednom scheduled callbacku zachytí `changedtick` a raw disk SHA-256. Bezprostředně před každou automatickou aplikací, Ours/Theirs conflict preference aplikací i potvrzením manual diffu plugin znovu načte obě hodnoty. Finální revalidace a `nvim_buf_set_text()` musí proběhnout ve stejném Neovim scheduled callbacku bez yield nebo dalšího async kroku. Pokud se změní buffer nebo disk, vypočtený výsledek se zahodí a Job zůstane `pending_apply` nebo `conflict`; nové rozhodnutí použije čerstvé vstupy. Plugin nikdy neaplikuje výsledek vypočtený ze stale Ours ani stale disk fingerprintu.

Před každým merge plugin načte aktuální diskový obsah targetu a porovná jej s Base a aktuálním Ours:

1. `disk == Base` znamená běžný neuložený Ours workflow,
2. `disk == Ours` znamená, že uživatel své mezilehlé změny uložil, a merge může pokračovat,
3. jiný diskový obsah znamená nezávislou external změnu; Job přejde do `conflict` s kind `external_change` a nic se neaplikuje.

External-change UI nabídne `open external diff`, `retry apply` a `cancel`. `retry apply` je povolen pouze když current disk kanonický text přesně odpovídá current Ours, takže uživatel svou reconciliaci explicitně uložil. Potom se znovu provede changedtick, disk a Base/Ours/Theirs validace. Tento dialog je oddělený od agentního merge conflict dialogu a nesmí automaticky reloadnout ani zapsat buffer.

Čistý nebo ručně vyřešený text se aplikuje:

1. pouze když buffer stále reprezentuje stejný canonical path,
2. mimo Insert mode,
3. až po druhé changedtick a disk-fingerprint kontrole,
4. výpočtem nejdelšího společného UTF-8-safe prefixu a suffixu mezi current Ours a merged result,
5. jedním `nvim_buf_set_text()` nahrazením pouze minimálního changed span mezi prefixem a suffixem,
6. bez `undojoin`,
7. bez write commandu,
8. bez `:e`, `checktime` nebo reloadu.

Prefix/suffix hranice se při byte shodě posunou na platné UTF-8 codepoint boundaries a převedou na Neovim row/byte-column souřadnice. Minimal-span mutace je povinná, protože whole-buffer replacement by zničil logické pozice extmarků ostatních paralelních Jobů. Hard scopes se nepřekrývají, proto changed span dokončeného Jobu nesmí obsahovat extmarky jiného aktivního Jobu.

Jedna API mutace vytváří jeden nový undo krok. Buffer zůstane přirozeně `modified`. Plugin uloží a obnoví `winsaveview()` pro všechna okna zobrazující buffer, cursor pozice omezí na platné line/byte columns a nechá Neovim aktualizovat extmarky. Extmarky dokončeného Jobu se odstraní až po úspěšné aplikaci; extmarky ostatních Jobů musí po mutaci stále ohraničovat stejný logický text.

## Job state machine

```text
running
  -> waiting_user(question|permission) -> running
  -> pending_apply
  -> scope_violation
  -> cancelled
  -> error

pending_apply
  -> completed
  -> conflict
  -> scope_violation
  -> cancelled
  -> error

conflict
  -> completed
  -> cancelled
  -> error
```

Terminální stavy jsou `completed`, `cancelled`, `error`, `scope_violation`. Transition musí být idempotentní. Event pro terminální Job může aktualizovat diagnostická metadata, ale nesmí změnit state ani aplikovat text.

`conflict` bez `conflict_kind` je nevalidní stav. Kind `agent` používá závazný Ours/Theirs/manual dialog. Kind `external_change` používá external diff/retry/cancel. Přechod do konfliktu atomicky uloží immutable dialog payload; zavření, cancel nebo vyřešení jej odstraní z FIFO queue právě jednou. Manual diff je pokračování stejného queued conflict requestu, nikoli nový paralelní dialog.

Session má `active_job_key` od registrace do terminálního transition včetně `pending_apply` a `conflict`. OpenCode `session.idle` tedy samo o sobě neuvolňuje Session.

## Event routing a reconciliation

### Live routing

SSE handler nejprve vybere Runtime podle streamu, potom Session a Job:

1. user-message event s `sessionID + userMessageID` vyžaduje přesný Job key,
2. assistant `message.updated` se mapuje pouze když jeho `parentID` odpovídá user message aktivního Jobu,
3. assistant part event se mapuje pouze přes již registrované `assistantMessageID -> Job key`,
4. question/permission event pouze se `sessionID` se smí přiřadit jedinému aktivnímu Jobu Session,
5. event neznámého nebo terminálního Jobu se nesmí aplikovat,
6. user/assistant event bez registrovaného Jobu zablokuje nové prompty a vyvolá reconciliation; nikdy nesmí vytvořit implicitní Job ani proposal,
7. globální mutable `current session/context` se nepoužije.

TUI select event je Runtime-local. Plugin garantuje právě jeden vlastněný TUI klient na Server, protože endpoint necílí konkrétního TUI klienta.

### Reconnect

SSE nemá garantovaný replay. Po reconnectu Runtime zablokuje nové prompty a načte:

- `GET /session/status`,
- messages aktivních Session,
- `GET /question`,
- `GET /permission`.

Pro každý lokální aktivní Job:

1. pokud Session stále běží, pokračuje se live,
2. pokud je idle a existuje právě jedna assistant response s `parentID == Job.user_message_id` a validním structured outputem, zaregistruje se její ID a pokračuje completion algoritmus,
3. pokud je idle bez prokazatelného výsledku, Job skončí `error`,
4. pending question/permission se znovu vloží do dialog queue,
5. neznámá nebo smazaná Session ukončí Job `error`.

Až po dokončení reconciliation Runtime opět přijímá prompty.

## Questions, permissions a dialog queue

Question, permission request, agentní conflict a external-change conflict se převedou na interní `DialogRequest` obsahující kind, Runtime root, Session title/short ID, Job key a případný OpenCode request ID. Jedna globální FIFO fronta serializuje modální UI napříč Runtime. Remote question/permission request má deduplicační klíč `root + sessionID + jobKey + requestID`; live event a reconciliation pending list tak vytvoří nejvýše jeden dialog a jeden reply.

Question nebo permission dialog nastaví Job `waiting_user`; conflict dialog ponechá Job v `conflict`. Odeslání reply/reject vrátí interaktivní agentní Job do `running`, pokud request Job neukončil. Zavření dialogu se mapuje na explicitní reject nebo cancel podle kind. Stejný request se při opakovaném live eventu, pending-list snapshotu nebo reconnectu pouze znovu použije; nesmí vzniknout druhý dialog ani druhá odpověď. Cancel Jobu odstraní jeho nezobrazené dialogy z fronty a odmítne právě zobrazený request, pokud patří tomuto Jobu.

### Permanentní TUI input lock a managed visibility lock

Pinovaný `opencode attach` je plný TUI a nemá transcript-only přepínač. Plugin proto po vytvoření pane trvale vynutí Terminal-Normal režim: `TermEnter` a `startinsert` pro tento pane okamžitě vrátí Terminal-Normal, pluginové mapy neposílají TUI prompt/control input a focus akce slouží pouze ke scrollu a navigaci transcriptu. Přímé `nvim_chan_send()` mimo plugin API je mimo podporovaný kontrakt.

Při managed `question.asked` nebo `permission.asked` plugin navíc ve stejném scheduled callbacku:

1. uloží, zda byl pane viditelný, a source return window,
2. nastaví Runtime `interaction_locked = true`,
3. skryje pane a zablokuje pluginové toggle/focus/select-session akce,
4. otevře autoritativní Snacks dialog z FIFO queue,
5. odešle odpověď přes canonical question/permission endpoint,
6. čeká na matching replied/rejected event nebo reconciliation potvrzení,
7. teprve potom Runtime visibility lock zruší a obnoví předchozí pane visibility jen když byl dříve viditelný; permanentní input lock zůstává.

TUI proces během visibility locku dál přijímá Server eventy, ale nemůže přijmout uživatelský input. Proto nemůže vzniknout druhá odpověď na stejný request ID. Pokud TUI proces během locku spadne, request zůstává ve Snacks queue a použije se TUI-only recovery; Server ani Job se nerestartují.

## Session identity and recovery

Runtime inventory filtruje pouze unarchived plugin-managed Session aktuálního Runtime se shodným root hash a contract version. Každá interní položka obsahuje project basename, Session title, short ID, mode posledního Jobu a stav; short ID je stabilní suffix/prefix OpenCode Session ID a barva je pouze doplněk.

Veřejná `select()` akce je recovery-only pro Runtime/TUI: slouží k retry attach, restartu, diagnostice a ovládání již vybraného pane, nikoli k běžné navigaci mezi Session. Plan vytvoří novou Session, pokud je to vyžádáno, jinak znovu ověří vybranou reusable Session; aktivní Session follow-up odmítne a nenabízí queue.

Po vytvoření nebo reuse Plan nejprve lazily zobrazí sdílený pane, potom přes `/tui/select-session` nastaví transcript. Pane zůstává input-locked a source window nepřijde o focus; explicitní Focus akce může pane zaostřit. Dedikovaná new-session akce vždy vytvoří nezávislou Session.

## Cancel semantics

Cancel-one:

1. označí Job cancelling interním guardem,
2. zavolá `POST /session/:sessionID/abort`, pokud OpenCode stále běží,
3. odstraní proposal, extmark highlight, temp merge soubory a dialogy,
4. přejde do `cancelled`,
5. uvolní Session.

Cancel action nabízí pouze aktivní Joby a po výběru provede stejné kroky pro jeden Job. Cancel-all provede stejné kroky pro snapshot všech aktivních Jobů; selhání jednoho abort requestu nesmí zabránit lokálnímu fail-closed zrušení ostatních. Žádný pozdní event nesmí aplikovat cancelled proposal.

## Logging a diagnostika

Default log record smí obsahovat:

```text
timestamp, level, root_hash, runtime_state,
session_short_id, message_short_id, old_state, new_state,
event_type, endpoint, status_code, error_class
```

Nesmí obsahovat prompt, reasoning preview, model response, structured replacement, Base/Ours/Theirs, absolute home path, auth secret ani source diff. Explicitní debug-content režim je mimo verzi 2.0.

Health check ověří:

- podporovaný Neovim a `snacks.nvim`,
- executable `opencode` s přesnou verzí,
- executable `git` a `git merge-file` capability,
- Tree-sitter parser availability jako informaci, ne hard failure,
- možnost bindnout loopback port,
- tmux stack: `$TMUX`, `$TMUX_PANE`, executable tmux a jeho verzi pro Plan a ruční TUI pane.

## Implementační hranice komponent

Konkrétní názvy Lua modulů se mohou přizpůsobit upstream struktuře, ale odpovědnosti nesmí být sloučeny do globálního stavu:

| Komponenta | Odpovědnost |
|---|---|
| Runtime manager | procesy, root registry, ownership manifest, auth, health, recovery, shutdown, tmux pane lifecycle |
| OpenCode client | pinované HTTP payloady, root header, endpointy, error mapping |
| Session registry | verified inventory, availability, Plan reuse, internal TUI selection |
| Job registry | state transitions, correlation, cancellation, late-event guard |
| Context/preflight | placeholders, dirty buffers, Base capture |
| Scope resolver | visual/function/file, Tree-sitter adapters, extmarks, overlap |
| Proposal validator | structured schema, hash/path/range, Theirs construction, scope diff |
| Merge engine | temp files, `git merge-file`, conflict strategies |
| Buffer applier | changedtick, disk fingerprint, InsertLeave, minimal undoable mutation, view/extmark preservation |
| Interaction queue | question/permission/conflict native UI serialization a TUI interaction lock |
| Prompt float / tmux pane / status UI | float prompt, inline Build status, tmux pane, focus lock, notifications, state rendering |

## Reference sources

- OpenCode releases: <https://github.com/anomalyco/opencode/releases/tag/v1.17.3> a <https://github.com/anomalyco/opencode/releases/tag/v1.18.9>
- OpenCode server docs: <https://opencode.ai/docs/server/>
- OpenCode agents: <https://opencode.ai/docs/agents/>
- OpenCode permissions: <https://opencode.ai/docs/permissions/>
- OpenCode commands: <https://opencode.ai/docs/commands/>
- OpenCode skills: <https://opencode.ai/docs/skills/>
- Git three-way file merge: <https://git-scm.com/docs/git-merge-file>
- Neovim API/extmarks: <https://neovim.io/doc/user/api/>
- `ThePrimeagen/99` range workflow reference: <https://github.com/ThePrimeagen/99/tree/c17422457027c913c76c75a921fca1e623d2678e>

`99` je inspirací pro per-request output a extmark tracking, nikoli bezpečnostním kontraktem. Jeho aktuální visual path nemá třícestný merge, overlap detection ani filesystem enforcement; tento fork tyto mezery výslovně uzavírá.
