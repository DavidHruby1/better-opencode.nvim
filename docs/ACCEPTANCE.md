# Acceptance contract pro inline workflow

## Stav a účel

| Položka | Hodnota |
|---|---|
| Stav | Implementačně závazný ověřovací kontrakt |
| Verze | 1.0 |
| Aktualizováno | 30. 7. 2026 |
| Produktový kontrakt | `docs/PRD.md` |
| Technický kontrakt | `docs/ARCHITECTURE.md` |

Scénáře definují pozorovatelné chování, nikoli konkrétní test framework. `P0` jsou safety a data-integrity gates, `P1` jsou povinné funkční gates a `P2` jsou povinné UX/diagnostické gates pro Definition of Done. Žádný P0 ani P1 scénář nesmí být skipped. P2 smí být automatizovaný nebo doložený reprodukovatelným manuálním testem.

## Testovací vrstvy

| Vrstva | Účel |
|---|---|
| Unit | Scope převody, overlap, schema, hash, state transitions, event correlation |
| Neovim integration | Buffery, changedtick, extmarky, undo, InsertLeave, views, dialogs |
| Contract | HTTP/SSE payloady proti uloženému OpenCode `v1.18.9` `/doc` fixture |
| End-to-end | Skutečný plugin-owned Server + TUI + Neovim workflow |
| Failure injection | Crash, disconnect, late event, save failure, invalid proposal, merge error |

Contract suite MUSÍ obsahovat neměnný `/doc` fixture získaný z OpenCode `v1.18.9` commitu `4da7bb44c84e013fa53e9c5d02ac753d1435c81a`. End-to-end suite MUSÍ běžet proti binárce stejné verze.

## Společné testovací fixture

Textový target obsahuje dvě nepřekrývající se funkce:

```lua
local function alpha()
  return 1
end

local function beta()
  return 2
end
```

Kde scénář používá Base/Ours/Theirs, platí:

- Base je uložený kanonický buffer text při dispatchi.
- Ours je aktuální in-memory buffer při merge.
- Theirs vzniká pouze ze structured replacementu.
- Kontrola disku a bufferu proběhne před aplikací.

## Runtime a kompatibilita

### AC-RUN-01: Vlastněný zabezpečený Runtime

**Priorita:** P0  
**Požadavky:** RUN-01, RUN-03, RUN-04, RUN-11

**Given** pro project root neexistuje Runtime  
**When** uživatel otevře první Plan nebo Build prompt  
**Then** plugin spustí nový Server na `127.0.0.1` s náhodným portem a HTTP heslem  
**And** Server i TUI mají process working directory rovný canonical project rootu  
**And** TUI je spuštěn s `attach --dir` rovným tomuto rootu  
**And** každý HTTP/SSE request nese stejný `x-opencode-directory`  
**And** spustí právě jeden TUI klient připojený k tomuto Serveru  
**And** `/global/health` vrátí `1.18.9`  
**And** `/doc` obsahuje všechny endpointy z architektury  
**And** port ani heslo nejsou v logu.

### AC-RUN-02: Žádný attach ani discovery cizího procesu

**Priorita:** P0  
**Požadavky:** RUN-01, RUN-05

**Given** na stroji běží jiný dostupný OpenCode Server  
**When** plugin inicializuje Runtime  
**Then** nepoužije `pgrep`, `lsof`, mDNS ani foreign URL  
**And** všechny requesty míří pouze na proces spuštěný aktuálním Runtime.

### AC-RUN-03: Nepodporovaná verze nebo API

**Priorita:** P0  
**Požadavky:** RUN-04, RUN-05

**Given** executable hlásí jinou verzi nebo `/doc` postrádá required operation  
**When** skončí preflight  
**Then** Runtime nepřejde do `ready`  
**And** žádný prompt se neodešle  
**And** health UI uvede očekávanou a nalezenou verzi nebo chybějící operation ID.

### AC-RUN-04: Startup timeout

**Priorita:** P1  
**Požadavky:** RUN-05, RUN-08

**Given** vlastněný Server se nestane healthy do timeoutu  
**When** timeout vyprší  
**Then** startup skončí diagnostickou chybou  
**And** částečně spuštěné vlastněné procesy se ukončí  
**And** plugin se nepokusí připojit jinam.

### AC-RUN-05: Více project roots

**Priorita:** P1  
**Požadavky:** RUN-01, RUN-02

