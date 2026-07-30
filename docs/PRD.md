# PRD: fork `opencode.nvim` pro bezpečný inline workflow

## Stav dokumentu a autorita

| Položka | Hodnota |
|---|---|
| Stav | Implementačně závazný produktový kontrakt |
| Verze | 2.0 |
| Aktualizováno | 30. 7. 2026 |
| Produkt | Fork `nickjvandyke/opencode.nvim` pro Neovim/OpenCode |
| Upstream baseline | `nickjvandyke/opencode.nvim` commit `7749a034db61258ece828df70a89ff31bb27ff47` |
| OpenCode baselines | `v1.17.3` (`8c8011336163d7e7fb24a6a4a049cdb1f6e6ee74`) a `v1.18.9` (`4da7bb44c84e013fa53e9c5d02ac753d1435c81a`) |
| Jazyk | Čeština |

Tento dokument je autoritou pro produktové chování a rozsah. `docs/ARCHITECTURE.md` je autoritou pro implementační kontrakty a `docs/ACCEPTANCE.md` pro ověření. Při rozporu se nejprve opraví dokumentace; implementace nesmí rozpor řešit skrytým předpokladem.

## Shrnutí produktu

Fork mění `opencode.nvim` z tenkého bridge na Neovim-native nástroj pro inline vývoj. Uživatel zadává prompt přes `snacks.input` u kurzoru, vidí zvolený režim a hard scope a sleduje transcript v pravém OpenCode TUI sidebaru. Build je výchozí režim pro změny kódu, Plan je technicky needitující režim pro analýzu.

Build agent nikdy nezapisuje přímo do source souborů. Vrací strukturovaný návrh změny autorizovaného rozsahu. Plugin z něj vytvoří Theirs, ověří hard scope a provede třícestný merge Base/Ours/Theirs do živého Neovim bufferu. Výsledek se nezapisuje na disk a zůstává jedním undo krokem.

Více Build Jobů může běžet paralelně ve stejném souboru a stejné branch, pokud mají nepřekrývající se hard scopes. Worktrees ani kopie workspace se pro tento workflow nepoužívají.

## Problém

Upstream integrace poskytuje hodnotný input, kontext, completion, event základ a TUI ovládání, ale neposkytuje následující produktové záruky:

1. Agentova změna je návrh, nikoli přímý zápis do workspace.
2. Změna mimo viditelný hard scope se nemůže aplikovat.
3. Souběžné změny uživatele a agentů se slučují bez tiché ztráty dat.
4. Eventy, otázky a oprávnění se nemíchají mezi Joby.
5. Plan je skutečně needitující.
6. Plugin vlastní a bezpečně spravuje svůj OpenCode server i TUI klient.

## Cíle

1. Udržet prompt, transcript, otázky a edit workflow uvnitř Neovimu.
2. Poskytnout rychlý Build nad visual range, funkcí nebo aktuálním souborem.
3. Umožnit bezpečné paralelní Joby nad nepřekrývajícími se rozsahy stejného bufferu.
4. Zachovat uživatelovy neuložené změny pomocí Base/Ours/Theirs merge.
5. Umožnit Plan konzultaci a následný Build ve stejné Session.
6. Zachovat hodnotné upstream UX a odstranit cizí process discovery a blind reload.

## Non-goals pro verzi 2.0

1. Přímé agentní zápisy do source workspace.
2. Worktrees, workspace kopie nebo branch orchestrace.
3. Unscoped nebo multi-file Build.
4. Vytváření, mazání nebo přejmenování souborů a editace binárních souborů.
5. Vlastní transcript renderer v Neovimu.
6. Quickfix jako chatový transcript.
7. Automatický attach nebo discovery cizích OpenCode procesů.
8. Průběžný autosave nebo automatický zápis sloučené změny na disk.
9. Prompt input history; OpenCode transcript a Session historie zůstávají zachované.
10. Vlastní `#command` nebo `#skill` namespace.
11. Specializovaný Review artefakt, Plan-to-scaffold a vlastní Search-to-quickfix workflow.
12. Blockwise visual Build; verze 2.0 podporuje pouze souvislý characterwise nebo linewise range.
13. Přímý TUI prompt jako managed inline edit workflow; podporovaná cesta pro Joby je `snacks.input`.
14. Spouštění OpenCode custom commands; command templates nejsou součástí bezpečného proposal-only workflow verze 2.0.

