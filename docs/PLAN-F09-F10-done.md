# Low-level plan F09-F10: recovery, multi-root lifecycle a shutdown

## Mandát

| Položka | Hodnota |
|---|---|
| Fáze | F09 Reconnect a single-root recovery; F10 Multi-root lifecycle a shutdown |
| Capability slice | Výpadek TUI/SSE/Serveru se rekonciluje fail-closed a jedna Neovim instance provozuje více přesně izolovaných root Runtime bez cross-root zásahu |
| Závislosti | Dokončený `docs/PLAN-F07-F08.md`, exact event routing, paralelní Job ownership a single-runtime cancel-all |
| Compatibility | Recovery i multi-root suite běží pro OpenCode `1.17.3` a `1.18.9` odděleně; Runtime nikdy nemíchá profily |

F09 se implementuje a uzavře nejprve nad jediným Runtime. F10 teprve potom změní cardinalitu registry. Nevytvářej v F09 alternativní singleton recovery cestu; stejné funkce musí přijímat explicitní Runtime objekt, aby je F10 pouze registry-orchestrated volala.

## Acceptance ownership a checkpointy

| Checkpoint | Primárně vlastněné scénáře |
|---|---|
| F09 | `AC-RUN-08`, `AC-EVT-03`, `AC-EVT-04`, `AC-EVT-05` |
| F10 | `AC-RUN-05`, `AC-RUN-06`, `AC-JOB-05` |

Root registry cardinalita zůstane jedna, dokud celý F09 řádek neprojde. F10 znovu spouští uvedené roadmap regrese, ale nepřebírá jejich primární ownership.

## Behavior homes a assigned paths

| Cesta | Změna |
|---|---|
| `lua/opencode/runtime/init.lua` | Prompt gate, TUI/Server lifecycle; v F10 root-keyed registry a active root |
| `lua/opencode/runtime/reconcile.lua` | Jediný algoritmus status/messages/pending requests reconciliation |
| `lua/opencode/runtime/ownership.lua` | Restart generations, verified stale manifests a cross-runtime cleanup |
| `lua/opencode/client.lua` | SSE reconnect lifecycle, exact profile, Runtime-bound requests a transport cancellation |
| `lua/opencode/events/init.lua` | Stream generation guard a dispatch jen do owning Runtime |
| `lua/opencode/ui/sidebar.lua` | TUI buffer recovery a active-root terminal switching |
| `lua/opencode/session.lua` | Reconciled remote status, selected Session a root-local inventory |
| `lua/opencode/job.lua` | Reconciliation completion-once a disconnected preservation |
| `lua/opencode/interaction.lua` | Pending request reconstruction a skutečně cross-runtime FIFO |
| `lua/opencode/api/prompt.lua` | Prompt rejection během disconnect/reconciliation |

Nevytvářej obecný distributed state synchronizer. Reconciliation má pevný vstupní seznam endpointů a konzervativní rozhodovací tabulku z architektury.

## Runtime recovery kontrakt

Rozšiř Runtime state přesně na:

```text
starting -> ready -> disconnected -> starting/ready
starting|ready|disconnected -> stopping -> stopped
```

`accepts_prompts` je odvozeno jen jako `state==ready && sse_live && !reconciling && !interaction policy block`. Nastavení booleans na více místech je zakázané; API prompt se vždy ptá Runtime metody.

Každý Server start a SSE connection dostane monotonic `generation`. Callback se starší generation po restartu nesmí dotknout Runtime/Session/Job. Lokální Base, Theirs, extmarky a dialog identities přežijí `disconnected`, ale nic se neaplikuje, dokud reconciliation neprokáže remote výsledek.

## Vertikální implementační kroky

### 1. TUI-only crash recovery

1. TUI exit callback nejprve ověří Runtime a process generation. Pokud Server health/SSE zůstávají validní, neměň Runtime ani Job state.
2. Skryj/wipe pouze mrtvý terminal buffer, zachovej sidebar window intent a spusť nový `opencode attach <same-url> --dir <same-root>` se stejným auth env/cwd.
3. Atomicky aktualizuj jen TUI PID/start identity v manifestu; Server identity/nonce/port zůstávají.
4. Po attach readiness zavolej `/tui/select-session` pro Runtime `selected_session_id`, pokud stále existuje managed Session. Obnov sidebar visibility bez focus steal.
5. Pokud crash nastal během interaction visibility locku, nový TUI zůstane skrytý/input-locked a current Snacks request pokračuje.
6. Opakovaný attach failure zobrazí metadata error a nabídne retry; neabortuje Server/Jobs a nepřipojí foreign TUI.

Gate: `AC-RUN-08`, včetně running Jobu, selected transcriptu a crash během question locku.

### 2. SSE disconnect gate a reconnect transport