**Given** Neovim má buffery ze dvou canonical roots  
**And** v prvním rootu běží background Job  
**When** uživatel odešle prompt ve druhém rootu  
**Then** vznikne druhý samostatný Runtime  
**And** sidebar zobrazí TUI druhého rootu  
**And** Job prvního rootu pokračuje a jeho eventy se nepřimíchají.

### AC-RUN-06: Bezpečný shutdown

**Priorita:** P1  
**Požadavky:** RUN-08

**Given** plugin vlastní dva Runtime a aktivní Joby  
**When** nastane `VimLeavePre`  
**Then** plugin abortuje aktivní vlastněné Session  
**And** ukončí pouze své TUI a Server procesy  
**And** odstraní své temp soubory  
**And** odstraní private ownership manifest  
**And** cizí OpenCode proces zůstane běžet.

### AC-RUN-07: Hard-crash orphan cleanup ověřuje ownership

**Priorita:** P0  
**Požadavky:** RUN-03, RUN-08

**Given** předchozí Neovim skončil tvrdě a zanechal mode-0600 manifest i vlastněný Server/TUI  
**When** nový plugin startup ověří PID start identity, executable, credentials, port a root  
**Then** ukončí ověřené stale procesy a odstraní jejich temp data i manifest  
**Given** některý ownership důkaz nesouhlasí nebo PID byl znovu použit  
**Then** proces nesignalizuje a zobrazí manuální cleanup diagnostiku.

### AC-RUN-08: TUI-only crash zachová Server a Joby

**Priorita:** P1  
**Požadavky:** RUN-06

**Given** Server je healthy a Job běží  
**When** skončí pouze TUI child proces  
**Then** Runtime nepřeruší Server ani Job  
**And** spustí nový `attach --dir` proti témuž Serveru  
**And** obnoví dříve zobrazenou Session přes `/tui/select-session`.

### AC-RUN-09: Custom plugin/tool nebo enabled MCP blokuje Runtime pasivně

**Priorita:** P0  
**Požadavky:** RUN-04, RUN-10

**Given** documented global/project/custom config obsahuje custom plugin, custom tool nebo MCP bez `enabled: false`  
**When** proběhne passive pre-spawn guard  
**Then** OpenCode Server se vůbec nespustí a žádný custom modul ani MCP command se neprovede  
**Given** až remote/managed effective `/config` odhalí takové rozšíření  
**When** proběhne post-start config preflight bez volání `/mcp`  
**Then** Runtime nepřejde do `ready` a žádný prompt se neodešle  
**And** diagnostika pojmenuje nepodporované rozšíření bez načtení jeho citlivé konfigurace do logu.

## Prompt, sidebar a kontext

### AC-UI-01: Inline prompt zobrazuje závazné údaje

**Priorita:** P1  
**Požadavky:** UI-01, UI-02, UI-03, MODE-01

**Given** kurzor je uvnitř rozpoznané funkce  
**When** uživatel otevře výchozí prompt  
**Then** `snacks.input` zobrazí Build, canonical root a function scope  
**And** po odeslání se focus vrátí do původního source window  
**And** předchozí prompt se nenabídne jako input historie.

### AC-UI-02: Sidebar bez focus steal

**Priorita:** P1  
**Požadavky:** UI-04, UI-05

**Given** sidebar je zavřený  
**When** se odešle prompt  
**Then** pravý sidebar zobrazí TUI aktivního rootu  
**And** source window zůstane current  
**And** sidebar lze samostatně focusovat, skrýt a znovu zobrazit  
**And** změna konfigurované šířky se projeví bez restartu Runtime.

### AC-UI-03: Čitelná identita bez barvy

**Priorita:** P2  
**Požadavky:** UI-06, UI-07, JOB-06

**Given** dvě Session používají stejnou barvu nebo barvy nejsou viditelné  
**When** uživatel otevře status nebo picker  
**Then** rozliší Session podle title, short ID, rootu a textového Job stavu  
**And** background notifikace obsahuje stejnou identitu.

### AC-UI-04: Všechny background notifikace jsou neinvazivní

**Priorita:** P2  
**Požadavky:** UI-07

**Given** source window je current a čtyři background Joby postupně dokončí, konfliktují, položí otázku a selžou  
**When** plugin zobrazí jejich notifikace  
**Then** každá notifikace obsahuje správný root, Session short ID a Job stav  
**And** completion, conflict, question i error mají odlišitelný text  
**And** žádná notifikace sama nezmění current window, cursor ani sidebar Session.

### AC-CTX-01: Zachované context placeholders

**Priorita:** P1  
**Požadavky:** CTX-01, CTX-02, CTX-03, CTX-04

