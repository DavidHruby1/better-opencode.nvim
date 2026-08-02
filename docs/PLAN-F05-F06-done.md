# Low-level plan F05-F06: konflikty, reconciliation a autoritativní dialogy

> Historical implementation plan. The tmux/TUI sidebar was later removed; this is not an active contract.

## Mandát

| Položka | Hodnota |
|---|---|
| Fáze | F05 Konflikty a disková reconciliation; F06 Questions, permissions a dialog queue |
| Capability slice | Jeden Build bezpečně vyřeší agentní nebo external-disk konflikt a všechny managed interakce probíhají sériově v nativním UI bez možnosti obejít hard deny |
| Závislosti | Dokončený `docs/PLAN-F03-F04.md`; Job umí `pending_apply` a uchovat immutable conflict payload |
| Compatibility | Každý HTTP/SSE interaction test běží pro OpenCode `1.17.3` i `1.18.9` profil |

F05 nejprve dokončí conflict workflow pro jeden Job. F06 potom sjednotí question, permission a oba conflict kinds v jediné FIFO frontě. Nevytvářej dočasný druhý queue systém v F05; `interaction.lua` vznikne hned, F05 v něm používá jen conflict requests.

## Acceptance ownership a checkpointy

| Checkpoint | Primárně vlastněné scénáře |
|---|---|
| F05 | `AC-MERGE-06`, `AC-MERGE-07`, `AC-MERGE-09`, `AC-MERGE-11` |
| F06 | `AC-EVT-02`, `AC-INT-01`, `AC-INT-02`, `AC-INT-03`, `AC-INT-04`, `AC-STATE-01` |

Question/permission behavior se zapne až po průchodu F05 conflict checkpointu. Shared queue kód může vzniknout v F05, ale F06 scénáře tím nepřecházejí pod F05.

## Behavior homes a assigned paths

| Cesta | Změna |
|---|---|
| `lua/opencode/merge.lua` | Přidat conflict-preference `--ours`/`--theirs`; zachovat jediný process backend |
| `lua/opencode/apply.lua` | Čerstvé disk/buffer revalidace pro automatic, preference, retry a manual confirmation |
| `lua/opencode/job.lua` | Úplná transition matice, waiting/conflict kinds a immutable dialog payload |
| `lua/opencode/interaction.lua` | Jediná globální FIFO fronta a přesně jeden displayed request |
| `lua/opencode/ui/dialog.lua` | Snacks question/permission/conflict UI a explicitní close semantics |
| `lua/opencode/ui/diff.lua` | Agentní Base/Ours/Theirs manual diff a external disk diff lifecycle |
| `lua/opencode/ui/sidebar.lua` | Managed visibility lock nad permanentním input lockem |
| `lua/opencode/events/init.lua` | Runtime-local routing question/permission/reply/reject eventů |
| `lua/opencode/client.lua` | Canonical question/permission list/reply/reject endpointy |

`interaction.lua` je jediný oprávněný globální mutable stav, protože kontrakt vyžaduje FIFO napříč Runtime. Fronta obsahuje identity, ne current Runtime/Session. Každý callback znovu dohledá Runtime a Job podle immutable root+Job key; nesmí uzavírat nad globálním current contextem.

## Datové kontrakty

### Job state machine

Implementuj explicitní tabulku povolených přechodů a jednu funkci `job.transition(job, next, attrs)`. Setter mimo tuto funkci je zakázaný.

```text
running -> waiting_user(question|permission) -> running
running -> pending_apply | scope_violation | cancelled | error
pending_apply -> completed | conflict(agent|external_change) | scope_violation | cancelled | error
conflict(agent|external_change) -> completed | cancelled | error
```

Terminální transition je idempotentní jen při opakování stejného cíle; jiný transition z terminal state se odmítne bez side effectu. `waiting_user` vyžaduje `waiting_kind`; návrat do running jej smaže. `conflict` vyžaduje `conflict_kind` a immutable payload; opuštění conflict payload smaže právě jednou.

