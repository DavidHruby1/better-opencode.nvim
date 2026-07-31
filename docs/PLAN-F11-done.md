# Low-level plan F11: UX, privacy, diagnostika a release evidence

## Mandát

| Položka | Hodnota |
|---|---|
| Fáze | F11 UX, privacy, diagnostika a release evidence |
| Capability slice | Hotový produkt je čitelný ve foreground/background režimu, bezpečně diagnostikovatelný a doložený jako v2.0 release candidate pro oba podporované OpenCode profily |
| Závislosti | Dokončené F01-F10 a všechny jejich owned acceptance gates |
| OpenCode matrix | `1.17.3` a `1.18.9`; žádný P0/P1 skip v žádném profilu |

F11 není prostor pro nové workflow ani architektonický refactor. Každá změna musí přímo uzavírat `AC-UI-03`, `AC-UI-04`, `AC-SEC-01`, `AC-SEC-02`, dokumentační mezeru nebo reprodukovatelnost release evidence.

## Acceptance ownership

F11 primárně vlastní právě `AC-UI-03`, `AC-UI-04`, `AC-SEC-01` a `AC-SEC-02`. Všech ostatních 59 scénářů je v této session pouze povinná regrese původního phase ownera; release report nesmí ownership přepsat.

## Assigned paths a behavior homes

| Cesta | Změna |
|---|---|
| `lua/opencode/ui/status.lua` | Finální textová Runtime/Session/Job identita a foreground/background přehled |
| `lua/opencode/ui/notify.lua` | Jediné notification formátování a focus-safe emit |
| `lua/opencode/health.lua` | Praktický hard/warning capability report pro oba compatibility profily |
| `lua/opencode/log.lua` | Final whitelist schema, path/secret redaction a audit hooks |
| `lua/opencode/config.lua` | Pouze dokumentované v2.0 volby a validace; žádné speculative options |
| `README.md` | Instalace, minimální quick start, Build/Plan workflow, keymaps a bezpečnostní model |
| `docs/CONFIGURATION.md` | Úplná podporovaná konfigurace a defaults |
| `docs/RECOVERY.md` | Health chyby, conflicts, disconnect, orphan/manual cleanup a no-data-loss postupy |
| `docs/MAINTAINERS.md` | Baselines, fixture capture, test matrix, upgrade procedure a release checklist |
| `docs/release/v2.0-evidence.md` | Generovaný/aktualizovaný auditovatelný acceptance report |
| `tests/release/` | Privacy audit, AC manifest validator a P2 protocol fixtures |

Nevytvářej druhý status cache nebo logger wrapper. Status čte registry přes read-only snapshot API; notification přijímá immutable metadata snapshot, ne live selected context.

## Vertikální implementační kroky

### 1. Acceptance inventory a nulová dluhová základna

1. Vytvoř machine-readable `tests/acceptance.lua` se všemi 63 AC IDs, priority, owning phase, automatizovaným test commandem nebo P2 manual protocol path. Toto je report metadata, ne nová autorita nad `docs/ACCEPTANCE.md`.
2. Validator porovná IDs z dokumentu a manifestu: žádný missing/duplicate owner, každý P0/P1 má automatizovaný test a každý P2 automatizovaný test nebo uložený protocol.
3. Spusť všechny F01-F10 gates pro oba OpenCode profily dříve než UX edit. Oprav jen regression/blocker; širší cleanup odlož.
4. Zaznamenej pre-existing flaky/manual-only scénáře. P0/P1 flaky nebo skipped je stop condition, ne release note.

Gate: úplný inventory report s nulou unknown/missing P0/P1.

### 2. Textově jednoznačný status

1. Status snapshot pro každý Runtime obsahuje root basename, Runtime state, compatibility version a počty active/reusable Sessions/Jobs. Session řádek obsahuje title, collision-safe short ID, last mode, availability a exact Job state/kind.
2. Barva/icon může doplňovat, ale odstraněním highlights musí zůstat všechny identity/stavy odlišitelné. Nepoužívej pouze spinner nebo generic busy.
3. Foreground status označí active sidebar root/selected Session textem; background Jobs zůstanou viditelné bez přepnutí.
4. Status render nesmí provádět HTTP, měnit registry ani otevírat window. Čte jeden immutable snapshot, aby se během renderu nesmíchaly generations.
5. Dlouhé title/root bezpečně zkrať display-width funkcí; short ID/state se nesmí oříznout.

Gate: `AC-UI-03` automatizovaný screenshot/text snapshot s vypnutými barvami a kolidujícími short IDs.

### 3. Neinvazivní notifications

