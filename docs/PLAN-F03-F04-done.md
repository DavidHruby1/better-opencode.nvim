# Low-level plan F03-F04: scoped Build, clean merge a bezpečná aplikace

> Historical implementation plan. Plan and the tmux/TUI sidebar were later removed; this is not an active contract.

## Mandát

| Položka | Hodnota |
|---|---|
| Fáze | F03 Scoped Build a strukturovaný proposal; F04 Čistý merge a bezpečná aplikace |
| Capability slice | Jeden visual/function/file Build skončí validovaným proposalem a clean nebo identický Base/Ours/Theirs výsledek vloží do živého bufferu jako jednu neuloženou undoable změnu |
| Závislosti | Dokončený `docs/PLAN-F01-F02.md` včetně obou OpenCode compatibility profilů a test harnessu |
| Autority | `docs/PRD.md`, `docs/ARCHITECTURE.md`, `docs/ACCEPTANCE.md`, `docs/ROADMAP.md` |

F03 musí být samostatně pozorovatelná: Build skončí ve `pending_apply` s validním immutable proposalem, ale buffer se ještě nemění. Teprve po průchodu F03 gates zapni F04 completion cestu.

## Acceptance ownership a checkpointy

| Checkpoint | Primárně vlastněné scénáře |
|---|---|
| F03 | `AC-UI-01`, `AC-CTX-05`, `AC-MODE-02`, `AC-SCOPE-01`, `AC-SCOPE-02`, `AC-SCOPE-03`, `AC-SCOPE-04`, `AC-SCOPE-05`, `AC-PROP-01`, `AC-PROP-02`, `AC-PROP-03` |
| F04 | `AC-MERGE-01`, `AC-MERGE-02`, `AC-MERGE-03`, `AC-MERGE-04`, `AC-MERGE-05`, `AC-MERGE-08`, `AC-MERGE-10`, `AC-MERGE-12` |

F04 apply path zůstane testově vypnutá, dokud celý F03 řádek neprojde. Pozdější použití stejného scénáře je regrese, ne druhé ownership.

## Převzatý stav a změnové hranice

Použij existující Runtime, client, Session, Job, context/preflight, sidebar a Plan workflow. Neměň ownership, compatibility ani Plan permission model, pokud konkrétní Build test neprokáže chybu. Upstream visual/operator vstup z `lua/opencode.lua` a placeholder rendering se rozvíjí; upstream `file.edited`, `diffpatch`, autoread a TUI prompt transport zůstávají odstraněné.

Assigned production paths:

| Cesta | Behavior home |
|---|---|
| `lua/opencode/api/prompt.lua` | Společná Plan/Build orchestrace a ordering, bez vlastní scope/merge logiky |
| `lua/opencode/snapshot.lua` | Logical buffer text, EOL metadata, raw disk fingerprint a disk-to-logical conversion |
| `lua/opencode/scope/init.lua` | Invocation range -> BaseScope, extmark pair, current ranges a overlap gate |
| `lua/opencode/scope/treesitter.lua` | Nejbližší podporovaný function node a bezpečný file fallback |
| `lua/opencode/scope/adapters/lua.lua` | Závazné Lua function/method node types |
| `lua/opencode/proposal.lua` | Exact schema v1, semantic validace, Theirs construction a Base-to-Theirs authorization |
| `lua/opencode/merge.lua` | Private temp files a argv-only `git merge-file` execution |
| `lua/opencode/apply.lua` | InsertLeave, stale guards, minimal UTF-8 span a jediná buffer mutation |
| `lua/opencode/job.lua` | Build-owned Base/scope/marks/proposal a F04 transitions/cleanup |

Nepřesouvej context placeholder formatting do scope resolveru. Hard scope, editor location a `@this` jsou tři odlišné hodnoty. Nevytvářej obecný diff framework: proposal authorization je jedna replacement operace a merge backend je přesně `git merge-file`.

## Závazná data

### Snapshot a BaseScope

Implementuj přesně struktury z architektury. `Snapshot.text` je `table.concat(nvim_buf_get_lines(buf,0,-1,false), "\n")`; `fileformat`, `endofline`, `fixendofline`, `changedtick` a SHA-256 jsou samostatná immutable metadata. Scope je half-open byte range v Base. Empty file je `text=""`, file scope `[0,0)` a insertion je validní.