**Given** existují cursor/range, buffers, visible windows, diagnostics, quickfix a uppercase marks  
**When** se expandují `@this`, `@buffer`, `@buffers`, `@visible`, `@diagnostics`, `@quickfix`, `@marks`  
**Then** každý token vytvoří upstream-compatible context  
**And** file-backed položky jsou path/range references  
**And** aktivní editor location je přítomná i bez explicitního context tokenu  
**And** `@this` nemění independently resolved hard scope  
**And** completion i highlight fungují v `snacks.input`.

### AC-CTX-02: Nativní commands, skills a AGENTS

**Priorita:** P1  
**Požadavky:** CTX-05, CTX-06

**Given** projekt obsahuje OpenCode command, skill a directory `AGENTS.md`  
**When** se otevře prompt a odešle Job  
**Then** plugin nevytváří `#command` ani `#skill` syntaxi  
**And** managed `/name` dispatch odmítne jako unsupported před vytvořením Jobu  
**And** OpenCode objeví skill a relevantní `AGENTS.md` právě jednou  
**And** plugin jejich obsah nepřidá podruhé do promptu.

### AC-CTX-03: Dirty preflight a write hooks

**Priorita:** P0  
**Požadavky:** CTX-08, CTX-09, CTX-10

**Given** target je dirty a `BufWritePre` změní jeho text  
**When** uživatel zvolí `save and continue`  
**Then** proběhne běžný write včetně autocmds  
**And** Base obsahuje až finální text po hooku  
**And** Base se shoduje s diskem a buffer není modified  
**And** teprve potom se vytvoří Job.

### AC-CTX-04: Dirty preflight cancel nebo save failure

**Priorita:** P0  
**Požadavky:** CTX-08, CTX-10

**Given** target nebo explicitní context buffer je dirty  
**When** uživatel zvolí `cancel` nebo write selže  
**Then** nevznikne Session prompt ani Job  
**And** žádný z ostatních dirty bufferů se potichu neuloží.

### AC-CTX-05: Nepodporovaný target

**Priorita:** P1  
**Požadavky:** CTX-07, SCOPE-09

**Given** target je unnamed, binary/NUL, non-UTF-8, scratch nebo Build používá blockwise selection  
**When** uživatel vyvolá Build nebo Plan  
**Then** dispatch skončí před vytvořením Jobu  
**And** UI uvede konkrétní nepodporovaný typ  
**And** neodešle celý buffer jako skrytý fallback.

### AC-CTX-06: Plan používá stejný dirty preflight

**Priorita:** P1  
**Požadavky:** CTX-07, CTX-08, CTX-10

**Given** Plan target nebo explicitní file context je dirty  
**When** uživatel odešle Plan prompt  
**Then** plugin nabídne `save and continue` nebo `cancel` stejně jako pro Build  
**And** při cancelu se prompt neodešle  
**And** při pokračování Plan čte až finální obsah po úspěšných write hooks.

## Režimy a permissions

### AC-MODE-01: Plan je technicky read-only

**Priorita:** P0  
**Požadavky:** MODE-03, MODE-04, INT-01, INT-02

**Given** Plan agent se pokusí použít `edit`, `bash`, `task`, external path nebo neznámý MCP/custom tool  
**When** OpenCode vyhodnotí Session permissions  
**Then** operace skončí hard deny bez schvalovací možnosti  
**And** source, plan files ani externí filesystem se nezmění  
**And** Plan může nadále používat povolené read-only nástroje.

### AC-MODE-02: Build používá proposal, nikoli source write

**Priorita:** P0  
**Požadavky:** MODE-01, MODE-02, INT-01

**Given** běží Build primary agent  
**When** navrhne změnu  
**Then** finální autoritou je JSON-schema structured output  
**And** resolved tool surface obsahuje interní `StructuredOutput` tool  
**And** source disk se před buffer application nezmění  
**And** pokus o edit/bash/task je hard denied.

### AC-MODE-03: Plan-to-Build follow-up

**Priorita:** P1  
**Požadavky:** MODE-05, JOB-01, JOB-02

**Given** Plan Job skončil a Session je reusable  
**When** uživatel v téže Session odešle Build  
**Then** transcript context zůstane zachován  
**And** vznikne nový Job s novým userMessageID, Base a scope  
**And** původní Plan Job se nezmění.

## Scope a proposal validation

### AC-SCOPE-01: Skutečný visual range má prioritu

**Priorita:** P0  
**Požadavky:** SCOPE-01, SCOPE-02