1. `ui/notify.lua` má explicitní templates pro completed, conflict(agent/external), question, permission a error/scope_violation. Každá obsahuje root basename, Session short ID, mode a textový state.
2. Notification se vytvoří z event-owning Job snapshotu, nikdy ze selected Session/active root. Neobsahuje prompt, summary/replacement, path ani diff.
3. Před emit zachyť current window/cursor/sidebar buffer a po callbacku assertion-testuj, že se nezměnily. Produkční kód je nemá aktivně obnovovat, protože notify nesmí focus měnit vůbec.
4. Dedupuj terminal notification podle root+Job key+terminal state. Conflict/question notification může být jednou při enqueue, ne při každém queue refresh/reconnect.
5. Notification config dovolí pouze enable/disable a standardní `vim.notify` options potřebné kontraktem; nepřidávej provider framework.

Gate: `AC-UI-04` se čtyřmi background Jobs a sidebar Session odlišnou od všech čtyř.

### 4. Praktický health check

1. Přepiš upstream health bez shell-interpolovaného `cd`, bez vypisování celé `vim.g.opencode_opts` a bez `pgrep/lsof` kontrol.
2. Hard errors s konkrétní nápravou: Neovim `>=0.11.0`, Snacks module + enabled input/picker, `curl` pokud zůstává produkční transport, OpenCode executable exact `1.17.3|1.18.9`, odpovídající `/doc` profile při safe temporary owned probe, `git merge-file -p --diff3`, loopback bind, terminal `jobstart(term=true)` API a writable private state/temp dirs.
3. Tree-sitter parser pro active/supported languages je warning s file-scope fallbackem; Lua parser/adapter fixture musí být přítomná v release test prostředí.
4. Config guard reportuje pouze source scope a unsupported key/type, ne config values. Ownership warning poskytne bezpečný odkaz na `docs/RECOVERY.md`.
5. Health nesmí startovat MCP, importovat plugin/tool, připojit foreign Server ani měnit active Runtime. Pokud exact API probe vyžaduje Server, použij explicitní user-triggered bounded owned probe a vždy cleanup.
6. Zobraz selected compatibility profile a fixture SHA, aby mismatch byl actionable.

Gate: `AC-SEC-02`, parametrizované missing dependency/version/profile/parser fixtures.

### 5. Metadata-only logging audit

1. `log.lua` přijímá pouze whitelist record fields z architektury. Nepřijímej arbitrary table/message body; unknown field odmítni v test/dev a dropni s error class v production.
2. Root ukládej jako SHA-256 a volitelný basename pouze UI, ne log. Session/message IDs zkrať deterministicky. URL normalizuj na endpoint path bez host/port/query/auth.
3. Error mapping převádí transport/process/schema chyby na enum-like classes před logem. `tostring(error)` z curl/OpenCode se nesmí logovat, pokud může obsahovat body/argv/env/path.
4. Vlož unikátní secret canaries do promptu, source, Base/Ours/Theirs, proposal summary/replacement, question/answer, permission pattern, credentials, home/root path a HTTP error body.
5. Proveď success, conflict, scope violation, HTTP error, reconnect, cancel a shutdown. Prohledej default log i captured notifications/status; žádný forbidden value/substring nesmí uniknout.
6. Explicitní content-debug mode nepřidávej.

Gate: `AC-SEC-01` pro oba compatibility profily a alespoň jeden multi-root run.

### 6. Uživatelská dokumentace

1. `README.md`: uveď fork původ/licenci, Neovim/Snacks/OpenCode/Git/curl dependencies, přesně dvě podporované OpenCode verze, konfiguraci binary, minimal keymaps pro default Build, explicit Plan, select Session, cancel one/all, sidebar toggle/focus a health.
2. Vysvětli proposal-only workflow pravdivě: oba exact profily filtrují hard-denied a unknown tools z final model surface přes ordered Session rules a současně používají execution-time hard deny na fresh isolated Serveru. Custom plugins/tools a enabled MCP Runtime navíc blokují preflight guards.
3. Popiš hard scope, dirty preflight, clean merge, one undo, modified/no autosave, conflicts, external reconciliation, Plan-to-Build, parallel non-overlap a multi-root.
4. Jasně označ deferred: multi-file/create/delete/rename, blockwise, worktrees, external attach, prompt history, managed custom commands a další OpenCode verze.
5. `CONFIGURATION.md` dokumentuje pouze skutečné options z `config.lua`, default, type, scope a restart requirement. Automatický test porovná documented option keys s defaults.
6. `RECOVERY.md` poskytne bezpečné kroky bez doporučení `killall`, `pgrep`, blind manifest delete, reload nebo overwrite Ours.

