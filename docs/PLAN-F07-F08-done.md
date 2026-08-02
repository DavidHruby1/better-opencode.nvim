# Low-level plan F07-F08: Session reuse, přesné routing a paralelní Joby

> Historical implementation plan. Plan and the tmux/TUI sidebar were later removed; this is not an active contract.

## Mandát

| Položka | Hodnota |
|---|---|
| Fáze | F07 Session reuse a přesné event routing; F08 Paralelní Joby a cancellation |
| Capability slice | Uživatel reuse managed Session včetně Plan-to-Build a současně bezpečně provozuje více Jobů v různých Session, i nad nepřekrývajícími se scopes stejného bufferu |
| Závislosti | Dokončený `docs/PLAN-F05-F06.md`, úplná Job state machine a jedna FIFO dialog queue |
| Compatibility | Všechny Session/message/event/cancel contract testy pro OpenCode `1.17.3` i `1.18.9` |

F07 nejprve odstraní poslední single-turn předpoklady. F08 smí zapnout souběh až po důkazu, že late event starého turnu nelze připsat novému Jobu téže Session.

## Acceptance ownership a checkpointy

| Checkpoint | Primárně vlastněné scénáře |
|---|---|
| F07 | `AC-MODE-03`, `AC-JOB-01`, `AC-JOB-02`, `AC-JOB-06`, `AC-JOB-07`, `AC-EVT-01`, `AC-STATE-02` |
| F08 | `AC-SCOPE-06`, `AC-JOB-03`, `AC-JOB-04` |

Runtime-wide souběh zůstane vypnutý, dokud celý F07 řádek neprojde včetně late-event testů. Cancel-all v F08 je prerequisite; jeho multi-runtime scénář zůstává F10 ownership.

## Behavior homes a assigned paths

| Cesta | Změna |
|---|---|
| `lua/opencode/session.lua` | Ownership filtering, availability, activity order, permission revalidation a selected Session |
| `lua/opencode/job.lua` | Per-Job assistant map, cancelling guard, cancel cleanup a diagnostics |
| `lua/opencode/events/init.lua` | Exact live routing a late/unknown reconciliation trigger |
| `lua/opencode/api/prompt.lua` | Reuse/new-session decision, active rejection a Plan-to-Build dispatch |
| `lua/opencode/ui/select_session.lua` | Managed-only picker a Runtime-local TUI selection |
| `lua/opencode/ui/status.lua` | Funkční foreground/background Job seznam; finální polish F11 |
| `lua/opencode/scope/init.lua` | Dispatch i pre-apply all-active overlap validation |
| `lua/opencode/apply.lua` | Order-independent per-Job generation a extmark-safe application |
| `lua/opencode/interaction.lua` | Job-isolated queued dialogs při souběhu |
| `lua/opencode/client.lua` | Session list/detail/status/update/select a abort |

Nevytvářej Session Job queue ani globální `selected/current Job`. Runtime může mít `selected_session_id` pouze jako transcript/UI volbu; routing ji nesmí číst.

## Session a routing kontrakt

Session je managed jen pokud současně platí:

- `metadata.client == "opencode.nvim-inline"`,
- `metadata.contract_version == 2`,
- `metadata.root_hash == sha256(Runtime.root)`,
- nemá archive timestamp,
- `Session.directory` po detail GET canonicalizuje na Runtime root.

Availability je vypočtená, ne uložený třetí state:

- `active(jobID)`, pokud `active_job_key` ukazuje na lokální neterminální Job,
- `reusable`, pokud pointer je nil a remote status idle.

Remote busy bez lokálního active Jobu blokuje Runtime prompty a spouští reconciliation. Remote idle neuvolní Session, pokud lokální Job čeká na apply/conflict/dialog.

Live routing pořadí:

1. Runtime podle konkrétního SSE stream handle,
2. user event podle `sessionID:userMessageID`,
3. assistant `message.updated` podle `sessionID:parentID`, potom atomicky `assistantMessageID -> Job key`,
4. part event pouze přes registrovaný assistant ID v téže Runtime,
5. request bez message ID pouze přes jediný `Session.active_job_key`,
6. terminal/unknown/older event nikdy nemění stav ani buffer.

## Vertikální implementační kroky

### 1. Managed Session inventory a permission revalidation

