# FIX-PLAN

Stav: implementace dokončena v pracovním stromu; zbývá ověřit plný testovací a release průchod.

Datum průzkumu: 2026-08-02

## Cíl

Plugin má po změně:

- používat pouze Build workflow;
- úplně odstranit Plan mode a celý tmux sidebar/TUI, ne pouze jeho keymapy;
- nabídnout session picker s jasnými řádky, mazáním a pokračováním v reusable session;
- zachovat bezpečný Build proposal/review/apply workflow;
- mít okamžitý Build dispatch bez vstupního okna;
- otevírat prompt jako jeden řádek, který se při délce soft-wrapuje a umožní skutečný nový řádek přes `<S-CR>`;
- opravit přenos Shift+Enter přes aktuální Windows/WSL -> WezTerm -> tmux -> Neovim řetězec.

Výchozí mapování navržená v tomto dokumentu jsou `<leader>oi` pro výběr session a `<leader>od` pro okamžitý Build. 99 nemá vestavěné keymapy; `<leader>9d` je pouze dokumentační příklad uživatelského mapování.

## Zjištěný stav

### Plan a Build

`mode = "plan"|"build"` je veřejný kontrakt v `lua/opencode.lua:3-7,71-103,166-184`. Plan je dále rozvětvený v:

- `lua/opencode/api/prompt.lua:41-50,73-180`: jiný agent, jiný payload, jiná completion cesta a otevření TUI;
- `lua/opencode/context/preflight.lua:15-59`: Plan se před dirty bufferem ptá, Build ukládá automaticky;
- `lua/opencode/job.lua:28-55`: Job implicitně začíná jako Plan;
- `lua/opencode/runtime/reconcile.lua:122-174`: Plan nepotřebuje structured proposal, Build ano;
- `lua/opencode/runtime/init.lua:473-489`: startup vyžaduje primární agenty `build` i `plan`;
- `lua/opencode/ui/ask/init.lua:94-109,212`: prompt zobrazuje Build nebo Plan a odlišný scope;
- `lua/opencode/session.lua`, `ui/status.lua`, `ui/notify.lua`: ukládání a zobrazování mode.

Build safety path je již správný a musí zůstat: uložení dirty souboru, Base snapshot, scope a extmarks, zákaz source-write nástrojů, structured response, `pending_apply`, merge/conflict ochrany, changedtick/disk kontroly a přesná SSE korelace.

### Sidebar/TUI

Sidebar není Neovim session okno. Je to sdílený lazy tmux pane, do kterého se spouští `opencode attach`:

- implementace: `lua/opencode/ui/sidebar.lua:1-286`;
- konfigurace: `lua/opencode/config.lua:3,18,128-141` a `docs/CONFIGURATION.md:15,39`;
- keymap příklady: `README.md:47-54` (`<leader>ot`, `<leader>of`);
- startup závislost: `lua/opencode/runtime/init.lua:506-509`;
- lifecycle, recovery a shutdown: `runtime/init.lua:532,609-617,639-657,806-845,930-950`;
- schovávání a obnovování pane při permission/question dialogu: `lua/opencode/interaction.lua:24-74`;
- TUI session switch: `lua/opencode/client.lua:195-197` a `lua/opencode/session.lua:211-224`.

Protože požadavek potvrzuje odstranění celého sidebaru/TUI, nemá zůstat ani ruční show/focus, TUI recovery, pane lock, `/tui/select-session`, tmux startup gate nebo `sidebar.width`.

### Sessions

User-facing session picker v aktuálním zdroji neexistuje. `runtime.selected_session_id` je jen interní pointer poslední vybrané/dispatchované session. `session.inventory()` (`lua/opencode/session.lua:130-179`) už ale vrací ověřené session podle rootu, ownership metadata, availability, activity a collision-safe short ID. Picker tento dataset zatím nepoužívá.

Aktuální reuse flow je v `lua/opencode/api/prompt.lua:19-52`:

1. vezme `runtime.selected_session_id`;
2. odmítne aktivní nebo remote-busy session;
3. reusable session znovu ověří přes `session.revalidate()`;
4. vytvoří nový Job a nový user message ve stejné remote session.