### DialogRequest

```lua
DialogRequest = {
  id = string,              -- local monotonic/ULID identity
  kind = "question" | "permission" | "agent_conflict" | "external_change",
  root = canonical_root,
  session_id = string,
  session_short_id = string,
  job_key = string,
  request_id = nil | string,
  payload = table,          -- immutable copy, nikdy loggable
  state = "queued" | "shown" | "awaiting_confirmation" | "closed",
}
```

Queue API smí pouze enqueue, remove-by-job, complete-current a advance. Duplicita stejného remote request ID+Job key je idempotentní. Žádný Job nesmí být `waiting_user` bez queued/shown/awaiting requestu.

## Vertikální implementační kroky

### 1. Agent conflict preference bez whole-file overwrite

1. Pro conflict Job použij původní immutable Base/Theirs, ale před každým rozhodnutím zachyť fresh Ours, changedtick a disk fingerprint.
2. `keep my changes` spouští `git merge-file -p --ours <ours> <base> <theirs>`, `accept agent changes` analogicky `--theirs`. Nepoužívej raw Ours nebo Theirs jako výsledek.
3. Preference řeší všechny conflict hunks jednou volbou a zachovává clean hunks obou stran. Neočekávaný process result je `error` bez apply.
4. Výsledek jde stejnou `apply.lua` minimal-span cestou jako clean merge, včetně extmark overlap, changedtick/disk second check, one mutation a one undo.

Gate: process fixtures s nejméně dvěma conflict hunks a jedním non-conflict hunkem dokazují správný obsah pro obě volby. Raw whole-file equality nesmí být implementační zkratka.

### 2. Manual Base/Ours/Theirs diff lifecycle

1. `ui/diff.lua` vytvoří čtyři scratch buffery: read-only Base, captured Ours, Theirs a editable result inicializovaný diff3 outputem. Buffery mají Job-local names, `bufhidden=wipe`, žádný source path a žádný swap/undo file.
2. Otevři vlastní tabpage/layout bez změny source bufferu. Source Session zůstává active a Job `conflict(agent)`; manual diff je pokračování stejného DialogRequest.
3. Confirm načte result jako UTF-8 logical text bez NUL/CR, vrátí se na source, provede fresh buffer/path/extmark/disk checks a aplikuje přes jediný `apply.lua` behavior home.
4. Pokud se source nebo disk změnil, manual result se neaplikuje. Přejdi do fresh external-change handling nebo obnov agent conflict s novým payloadem podle klasifikace; nikdy automaticky nepřepiš result/source.
5. Cancel/q/invalid buffer close zavře všechny Job-owned diff buffery, zachová source Ours a ukončí Job `cancelled` právě jednou.

Gate: `AC-MERGE-07`, včetně source unchanged assertion před confirm, one undo po confirm a cleanup při ručním wipe jednoho diff bufferu.

### 3. External-change reconciliation

1. Zachovej klasifikaci `disk==Base`, `disk==Ours`, jiný disk z F04. Jiný disk přejde atomicky do `conflict(external_change)` s payloadem obsahujícím jen private snapshots/fingerprints.
2. Dialog nabízí přesně `open external diff`, `retry apply`, `cancel`. External diff je read-only srovnání current buffer Ours a fresh disk; nesmí reloadnout source ani nabízet automatický overwrite.
3. `retry apply` nejprve vyžaduje fresh canonical disk logical text přesně rovný fresh Ours. Jinak zůstane conflict a UI vysvětlí nutnost explicitní user reconciliation/save.
4. Po splnění podmínky zahoď starý merge výsledek a spusť nový Base/fresh Ours/Theirs merge. Před apply znovu ověř raw disk fingerprint a changedtick ve stejném callbacku.
5. Stejný disk race guard použij před automatic apply, Ours/Theirs preference i manual confirm. Failure injection hook umísti mezi process completion a final callback, ne do produkčního rozhodování.