## Cílový uživatel a hlavní workflow

Primární uživatel je vývojář pracující v Neovimu, který chce delegovat přesně vymezenou úpravu bez opuštění aktivního bufferu. Uživatel:

1. označí rozsah nebo umístí kurzor do funkce,
2. otevře inline prompt,
3. zkontroluje Build/Plan a effective scope,
4. odešle Job do nové nebo reusable Session,
5. pokračuje v editaci,
6. sleduje stav ve status UI a transcript v sidebaru,
7. dostane čistý merge automaticky do bufferu nebo vyřeší skutečný konflikt,
8. může výsledek vrátit standardním Neovim undo.

## Terminologie

| Termín | Význam |
|---|---|
| Server | Pluginem spuštěný headless OpenCode HTTP server pro jeden project root |
| TUI klient | Pluginem spuštěný `opencode attach` proces zobrazený v sidebar terminal bufferu |
| Runtime | Vlastněná dvojice Server + TUI klient pro jeden canonical project root |
| Session | Persistentní OpenCode konverzace; může obsahovat více Jobů v čase |
| Job | Jeden prompt a jeho lokální transakce, identifikovaná `sessionID + userMessageID` |
| Build | Primární OpenCode agent, který navrhuje strukturovanou změnu kódu |
| Plan | Primární OpenCode agent pro analýzu bez write-capable nástrojů |
| Base | Přesný text cílového bufferu, proti kterému vznikl návrh |
| Ours | Aktuální in-memory text bufferu těsně před merge |
| Theirs | Base s přesně aplikovaným strukturovaným návrhem agentovy změny |
| Hard scope | Jediný soubor a autorizovaný half-open byte range v Base |
| Effective scope | Scope zobrazený a potvrzený před odesláním |
| Scope violation | Návrh, jehož Base-to-Theirs diff zasahuje mimo hard scope |
| Reusable Session | Session bez aktivního neterminálního Jobu |

## Produktové invarianty

1. Neovim je primární pracovní plocha; sidebar zůstává skutečný OpenCode TUI.
2. Plugin MUSÍ vlastnit Server i TUI klient a NESMÍ se připojit na cizí proces.
3. Build MUSÍ být výchozí primární agent; Plan MUSÍ být explicitně dostupný primární agent.
4. Režim a effective scope MUSÍ být viditelné před odesláním.
5. Build ani Plan NESMÍ mít možnost použít source `edit`, `bash`, write-capable subagent ani neznámý tool mimo explicitní read-only allowlist.
6. Build změnu kódu navrhuje; jediným zapisovatelem do živého source bufferu je plugin.
7. Každý Build MUSÍ mít hard scope; unscoped Build neexistuje.
8. Scope se MUSÍ vynutit z Base-to-Theirs diffu. Highlight ani prompt instrukce nejsou enforcement.
9. Scope violation MUSÍ odmítnout celý návrh Jobu.
10. Dva aktivní Build Joby se stejným souborem se smějí spustit jen při nepřekrývajících se scopes.
11. V jedné Session smí být nejvýše jeden neterminální Job; follow-up do aktivní Session se nezařazuje do fronty.
12. Routing MUSÍ používat `sessionID + userMessageID` a registrovanou vazbu assistant response na parent user message; samotné `sessionID` nestačí.
13. Čistý merge se MUSÍ aplikovat automaticky, ale NESMÍ se automaticky zapsat na disk.
14. Aplikace MUSÍ být jeden undo krok a NESMÍ použít `:e`, `checktime` ani blind reload.
15. Permission, question a conflict interakce managed Jobů MUSÍ probíhat v nativním Neovim/Snacks UI.
16. Prompt a source obsah se NESMÍ ve výchozím nastavení zapisovat do logu.
17. Plugin-owned TUI MUSÍ být trvale input-locked; focus slouží pouze k Terminal-Normal navigaci a nesmí umožnit odeslat prompt nebo permission/question odpověď.