Problém je, že uživatel nemůže pointer vybrat a picker neexistuje. Inventory se navíc běžně naplní jen při startupu a samo neodstraňuje session, která mezitím zmizela ze serveru.

### Prompt

Samostatný inline prompt v pluginu není. `ask()` otevírá multiline `Snacks.win` (`lua/opencode/ui/ask/init.lua:81-91,197-307`), zatímco `prompt()` je přímý dispatch bez UI (`lua/opencode.lua:91-103`).

Aktuální prompt:

- začíná minimálně na výšce 3 řádky a roste podle skutečných řádků;
- má `wrap=true`, `linebreak=true`;
- používá `<CR>` pro submit a `<C-j>` pro skutečný newline;
- `<S-CR>` už není namapováno, protože transport ho dosud nedoručil spolehlivě;
- testy v `tests/release/ac/test_ui_context.lua:397-484` a `tests/e2e/smoke.lua:28-115` explicitně vyžadují multiline chování.

Nový požadavek znamená: prompt se má otevřít jako jeden content řádek, text se při dosažení šířky pouze vizuálně zalomí, okno může růst podle wrapped řádků a `<S-CR>` má vložit skutečný newline. Nesmí se zaměnit počáteční one-line layout za zákaz víceřádkového textu.

## Cílový návrh

### 1. Build-only kontrakt

Doporučená varianta je čistý Build behavior s malou kompatibilitou pro existující Build callers:

- `mode = "build"` může zůstat jako přijímaný no-op, aby se nerozbila existující uživatelská mapování;
- `mode = "plan"` má skončit deterministickou chybou `mode_unavailable`, ne tichým přepnutím na Build;
- žádný runtime branch už nesmí rozlišovat Plan a Build;
- interní Job může dočasně ponechat `mode = "build"` kvůli čitelnému statusu, ale jeho invariants mají být unconditional Build;
- všechny prompt payloady posílají `agent = "build"` a současný structured JSON schema/build instruction;
- `last_mode` se přestane používat pro chování. Starší metadata s `last_mode = "plan"` se mohou bezpečně ignorovat/normalizovat;
- starší managed Plan session se může znovu použít pro Build, protože reuse znovu aplikuje ownership metadata a permissions.

Alternativa je úplně odstranit `mode` ze všech datových struktur. Je čistší, ale rozšiřuje kompatibilitní zásah do statusů, notifikací a test fixtures. Pro tento fix je menší collapse na Build.

Konkrétní zdrojové změny k naplánování:

- `lua/opencode.lua`: odstranit Plan z platného typu, zachovat explicitní odmítnutí `mode="plan"`, ponechat Build default a přímý `prompt()` entrypoint;
- `lua/opencode/api/prompt.lua`: odstranit Plan title/payload/completion větve a TUI tail; všechny dispatches vést Build cestou;
- `lua/opencode/context/preflight.lua`: vždy uložit dirty Build buffer, odstranit Plan dialog;
- `lua/opencode/job.lua`, `runtime/reconcile.lua`, `events/init.lua`, `ui/request_status.lua`: všechny Job/status/completion assumptions převést na Build;
- `lua/opencode/ui/ask/init.lua`: odstranit Plan label/read-only scope;
- `lua/opencode/runtime/init.lua`: validovat jen primární `build` agent;
- `lua/opencode/session.lua`, `ui/status.lua`, `ui/notify.lua`: odstranit Plan mode jako řídicí stav a text.

Permissions zůstávají fail-closed a Build deny rules se nemění. Aktuální nekonzistence `external_directory` (kód ho hard-denies, dokumentace připouští ask) se v tomto fixu nemá měnit bez samostatného rozhodnutí.

### 2. Úplné odstranění sidebaru/TUI

Odstranit celý modul `lua/opencode/ui/sidebar.lua` a všechny jeho consumers:

- odstranit tmux precondition ze startupu; runtime musí fungovat mimo tmux;
- odstranit `tui_*` state, `Runtime.show_root()`, `retry_tui()`, TUI death/recovery a TUI shutdown čekání;
- odstranit pane hide/show/lock/restore z `lua/opencode/interaction.lua`, ale ponechat FIFO interaction queue, `waiting_user` stav, request deduplication a SSE potvrzení;
- odstranit `Client:select_session()` a `tui.selectSession` z `lua/opencode/compat.lua`;
- odstranit `sidebar.width`, tmux health probing a tmux-only diagnostics;
- z `opencode.select()` odstranit `Retry TUI attach`; ponechat pouze `Restart runtime` a `Show diagnostics`, nebo tento recovery entrypoint později zrušit jako samostatný cleanup;
- z `runtime/ownership.lua` odstranit nově vytvářený/trackovaný TUI identity stav.