Gate: `AC-MERGE-09/11`; navíc regrese `AC-MERGE-10` dokazuje, že saved Ours není external conflict.

### 4. F05 queue integration a exit

1. Všechny conflict transitions vytvoří přesně jeden `DialogRequest`; `interaction.lua` zobrazí jeden request a další drží FIFO, i když v F05 běží typicky jeden Job.
2. Agent dialog má přesně tři požadované labels; external dialog přesně tři vlastní labels. Close se mapuje na cancel, ne na tiché ponechání conflict bez requestu.
3. Completion/cancel/error odstraní queued i current request a pokračuje dalším. Stale UI callback pro odstraněný request je no-op.
4. Spusť F01-F04 regrese a uzavři `AC-MERGE-06`, `AC-MERGE-07`, `AC-MERGE-09`, `AC-MERGE-11`.

### 5. Request routing bez message ID

1. SSE handler nejprve zná Runtime ze streamu a Session z eventu. `question.asked`/`permission.asked` bez message ID smí mapovat pouze `Session.active_job_key`.
2. Ověř, že nalezený Job je neterminální a patří téže Session/root. Bez jediného Jobu nezobrazuj dialog, zablokuj nové prompty Runtime a spusť fail-closed reconciliation hook připravený pro F09.
3. Dedupuj live event proti pending-list response pomocí remote request ID+Session. Nikdy nevytvoř implicitní Job.
4. Matching replied/rejected event je autorita pro dokončení interaction locku; samotný HTTP 2xx pouze přepne request do `awaiting_confirmation`.

Gate: `AC-EVT-02` pro live i duplicate/pending-list fixtures na obou compatibility profilech.

### 6. Questions

1. Při accepted question eventu atomicky přejdi `running -> waiting_user(question)` a enqueue request.
2. `ui/dialog.lua` použije Snacks picker pro options a Snacks input pro free text podle exact question schema fixture. Odpověď serializuj jako `answers: string[][]` v pořadí remote questions.
3. Reply odešli pouze na exact `/question/:requestID/reply`. Close/cancel odešle `/reject`; při HTTP failure ponech request rekoncilovatelný a zablokuj prompt, ale nezobrazuj další dialog jako by byl potvrzen.
4. Po matching replied eventu přejdi zpět do `running`, smaž request a advance queue. Late event terminal Job nemění state.

Gate: `AC-INT-01`; assertion, že odpověď Jobu B nikdy nezasáhne Job A ani při stejném question textu.

### 7. Permissions a execution-time hard deny

1. Vytvoř explicitní policy funkci nad permission name, patterns a případnou tool identity. Výstup je `hard_reject`, `ask_once`, nebo `ask_once_always`. Surface filtering z exact OpenCode profilů je první obranná vrstva; UI policy a execution deny jsou nezávislá druhá vrstva pro neočekávaný request.
2. `edit`, `write`, `apply_patch`, `bash`, `task`, external write/path a unknown/custom/MCP capability jsou `hard_reject`: canonical API reject bez UI, Job přejde fail-closed do `error`, Runtime zavře prompt gate a spustí reconciliation. Plugin nikdy neposílá `once` ani `always` a žádný pozdější event nesmí tento Job vrátit do running.
3. `read` a `external_directory` nikdy nenabídnou `always`. Schvalovatelné explicitně allowlisted capabilities mohou nabídnout API-supported once/always/reject.
4. Fresh owned Server a passive/effective config guards jsou povinný předpoklad. Test fixture s custom tool musí být zastaven při Runtime preflightu; pluginy a MCP se ignorují bez volání `/mcp`. Instrumentovaný final LLM request prokáže, že wildcard/hard rules odfiltrují unknown/edit/bash/task i při předvyplněném Server-wide edit approval.
5. Matching permission reply event vrací Job do running pouze u dříve schvalovatelného requestu. Close posílá reject. Unknown action/schema a každý hard-deny request jsou terminal error plus reconciliation.
6. Contract/source-backed testy pro oba profily dokazují final model surface filtering, execution denial a nemožnost vytvořit hard-deny approval podporovaným UI. Test musí selhat, pokud se permission ordering nebo `Permission.disabled` call path změní.