## Funkční požadavky

### UI

| ID | Požadavek |
|---|---|
| UI-01 | Prompt MUSÍ používat `snacks.input` poblíž kurzoru a po odeslání vrátit focus do source window. |
| UI-02 | Input MUSÍ ukázat Build/Plan, project root a effective scope před odesláním. |
| UI-03 | Prompt input history MUSÍ být vypnutá; Session transcript tím není dotčen. |
| UI-04 | Sidebar MUSÍ automaticky zobrazit aktivní TUI při odeslání, nesmí ukrást focus a musí být toggleovatelný i focusovatelný v input-locked Terminal-Normal režimu. |
| UI-05 | Výchozí sidebar MÁ zabírat přibližně 30 % šířky a MUSÍ být konfigurovatelný. |
| UI-06 | Status UI MUSÍ ukázat Session title, short ID, Job stav a režim; barva nesmí být jediný identifikátor. |
| UI-07 | Background dokončení, konflikt, otázka a chyba MUSÍ vyvolat neinvazivní notifikaci s identitou Jobu. |

### Režimy

| ID | Požadavek |
|---|---|
| MODE-01 | Build MUSÍ být výchozí a musí použít OpenCode primary agent `build`. |
| MODE-02 | Build MUSÍ vrátit strukturovaný replacement; nesmí přímo editovat source filesystem. |
| MODE-03 | Plan MUSÍ použít OpenCode primary agent `plan` s `edit`, `bash` a write-capable `task` nastavenými na `deny`. |
| MODE-04 | Plan NESMÍ vytvořit ani aplikovat source proposal. |
| MODE-05 | Po dokončeném Plan Jobu MUSÍ uživatel umět spustit nový Build Job ve stejné Session a zachovat transcript context. |

### Kontext a preflight

| ID | Požadavek |
|---|---|
| CTX-01 | Fork MUSÍ zachovat `@this`, `@buffer`, `@buffers`, `@visible`, `@diagnostics`, `@quickfix`, `@marks` a operator/visual podporu. |
| CTX-02 | File-backed context MUSÍ používat path/range reference; aktivní editor location MUSÍ být vždy přítomná. |
| CTX-03 | `@this` znamená zachycený visual/operator range, jinak pozici kurzoru; hard scope je samostatný kontrakt. |
| CTX-04 | Kontextové tokeny a OpenCode agenti MUSÍ mít completion a zvýraznění navazující na upstream implementaci. |
| CTX-05 | Plugin NESMÍ vytvářet `#command` ani `#skill`; managed inline input MUSÍ `/command` dispatch odmítnout jako unsupported. Skills se ponechají nativnímu OpenCode skill discovery/tool mechanismu. |
| CTX-06 | Globální a project/directory `AGENTS.md` MUSÍ načítat OpenCode; plugin je NESMÍ duplicitně injektovat. |
| CTX-07 | Cílový buffer Build i Plan promptu MUSÍ mít cestu a být běžný UTF-8 textový file buffer bez NUL; jinak se dispatch zastaví. |
| CTX-08 | Před každým prompt dispatchem MUSÍ dirty target nebo explicitně referencované dirty buffery zobrazit preflight `save and continue` nebo `cancel`; plugin je nesmí uložit potichu. |
| CTX-09 | Base se MUSÍ zachytit až po úspěšném zápisu a dokončení write hooks; buffer a disk se musí shodovat. |
| CTX-10 | Selhání save nebo změna provedená write hookem MUSÍ dispatch zastavit nebo použít až finální uložený obsah jako Base. |

### Hard scope