Upgrade detail: starý ownership manifest může obsahovat ověřený `manifest.tui`. Je bezpečné ponechat jednorázové ověření a cleanup takového legacy pane, ale plugin nesmí nový TUI vytvářet, attachovat ani dále evidovat.

### 3. Session inventory a picker

Nový picker má být samostatná session akce, ne přetížený TUI `select()`.

Doporučený flow pro `<leader>oi` v normal i visual mode:

1. před otevřením pickeru zachytit `Context.capture()` včetně bufferu, cursoru a visual range;
2. získat aktuální root Runtime a provést čerstvý `session.inventory()`;
3. zobrazit jen verified managed sessions pro tento canonical root;
4. po výběru reusable session otevřít one-line Build `ask()` se stejným captured Context;
5. při submitu poslat prompt do právě vybrané session;
6. při cancelu promptu nezměnit poslední úspěšně použitou session.

`runtime.selected_session_id` by neměl být používán jako nepotvrzený picker selection. Menší bezpečný kontrakt je přidat explicitní `session_id` do prompt options a nastavit `selected_session_id` až po úspěšném dispatchi. `api.prompt.prepare_session()` zůstává poslední autorita a session znovu ověří těsně před Job registrationem.

Řádek pickeru musí mít stabilní identity i při stejných titlech. Minimální zobrazení:

```text
[reusable] a1b2  Fix parser                         2 min ago
           path/to/project  updated 14:02  parent: -
```

Použít:

- collision-safe `short_id` a zkrácený nebo celý `id`;
- `title`, s fallbackem na `Untitled`;
- `availability`/remote status;
- `time.updated` jako absolutní nebo relativní čas;
- `directory`/relative `path`;
- `parentID` nebo child marker pro paralelní agent/session vztahy.

`summary` z OpenCode není text posledního promptu, ale file-change summary. Pokud bude potřeba lepší preview, načítat poslední user message lazy přes message endpoint, ne ho předpokládat v list response. `snacks.picker` je již dependency a v pluginu se zatím nepoužívá; je vhodnější než holé `vim.ui.select`, protože umožní filtering, preview a action pro delete. Před implementací ověřit pinned Snacks action API.

### 4. Mazání session

OpenCode 1.17.3 i 1.18.9 mají common legacy endpoint:

```text
DELETE /session/:sessionID
```

Lokální klient ho zatím nemá. Doplnit ho do `lua/opencode/client.lua`, compat/profile operation listu a contract testů pro obě podporované verze.

Delete action v pickeru:

- `d` nebo `<C-d>` otevře explicitní potvrzení s title, short ID a rootem;
- active, busy nebo reconciliation-blocked session se nemaže bez bezpečné policy; doporučení je takové řádky označit jako non-deletable;
- po potvrzení znovu ověřit ownership a aktuální detail, aby stale picker nesmazal cizí session;
- lokální registry a picker refreshovat až po úspěšném remote delete;
- 404 řešit refreshnutím inventory, ne lokálním předstíráním úspěchu;
- smazání parent session může smazat i child sessions, proto to musí být v potvrzení explicitně uvedené;
- pokud byla smazaná session poslední selected session, vyčistit pointer až po serverovém úspěchu.

### 5. Pokračování v reusable session a paralelní agenti

OpenCode legacy API pokračování řeší implicitně: nový `prompt_async` na stejném `sessionID` pokračuje v historii. `prompt_async` vrací pouze `204`, proto se nesmí korelovat podle „poslední zprávy“; současná přesná korelace session/message/request ID a následná reconciliation musí zůstat.

Picker selection musí používat `availability == "reusable"`, ne pouze remote `idle`. Legacy status map idle sessions vynechává; absence znamená idle. Lokální nonterminal Job, `pending_apply`, conflict nebo waiting interaction mají přednost před samotným remote statusem.