Gate: všechny README příklady projdou headless load/syntax smoke; documented defaults match config.

### 7. Maintainer dokumentace a baseline upgrade procedure

1. `MAINTAINERS.md` popíše přesný upstream plugin import, oba OpenCode commits, jak bezpečně capture `/doc`, spočítat SHA, přidat explicit compatibility profile a spustit contract/e2e matrix.
2. Zdůrazni, že support není semver range. Nová OpenCode verze vyžaduje source audit tool construction/permissions, route/schema diff, frozen fixture a všechny P0/P1 tests.
3. Dokumentuj append semantics Session PATCH permissions, `info.structured`, SSE `event: message` + JSON `type`, root header, fresh approval assumption a profile-specific extra events v `1.18.9`.
4. Popiš release commands shodně s CI: format, LuaLS, unit, integration, contract pro obě verze, real e2e pro obě verze, failure injection, privacy scan a evidence generation.
5. Pinuj external CI actions/tool versions podle repository policy; nevytvářej auto-upgrade OpenCode job, který by měnil baseline bez review.

Gate: nový checkout podle dokumentu reprodukuje fixtures checksums a test commands.

### 8. P2 protocols a release evidence

1. Automatizuj `AC-UI-03/04` a `AC-SEC-02`, pokud harness umí deterministicky zachytit výstup. Pokud část zůstane manual, vytvoř pod `tests/release/protocols/` přesný setup, commands, expected observations, artifact names, tester/date/profile fields.
2. Evidence generator načte acceptance manifest a test result artifacts; nevydává PASS bez exit code/artifact. Manual PASS vyžaduje vyplněný reprodukovatelný protocol.
3. `docs/release/v2.0-evidence.md` obsahuje pro každý AC ID priority, owner, profiles, test/protocol, result a artifact/checksum. P0/P1 skip nebo chybějící profile nastaví overall FAIL.
4. Samostatné negative assertions shrnou: no source disk write, no stale apply, no cross-Job/root event, no unauthorized execution, no foreign process termination, no Ours loss, no whole-buffer/reload a one undo.
5. Report nesmí embedovat logs s contentem, credentials nebo absolute home paths. Artifact references jsou repository-relative nebo CI IDs.

Gate: evidence validator odmítne záměrně odstraněný test result, skipped P0, chybějící `1.17.3` run a nevyplněný P2 protocol.

### 9. Finální release-candidate run

Spusť čistě od importu dependencies celý matrix:

1. StyLua a LuaLS.
2. Unit a Neovim integration na minimálním Neovim `0.11.0` a podporovaném stable CI editoru.
3. Frozen contract suite pro `1.17.3` a `1.18.9`.
4. Real owned Server+TUI e2e pro oba profily, včetně Plan, Build, question/permission, conflict, reuse, parallel, reconnect, multi-root a shutdown.
5. Failure injection a privacy canary scan.
6. P2 automation/protocol collection a evidence generation.

Release candidate je PASS pouze pokud všechny dřívější exit gates i `AC-UI-03`, `AC-UI-04`, `AC-SEC-01`, `AC-SEC-02` projdou a evidence uvádí nulu P0/P1 skips.

## Povinné testy

| Vrstva | Minimální důkaz |
|---|---|
| Unit | Status/notification templates, collision-safe IDs, log whitelist/redaction, config-doc parity, evidence manifest validation |
| Neovim integration | Focus-safe notifications, colorless status, health fixtures, README examples |
| Contract/e2e | Oba exact OpenCode profiles bez unknown fallbacku |
| Failure/privacy | Canary scan přes všechny hlavní success/failure/recovery paths |
| Release | Úplný AC manifest a reprodukovatelné P2 artifacts/protocols |

## Mimo fázi

Nové workflow, další compatibility profil, model picker, debug-content logging, telemetry, plugin/provider abstraction, design refactor bez failing gate, external Server attach nebo automatický release approval. F11 připraví evidence; nemění produktový kontrakt, aby report vyšel zeleně.

## Stop conditions

- Kterýkoli P0/P1 scénář je skipped/flaky nebo chybí pro jeden podporovaný OpenCode profil.
- Health/diagnostika vyžaduje foreign discovery, vypisuje config/secrets nebo inicializuje MCP.
- Status/notification identita závisí pouze na barvě nebo selected global contextu.
- Privacy canary unikne do logu, notification, statusu nebo release artifactu.
- Evidence nelze navázat na konkrétní test exit/artifact nebo dokumentovaných 63 AC IDs.
- Oprava vyžaduje nový product scope či změnu safety invarianty; vrať se do autoritativních dokumentů místo lokální výjimky.