Raw disk SHA-256 se počítá nad přesnými bytes. `snapshot.lua` je jediný behavior home pro převod CRLF/LF a syntetického terminálního EOL. Replacement musí být UTF-8 bez NUL a `\r`; proposal nesmí měnit buffer options.

### Extmark pair

- start: `right_gravity=false`,
- end: `right_gravity=true`,
- oba v jednom plugin namespace a s Job key v user data nebo owning registry,
- Base offsets se po dispatchi nikdy nepřepisují,
- current extmark range slouží jen pro highlight/overlap/application safety.

Ztracený mark je `error`; validní, ale překrytý/kolabovaný scope při pre-apply je `scope_violation`.

### Proposal schema v1

Schema musí být jediná konstantní Lua tabulka v `proposal.lua`, deep-copied do prompt payloadu. Zakázané additional properties a required fields musí přesně odpovídat architektuře. Validace po `session.idle` vyžaduje právě jednu assistant response s `parentID=Job.user_message_id` a table v `info.structured`; text/Markdown/parts/file events nejsou fallback.

Výsledek validátoru je buď immutable `{proposal, theirs}`, nebo typed failure:

- `scope_violation`: path traversal/n mismatch, Base hash, scope offsets, prefix/suffix nebo out-of-scope change,
- `error`: missing/duplicate/invalid structured output, invalid UTF-8/NUL/CR, client/process failure.

Žádný typed failure nesmí obsahovat replacement nebo source text v loggable message.

### Job transitions do F04

Rozšiř state machine jen o aktuálně potřebné cesty:

```text
running -> pending_apply
running -> scope_violation | cancelled | error
pending_apply -> completed | conflict(agent|external_change) | scope_violation | cancelled | error
```

`conflict` v F04 pouze uchová immutable payload, zachová Session active a dovolí cancel. Žádný resolution dialog do F05.

## Vertikální implementační kroky

### 1. Snapshot a byte-coordinate proof

1. Přidej parametrizované unit/integration fixtures: LF, CRLF, `noendofline`, `fixendofline` on/off, empty file, one empty line, trailing empty logical line a multibyte UTF-8 před/uvnitř/za scopem.
2. Implementuj logical capture a raw disk decode/encode comparison v `snapshot.lua`. Nepoužívej `readfile()` v text mode pro raw fingerprint.
3. Implementuj převody Neovim row/byte-column <-> absolute byte offset. Characterwise selection zahrne poslední zvolený byte/codepoint; linewise selection zahrne celé řádky včetně mezilehlého `\n`, ale nepřidá neexistující terminální logical newline.
4. Round-trip test musí pro každý validní codepoint boundary vrátit stejný offset; mid-codepoint input odmítni.

Gate: `AC-MERGE-12` data část prochází ještě bez merge a žádný test nesrovnává pouze normalizované lines tam, kde se požaduje raw disk SHA.

### 2. Effective scope resolver

1. Změň visual/operator entrypoint tak, aby explicitní range předal přímo do workflow; nikdy později nečti `'<`, `'>` ani stale marks. Blockwise odmítni před inputem/Jobem.
2. Bez invocation range najdi v aktuálním parser tree nejbližší Lua function/method node podle adapteru. Parser/query chyba je capability warning a file fallback, ne unscoped mode.
3. Zobraz default `range|function|file` v Build inputu a dovol jedinou změnu range/function -> file před submit; zvolený effective scope znovu renderuj.
4. Po dirty preflight zachyť Base, převeď effective scope do Base offsets a vytvoř extmark pair. Scope se nesmí zachytit před write hooks.
5. Před vytvořením Session/Job porovnej nový current half-open range se všemi neterminálními Build Joby stejného bufferu. `a.start < b.end && b.start < a.end` je overlap; equality hranic je povolena.

Gate: `AC-UI-01`, `AC-CTX-05`, `AC-SCOPE-01/02/04/05` integration tests. Overlap rejection neodešle HTTP a ukáže short ID existujícího Jobu.

### 3. Build Session a structured dispatch