OpenCode child sessions mají `parentID` a mohou vznikat přes `task` tool. 99 skutečné subagenty nemá; jeho relevantní inspirace je pouze:

- historie requestů se stabilním ID;
- active request count a cancel-all;
- viditelný coarse state;
- action-level `additional_prompt` pro přímý dispatch;
- visual context capture před otevřením UI.

Nekopírovat 99 `Prompt` serialization ani one-shot CLI model. Picker může child sessions seskupovat/odsazovat a zobrazit jejich parent/status, ale nemá se přidávat nový scheduler nebo provider abstraction. Stávající exact SSE routing už umožňuje více concurrent session Jobů; doplnit testy, že picker ani selected pointer nemůže zaměnit child/parent eventy.

Nutná race ochrana: dva rychlé výběry nesmí oba projít reusable checkem a přepsat `active_job_key`. Před revalidate -> Job registration použít existující prompt lock nebo atomický per-session claim a veškeré finální rozhodnutí nechat na `prepare_session()`.

### 6. Okamžitý Build bez prompt window

99 nemá defaultní zkratku a neumí resumovat OpenCode session. Dokumentační příklad `<leader>9d` pouze volá `additional_prompt` s textem `run make test and diagnose failures`. Převzít princip, ne lhs ani model 99.

Pro tento plugin použít namespace `<leader>od` a existující veřejný `require("opencode").prompt(text, opts)`:

- nevolat `ask()`;
- nevolat privátní `api.prompt()` přímo;
- zachovat Context capture, startup, dirty preflight, scope/Base, Job registration, SSE a error handling;
- poslat neprázdný explicitní text, protože `nil` není validní prompt;
- pro visual map zachovat označený range;
- zvolit, zda shortcut pokračuje reusable session, nebo použije `new_session = true`; doporučení pro samostatnou akci je `new_session = true`.

Navržený pevný text, který je třeba ještě schválit při implementaci:

```text
Implement the current target safely and return the required structured replacement.
```

Tím vznikne okamžitý Build request bez UI, ale stále s aktivní lokací/contextem a stávající Build instruction. Pokud se později ukáže, že požadovaný shortcut má pokračovat v session z `<leader>oi`, odstraní se `new_session = true` a použije se explicitní `session_id`.

### 7. One-line prompt a Shift+Enter

Prompt má být jeden řádek pouze při otevření. Navržené chování:

- startovní content height = 1;
- pevná/clamped šířka, aby dlouhý text neroztahoval okno do nekonečna;
- `wrap=true`, `linebreak=true`, takže text za hranicí se vizuálně zalomí;
- výška se přepočítává podle display řádků i skutečných newline, ale nezačíná jako třířádkový editor;
- `<CR>` stále submituje nebo přijme visible completion;
- `<S-CR>` vloží skutečný newline přes existující `insert_newline()` mechanismus;
- `<C-j>` může zůstat jako fallback pro klienty, které Shift sequence nedoručí;
- newline se nesmí chovat jako submit;
- context highlights a completion zůstávají stejné.

Změnit hlavně `lua/opencode/ui/ask/init.lua:13-62,186-195,197-307` a související default `ask.snacks.win` v `lua/opencode/config.lua`. Přidat testy pro počáteční výšku 1, soft-wrap, explicitní `<S-CR>`, růst po skutečném newline, submit a retry.

#### Root cause v aktuální konfiguraci

Aktivní řetězec je:

```text
Windows -> WezTerm -> WSL Ubuntu -> zsh -> tmux -> Neovim
```

Ověřené soubory:

- WezTerm: `/mnt/c/Users/hruby/.wezterm.lua`, build `20240203-110809-5046fc22`;
- WSL: `/etc/wsl.conf`;
- tmux: `/home/hruby/.tmux.conf`, tmux 3.4;
- Neovim: 0.12.0;
- prompt pluginu: `lua/opencode/ui/ask/init.lua`.

WezTerm na `/mnt/c/Users/hruby/.wezterm.lua:176-180` nyní dělá:

```lua
action = act.SendString("\x1b\r")
```