| ID | Požadavek |
|---|---|
| SCOPE-01 | Scope precedence je: aktivní visual selection, nejbližší Tree-sitter funkce pod kurzorem, celý aktuální soubor. |
| SCOPE-02 | Visual selection se MUSÍ zachytit při vyvolání akce a nesmí se odvozovat ze stale `'<`/`'>` marks. |
| SCOPE-03 | Když Tree-sitter funkci nerozpozná, Build MUSÍ bezpečně spadnout na file scope. |
| SCOPE-04 | Uživatel MUSÍ před odesláním umět explicitně rozšířit range/function scope na file scope. |
| SCOPE-05 | Scope MUSÍ být zvýrazněn a sledován extmarky, ale autorizace MUSÍ používat původní Base scope. |
| SCOPE-06 | Base-to-Theirs diff MUSÍ měnit pouze autorizovaný range a žádný jiný soubor. |
| SCOPE-07 | Jakýkoli out-of-scope hunk MUSÍ ukončit Job stavem `scope_violation`; nic z návrhu se neaplikuje. |
| SCOPE-08 | Nový Build MUSÍ být odmítnut, pokud se jeho current extmark range překrývá s aktivním Build Jobem ve stejném bufferu. |
| SCOPE-09 | Blockwise visual selection MUSÍ být odmítnuta s vysvětlením; nesmí být potichu převedena na souvislý range. |
| SCOPE-10 | Před automatickou aplikací se MUSÍ znovu ověřit platnost a nepřekrývání current extmark ranges; uživatelem vytvořený překryv musí celý Job ukončit jako `scope_violation`. |

### Session a Job

| ID | Požadavek |
|---|---|
| JOB-01 | Plugin MUSÍ před async promptem vytvořit OpenCode-kompatibilní `userMessageID`; Job key je `sessionID + userMessageID`. |
| JOB-02 | Session availability je pouze `active(jobID)` nebo `reusable`; Job error nedělá Session trvale chybnou. |
| JOB-03 | Job stavy jsou `running`, `waiting_user`, `pending_apply`, `conflict`, `completed`, `cancelled`, `error`, `scope_violation`; `conflict` MUSÍ nést kind `agent` nebo `external_change`. |
| JOB-04 | `waiting_user` MUSÍ nést kind `question` nebo `permission`. |
| JOB-05 | Session s neterminálním Jobem MUSÍ odmítnout follow-up a nabídnout založení nové Session; fronta neexistuje. |
| JOB-06 | Session picker MUSÍ zobrazit všechny unarchived plugin-managed Session aktivního Runtime, jejich availability, poslední Job stav a stabilní textovou identitu. |
| JOB-07 | Výběr Session MUSÍ přes `/tui/select-session` přepnout transcript správného plugin-owned TUI. |
| JOB-08 | Uživatel MUSÍ umět zrušit jeden Job i všechny aktivní Joby. Cancel MUSÍ zahodit pending proposal a zabránit aplikaci pozdních eventů. |
| JOB-09 | User-message event se smí přiřadit přes `sessionID + userMessageID`. První assistant `message.updated` se MUSÍ bootstrapnout přes `sessionID + parentID`; teprve další assistant/part eventy používají registrované `assistantMessageID`. Request bez message ID se smí přiřadit jedinému aktivnímu Jobu Session. |
| JOB-10 | Po reconnectu MUSÍ plugin rekoncilovat Session status, messages, pending questions a permissions před přijetím dalších promptů. |
| JOB-11 | Každá vytvořená Session MUSÍ mít plugin ownership/version metadata; cizí nebo archived Session se nesmí automaticky reuse a plugin-managed Session se nesmí automaticky mazat. |
| JOB-12 | Plugin-owned TUI NESMÍ odeslat user message ani control reply; TermEnter/startinsert a pluginové TUI input akce musí být zablokované, zatímco Terminal-Normal scroll/navigace zůstává dostupná. |

### Merge a aplikace