1. Načti Session list/status Runtime-local a pro kandidáty ověř detail. Foreign, wrong-version, wrong-root a archived pouze filtruj; nemaž ani neupravuj.
2. Stabilní `short_id` odvozuj vždy stejným prefix/suffix pravidlem a detekuj kolizi v picker datasetu rozšířením délky.
3. Před každým reuse znovu pošli exact ordered permission profile přes PATCH a načti detail. Oba frozen profily dokazují append-only PATCH a last-match evaluation, proto verifikuj, že výsledný ruleset končí přesnou požadovanou sekvencí a za ní není žádné pravidlo; starší prefix je přestíněn. Nepředstírej replacement ani cleanup starých rules.
4. Pokud suffix nebo metadata/root nesedí, reuse odmítni. Pro novou Session posílej metadata/rules při create a také ověř response.
5. Retention je remote/OpenCode ownership: plugin Session automaticky nearchive ani nemaže.

Gate: `AC-JOB-06`, parametrizovaný pro oba compatibility profily a rule arrays s existujícím prefixem.

### 2. Session picker a active follow-up rejection

1. Picker dataset obsahuje jen managed unarchived Session aktuálního Runtime; řadí active a reusable skupiny podle poslední aktivity.
2. Každý řádek má project basename, title, unambiguous short ID, last mode a textový availability/state. Barva je doplněk.
3. Výběr vždy zavolá Runtime-local `/tui/select-session`, nastaví `selected_session_id` až po success a přepne pouze sidebar transcript.
4. Active Session lze zobrazit, ale nový prompt do ní se odmítne a nabídne `create new session`; nevytvářej queued Job.
5. Reusable Session lze explicitně zvolit pro další prompt. New-session action volbu resetuje.

Gate: `AC-JOB-01/02`; background event nezmění selected transcript a picker close nemění Session.

### 3. Plan-to-Build continuity

1. Dokončený Plan Job zůstává immutable v Job history/diagnostics; reuse jeho Session nevymění ani znovu neotevře.
2. Nový Build získá fresh target preflight, Base, scope, extmarky a `msg_<ULID>`, ale stejný Session ID/model context. `agent="build"` je per-prompt.
3. Registruj nový Job/active pointer před dispatchí a až poté označ Session activity. Old assistant IDs zůstávají mapované na old terminal Job pro late-event rejection.
4. Build completion používá jen responses s novým parent ID. Old structured response nelze znovu validovat ani aplikovat.

Gate: `AC-MODE-03` s late Plan events během nového Build.

### 4. Exact event correlation a F07 exit

1. Nahraď každý fallback typu selected Session, latest Job nebo latest assistant přesným map lookupem. Assertion test musí selhat, pokud event handler čte UI selection.
2. První assistant update s novým ID lze bootstrapnout jen z matching parent. Part před bootstrapem se nebufferuje pro jiný Job; vyvolá bounded reconciliation diagnostic.
3. User/assistant event pro unknown Job nebo remote busy bez lokálního Jobu zavře prompt gate. Nevytvářej implicitní Job.
4. Terminal Job může doplnit metadata o late-event count, ale transition/apply/dialog jsou no-op.
5. Diagnostika Session uvádí ownership fields, availability reason, active Job short IDs a correlation counts bez contentu.
6. Uzavři `AC-MODE-03`, `AC-JOB-01/02/06/07`, `AC-EVT-01`, `AC-STATE-02` a všechny starší regrese.

### 5. Povolení paralelních Session/Jobů

1. Odstraň Runtime-wide single-active omezení; zachovej právě jeden active Job na Session. Každý Job vlastní Base, Theirs, marks, generation, proposal, temp dir a dialog IDs.
2. Dispatch scope gate iteruje snapshot všech neterminálních Build Jobů stejného bufferu. Překryv odmítne, dotyk povolí. Plan bez scope neblokuje Build jiných Session.
3. Status UI vypíše všechny active Jobs bez změny current window/sidebar selection. Completion/conflict/question/error může poslat základní metadata notification; finální text F11.
4. Event a dialog tests interleave dvě Session a prokazují, že state, proposal a request payload se nikdy nepřepíše.

Gate: isolation integration test s out-of-order SSE a stejnými assistant short suffixes.

### 6. Pre-apply all-active scope gate

1. Bezprostředně po fresh Ours capture a znovu ve final scheduled callbacku načti extmark pair každého neterminálního Build Jobu stejného bufferu.
2. Ověř existence, ordered non-collapsed ranges a pairwise non-overlap. Pro empty-file insertion povol `[0,0)` pouze dokud nekoliduje s jinou insertion na stejné pozici.
3. Pokud edit uživatele vytvořil overlap/kolaps, aplikovaný Job končí `scope_violation`; nemaž marks/proposal druhého Jobu a neaplikuj žádný partial result.
4. Changed span dokončeného Jobu nesmí zahrnout current marks jiného active Jobu. Porušení je fail-closed `scope_violation`, i kdyby merge byl clean.