**Given** existují stale visual marks a uživatel právě označí jiný characterwise nebo linewise range  
**When** vyvolá Build z visual mappingu  
**Then** hard scope odpovídá právě aktivnímu invocation range  
**And** stale marks se nepoužijí.

### AC-SCOPE-02: Function, file fallback a explicitní rozšíření

**Priorita:** P1  
**Požadavky:** SCOPE-01, SCOPE-03, SCOPE-04

**Given** kurzor je uvnitř podporované Tree-sitter funkce  
**When** se otevře Build  
**Then** default je function scope  
**And** uživatel jej může před odesláním rozšířit na file  
**When** parser nebo funkce není dostupná  
**Then** default je file scope, nikdy unscoped.

### AC-SCOPE-03: Scope violation odmítne celý proposal

**Priorita:** P0  
**Požadavky:** SCOPE-05, SCOPE-06, SCOPE-07, MERGE-07

**Given** JSON-valid proposal má nesprávný path/range nebo testovaný validator dostane Theirs s prefixem či suffixem odlišným od Base  
**When** proběhne Base-to-Theirs validace  
**Then** Job skončí `scope_violation`  
**And** neaplikuje se ani in-scope část  
**And** buffer i disk zůstanou beze změny  
**And** UI neoznačí událost jako merge conflict.

### AC-SCOPE-04: Overlap je odmítnut, sousední scope povolen

**Priorita:** P0  
**Požadavky:** SCOPE-08

**Given** Job A má aktivní function scope `alpha`  
**When** nový Build cílí do stejného current extmark range  
**Then** nevznikne Job ani prompt a UI odkáže na Job A  
**When** nový Build cílí do nepřekrývajícího scope `beta`  
**Then** dispatch je povolen v nové Session.

### AC-SCOPE-05: Extmark sleduje posun, neautorizuje změnu

**Priorita:** P1  
**Požadavky:** SCOPE-05

**Given** aktivní Job cílí funkci `beta`  
**When** uživatel vloží řádky před funkcí  
**Then** highlight a current scope se posunou s extmarky  
**And** Base scope offsets se nezmění  
**And** validace proposal proběhne proti původnímu Base.

### AC-SCOPE-06: Uživatelem vytvořený překryv odmítne proposal

**Priorita:** P0  
**Požadavky:** SCOPE-08, SCOPE-10

**Given** dva aktivní Joby původně mají nepřekrývající se extmark ranges  
**When** uživatel editací způsobí jejich překryv nebo kolaps před dokončením prvního Jobu  
**Then** pre-apply overlap revalidation automatickou aplikaci zastaví  
**And** Job skončí `scope_violation` bez částečné aplikace  
**And** buffer ani druhý Job se automaticky nezmění.

### AC-PROP-01: Validní proposal vytvoří přesný Theirs

**Priorita:** P0  
**Požadavky:** MERGE-01, SCOPE-06

**Given** proposal má správný path, Base SHA-256, scope offsets a replacement  
**When** validátor sestaví Theirs  
**Then** Theirs je přesně `Base prefix + replacement + Base suffix`  
**And** žádný jiný byte ani soubor se nezmění.

### AC-PROP-02: Nevalidní structured output

**Priorita:** P0  
**Požadavky:** MODE-02, MERGE-01

**Given** assistant skončí bez structured outputu nebo s nevalidním schematem  
**When** plugin načte exact message  
**Then** Job skončí `error`  
**And** plugin se nepokusí parsovat Markdown, stdout ani `file.edited`  
**And** nic se neaplikuje.

### AC-PROP-03: Neshoda transaction identity

**Priorita:** P0  
**Požadavky:** JOB-01, SCOPE-06

**Given** proposal obsahuje jiný path, hash nebo scope offsets  
**When** proběhne validace  
**Then** Job skončí fail-closed `scope_violation`  
**And** proposal jiného Jobu nelze použít.

## Merge, InsertLeave a undo

### AC-MERGE-01: Čistá agentova změna

**Priorita:** P0  
**Požadavky:** MERGE-02, MERGE-04, MERGE-06, MERGE-12, MERGE-13

**Given** Ours se rovná Base a validní Theirs mění pouze scope  
**When** agent dokončí mimo Insert mode  
**Then** merge se aplikuje bez dialogu  
**And** buffer obsahuje Theirs  
**And** disk stále obsahuje Base  
**And** buffer je `modified`.

### AC-MERGE-02: Nekolizní uživatelská změna

**Priorita:** P0  
**Požadavky:** MERGE-05, MERGE-06