1. Neočekávaný SSE exit nebo heartbeat timeout nastaví `reconciling=true` a okamžitě zavře prompt gate. Existing stream handle/generation invaliduj před reconnectem.
2. Reconnect používa stejný owned Server URL/auth/root/profile. Žádné process discovery nebo Server restart při samotném SSE výpadku.
3. Po novém `server.connected` eventu nespouštěj live completion, dokud `runtime/reconcile.lua` neskončí. Příchozí events během snapshotu buď queue podle stream sequence/generation, nebo po snapshotu spusť druhý bounded reconcile; neaplikuj je proti částečnému stavu.
4. Backoff musí být bounded/configurable a cancelovatelný při shutdownu; timeout ponechá Runtime prompt-blocked s explicitní retry/cancel Jobs volbou.

Gate: integration fake odpojí stream mezi assistant update a idle; nový prompt se před reconcile neodešle.

### 3. Jediný reconciliation algoritmus

1. Pro snapshot lokálních neterminálních Jobs načti v tomto pořadí `/session/status`, exact messages každé active Session, `/question`, `/permission`. Všechny requesty nesou root header a Session detail root check.
2. Pro Job v remote busy zachovej lokální state a obnov live routing maps z matching assistant messages; neprováděj completion.
3. Pro remote idle vyber responses s `parentID==Job.user_message_id`. Právě jedna validní structured response u Build pokračuje proposal validation/completion jednou; Plan se dokončí podle exact message. Missing/duplicate/invalid result je `error` bez apply.
4. Missing/foreign/wrong-root Session ukončí Job `error`. Busy Session bez lokálního Jobu blokuje Runtime a vyžaduje explicitní user resolution; nevytvářej Job.
5. Pending question/permission mapuj jen k active Job stejné Session, dedupuj a enqueue v remote-list pořadí stabilizovaném request timestamp/ID. Pro lokální `waiting_user` request použij pevnou tabulku: matching pending remote request -> obnovit queue; matching replied/rejected event zachycený v aktuální generation -> aplikovat potvrzený transition; request chybí v pending listu a matching confirmation neexistuje -> Job `error`, odstranit lokální request, ponechat Runtime prompt-blocked do dokončení reconciliation. Nikdy se nevracej do `running` pouze z absence pending requestu.
6. Reconcile completion je generation-guarded a idempotentní. Až po úplném snapshotu a zpracování buffered events nastav `reconciling=false` a otevři prompt gate.

Gate: `AC-EVT-03/04`, completion-count assertion přes reconnect twice a oba compatibility profily.

### 4. Server crash a explicitní restart

1. Owned Server exit invaliduje Server, TUI a SSE generations, nastaví `disconnected`, skryje dead TUI a zachová lokální Job data/marks. Žádný pending apply callback nesmí pokračovat.
2. UI nabízí explicitní `restart owned runtime`, `cancel jobs`, `show diagnostics`. Restart znovu provede passive guard, port/credentials/manifest, exact version/profile/doc/config preflight a attach; nikdy nereuse foreign URL.
3. Nový Server nad stejným rootem může objevit persisted managed Sessions. Před promptem spusť stejný reconciliation algoritmus. Pokud old Session/result nelze prokázat, Job skončí error bez apply.
4. Starý manifest/process generation odstraň jen po ownership verification. Nové credentials nikdy nepřepisuj do starého manifestu in-place před úspěšným atomic replace.
5. Shutdown během restartu zruší backoff/start callbacks a provede cleanup obou prokazatelně owned generations.

Gate: `AC-EVT-05`; fixture s foreign Serverem na původním portu zůstane nedotčená.

### 5. F09 exit a regression

Spusť TUI, SSE a Server crash v každém neterminálním Job stavu, včetně pending_apply, agent/external conflict a waiting question/permission. Dokaž no double apply, no lost Ours, no dialog duplication a prompt block. Uzavři F09-owned `AC-RUN-08`, `AC-EVT-03`, `AC-EVT-04`, `AC-EVT-05` před změnou registry cardinality.

### 6. Root-keyed Runtime registry

1. Změň `runtime/init.lua` na registry `canonical_realpath -> Runtime`. `get_or_start(buffer)` vždy znovu použije `runtime/root.lua`; symlink alias vrací stejný objekt.
2. Každý Runtime vlastní Server/TUI/SSE generation, Sessions, Jobs, temp root, manifest a selected Session. Žádná tabulka těchto entit nesmí být module-global bez root key.
3. `active_root` je pouze sidebar/UI selection. HTTP/event/job routing nikdy active root nečte; používá owning Runtime argument/stream.
4. Prompt z bufferu druhého rootu vytvoří druhý Runtime a sidebar přepne na jeho terminal buffer. První background Job/interaction pokračuje.
5. Runtime může používat jiný podporovaný OpenCode profil podle executable konfigurace jen pokud je executable volba explicitně root-scoped; default binary je společný. Jeden Runtime po startu profil nemění.

Gate: symlink dedupe unit test a `AC-RUN-05` základ se dvěma fake Servers na různých ports.