Gate: `AC-SCOPE-06` s overlap i collapsed mark fixture.

### 7. Order-independent two-scope application

1. Dispatch Job A(alpha) a B(beta) proti stejnému Base v oddělených Session. Zpozdi responses tak, aby se dokončily v obou pořadích.
2. Po první minimal-span mutation ověř, že marks druhého Jobu stále ohraničují stejný logical target. Druhý merge používá svůj původní Base/Theirs a current Ours obsahující první změnu.
3. Final text musí obsahovat každou změnu jednou, disk musí zůstat Base a dva standardní undo kroky musí vracet dvě jednotlivé apply operace v opačném pořadí.
4. Žádný shared temp filename, generation nebo callback nesmí být indexován pouze bufferem/Session; vždy Job key.

Gate: `AC-JOB-03` pro character/function scopes, multibyte prefix a trailing-line fixture.

### 8. Cancel-one

1. `job.cancel(key)` nastaví interní cancelling guard před HTTP, snapshotne owned resources a idempotentně zabrání novému apply/dialog callbacku.
2. Pokud remote Session běží, zavolej exact `/session/:id/abort`; HTTP failure se zaloguje, ale lokální fail-closed cancellation pokračuje.
3. Odstraň pouze Job proposal, extmarky, temp files, InsertLeave callback a queued/current dialog. Current remote request rejectni best-effort.
4. Přejdi `cancelled`, uvolni Session pointer a ignoruj všechny late events. Jiný Job/Session/buffer zůstane beze změny.

Gate: `AC-JOB-04`, včetně abort failure a late structured result.

### 9. Single-runtime cancel-all a F08 exit

1. Snapshotni keys všech neterminálních Jobů aktuální Runtime před prvním cancel. Iteruj snapshot; změna registry během cancelu nesmí přeskočit Job.
2. Volej stejný cancel-one behavior home. Selhání jednoho abortu nezastaví ostatní a výsledný report obsahuje pouze counts/error classes.
3. F10 rozšíří scope na všechny Runtime; nyní příkaz jasně uvádí active root.
4. Spusť paralelní dialog/proposal/event failure injections a celý F01-F07 regression set pro obě OpenCode verze.

Gate: F08 vlastní `AC-SCOPE-06`, `AC-JOB-03`, `AC-JOB-04`. Single-runtime část cancel-all je integrační prerequisite pro F10-owned `AC-JOB-05`.

## Povinné testy

| Vrstva | Minimální důkaz |
|---|---|
| Unit | Ownership filter, permission suffix, availability, activity order, exact routing maps, all-active overlap, cancel resource ownership |
| Neovim integration | Picker/TUI select, Plan-to-Build, two-scope both orders, extmarks after first apply, cancel-one/all, background status focus stability |
| Contract | Session list/detail/status/PATCH, parent/part events, abort a select-session pro oba profiles |
| End-to-end | Reuse, Plan-to-Build a dva real concurrent Jobs přes owned Server/TUI/Neovim pro oba profily; deterministic fake proposal testy jsou pouze doplňkové a nesmí nahradit P0 E2E důkaz |
| Failure injection | Late old turn, part-before-parent, busy without Job, permission revalidation mismatch, abort failure, overlap before apply, out-of-order dialogs |

## Observability a privacy

Status/diagnostika smí používat root basename/hash, Session title/short ID, mode, availability a Job state. Title je remote metadata určené UI, ale neloguj jej do default logu. Notification nesmí změnit selected Session, current window, cursor ani sidebar. Log correlation obsahuje short user/assistant IDs a late-event class, ne message parts.

## Mimo fázi

SSE reconnect, TUI/Server restart, multi-root registry, cross-runtime cancel-all a release UX polish. Nevytvářej Job queue, shared Base per buffer, worktree, implicitní Session recovery ani automatické mazání Session.

## Stop conditions

- PATCH permission semantics se mezi compatibility profily liší od ověřeného append+last-match kontraktu.
- Event nelze přesně přiřadit bez selected/latest fallbacku; použij reconciliation, ne guess.
- Minimal-span apply posune marks druhého Jobu na nesprávný logical text.
- Cancel callback může po terminal transition aplikovat proposal nebo znovu otevřít dialog.
- Paralelní test potřebuje sdílený mutable proposal/temp state.