**Given** uživatel změnil `alpha` a agent proti stejnému Base změnil `beta`  
**When** proběhne merge  
**Then** výsledek obsahuje obě změny právě jednou  
**And** dialog se neotevře.

### AC-MERGE-03: Identická změna

**Priorita:** P1  
**Požadavky:** MERGE-06

**Given** Ours a Theirs provedly identickou změnu proti Base  
**When** proběhne merge  
**Then** změna je ve výsledku právě jednou  
**And** nevznikne konflikt.

### AC-MERGE-04: InsertLeave odkládá aplikaci

**Priorita:** P0  
**Požadavky:** MERGE-03, MERGE-04

**Given** validní proposal dokončí během Insert mode  
**When** přichází completion event  
**Then** Job přejde do `pending_apply` a buffer se nezmění  
**When** nastane `InsertLeave`  
**Then** zachytí se aktuální Ours a spustí merge právě jednou.

### AC-MERGE-05: Changedtick race

**Priorita:** P0  
**Požadavky:** MERGE-05, MERGE-16

**Given** merge se počítá nad Ours s changedtick N  
**When** uživatel před aplikací změní buffer na changedtick N+1  
**Then** stale výsledek se zahodí  
**And** nic se neaplikuje  
**And** nový merge použije Ours z N+1.

### AC-MERGE-06: Agentní konflikt má tři volby

**Priorita:** P0  
**Požadavky:** MERGE-08, MERGE-09, MERGE-10, MERGE-12, MERGE-13, MERGE-16

**Given** Ours a Theirs nekompatibilně změnily stejné řádky a současně existují nekolizní změny  
**When** plugin detekuje konflikt  
**Then** dialog obsahuje přesně `keep my changes`, `accept agent changes`, `open manual diff`  
**And** neobsahuje `merge both`  
**When** uživatel vybere Ours nebo Theirs  
**Then** volba se použije na všechny conflict hunks  
**And** nekolizní změny obou stran zůstanou zachované  
**And** výsledek se aplikuje jedním minimálním undo krokem, buffer zůstane modified a disk se nezmění.

### AC-MERGE-07: Manual diff lifecycle

**Priorita:** P1  
**Požadavky:** MERGE-11, MERGE-12, MERGE-13, MERGE-16

**Given** Job je v agentním konfliktu  
**When** uživatel otevře manual diff  
**Then** vidí read-only Base, Ours, Theirs a editovatelný result  
**And** Session zůstává active  
**When** výsledek explicitně potvrdí  
**Then** po nové changedtick/disk kontrole se aplikuje jedním undo krokem, disk se nezmění a Job skončí `completed`  
**When** řešení zruší  
**Then** source Ours zůstane nedotčen a Job skončí `cancelled`.

### AC-MERGE-08: Jeden undo krok, žádný reload

**Priorita:** P0  
**Požadavky:** MERGE-12, MERGE-13, MERGE-14

**Given** čistý merge změnil více řádků  
**When** plugin aplikuje výsledek  
**Then** nevolá write, `:e`, `checktime` ani reload  
**And** provede právě jeden `nvim_buf_set_text()` nad minimálním changed span, nikoli whole-buffer replacement  
**And** window view a platný cursor zůstanou zachované  
**And** jeden standardní undo vrátí přesný předchozí Ours  
**And** disk nebyl změněn.

### AC-MERGE-09: Externí disková změna

**Priorita:** P0  
**Požadavky:** JOB-03, MERGE-15, MERGE-16

**Given** disk se po dispatchi změnil na obsah odlišný od Base i current Ours  
**When** se má aplikovat agentův proposal  
**Then** Job přejde do `conflict` kind `external_change`  
**And** buffer ani disk se nezmění  
**And** UI nabídne `open external diff`, `retry apply`, `cancel`  
**And** retry není úspěšný, dokud uživatel disk a buffer explicitně nereconciluje a disk se přesně nerovná Ours.

### AC-MERGE-10: Uživatel během Jobu uloží Ours

**Priorita:** P1  
**Požadavky:** MERGE-15

**Given** uživatel během Jobu uloží svůj current buffer a disk se rovná Ours, ale ne Base  
**When** proposal dokončí  
**Then** nejde o external-change konflikt  
**And** běžný Base/Ours/Theirs merge zachová uloženou uživatelskou změnu.

### AC-MERGE-11: Disk se změní mezi merge a aplikací

**Priorita:** P0  
**Požadavky:** MERGE-15, MERGE-16