1. Po F03 přepni default mode veřejného `ask/prompt/operator` na `build`; Plan zůstane explicitní `mode="plan"`.
2. Build používá stejný isolated Server a execution-time permission profile jako Plan. Odesílej `agent="build"`, nové `msg_<ULID>`, `format={type="json_schema",schema=<v1>}` a parts s canonical relative target, editor location, Base hash, scope offsets a instrukcí replacement-only.
3. Base/scope/marks musí být v Jobu a Job v registries před `prompt_async`. HTTP 204 pouze potvrzuje přijetí.
4. Pro oba OpenCode profily contract test ověří payload a real e2e ověří, že `info.structured` je dostupné na assistant message. `StructuredOutput` je očekávaný protocol tool; hard-denied a unknown capability tools zůstávají mimo model surface a execution-time denied.
5. Source disk fingerprint před a po agentním běhu musí být shodný. Jakýkoli `file.edited` event je security diagnostic a Job `error`, ne proposal input.

Gate: `AC-MODE-02` a Build část `AC-CTX-05` procházejí bez buffer mutation.

### 4. Proposal completion a F03 exit

1. Live router bootstrapne assistant IDs přes exact `sessionID+parentID`; po idle vždy načti exact messages, ne poslední globální message.
2. Vyber responses s matching parent, vyžaduj právě jednu validní structured hodnotu a zvaliduj schema i lokální transaction identity v předepsaném pořadí.
3. Canonical proposal path musí být přesně Job path; normalizace nesmí přijmout traversal nebo symlink alias.
4. Sestav Theirs jedním byte slice replacementem. Ověř byte-identický prefix/suffix a autorizovaný single change; není třeba line diff.
5. Validní výsledek atomicky uloží proposal/Theirs a přejde `running -> pending_apply`. F03 test mode zde zastaví; buffer/disk se nezmění a Session zůstává active.
6. Invalidní návrh přejde celý do `scope_violation` nebo `error`, odstraní extmarky/proposal transient data a uvolní Session. Nikdy nepřijmi validní podmnožinu.

Gate: `AC-SCOPE-03`, `AC-PROP-01/02/03`; spolu s předchozími gates tím uzavři všechny F03 owned AC před povolením F04 apply.

### 5. Merge backend a disk classification

1. Health/runtime capability check před prvním Buildem ověří `git merge-file -p --diff3` a file-operand mode bez Git repozitáře.
2. `merge.lua` vytvoří private mode-0600 Base/Ours/Theirs temp files pod Runtime-owned temp dir a spustí přes argv bez shellu `git merge-file -p --diff3 -L Ours -L Base -L Theirs <ours> <base> <theirs>`.
3. Exit 0 vrací clean text; kladný code je agent conflict; spawn/signál/neočekávaný code je error. Stdout je content a nesmí do logu. Temp files cleanup v `finally` i cancel/shutdown.
4. Před merge zachyť v jednom scheduled callbacku Ours logical snapshot, changedtick a raw disk fingerprint. Disk klasifikuj přes `snapshot.lua`: logical disk==Base nebo logical disk==Ours smí pokračovat; jinak `conflict(external_change)` bez UI do F05.
5. Identické Ours/Theirs můžeš short-circuitnout pouze po stejné disk/changedtick validaci; výsledná apply cesta zůstává společná.

Gate: pure merge unit/process tests pokrývají clean, non-overlap, identical, conflict a process failure; temp dir je po každé cestě prázdný.

### 6. InsertLeave a stale recomputation

1. Pokud je target buffer v Insert mode při proposal completion, nech Job `pending_apply`, zaregistruj právě jeden buffer-local `InsertLeave` callback svázaný s Job key a nic nezachycuj předem.
2. Mimo Insert mode schedule apply ihned. Callback vždy znovu ověří Job state, buffer/path, extmark existence a všechny current active Build ranges.
3. Po async merge výsledku schedule finální callback; v něm bez dalšího yield načti current changedtick a raw disk SHA. Při změně výsledek zahoď a znovu spusť klasifikaci+merge nad čerstvým Ours. Použij generation counter, aby starší merge completion nemohl vyhrát.
4. Uživatelem vytvořený overlap/kolaps ukončí právě aplikovaný Job jako `scope_violation`; ostatní Job nezmění.
5. V F04 je opakování bounded aktuálními events, ne busy loop. Každá změna invaliduje jednu generation a nový merge startuje jednou.

Gate: `AC-MERGE-04/05` s controllable delayed merge fake a immediate `InsertLeave` testem.

### 7. Minimální UTF-8-safe buffer application