Tím se Shift modifier ztratí ještě před WSL. `ESC CR` je nerozeznatelné od Alt+Enter nebo rychlého Escape+Enter. tmux pak čeká podle `escape-time = 500`, rozešle Escape a Enter, a Neovim buď nic nenamapuje, nebo Escape spustí cancel promptu. `extended-keys` nemůže obnovit modifier, který už není v byte streamu.

Nejmenší doporučená konfigurace je změnit pouze WezTerm binding na:

```lua
action = act.SendString("\x1b[13;2u")
```

`CSI 13;2u` je CSI-u Shift+Enter. Aktuální tmux už má:

```tmux
set -as terminal-features ',xterm-256color:extkeys'
set -s extended-keys on
setw -g xterm-keys on
```

Nejdříve ověřit byte flow. Teprve pokud tmux sequence zahodí, zvažovat `extended-keys always`; nepřidávat naslepo novější option, kterou tmux 3.4 nemusí znát. `allow-passthrough` se Shift+Enter netýká.

Po doručení CSI-u má Neovim přijmout `<S-CR>`, což je správná mapping notation. `<S-Enter>` nepoužívat jako primární spelling.

WSL konfigurace příčinu neřeší: `.wslconfig` řídí VM a `/etc/wsl.conf` distro/interop/automount/systemd, ne terminal keyboard protocol. V aktuálním `/etc/wsl.conf` není žádné relevantní key nastavení.

#### Ověření transportu

Před změnou:

```bash
od -An -tx1 -v
```

Spustit jednou přímo ve WezTerm bez tmux a jednou uvnitř tmux, stisknout Shift+Enter a ukončit `Ctrl-D`. Očekávání před opravou je `1b 0d`.

Po změně očekávat:

```text
1b 5b 31 33 3b 32 75
```

Další ověření:

```bash
wezterm show-keys --lua

tmux display -p '#{client_termname}'
tmux show-options -g extended-keys escape-time terminal-features

tmux -vv new-session -s keytest
```

V Neovimu ověřit decode bez pluginu:

```vim
:lua vim.on_key(function(k) print(vim.fn.keytrans(k)) end)
:verbose imap <S-CR>
```

Výsledek musí být `<S-CR>`, ne `<Esc>`, `<CR>` nebo `<M-CR>`. Teprve potom má smysl testovat prompt mapping.

## Implementační pořadí

1. Aktualizovat acceptance/contract očekávání tak, aby Build-only a no-tmux startup byly explicitní.
2. Odstranit Plan branches a sjednotit dispatch/completion/preflight na Build.
3. Odstranit sidebar/TUI runtime, client, health, interaction a legacy TUI recovery; ponechat pouze jednorázový bezpečný cleanup starého manifestu.
4. Doplnit common `DELETE /session/:id` contract, client metodu a managed-session delete testy.
5. Přidat čerstvý inventory-backed picker s identifikačními řádky, preview/action delete a explicitním `session_id` prompt flow.
6. Přidat reusable/active/stale/race testy pro visual context -> picker -> Build continuation a parent/child session zobrazení.
7. Přidat `<leader>od` immediate Build action přes veřejný `prompt()` s potvrzeným pevným textem.
8. Upravit one-line/wrap prompt a znovu zavést `<S-CR>` plus `<C-j>` fallback.
9. Opravit WezTerm binding a ověřit celý byte transport; pak spustit plugin UI/e2e testy.
10. Aktualizovat dokumentaci a release manifest až po ustálení nových acceptance ID.

## Dokumentace k aktualizaci

Nutné upravit:

- `README.md`: odstranit Plan, sidebar/TUI keymapy, tmux prerequisite a starý multiline popis; přidat `<leader>oi`, `<leader>od`, delete/resume a one-line prompt;
- `docs/PRD.md`: odstranit Plan requirements, shared tmux pane, TUI recovery a starý multiline contract;
- `docs/ARCHITECTURE.md`: přepsat mode/session/TUI ADRs, odstranit `/tui/select-session`, popsat Build-only safety a nový picker;
- `docs/ACCEPTANCE.md`: nahradit Plan/sidebar scénáře Build-only, picker/delete/resume a no-tmux scénáři;
- `docs/CONFIGURATION.md`: odstranit `sidebar.width`, popsat initial one-line + wrap + `<S-CR>`/`<C-j>`;
- `docs/RECOVERY.md`: odstranit TUI attach/retry postup;
- `docs/ROADMAP.md`, `docs/PLAN-F01-F02-done.md`, `docs/PLAN-F07-F08-done.md` a další historické plány: opravit reference na již neexistující picker/TUI contract;
- `docs/release/v2.0-evidence.md`: přegenerovat release evidence.