**Given** plugin zachytil disk fingerprint D1 a dokončil čistý merge  
**When** failure injection změní disk na D2 před buffer API mutací a changedtick zůstane stejný  
**Then** plugin D2 znovu načte, stale merge neaplikuje a přejde do `conflict` kind `external_change`  
**And** stejná kontrola proběhne před Ours/Theirs conflict preference i manual-diff confirmation.

### AC-MERGE-12: Kanonizace EOL a empty files

**Priorita:** P0  
**Požadavky:** MERGE-17

**Given** parametrizované fixtures LF, CRLF, `noendofline`, empty file a skutečný trailing empty line  
**When** se zachytí Base, sestaví Theirs, sloučí a aplikuje replacement  
**Then** logical text odpovídá `table.concat(buffer_lines, "\n")`  
**And** `fileformat`, `endofline` a `fixendofline` zůstanou beze změny  
**And** empty file a trailing empty line se vzájemně nezamění  
**And** replacement obsahující `\r` se odmítne bez aplikace.

## Session, paralelismus a cancel

### AC-JOB-01: Jedna Session, jeden neterminální Job

**Priorita:** P0  
**Požadavky:** JOB-02, JOB-05

**Given** Session má Job `pending_apply` nebo `conflict`  
**When** uživatel odešle follow-up do této Session  
**Then** prompt se do ní nezařadí  
**And** UI nabídne vytvoření nové Session  
**And** neexistuje `queued` Job.

### AC-JOB-02: Přepnutí transcriptu

**Priorita:** P1  
**Požadavky:** JOB-06, JOB-07

**Given** Runtime má dvě Session s odlišnými transcripts  
**When** uživatel vybere druhou Session v pickeru  
**Then** plugin zavolá `/tui/select-session` pro správný Runtime  
**And** sidebar zobrazí transcript druhé Session  
**And** background event první Session se do něj nevloží.

### AC-JOB-03: Dva nepřekrývající se Joby ve stejném bufferu

**Priorita:** P0  
**Požadavky:** SCOPE-05, SCOPE-08, JOB-09, MERGE-06, MERGE-12

**Given** Job A mění `alpha` a Job B v jiné Session mění `beta` proti stejnému Base  
**When** Job B dokončí před A a výsledky se aplikují v libovolném pořadí  
**Then** finální buffer obsahuje obě změny právě jednou  
**And** po aplikaci prvního Jobu extmarky druhého stále přesně ohraničují funkci `beta`  
**And** disk se automaticky nezmění  
**And** nevznikne worktree ani workspace copy.

### AC-JOB-04: Cancel jednoho Jobu

**Priorita:** P0  
**Požadavky:** JOB-08

**Given** běží dva Joby v různých Session  
**When** uživatel zruší Job A  
**Then** plugin abortuje Session A, zahodí její proposal, extmarky, temp files a dialogy  
**And** Job A skončí `cancelled`  
**And** Job B pokračuje.

### AC-JOB-05: Cancel all

**Priorita:** P1  
**Požadavky:** JOB-08

**Given** více Runtime obsahuje aktivní Joby  
**When** uživatel zvolí cancel all  
**Then** každý snapshotnutý aktivní Job lokálně skončí `cancelled` i při selhání jednoho HTTP abortu  
**And** žádný pending proposal se později neaplikuje.

### AC-JOB-06: Session ownership, reuse a retention

**Priorita:** P0  
**Požadavky:** JOB-06, JOB-11, INT-01

**Given** Server vrací jednu plugin-managed reusable Session, jednu foreign Session bez markeru a jednu archived managed Session  
**When** uživatel otevře plugin session picker  
**Then** picker nabídne pouze unarchived plugin-managed Session se shodným root hash a contract version  
**When** uživatel managed Session zvolí pro follow-up  
**Then** plugin před dispatchí znovu nastaví a ověří hard permission profile  
**And** foreign ani archived Session se automaticky nereuse  
**And** žádná Session se automaticky nesmaže.

### AC-JOB-07: TUI je permanentně input-locked

**Priorita:** P0  
**Požadavky:** JOB-02, JOB-05, JOB-09, JOB-12

**Given** uživatel focusuje plugin-owned TUI sidebar  
**When** použije `i`, `a`, `startinsert`, terminal-mode mapping nebo pluginovou input akci  
**Then** buffer zůstane v Terminal-Normal a žádný input se neodešle TUI channelu  
**And** transcript lze scrollovat a přepínat přes plugin Session picker  
**And** user message může vzniknout pouze registrovanou HTTP cestou s plugin Jobem.

## Event routing a recovery