### 7. Multi-root sidebar, events a dialogs

1. Sidebar window je stále jedna; `show_root(root)` pouze vymění buffer a `active_root`, zachová source focus a neukončí předchozí TUI.
2. `/tui/select-session` jde přes client owning Runtime. Stejné Session ID v jiném fake Runtime nesmí být zaměnitelné; interní lookup vždy root+Session.
3. SSE callback nese Runtime identity z connection closure a generation. Header/payload directory mismatch je contract error daného Runtime, ne rerouting.
4. Existing global `interaction.lua` FIFO nyní serializuje requests napříč roots. Dialog text vždy obsahuje root basename a Session short ID; callback lookup používá root+Job key.
5. Background status/notifikace nesmí samy přepnout active root, terminal buffer, current window ani cursor.

Gate: interleaved event/question/conflict stejných short IDs ve dvou roots zůstane izolovaný.

### 8. Cross-runtime cancel-all

1. Při command invocation snapshotni `{root, job_key}` všech neterminálních Jobs všech Runtime před prvním side effectem.
2. Zavolej existující cancel-one pro každý snapshot item. Abort míří do owning Runtime; HTTP failure nezastaví další a lokální terminal transition platí.
3. Queue removal používá root+Job key. Late event kterékoli Runtime/generation nesmí apply proposal.
4. Výsledek vrací counts `requested/cancelled/abort_failed`, bez title/path/content.

Gate: uzavři celý `AC-JOB-05`, včetně jednoho mrtvého Serveru a jednoho healthy Runtime.

### 9. Multi-runtime shutdown a orphan cleanup

1. Jediný `VimLeavePre` snapshotne všechny Runtime a zakáže nové starts/prompts. Pro každý: `stopping`, abort active Sessions best-effort, close dialogs/SSE, terminate TUI, terminate Server, cleanup temp, verify/remove manifest, `stopped`.
2. Shutdown nesmí čekat neomezeně. Použij bounded graceful timeout, potom signalizuj pouze handles/identities, které stále odpovídají manifestu. Foreign/reused PID nikdy nesignalizuj.
3. Selhání jednoho Runtime cleanup nezastaví ostatní; u neověřeného orphan ponech manifest a metadata-only manual instruction.
4. Příští plugin startup projde všechny stale manifests před startem prvního Runtime. Každý manifest ověří root hash, nonce schema, Server/TUI PID start identity, executable, authenticated health a routed root. Jen plná shoda dovolí terminate+cleanup.
5. Normal shutdown odstraní secrets/manifests; hard crash test ukončí Neovim bez hooku a následující run prokáže safe cleanup.

Gate: `AC-RUN-06/07` multi-root regrese a důkaz, že vedlejší foreign OpenCode proces přežije.

### 10. F10 exit

Uzavři F10-owned `AC-RUN-05`, `AC-RUN-06`, `AC-JOB-05` a roadmap regrese `AC-RUN-01/02/07`, `AC-EVT-01`. Proveď matrix obou compatibility profilů; mixed-profile multi-root je doplňkový contract test, pokud config dovoluje root-specific executable.

## Povinné testy

| Vrstva | Minimální důkaz |
|---|---|
| Unit | Runtime/generation transitions, reconcile decision table, root registry/symlink, cross-root keys, shutdown snapshot |
| Neovim integration | TUI restart, selected transcript, prompt gate, reconnect exactly once, two-root sidebar, cross-root FIFO/cancel-all |
| Contract | Status/messages/pending endpoints po reconnectu pro oba profiles; root header a directory validation |
| End-to-end | Real TUI crash, SSE reconnect, Server restart, two roots a normal shutdown pro oba supported binaries |
| Failure injection | Dropped/reordered events, duplicate reconnect, missing Session/result, process/PID reuse, shutdown during restart, one abort/cleanup failure |

## Observability a privacy

Log přidá Runtime/stream generation, reconnect attempt count, reconciliation outcome class a root hash. Nesmí obsahovat Server URL s credentials, absolute root, manifest content, messages, pending request payload ani recovered structured output. Health/manual cleanup zobrazí manifest location relativně ke state dir nebo explicitně až na user command, ne v default logu.

## Mimo fázi

Nové workflow, další OpenCode verze, automatic foreign attach, unbounded replay, cross-machine Runtime, persistent local Job recovery po editor crash a finální release polish. Hard crash obnovuje proces ownership, ne neprokazatelnou in-memory proposal transakci.

## Stop conditions

- Reconciliation by musela odhadnout Job podle latest Session/message místo exact parent identity.
- SSE reconnect nelze oddělit generation guardem od starého streamu.
- Server restart nenajde prokazatelnou persisted Session/result; Job musí error, ne apply.
- Multi-root cesta čte active root pro routing nebo sdílí credentials/temp/registry bez root key.
- Shutdown by musel signalizovat PID bez process start identity a authenticated root proof.