## Testovací plán

### Unit a integration

- public API přijme Build/default a odmítne `mode = "plan"` s `mode_unavailable`;
- startup a health fungují mimo tmux a neprovádí tmux probing;
- runtime nespouští `opencode attach` ani `/tui/select-session`;
- všechny Jobs mají Build proposal invariants a structured completion;
- Build dirty buffer se uloží bez Plan dialogu;
- question/permission queue funguje bez sidebar hide/show state;
- DELETE contract funguje pro 1.17.3 i 1.18.9;
- picker zobrazuje stable ID, title, updated, status, path a parent/child informace;
- delete vyžaduje potvrzení, chrání active session, refreshuje po success a zvládá stale 404;
- visual context se zachová přes picker;
- reusable selection použije stejný `session_id` a nový message/Job;
- active/busy/blocked selection se nedispatchne;
- cancel picker/prompt nemění poslední session;
- dva concurrent dispatches nemohou přepsat `active_job_key`;
- initial prompt height je 1, soft-wrap roste podle display width a `<S-CR>` vytvoří newline;
- `<CR>` submituje, completion má přednost a retry zachová text.

### E2E a release

Plan/sidebar blok v `tests/e2e/smoke.lua` odstranit a nahradit Build reuse, direct prompt a session picker flow. `tests/e2e/run.sh`, `tests/e2e/tmux_transport.lua` a `tests/e2e/README.md` přestat stavět na TUI attach; tmux už nemá být runtime prerequisite.

Přepsat nebo odstranit odpovídající Plan/sidebar testy v:

- `tests/release/ac/test_ui_context.lua`;
- `tests/release/ac/test_jobs.lua`;
- `tests/release/ac/test_runtime.lua`;
- `tests/release/ac/test_security.lua`;
- `tests/unit/test_public_api.lua`, `test_core.lua`, `test_recovery.lua`, `test_request_status.lua`, `test_f11.lua`;
- `tests/contract/test_profiles.lua` a `test_reasoning_events.lua` podle nového contractu;
- `tests/release/ac/test_merge.lua` podle odstranění sidebar double.

`tests/acceptance.lua` a `tests/release/validator.lua` mají přesnou vazbu acceptance ID <-> dokumentace. Po změně je nutné aktualizovat manifest count a `docs/release/v2.0-evidence.md`, jinak release validation selže.

## Akceptační brány

1. Neovim se spustí a Build prompt funguje mimo tmux.
2. Plugin nevyžaduje ani nespouští `opencode attach`.
3. Neexistuje veřejná Plan cesta, Plan agent není startup dependency a `mode="plan"` selže čitelně.
4. Build proposal/review/apply safety zůstane beze změny.
5. `<leader>oi` zachytí visual selection před pickerem a po výběru otevře Build prompt pro přesně zvolenou reusable session.
6. Active/busy session se nedá omylem použít; stale selection se znovu ověří před dispatch.
7. Picker odliší i sessions se stejným titlem a nabídne potvrzené mazání.
8. Mazání správně varuje před parent/child dopadem a lokální stav změní až po remote success.
9. `<leader>od` neotevře prompt window a projde veřejným Build dispatchem s explicitním textem.
10. Prompt začíná jako jeden řádek, při délce se vizuálně zalomí a `<S-CR>` vloží skutečný newline.
11. WezTerm po opravě posílá `CSI 13;2u`, tmux ho propustí a Neovim dekóduje `<S-CR>`.
12. Všechny acceptance, contract, type-check a format kontroly projdou.

## Otevřené rozhodnutí před implementací