1. Mezi current Ours a merged logical result najdi nejdelší společný byte prefix a suffix bez overlapu. Posuň hranice zpět/vpřed na platné UTF-8 boundaries a převeď je přes otestovaný coordinate helper.
2. Ulož `winsaveview()` a validní cursory všech oken zobrazujících buffer. Ve stejném scheduled callbacku jako finální stale check zavolej právě jednou `nvim_buf_set_text()` nad changed span. Nepoužij `undojoin` ani whole-buffer set_lines.
3. Nevolej write, `:e`, `checktime`, reload ani option mutation. Buffer musí zůstat `modified`; disk raw fingerprint se po apply nezmění.
4. Obnov views a clampni cursor na validní row/byte-column. Nech Neovim přemístit cizí extmarky; odstraň pouze marks dokončeného Jobu až po úspěšné mutaci.
5. Přechod `pending_apply -> completed` uvolní Session a uklidí temp/proposal data idempotentně. Jeden standardní undo musí vrátit přesný předchozí Ours.

Gate: `AC-MERGE-01/02/03/08/10/12`, včetně assertion přes spy, že proběhl jeden `nvim_buf_set_text` a žádná zakázaná command/API cesta.

### 8. F04 failure closure a regrese

1. Agent conflict uchovej jako `conflict_kind="agent"` s immutable Base/Ours/Theirs metadata; external disk jako `external_change`. V této fázi nabídni jen cancel a text, že resolution přidá F05.
2. Buffer unload, rename, invalid marks, merge spawn error, unsupported encoding nebo repeated stale invalidation musí skončit terminálně/reconcilovatelně bez apply.
3. Spusť oba compatibility profily, celý F01-F02 regression set a všechny F03-F04 owned AC.

## Povinné testy a exit gate

| Vrstva | Minimální důkaz |
|---|---|
| Unit | Byte offsets, visual conversion, Tree-sitter adapter, overlap, schema, path/hash/range validation, Theirs, EOL/disk conversion, UTF-8 changed span |
| Neovim integration | Explicitní range, extmark gravity, scope expansion, InsertLeave, changedtick race, views/cursors/extmark preservation, one undo/one API mutation |
| Contract | Structured payload a `info.structured` pro oba `/doc` profily, exact assistant parent lookup |
| End-to-end | Visual/function/file Build -> pending_apply -> clean modified buffer pro `1.17.3` i `1.18.9` |
| Failure injection | Invalid/duplicate proposal, source disk edit, merge failure/delay, buffer edit race, extmark loss/overlap, CR/NUL/invalid UTF-8 |

F03 vlastní `AC-UI-01`, `AC-CTX-05`, `AC-MODE-02`, `AC-SCOPE-01` až `AC-SCOPE-05`, `AC-PROP-01` až `AC-PROP-03`. F04 vlastní `AC-MERGE-01` až `AC-MERGE-05`, `AC-MERGE-08`, `AC-MERGE-10`, `AC-MERGE-12` podle roadmapy. `AC-SCOPE-06` zůstává F08, ale pre-apply gate už musí mít unit/integration základ.

## Observability a privacy

Přidej pouze metadata: scope kind a byte length lze logovat, ale path, offsets spojené s absolutní cestou, Base hash, replacement, merge stdout a temp content ne. Security event `file.edited`, scope violation, stale generation a merge error mají error class a short Job ID. Test se secret fixture musí projít success, scope violation, conflict placeholder a process error cestou.

## Mimo fázi

Conflict preference, manual diff a external reconciliation UI; questions/permissions queue; Session reuse/picker; paralelní acceptance; cancel-all; reconnect; multi-root. Nevytvářej line-diff authorizer, worktree, workspace copy, multi-file proposal, create/delete/rename ani autosave.

## Stop conditions

- Jeden z podporovaných OpenCode profilů neuloží structured output do matching assistant `info.structured` nebo nedodrží parent ID.
- `git merge-file` na podporované platformě neumí požadovaný file-operand/`--diff3` kontrakt.
- Nelze odlišit empty file, no-EOL a trailing empty logical line bez změny buffer options.
- Finální stale check a buffer mutation by byly oddělené async yieldem.
- Implementace by kvůli jednoduchosti použila whole-buffer replacement, write/reload, Markdown diff nebo `file.edited` fallback.

Při stop condition se nic neaplikuje. Zaznamenej reprodukční fixture a eskaluj rozpor do autoritativní dokumentace.