### AC-EVT-01: Routing podle Session a Message

**Priorita:** P0  
**Požadavky:** JOB-01, JOB-09

**Given** reusable Session již obsahuje terminální Job A a nyní běží Job B  
**When** přijde první assistant `message.updated` s novým ID a `parentID == JobB.userMessageID`  
**Then** plugin bootstrapne mapu nového assistant ID na Job B  
**And** následující part eventy tohoto assistant ID routuje pouze Jobu B  
**When** přijde opožděný user event Jobu A nebo assistant part event mapovaný na assistant response Jobu A  
**Then** event se nepřiřadí Jobu B  
**And** nezmění state ani buffer.

### AC-EVT-02: Request bez messageID

**Priorita:** P0  
**Požadavky:** JOB-09, INT-03, INT-04

**Given** Session má právě jeden aktivní Job  
**When** přijde question nebo permission event s requestID a sessionID bez messageID  
**Then** request se přiřadí tomuto Jobu  
**When** Session aktivní Job nemá  
**Then** request se neukáže jako dialog jiného Jobu a reconciliation jej vyřeší fail-closed.

### AC-EVT-03: SSE reconnect s dokončeným výsledkem

**Priorita:** P0  
**Požadavky:** JOB-10, RUN-06, RUN-07

**Given** SSE se odpojí během running Jobu a agent mezitím dokončí validní structured output  
**When** se Runtime reconnectne  
**Then** před novým promptem načte status, exact messages, questions a permissions  
**And** najde právě jednu assistant response s `parentID` rovným userMessageID Jobu a pokračuje proposal validací právě jednou.

### AC-EVT-04: SSE reconnect bez prokazatelného výsledku

**Priorita:** P0  
**Požadavky:** JOB-10, RUN-07

**Given** po reconnectu je Session idle, ale exact message nemá validní dokončený výsledek  
**When** skončí reconciliation  
**Then** Job skončí `error`  
**And** nic se neaplikuje  
**And** Session se může stát reusable.

### AC-EVT-05: Server crash a restart

**Priorita:** P1  
**Požadavky:** RUN-06, RUN-07

**Given** vlastněný Server spadne s aktivním Jobem  
**When** plugin detekuje ukončení procesu  
**Then** Runtime přejde `disconnected` a zablokuje prompty  
**And** automaticky se nepřipojí k jinému Serveru  
**When** uživatel zvolí restart  
**Then** vznikne nový vlastněný Server/TUI a před použitím proběhne reconciliation nebo fail-closed ukončení starého Jobu.

## Questions, permissions a dialog queue

### AC-INT-01: Question pokračuje ve správném Jobu

**Priorita:** P0  
**Požadavky:** INT-04

**Given** Job B vyvolá OpenCode question  
**When** uživatel odpoví v nativním Snacks pickeru/inputu  
**Then** odpověď se odešle na přesný requestID  
**And** pouze Job B přejde z `waiting_user` zpět do `running`.

### AC-INT-02: Permission dialog a hard deny

**Priorita:** P0  
**Požadavky:** INT-01, INT-02, INT-03

**Given** agent požádá o běžné schvalovatelné oprávnění  
**When** přijde permission request  
**Then** nativní dialog ukáže Session/Job identitu a API-supported odpovědi  
**Given** požadavek odpovídá hard deny edit/bash/task/external nebo neznámému toolu mimo allowlist  
**Then** OpenCode jej odmítne bez možnosti `once` nebo `always`  
**Given** contract fixture přímo předvyplní Server-wide `always` approval pro edit  
**Then** managed Session edit ani neznámý tool nemá v resolved model tool surface a approval jej nemůže znovu zpřístupnit  
**And** permission pro `read` nebo `external_directory` nikdy nenabídne `always`, pouze `once` nebo `reject`.

### AC-INT-03: FIFO dialog queue

**Priorita:** P1  
**Požadavky:** INT-05, INT-06

**Given** tři Joby téměř současně vyvolají question, permission nebo conflict dialog  
**When** jsou requesty přijaty  
**Then** UI zobrazí právě jeden a ostatní drží ve FIFO pořadí  
**And** question/permission Job má `waiting_user` a conflict Job zůstává `conflict`  
**When** uživatel dialog zavře  
**Then** odešle se explicitní reject/cancel a zobrazí se další request  
**And** žádný Job nezůstane viset bez pending requestu.

### AC-INT-04: Snacks dialog je jediná managed interakce

**Priorita:** P0  
**Požadavky:** INT-03, INT-04, INT-07