Gate: `AC-INT-02` a regrese `AC-MODE-01/02` pro oba OpenCode profily.

### 8. Globální FIFO a managed visibility lock

1. Enqueue ordering stanov monotonic sequence při přijetí v Neovim main loop. Žádné priority podle kind/root.
2. Při show question/permission ve stejném scheduled callbacku ulož sidebar visibility a source return window, nastav `Runtime.interaction_locked=true`, skryj sidebar a zablokuj plugin toggle/focus/select-session.
3. Permanentní terminal input lock zůstává aktivní. TUI proces běží, ale uživatel nevidí druhý remote dialog.
4. Lock uvolni až matching replied/rejected eventem nebo výsledkem explicitní reconciliation, ne HTTP response. Obnov předchozí visibility bez focus steal, pokud jsou původní window/buffer stále validní.
5. Conflict dialog sidebar skrývat nemusí, ale prochází stejnou FIFO. TUI crash během locku nesmí odstranit request; recovery seam zavolá F09.
6. Cancel/termination odstraní všechny Job requests. Pokud je current remote question/permission, odešli reject best-effort a lokálně jej uzavři fail-closed; queue vždy postoupí.

Gate: tři interleaved requesty různých kinds/Jobs zachovají FIFO, zavření explicitně uzavře první a žádný Job nezůstane waiting bez requestu. Uzavři `AC-INT-03/04`.

### 9. Úplná transition a regression suite

1. Unit test vygeneruje cartesian product všech stavů a ověří každou povolenou/zakázanou hranu, povinné kind a idempotenci.
2. Session zůstane active přes waiting, pending_apply a conflict. OpenCode idle ji neuvolní.
3. Spusť oba compatibility profily a všechny starší AC, zejména source no-write, one undo, stale disk a input lock.
4. Uzavři `AC-STATE-01`; `AC-STATE-02` vlastní F07.

## Povinné testy

| Vrstva | Minimální důkaz |
|---|---|
| Unit | Transition matrix, policy classification, queue dedupe/order/removal, conflict process args, disk retry predicate |
| Neovim integration | Oba conflict dialogs, manual diff confirm/cancel, external diff, visibility/focus lock, three-request FIFO |
| Contract | Question/permission list/reply/reject payloady a events pro oba `/doc` fixtures |
| End-to-end | Real question a schvalovatelná permission; hard-denied edit execution; agent conflict resolution bez disk write |
| Failure injection | Disk race na každé apply cestě, dialog close, HTTP reply failure, duplicate/late event, TUI crash seam, diff buffer wipe |

## Observability a privacy

Log smí přidat `dialog_kind`, local request short ID a queue length. Nesmí obsahovat question text/answers, permission patterns, filenames, Base/Ours/Theirs, diff/result ani remote metadata. Notification zobrazuje Session short ID a stav, ne payload. Secret scan pokryje všechny čtyři dialog kinds.

## Mimo fázi

Session picker/reuse, přesný multi-turn event routing, skutečně paralelní Joby, cancel-all, reconnect reconstruction, multi-root a finální notification/status polish. Nevytvářej merge-both, per-hunk preference, auto-save/reload, background dialog priority ani generic policy plugin API.

## Stop conditions

- Jeden compatibility profil má odlišný question/permission payload, který není zachycen exact profile fixture.
- Hard-denied execution na fresh isolated Serveru lze schválit některou podporovanou UI cestou.
- Final apply check musí yieldnout mezi fingerprintem a mutation.
- Snacks dialog nelze spolehlivě zavřít/rejectnout bez visícího Jobu.
- Manual diff by vyžadoval edit source bufferu před explicitním confirm.