| ID | Požadavek |
|---|---|
| MERGE-01 | Theirs MUSÍ vzniknout deterministicky aplikací validního structured replacementu do Base. |
| MERGE-02 | Ours je aktuální in-memory text bufferu; před merge se nesmí zapisovat na disk. |
| MERGE-03 | Pokud agent dokončí v Insert mode, Job přejde do `pending_apply` a čeká na `InsertLeave`. |
| MERGE-04 | Mimo Insert mode se validace a merge spustí bez zbytečného odkladu. |
| MERGE-05 | Před aplikací MUSÍ plugin ověřit `changedtick`; při změně MUSÍ znovu zachytit Ours a merge přepočítat. |
| MERGE-06 | Merge MUSÍ být třícestný Base/Ours/Theirs a automaticky přijmout identické i nekolizní změny. |
| MERGE-07 | Scope violation je vyhodnocena před merge a nikdy se nezobrazuje jako konflikt. |
| MERGE-08 | Skutečný konflikt MUSÍ nabídnout přesně `keep my changes`, `accept agent changes`, `open manual diff`. |
| MERGE-09 | `keep my changes` MUSÍ vyřešit všechny konfliktní hunks souboru ve prospěch Ours a zachovat všechny nekolizní změny obou stran. |
| MERGE-10 | `accept agent changes` MUSÍ vyřešit všechny konfliktní hunks souboru ve prospěch Theirs a zachovat všechny nekolizní změny obou stran. |
| MERGE-11 | `open manual diff` MUSÍ otevřít Base/Ours/Theirs conflict UI a Job ponechat neterminální do potvrzení nebo zrušení. |
| MERGE-12 | Čistý nebo vyřešený výsledek MUSÍ být aplikován jednou minimální changed-span buffer API operací jako jeden undo krok. |
| MERGE-13 | Aplikace NESMÍ volat write, `:e`, `checktime` ani reload; buffer MUSÍ zůstat `modified`. |
| MERGE-14 | Cursor, window view a platné extmarky se MUSÍ zachovat nebo bezpečně omezit na nový rozsah. |
| MERGE-15 | Pokud se disk od Base odchýlil a neshoduje se s aktuálním Ours, aplikace se MUSÍ zastavit v external-change konfliktu do explicitní reconciliation; plugin nesmí diskovou změnu přepsat ani ignorovat. |
| MERGE-16 | `changedtick` i disk fingerprint se MUSÍ zachytit před merge a znovu ověřit bezprostředně před každou automatickou nebo potvrzenou aplikací. |
| MERGE-17 | Base/Ours/Theirs MUSÍ používat přesně definovaný LF logical-buffer formát, který zachová `fileformat`, `endofline`, `fixendofline`, trailing empty lines a empty file. |

### Permission, question a dialogy

| ID | Požadavek |
|---|---|
| INT-01 | Session permission profile MUSÍ defaultně zakázat všechny tools, povolit jen explicitní read-only allowlist a neoverrideovatelně zakázat `edit`, `bash`, `task`, external writes a neznámé MCP/custom tools. |
| INT-02 | Hard deny se NESMÍ změnit odpovědí v permission dialogu. |
| INT-03 | Ostatní permission requesty managed Jobu MUSÍ přijít do nativního Snacks dialogu s identitou Session/Job; `always` se smí nabídnout jen pro allowlisted tool permission, nikdy pro `read` nebo `external_directory`. |
| INT-04 | OpenCode `question` managed Jobu MUSÍ přijít do nativního pickeru/inputu a odpověď MUSÍ pokračovat ve správném Jobu. |
| INT-05 | Současné dialogy z více Jobů MUSÍ být serializovány ve FIFO frontě; question/permission Job zůstává `waiting_user` a conflict Job zůstává `conflict`. |
| INT-06 | Zavření nebo odmítnutí dialogu MUSÍ odeslat explicitní reject/cancel a nesmí Job ponechat viset. |
| INT-07 | Při managed question/permission requestu MUSÍ plugin již input-locked TUI sidebar skrýt do potvrzeného API reply/reject eventu, aby TUI dialog nebyl druhým viditelným interaction UI. |

### Runtime, kompatibilita a soukromí