**Given** managed Job vyvolá question nebo permission a permanentně input-locked TUI sidebar je viditelný  
**When** plugin request přijme  
**Then** ve stejném callbacku TUI skryje, visibility-lockne jeho toggle/focus a otevře Snacks dialog  
**And** podporovaný workflow nemůže odeslat odpověď přes TUI  
**When** canonical API reply/reject potvrdí matching event  
**Then** plugin visibility lock zruší a obnoví předchozí visibility bez focus steal, ale permanentní input lock zachová  
**And** na requestID existuje právě jedna uživatelská odpověď.

## Stavový model

### AC-STATE-01: Povolené a zakázané transitions

**Priorita:** P0  
**Požadavky:** JOB-03, JOB-04

**Given** tabulka přechodů z architektury  
**When** unit suite vyzkouší všechny dvojice Job stavů  
**Then** povolené přechody uspějí idempotentně  
**And** nepovolené přechody nezmění state  
**And** `waiting_user` bez kind question/permission a `conflict` bez kind agent/external_change jsou odmítnuty  
**And** terminální stav nelze vrátit na neterminální.

### AC-STATE-02: Session availability je odvozená

**Priorita:** P1  
**Požadavky:** JOB-02, JOB-03

**Given** Job je `running`, `waiting_user`, `pending_apply` nebo `conflict`  
**Then** Session je `active(jobID)` i když OpenCode hlásí idle  
**Given** Job skončí `completed`, `cancelled`, `error` nebo `scope_violation`  
**Then** Session je `reusable`, pokud OpenCode hlásí idle  
**And** OpenCode busy bez lokálního Jobu je contract violation, která zablokuje prompty a spustí reconciliation  
**And** Job error nevytvoří samostatný Session error stav.

## Soukromí a diagnostika

### AC-SEC-01: Metadata-only logging

**Priorita:** P0  
**Požadavky:** RUN-09

**Given** prompt, Base a replacement obsahují unikátní secrets  
**When** proběhne úspěch, conflict, scope violation, HTTP error a reconnect  
**Then** žádný default log neobsahuje secret, source text, diff, absolute home path, port password ani authorization header  
**And** obsahuje pouze povolená metadata z architektury.

### AC-SEC-02: Health check je praktický

**Priorita:** P2  
**Požadavky:** RUN-04, RUN-05

**Given** chybí postupně podporovaný Neovim, OpenCode, správná verze, `git merge-file`, Snacks input/picker nebo Tree-sitter parser  
**When** uživatel spustí health check  
**Then** hard dependencies jsou errors s konkrétní nápravou  
**And** chybějící Tree-sitter parser je warning s file-scope fallbackem  
**And** health check nevyžaduje `pgrep` ani `lsof`.

## Traceability matrix

| Oblast požadavků | Pokrývající scénáře |
|---|---|
| UI-01 až UI-07 | AC-UI-01 až AC-UI-04, AC-JOB-02 |
| MODE-01 až MODE-05 | AC-MODE-01 až AC-MODE-03, AC-PROP-01 |
| CTX-01 až CTX-10 | AC-CTX-01 až AC-CTX-06 |
| SCOPE-01 až SCOPE-10 | AC-SCOPE-01 až AC-SCOPE-06, AC-PROP-01 až AC-PROP-03 |
| JOB-01 až JOB-12 | AC-JOB-01 až AC-JOB-07, AC-EVT-01 až AC-EVT-05, AC-STATE-01 až AC-STATE-02 |
| MERGE-01 až MERGE-17 | AC-PROP-01 až AC-PROP-03, AC-MERGE-01 až AC-MERGE-12, AC-JOB-03 |
| INT-01 až INT-07 | AC-MODE-01 až AC-MODE-02, AC-EVT-02, AC-INT-01 až AC-INT-04 |
| RUN-01 až RUN-11 | AC-RUN-01 až AC-RUN-09, AC-EVT-03 až AC-EVT-05, AC-SEC-01 až AC-SEC-02 |

## Release gate

Release candidate je přijatelný pouze tehdy, když:

1. všechny delivery slices jsou dokončené a všechny P0 a P1 scénáře procházejí,
2. žádný scenario skip nezakrývá unsupported platform nebo API drift,
3. real OpenCode `v1.18.9` contract suite prochází bez legacy fallbacku,
4. failure-injection suite neprokáže diskový write, stale apply, cross-Job event nebo ztrátu Ours,
5. P2 scénáře mají automatizovaný výsledek nebo uložený reprodukovatelný manuální protokol.