- Přesný pevný text pro `<leader>od`: navržený text je `Implement the current target safely and return the required structured replacement.`
- Zda `<leader>od` vždy vytvoří novou session (`new_session = true`, doporučeno) nebo pokračuje poslední reusable session.
- Zda starý `sidebar` config okamžitě selže jako neznámá konfigurace, nebo se jednorázově toleruje. Pro úplné odstranění je preferována explicitní chyba, ne tichý no-op.
- Zda veřejné `select()` ponechat jako restart/diagnostics menu. Doporučení: ponechat, ale bez TUI volby; nový session picker má vlastní entrypoint/action.
- Zda picker preview načte latest user message lazy. Title + ID + time + status + path jsou dostupné a stačí pro první implementaci.
- Zda konkrétní tmux 3.4 instalace potřebuje `extended-keys always`. Rozhodnout až podle raw-byte testu, ne naslepo.

## Zdroje

### Lokální zdroje

- `lua/opencode.lua`, `lua/opencode/api/prompt.lua`, `lua/opencode/session.lua`;
- `lua/opencode/runtime/init.lua`, `runtime/reconcile.lua`, `runtime/ownership.lua`;
- `lua/opencode/ui/ask/init.lua`, `ui/sidebar.lua`, `ui/status.lua`, `ui/notify.lua`;
- `lua/opencode/context/init.lua`, `context/preflight.lua`, `lua/opencode/interaction.lua`;
- `lua/opencode/client.lua`, `compat.lua`, `health.lua`, `job.lua`;
- `README.md`, `docs/PRD.md`, `docs/ARCHITECTURE.md`, `docs/ACCEPTANCE.md`, `docs/CONFIGURATION.md`;
- test suites listed in the test plan above.

### ThePrimeagen/99

Analyzovaný commit: [`c17422457027c913c76c75a921fca1e623d2678e`](https://github.com/ThePrimeagen/99/commit/c17422457027c913c76c75a921fca1e623d2678e).

- [`lua/99/init.lua`](https://github.com/ThePrimeagen/99/blob/c17422457027c913c76c75a921fca1e623d2678e/lua/99/init.lua): visual capture, `additional_prompt`, history picker;
- [`lua/99/state/tracking.lua`](https://github.com/ThePrimeagen/99/blob/c17422457027c913c76c75a921fca1e623d2678e/lua/99/state/tracking.lua): active requests a cancel-all;
- [`lua/99/providers.lua`](https://github.com/ThePrimeagen/99/blob/c17422457027c913c76c75a921fca1e623d2678e/lua/99/providers.lua): hardcoded Build in one-shot CLI;
- [`README.md`](https://github.com/ThePrimeagen/99/blob/c17422457027c913c76c75a921fca1e623d2678e/README.md): user mapping example `<leader>9d`.

99 nemá conversation sessions, delete session API, skutečné subagents ani defaultní keymaps. Přenositelný je UX princip, ne jeho interní model.

### OpenCode API

Ověřené release tags: `v1.17.3` (`8c8011336163d7e7fb24a6a4a049cdb1f6e6ee74`) a `v1.18.9` (`4da7bb44c84e013fa53e9c5d02ac753d1435c81a`).

- [v1.18.9 session routes](https://github.com/anomalyco/opencode/blob/v1.18.9/packages/opencode/src/server/routes/instance/httpapi/groups/session.ts)
- [v1.17.3 session routes](https://github.com/anomalyco/opencode/blob/v1.17.3/packages/opencode/src/server/routes/instance/httpapi/groups/session.ts)
- [v1.18.9 session schema](https://github.com/anomalyco/opencode/blob/v1.18.9/packages/opencode/src/session/session.ts)
- [official server docs](https://opencode.ai/docs/server/)

Common legacy routes potvrzují list/detail/create/update/delete, `prompt_async`, status, abort a SSE session/message events. Novější `/api` protocol se nemá použít jako common denominator, protože 1.17.3 a 1.18.9 se v něm liší.

### Terminal input

- [WezTerm keyboard encoding](https://wezterm.org/config/key-encoding.html)
- [WezTerm SendString](https://wezterm.org/config/lua/keyassignment/SendString.html)
- [tmux Modifier Keys](https://github.com/tmux/tmux/wiki/Modifier-Keys)
- [Neovim TUI input](https://neovim.io/doc/user/tui/)
- [Neovim mappings](https://neovim.io/doc/user/map/)
- [Microsoft WSL configuration](https://learn.microsoft.com/en-us/windows/wsl/wsl-config)