| ID | Požadavek |
|---|---|
| RUN-01 | Runtime MUSÍ být klíčován canonical project rootem; každý root má vlastní plugin-owned Server a TUI klient a každý instance request musí být explicitně routován do tohoto rootu. |
| RUN-02 | Sidebar MUSÍ zobrazit TUI aktivního rootu; přepnutí rootu nesmí ukončit background Joby jiných rootů. |
| RUN-03 | Server MUSÍ poslouchat pouze na `127.0.0.1`, použít náhodný volný port a náhodné HTTP Basic credentials uložené pouze v paměti a private mode-0600 ownership manifestu. |
| RUN-04 | Plugin MUSÍ před použitím ověřit `/global/health`, přesnou podporovanou verzi OpenCode `v1.17.3` nebo `v1.18.9` a odpovídající profil požadovaných `/doc` operací. Jiná verze nebo neshoda s profilem je fail-closed compatibility error. |
| RUN-05 | Startup MUSÍ mít timeout a diagnostickou chybu; plugin nesmí fallbacknout na cizí Server. |
| RUN-06 | Pád TUI MUSÍ restartovat jen TUI nad živým Serverem; pád Serveru MUSÍ označit Runtime jako disconnected, zachovat lokální pending data a vyžádat Server reconciliation. |
| RUN-07 | Reconnect MUSÍ proběhnout až po reconciliation; nedokončený Job bez prokazatelného výsledku skončí `error` bez aplikace. |
| RUN-08 | Runtime MUSÍ mít private durable ownership manifest; `VimLeavePre` i příští startup smí po kryptografickém ověření ownership ukončit pouze vlastní procesy a odstranit vlastní temp soubory. |
| RUN-09 | Logy MUSÍ obsahovat pouze metadata jako root ID, short Session/Job ID, state transition a error class. Prompt, replacement a source jsou defaultně zakázané. |
| RUN-10 | Passive pre-spawn config guard a následný effective-config preflight NESMÍ připustit custom plugins, custom tools ani enabled MCP servery; kontrola nesmí plugin/tool kód importovat ani MCP inicializovat. |
| RUN-11 | TUI MUSÍ použít `attach --dir <canonical-root>` a každý HTTP/SSE request MUSÍ nést `x-opencode-directory` se stejným rootem. |

## Job state model

```text
running -> waiting_user -> running
running -> pending_apply -> completed
running -> scope_violation
pending_apply -> conflict -> completed
pending_apply -> scope_violation
conflict -> cancelled
nonterminal -> cancelled
nonterminal -> error
```

`running`, `waiting_user`, `pending_apply` a `conflict` jsou neterminální a drží Session v `active(jobID)`. Po terminálním stavu je Session `reusable`. OpenCode busy bez lokálního Jobu je contract violation, protože input-locked TUI ani plugin nesmí spustit neregistrovaný turn; Runtime v takovém případě zablokuje prompty a spustí reconciliation.

## UX flows

### Build

1. Uživatel vyvolá Build z visual/operator nebo normal mode.
2. Plugin zachytí skutečný invocation range, rozpozná function/file scope a zobrazí ho v inputu.
3. Dirty-context preflight nabídne `save and continue` nebo `cancel`.
4. Plugin zachytí Base, extmarky, vytvoří `messageID` a odešle async structured prompt.
5. TUI sidebar se zobrazí bez změny source focusu.
6. Po odpovědi plugin ověří schema, Base hash, path a scope.
7. V Insert mode čeká na `InsertLeave`; jinak provede merge okamžitě.
8. Čistý výsledek se objeví jako neuložená, undoable změna bufferu.

### Plan a přechod na Build

1. Uživatel zvolí Plan; UI jasně ukáže read-only režim.
2. Dirty-context preflight nabídne `save and continue` nebo `cancel`, aby Plan četl aktuální diskový obsah.
3. Plan může číst projekt, ale nemůže použít write-capable nástroj.
4. Odpověď se zobrazí ve stejném TUI sidebaru.
5. Po dokončení může uživatel v téže reusable Session odeslat nový Build Job.
6. Build převezme transcript context, ale vytvoří nové `userMessageID`, Base a scope.

### Paralelní změny stejného bufferu

1. Job A dostane scope funkce A a Session A.
2. Job B dostane nepřekrývající se scope funkce B a Session B.
3. Oba Joby pracují nad vlastní Base/proposal transakcí a nikdy nepíšou source file.
4. První výsledek se sloučí do bufferu.
5. Druhý třícestný merge zachová první nekolizní změnu a přidá druhou.
6. Překrývající se třetí Job je odmítnut už při dispatchi.

### Konflikt

1. Plugin detekuje překrývající se nekompatibilní změnu Ours a Theirs proti Base.
2. Dialog nabídne pouze tři závazné akce.
3. Volba Ours/Theirs platí pro všechny konfliktní hunks souboru, nikoli pro nekolizní hunks.
4. Manual diff ponechá Job aktivní do explicitního dokončení nebo zrušení.
5. Výsledek se aplikuje do bufferu bez zápisu na disk.

## Upstream fork strategie

Zachovat, pokud splňuje kontrakty:

- `snacks.input`, context rendering a completion,
- keymapy a operator/visual vstupy,
- statusline/event základ,
- health checks,
- TUI terminal/sidebar,
- session selector a TUI select-session transport,
- diff UI jako základ manual conflict workflow.

Nahradit nebo odstranit:

- process discovery přes `pgrep`/`lsof`,
- externí server picker a default attach,
- globální single-current-context stav,
- routing pouze podle Session,
- `file.edited` blind reload,
- přímé Build zápisy do source workspace,
- legacy permission/event předpoklady.

## Vertikální delivery plán

### Slice 1: Vlastněný read-only Plan

Plugin spustí zabezpečený Runtime, otevře inline Plan prompt, odešle context reference, zobrazí odpověď v TUI a bezpečně obslouží shutdown. Slice obsahuje version/API preflight a prokazuje nulové source zápisy.

### Slice 2: Jeden scoped Build bez konfliktu

Build nad visual/function/file scope vytvoří structured replacement, scope gate jej ověří a čistý Base/Ours/Theirs merge vloží jako jeden neuložený undo krok. Slice obsahuje dirty preflight, InsertLeave a fail-closed invalid/scope-violation cesty.

### Slice 3: Interaktivní bezpečnost

Question, permission, cancel, conflict dialog, manual diff, changedtick race a dialog queue fungují end-to-end pro jeden Job.

### Slice 4: Session reuse a paralelní ranges

Session picker, Plan-to-Build follow-up, nová paralelní Session, dva nepřekrývající se Joby ve stejném bufferu, overlap rejection, cancel-one/all a background status fungují bez event mixu.

### Slice 5: Multi-root lifecycle a recovery

Runtime registry obslouží více project roots, TUI switching, crash/restart, SSE reconnect/reconciliation, orphan cleanup a privacy-safe diagnostiku.

Každý slice MUSÍ splnit odpovídající scénáře z `docs/ACCEPTANCE.md`; horizontální infrastruktura bez dokončeného workflow není slice.

## Deferred

1. Multi-file, create/delete/rename a binary Build.
2. Unscoped project-wide Build.
3. Worktree nebo workspace orchestrace.
4. Specializované Search-to-quickfix, Review artefakty a Plan-to-scaffold.
5. Vlastní transcript renderer.
6. Prompt input history.
7. Attach na externí OpenCode procesy.
8. Rozšíření quickfixu nad navigační index.

## Definition of Done

Verze 2.0 je hotová, když jsou dokončeny všechny delivery slices, všechny P0/P1 scénáře v `docs/ACCEPTANCE.md` pro pinovaný OpenCode baseline procházejí a P2 scénáře mají požadovaný důkaz. Build a Plan fungují přes plugin-owned Runtime, každý Job je korelován `sessionID + userMessageID` a assistant-parent vazbou, žádný agent nemůže přímo zapisovat source workspace, hard scope je fail-closed, paralelní nepřekrývající se ranges se bezpečně sloučí, konflikt ani reconnect neztratí uživatelskou práci a aplikovaný výsledek zůstane neuložený a vratný jedním undo krokem.
