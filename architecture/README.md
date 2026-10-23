# mcl-chess architecture: C4 model

*This exists so two strangers' agents can play a timed game of chess on the mesh with a referee neither of them has to trust the other to be.*

**Status: 2026-10-22, WP7 built.** The Design Gate is settled (mcl-chess#1, answer 6 approved the two evoq hooks on 12 Oct), WP0 shipped them (evoq 1.27.0 and reckon_evoq 2.8.0 are released), WP2 built the walking skeleton, WP3 seated and started a game, WP4 built the rules engine (a Rust NIF over cozy-chess, cross-checked against the published perft counts and loadable from the assembled release), WP5 played and ended a game, WP6 added the clock, flagging, retention and archiving, and WP7 pinned the nine facts on the mesh. The rules engine is called by `submit_move` and the end policy. What is not built is the realm grants (WP8) and the live game between two agents; the fleet definition exists, and macula-fleet runs a pinned digest of the release; the tables below say which elements are still planned, and all of it is tracked in [#1](https://github.com/macula-services/mcl-chess/issues/1).

`mcl-chess` is an **mcl_om mesh service**, like any `mcl-*` service: one OTP release in one OCI container on its own box, with its node identity, realm admission, mesh pool and `/health` from `mcl-om`. It joins the mesh through pinned stations and it is not part of any station.

Legend, the same in all three diagrams: amber is the element in scope, lavender-grey **Macula infrastructure** (the stations and their DHT, macula-realm, evoq where it is the substrate), grey-green an external system, white a container or component, a thin solid rounded outline with a muted label a boundary, and dashed boxes are planned, not built; dashed means nothing else.

## Level 1: system context

![mcl-chess system context](../assets/c4-context.svg)

| Element | Kind | Role | Status |
| --- | --- | --- | --- |
| mcl-chess | In scope | The referee: validates, clocks and sequences one game, records a disputable transcript, publishes facts. Never plays, never picks a move, never contacts an agent | built (WP2 to WP6): initiate, claim a seat, start, move, resign, end, flag, withdraw and retention archive |
| Player A's agent, Player B's agent | External | The two seats. An agent picks its moves; calling `claim_seat` is its consent to the time control | external |
| macula-mcp | External | Each agent's harness: how it reaches the mesh, and the scheduler it waits on. The thinking half of the game lives here, not in the service | external, built |
| Macula mesh | Macula infrastructure | The pinned stations are the entry points (QUIC); the union of stations routes an org procedure; the facts travel its topics | built |
| macula-realm | Macula infrastructure | Admits the org `mcl-chess` and issues the D25 provider grant per procedure; a call without that grant is refused at the boundary | built |
| Anyone watching | External | Other agents, board viewers, a future reputation division: they read the facts, never the service's private state | external |
| Future matchmaker | Planned, separate division | Decides who plays whom, then starts a game with pre-assigned seats through the command, never the wire. Nothing in this division pairs players | planned |

**Trust, honestly.** The referee is one service both sides call, so neither has to trust the other's agent to keep the rules. Every decision is an event in the service's own store and every event a fact on the mesh, so a game replays and is disputed from the transcript alone. Attribution is by the wire, never by the payload: the caller is the node id macula verified on the call, so a caller cannot claim the other seat. A node that stops moving forfeits on the clock both seats accepted by claiming; the service never pokes an agent.

**What is not here.** Matchmaking (offers, invitations, Elo), an engine or bot, pause and resume, a reputation division, SAN rendering, tournaments and payload encryption are all out of scope for v1. Facts are readable by anyone who learns the topics, the same standing caveat as rooms and mcl-mpong.

## Level 2: the service's containers

![mcl-chess containers](../assets/c4-containers.svg)

| Container | Technology | Responsibility | Status |
| --- | --- | --- | --- |
| mcl_chess (boot app) | mcl_om mesh service, OCI image, OTP release | Opens the event store before `mcl_om:boot/1`, starts no child of its own (the departments are application dependencies), and serves `/health`. `mcl-chess/initiate_game`, `claim_seat`, `submit_move`, `resign_game`, `withdraw_game` and `get_game_by_id` are the service's own procedures, and the only ones; `mcl-om` adds `<org>/info` and `<org>/get_limits` to every service, both open, and `capabilities/0` is the list. Names any missing D25 grant | built (WP2) |
| play_games | CMD app, evoq | One desk per lifecycle slice, from game initiation to archive. The only writer of events | built for initiate, claim, start, move, resign, end, withdraw, flag and archive (WP2 to WP6). It also hosts the rules engine's BEAM module (WP4) |
| project_games | PRJ app, evoq | One projection per event, writing the read model and the status label computed at projection time | built for every state-changing event (WP2, WP3, WP5). A refusal is evidence, not state, and is not projected |
| query_games | QRY app, esqlite | `get_game_by_id`, by status, page, by player. Answers from the read model, never from events | `get_game_by_id` built (WP2); the other three are later |
| Event store | reckon_db, volume `/data` | The source of truth: one stream per game, replayed to rebuild the aggregate on demand | built (WP2) |
| Read model | SQLite through esqlite | Board, move list, clocks, status and label: what queries serve and what a board viewer rebuilds from | built: birth, seats, start, every move and the end projected (WP2, WP3, WP5). The move list is its own table (see the migration note below) |
| Identity and realm admission | Node identity key, D25 grants | The identity key names the service to the realm; a procedure without its grant is refused at the boundary | wired (WP2); the grants are an operator step (WP8) |
| ghcr.io | External | The release image, built and pushed by `build-push.yml`, signed and attested, then pinned by digest | built |
| macula-fleet | Runs it | The fleet row: the service's edge config env, `reconcile.manifest` entry and digest pin | canary first |

**One container, one box.** The v1 horizon is a single service node hosting many concurrent games, each its own aggregate and its own clock instance. Scaling out to several nodes is a later design (mcl-chess#1, open question 7), not v1; the per-game independence is what keeps it possible.

## Level 3: components of the referee

![mcl-chess components](../assets/c4-components.svg)

| Component | Kind | Responsibility | Status |
| --- | --- | --- | --- |
| `game_aggregate`, `game_state`, `game_status.hrl` | `evoq_aggregate` and its state module | Replays its own stream to the state: seats, position, `to_move`, ply, clocks, halfmove count, repetition history, status flags, outcome. Every guard lives in a `maybe_*` handler, never in a caller | built (WP2, extended in WP3 for seats and start and in WP5 for moves and the end) |
| `initiate_game/` | Desk, CMD | `initiate_game_v1` to `game_initiated_v1`: mints the stream id through `evoq_event_store:new_stream_id/1` and records the full initial state | built (WP2) |
| `claim_seat/` | Desk, CMD | `seat_claimed_v1`, `seat_refused_v1`: a claim is for a color, the first claim wins it, a full game refuses the third claimer, and one node holds one seat | built (WP3) |
| `start_game/` | Desk, CMD, internal | `game_started_v1` once both seats are filled. Dispatched by a policy, never served on the wire | built (WP3) |
| `submit_move/` | Desk, CMD | `move_played_v1` for a legal move by the seat to move and `move_refused_v1` (the evidence class) for a seat holder's foul attempt. Charges the mover's clock, advances the halfmove count and counts the repetition | built (WP5) |
| `resign_game/` | Desk, CMD | `game_ended_v1` with outcome `forfeit` and reason `resignation`, the opponent named as the winner | built (WP5) |
| `withdraw_game/` | Desk, CMD | `game_archived_v1` with reason `withdrawn`, pre-start only: a game that never began is not an end, and a game that ended is the retention slice's to archive | built (WP2); refuses a started or ended game, the latter since WP5 |
| `end_game/` | Desk, CMD, internal | `game_ended_v1`: the one way a game ends, whether a policy, a resignation or a flagged clock triggered it. Refuses a winner the game never admitted, and re-judges the position when the reason is `clock_flag` | built (WP5, re-judging since WP6) |
| `flag_clock/` | Desk, CMD, internal | `clock_flagged_v1`, dispatched by the clock instance when a deadline fires. Refuses a stale deadline (not that player's turn, clock not expired, already flagged) | built (WP6) |
| `archive_game/` | Desk, CMD, internal | `game_archived_v1` with reason `retention`, dispatched by the retention instance after the window: the death slice | built (WP6) |
| `on_* policies` | `evoq_event_handler`, `replay_policy -> skip` | Subscribe by event type and dispatch the next command: seats full starts the game, a terminal position or a flagged clock ends it | `on_seat_claimed_v1_maybe_start_game` (WP3), `on_move_played_v1_maybe_end_game` (WP5), `on_clock_flagged_v1_maybe_end_game` (WP6) |
| `game_clock_pm` | `evoq_process_manager`, one per game | White's clock starts, the mover's stops and the opponent's starts, both stop at the end; the deadline arrives in `handle_info/2`, the hook evoq 1.27.0 added. It is also what finishes a sequence a crash left half done (see the decisions below) | built (WP6) |
| `game_retention_pm` | `evoq_process_manager`, one per game | Holds the one deadline a policy cannot: the retention window after `game_ended_v1`, then `archive_game_v1` | built (WP6) |
| `play_games_pm_registrar` | `gen_server` child of the CMD supervisor | Registers both process managers with evoq's PM router, and registers them again if the router restarts (evoq#9) | built (WP6) |
| `emit_*_to_mesh` (nine) | `evoq_event_handler`, `replay_policy -> skip` | The only publishers: one per fact, each reading the recorded event and publishing it through `mcl_chess_facts`. A desk dispatches the command; the emitter turns the event into a fact | built (WP2, WP3, WP5, WP6) |
| `mcl_chess_facts` | Module, the only one naming a topic | Owns every topic and every translation. The nine `emit_*_to_mesh` handlers publish through it; nothing else names a topic | built: nine facts (WP2, WP3, WP5, WP6) |
| `mcl_chess_rules` | Rust NIF over cozy-chess, stateless | `validate_move/2`, `apply_move/2` returning the FEN, its Zobrist hash and whether the move reset the halfmove counter, `position_hash/1`, `status/2` and `cannot_mate/2`. Legal-only generation | built (WP4) and called by `submit_move` and the end policy (WP5) |
| evoq 1.27.0 | Library, the CQRS framework | Commands, events, aggregate, handlers, process managers, the router and bit flags. The adapter is named in `sys.config` only: no desk touches the store | built (released 2026-10-19) |

**Only the adapter is hidden.** The `reckon_evoq_adapter` is named in `config/sys.config.src` and nowhere else, and no module in `apps/` calls it. Two other reckon modules are named where each belongs: `mcl_chess_app.erl` opens the store through `reckon_db_sup`, and the desks validate a stream id through `reckon_gater_stream_id:validate/1`, which is pure: it checks the shape of a stream id and opens nothing. Everything else goes through evoq. Two gaps used to make that impossible, and both are closed as of evoq 1.27.0: a process manager instance could not receive a message it sent itself, and evoq had no way to mint a stream id.

**Where the station list comes from.** It is not in `config/sys.config.src`: `mcl_om` reads `MACULA_STATION_SEEDS` and `MACULA_STATION_NODE_IDS` from the environment at boot, paired index for index, so this repository pins no station and the list may be any length.

## Level 4: the code

Level 4 is a table rather than a picture: the aggregate record, its state module and the status flags are clearer written down, and they move with the code.

| Element | Where | Holds or does |
| --- | --- | --- |
| `#game{}` | `apps/play_games/include/game_state.hrl` | `game_id`, `protocol`, `time_control`, `seats`, `position`, `to_move`, `ply`, `clocks`, `halfmove_clock`, `hashes`, `status`, `outcome`, `winner_node_id`, `end_reason`, `initiator_node_id`, `flagged_node_id`, `refusals`, `at_ms` |
| `game_state` | `apps/play_games/src/game_state.erl` | `apply/2`: one clause per event, folding the event into `#game{}` |
| `game_status.hrl` | `apps/play_games/include/game_status.hrl` | The `evoq_bit_flags` integers and their label map |
| Event modules | one per event, `_v1` suffixed | The full state the event produced, so a projection or a replay never needs a second stream |
| Command modules | one per desk | `_v1` suffixed, validated at the boundary before the handler sees them |

**Status is a bit-flag integer**, never a string and never a bare atom, and the label is computed in the projection, never client-side:

| Event | unset | set | status after | label after |
| --- | --- | --- | --- | --- |
| `game_initiated_v1` | none | `INITIATED`, `OPEN` | 3 | `initiated, open` |
| `seat_claimed_v1` | none | none | 3 | `initiated, open` |
| `game_started_v1` | `OPEN` | `STARTED` | 5 | `initiated, started` |
| `move_played_v1` | none | none | 5 | `initiated, started` |
| `clock_flagged_v1` | none | none | 5 | `initiated, started` |
| `game_ended_v1` | `STARTED` | `ENDED` | 9 | `initiated, ended` |
| `game_archived_v1` | `ENDED` | `ARCHIVED` | 17 | `initiated, archived` |

`INITIATED` is never cleared: it is the "this dossier exists" flag every slice guard checks, and the archived aggregate keeps it.

A game that has ended is no longer started, which is why `game_ended_v1` clears `STARTED`. Every handler therefore asks "has it ended?" before "has it started?": an ended game answering `not_started` would read to the agent that ended it as a fault in the referee.

## What ends a game (WP5, plus the operator's decision on mcl-chess#4)

A move is judged by the rules engine, and `on_move_played_v1_maybe_end_game` acts on the verdict. The draw rule was settled by the operator on 2026-10-19: **FIDE's automatic draws only.**

| End | Outcome | Reason | Judged by |
| --- | --- | --- | --- |
| No legal moves and in check | `winner` | `checkmate` | the rules engine |
| No legal moves and not in check | `draw` | `stalemate` | the rules engine |
| Neither side can ever mate | `draw` | `insufficient_material` | the rules engine |
| 150 halfmoves without a pawn move or a capture | `draw` | `seventy_five_moves` | the rules engine, given the referee's own count |
| The same position five times | `draw` | `fivefold_repetition` | the aggregate, counting the hashes its events recorded |
| A player resigns | `forfeit` | `resignation` | the resign desk |
| A clock runs out | `forfeit` | `clock_flag` | the clock instance, unless the position above already decided it |
| A clock runs out and the opponent cannot mate | `draw` | `clock_flag_insufficient_material` | the rules engine, asked FIDE 6.9's one-sided question |

The order is FIDE's: checkmate wins over the counter, a position that is dead on its own terms reports its own reason, and the counter is asked last. The 50 move and threefold draws are **claims**, and claims are v2.

**The referee keeps its own halfmove count, and that is why `apply_move/2` returns a flag.** cozy-chess keeps the FEN's counter in a `u8` and clamps it at 100, so a FEN alone can never report the 150 halfmoves the 75 move rule fires at. `apply_move/2` therefore says whether the move reset the counter (a pawn moved, or something was captured), `game_state` keeps the count uncapped, and `move_played_v1` carries it: a replay folds the number the desk computed rather than re-deriving it.

**Fivefold is the aggregate's because it is not a function of one position.** Every event that advances the position records its FIDE Zobrist hash; the state keeps the hashes since the last irreversible move (trimmed there, because no position before one can recur); the move event carries how many times the position it produced has occurred. The end policy reads that count off the event, so it decides from one event and never from a read model.

**The mover's clock is charged by the move desk.** The turn began at the state's own `at_ms` (the last event that changed the game), so the time is derived from the record and not from a wall clock, and the increment is paid on top when a move completed. A player whose time ran out is recorded at zero and pays no increment. The move desk refuses a move on an overdrawn clock (`time_expired`, recorded like any other foul by a seat holder) with the same arithmetic the flag uses, so the two cannot disagree about whether the time was there.

**A flag re-judges the position before it forfeits.** `clock_flagged_v1` records the fact, `on_clock_flagged_v1_maybe_end_game` dispatches `end_game_v1`, and that desk asks `game_verdict` about the position first. A live position is a forfeit and the flagged player's opponent wins it; a position the rules had already decided keeps its own verdict, which is how a game left mated by a crash ends `checkmate` rather than `clock_flag`. A resignation and every other end keep the decision they were sent with. **A live position is not automatically a loss.** FIDE 6.9 draws the game when the side that would be credited with the win cannot checkmate the flagged player's king by any possible series of legal moves, so the flag path asks the rules engine one more question about the opponent's material, and a flag against a bare king ends `draw` with reason `clock_flag_insufficient_material`. The end's reason therefore says what actually happened, and a future reputation division reading the transcript sees the truth rather than the last event.

## The facts on the mesh, and their contract (WP7)

Nine facts leave this service, one topic each under `<realm>/mcl-chess/chess/game/`, with the game id in the payload and never in the topic name, so a consumer subscribes once and filters. `mcl_chess_facts` is the only module where the internal event and the published fact meet, and `mcl_chess_facts_tests` is what makes a wire change visible before a consumer finds it: every topic is pinned, every fact's key set is pinned, and a table gives the CBOR type of every key (text, integer, or a map and the types of its values). A key that is added, renamed, or quietly turned from text into an atom fails that table rather than a subscriber written in another language. Flags travel as 1/0, reasons and outcomes as text, and both shapes of an event (atom-keyed from a desk, binary-keyed from the store) produce the same fact.

## The read model's shape, and how it changes

The move list is a table of its own, `moves(game_id, ply, uci)` with a primary key on the first two, not a text column grown by concatenation: a projection must survive a replay, and appending to a string is not idempotent. `INSERT OR REPLACE` keyed on `(game_id, ply)` is.

A read model file outlives a release, and `CREATE TABLE IF NOT EXISTS` does nothing to a table that already exists, so a column added to the DDL is also declared in `game_read_model_store:migrations/0`, which `ALTER TABLE`s it only when `PRAGMA table_info` does not already list it. That is the only way this schema changes.

**The row carries the moments the game passed through.** `initiated_at` comes from `game_initiated_v1`, `started_at` from `game_started_v1`'s own `at_ms` (mcl-chess#3, and the same reading the clock's first deadline is set from), `ended_at` from `game_ended_v1`, `archived_at` from `game_archived_v1`. `started_at` is in the DDL and in `migrations/0` like the rest: the first deployment is this one, but a read-model file built from a 0.6.0 image can already exist (the repository's own `deploy/docker-compose.yml` runs as-is against a persistent data directory), and a projection writing a column that file lacks fails on every start, silently, with games stuck at `initiated`.

**The schema is held by a contract test, not by good intentions.** `game_schema_contract_tests` parses the columns out of the DDL itself (no second copy of the schema is written down), and then uses the real store to prove three things: the parsed DDL is what the file has, the columns `get_game_by_id` selects exist and arrive in the order its destructuring expects, and every projection's SQL names only declared columns. Each of the three is red if it drifts, which was checked by breaking each one and watching it fail.

## The rules engine, built in WP4

`native/mcl_chess_rules/` is a Rustler cdylib over [cozy-chess](https://crates.io/crates/cozy-chess) 0.3.4 (MIT; the licensing decision is in the design of record). Five functions, no state, no dirty scheduler: a call is one FEN parse and one move-generation pass.

| Layer | Where | What |
| --- | --- | --- |
| Pure rules | `native/mcl_chess_rules/src/rules.rs` | `validate_move/2`, `apply_move/2`, `position_hash/1`, `status/2` and `cannot_mate/2` over FEN and UCI strings. No BEAM types, so the perft suite runs as an ordinary `cargo test` |
| NIF translation | `native/mcl_chess_rules/src/nif.rs` | The five `#[rustler::nif]` functions, compiled out under `cfg(test)`: the `enif_*` calls they make do not exist in a test binary |
| BEAM module | `apps/play_games/src/mcl_chess_rules.erl` | Loads the `.so` from `play_games`' own `priv/lib` and is the module a desk calls |
| Build | `scripts/build-nif.sh`, run by the umbrella's `compile` pre_hook | `cargo build --release --locked`, then the `.so` into `apps/play_games/priv/lib`, which relx copies into the release |

**The library is installed with a new inode, never in place** (mcl-chess#7). A VM that has loaded it has the file mmap'd, and `cp src dst` would truncate and rewrite the very inode that mapping is backed by: the loader then reads unrelocated content out of an already relocated object, `fini_array[0]` comes back as zero, and the VM dies inside `_dl_fini` at shutdown. The script copies to a temporary name and renames it, so a running VM keeps the inode it mapped and the next load gets the new file. `scripts/fault-in-place.sh` is the proof harness: the in-place mode crashes every VM it is run against, the atomic mode none.

**Correctness is perft, not opinion.** The suite walks the published node counts for the six standard perft positions (start, Kiwipete, positions 3 to 6) to depths 3 to 5, and walks the same trees a second time through `apply_move` so the referee's own path, including the FEN round trip, is measured and not just the library under it. `scripts/test-nif.sh` runs it in release, which is the profile the deep depths are compiled for.

**Three things it decides that the wire depends on.**

- **Castling is spelled twice.** The wire says `e1g1`; cozy-chess, like every Chess960-aware engine, says `e1h1` (the king takes its own rook). Both spellings are accepted and both arrive at the same position, and a king move to `g1` that is not a castle is simply illegal, so there is no ambiguity to preserve.
- **The recorded hash is the FIDE one.** `apply_move/2` returns a Zobrist hash in which a dead en passant square does not count: two positions a repetition check must call identical hash identically. `hash()` and `hash_without_ep()` alone are each wrong here, so the hash is `hash()` only when the en passant capture is actually legal.
- **The verdicts are the v1 end conditions**: `active`, `checkmate`, `stalemate`, `insufficient_material`, `seventy_five_moves`. `cannot_mate/2` sits beside them and answers a different question: not whether the position is dead for both sides, but whether one named colour can mate at all, which is what a flag has to know (FIDE 6.9). Insufficient material is bare kings, a lone minor piece, or a bishop each on the same colour of square; `seventy_five_moves` is the 150th halfmove, asked last, after mate, stalemate and dead material have had their say.
- **`apply_move/2` reports the halfmove reset** (a pawn move or a capture), because the counter it would otherwise read back is clamped at 100 and the rule fires at 150. `position_hash/1` hashes a position without playing a move into it, which is how a game's start position enters the repetition history.

**What it does not decide.** The fivefold draw, which is not a function of one position (the aggregate counts it), and the 50 move and threefold draws, which are claims and are v2. [#4](https://github.com/macula-services/mcl-chess/issues/4) settled which automatic draws v1 takes: the closing comment there is the record.

## Decisions

- [x] **Event-sourced, unlike mcl-mpong** (design of record, mcl-chess#1). mpong's "no event store" is a scoped waiver for a throwaway demo; chess is adversarial and needs replay, dispute and audit.
- [x] **One authoritative referee.** No dual-host pairing: one service, one truth.
- [x] **Consent by seat claim; seats are by color, not by role.** The initiator is not pinned to white.
- [x] **Wire names `mcl-chess/<verb>`**, no `_v1` in the name; the version is a capability field (the Design Gate's first answer).
- [x] **The two evoq hooks shipped** in evoq 1.27.0 and reckon_evoq 2.8.0, so WP6 needs no node-wide clock fallback and no hand-rolled stream id (Design Gate answer 6, WP0).
- [x] **The pre-start withdraw archives directly** (WP2). The design of record splits the death slice along its trigger: `withdraw_game/` serves the initiator's pre-start withdraw and `archive_game/` is the retention path dispatched by a policy. WP2 built the first and the shared `game_archived_v1` event; the second arrives with the retention policy in WP6, which is the work package the design of record gives that policy to. Nothing was invented to bridge the gap, and there is no stub desk waiting for a caller.
- [x] **The wire cannot seat anyone** (WP2 review). Consent is a seat claim, so `initiate_game_responder_v1` does not read `seats` at all: every call over the wire gives two empty seats. Seating two agents who never agreed, and then letting the clock forfeit them, is the harm the rule closes. The command keeps its `seats` field for the future matchmaker, which will need its own authorization to use it.
- [x] **Emitters live in their own `emit_*/` directories, not inside a desk.** `emit_game_initiated_v1_to_mesh` belongs to `game_initiated_v1`'s desk, but `emit_game_archived_v1_to_mesh` is shared by `withdraw_game/` and the planned `archive_game/`, so a per-desk placement would have had to pick one of them. `mcl_chess_facts` still owns every topic and every translation.
- [x] **Distribution stays, bound to loopback, with the cookie from the box, never the image** (mcl-om#24, WP2 review). The scaffold baked `ENV MCL_COOKIE` into the Containerfile and named the node `@127.0.0.1`, which advertises loopback but does not bind the dist listener to it, so a shared public cookie sat behind a listener on every interface. The image now carries no cookie: `deploy/docker-compose.yml` refuses to start without `${MCL_COOKIE:?}`, and `config/vm.args.src` reads it at run time. Distribution itself is kept rather than dropped, because the Ra member identity is `node()`: a nameless node is pinned to `nonode@nohost`, and naming it later would change a live store's identity, exactly the way the realm release that renamed a node stalled its Ra store. It is bound on both halves, `ERL_EPMD_ADDRESS=127.0.0.1` in the image and `-kernel inet_dist_use_interface {127,0,0,1}` in `vm.args.src`, and `mcl_chess_service_tests` asserts all of it. Keeping a name also keeps `bin/mcl_chess remote_console`, which is how an operator gets into a box.
- [x] **A node holds one seat, and only its own** (WP3). Consent is a claim, so `claim_seat` reads the caller as the claimant and has no field for naming anybody else: a body carrying a node id is not read (the same rule WP2's review fixed on `initiate_game`). A node that already holds a seat is refused `already_seated` rather than given the second one, because two seats are two consenting agents and one node in both is a game with itself. The design of record named `seat_taken` and `game_full` and left this case open; this is the reading it takes.
- [x] **A recorded refusal is still a refusal to the caller, and it is capped** (WP3, capped after review). A claim on a taken or full seat writes `seat_refused_v1` to the stream, because a claim is how matchmaking sees demand, and the caller is answered `{error, Reason}` anyway. The event is the evidence, the answer is the answer; every refusal with no standing (no stream, archived, bad colour) writes nothing at all. And the evidence is bounded: `game_state` counts recorded refusals per player and the desk stops writing after ten (the Design Gate's number, answer 5), because a node holding no seat passes the `already_seated` check and could otherwise write to a game's stream for as long as it lives. The same counter serves `move_refused_v1` in WP5.
- [x] **The two sequences a crash can leave half done are finished by the clock instance** (WP6). A crash between the second claim and the seats-full policy's dispatch leaves a full, unstarted game; a crash between a flag and the flag policy's dispatch leaves a flagged, unended one. The policies stay policies, and the repair lives in `game_clock_pm`: its instances are rebuilt from the log on the next boot, and an instance whose folded state still shows a gap schedules a delayed self-message that dispatches the missing `start_game_v1` or `end_game_v1`. The delay is what keeps a healthy node from double-dispatching (the policy's command has landed by the time it fires), and both desks' guards make a late command a refusal rather than a second event. The mated game that gap used to produce is also fixed where it is recorded: `end_game` re-judges a `clock_flag` against the position.
  A process manager rather than a sweep, because the manager is the thing that already holds this game's event history and outlives the gap; a sweep would need a read model (a cache) to find the games, which is exactly what the design refuses to read from.

  One cost, recorded before WP8: on each rebuild the retention instances of already-archived games are created by `game_ended_v1` and fire one `archive_game_v1` before `game_archived_v1` folds and stops them. Each is refused (the game is archived) and logged, so the noise is linear in the store's history rather than in live games. A `game_archived_v1` seen first would have to be replayed before the end, which the store does not promise.
- [x] **A move on an overdrawn clock is refused, not clamped and played** (WP6, Design Gate answer 4). `game_state:expired/3` is the one arithmetic, and both the move desk and the flag desk ask it, so a player who has run out cannot escape by moving late: the desk answers `{error, time_expired}` and records `move_refused_v1`, and the clock flags the turn a moment later. The flagged player's clock is still recorded at zero by `charge_turn`, which is the charge a turn pays, not a permission to play.
- [x] **A deadline that fires is kept, not forgotten, and a failed dispatch is asked again** (WP6, review R1). evoq's process manager runtime only logs a failed `evoq_router:dispatch`: it retries nothing, and the only thing that could re-arm a clock is an event, which a failed dispatch never produces. So the instance keeps the deadline and asks again after `catch_up_ms`, and what clears it is the event that settles it (the flag, a move that bought the time, or the end; `game_archived_v1` for the retention). A retry nobody needs is refused by the desks' own guards. Without this, one store timeout or Ra leader change during a station roll would leave a player who is out of time in a game that never ends, which is the one thing gate answer 4 says cannot happen.
- [x] **A clock runs during downtime, and that is deliberate** (WP6, review observation). A deadline that passed while the node was down fires when the instance is rebuilt, so a restart or a station roll charges its downtime to the side to move, and a 1+0 game can be lost to one. That is "the clock alone decides" taken literally: the alternative is a clock only the service can see, and a player who can stop the service to stop their clock.
- [x] **An archived game takes its clock instance with it** (WP6, review R2). `game_archived_v1` stops the instance, as `game_ended_v1` does. A game withdrawn before it started (two seats filled, no start dispatched, then the initiator withdraws) never produces an end, so without this its instance would live for the node's lifetime and ask for a start on a dead game every time it was rebuilt.
- [x] **The retention window is 24 hours and it is configuration** (WP6, the design of record's open question 2). `play_games`' `game_retention_ms`, set in `config/sys.config.src`, defaulting to a day in `game_retention_pm:window_ms/0`. Long enough that an agent, its operator or a reviewer can still read a finished game; short enough that the store does not keep every game forever. It is read when `game_ended_v1` arrives, and a game replayed after a longer shutdown is archived from its own `at_ms`, so lowering the number clears the backlog on the next boot rather than leaving it.
- [x] **The retention is a process manager, not an `on_*` policy** (WP6). The design of record gives the death slice "a deadline of its own, on the same `handle_info/2` hook as the clock", and a policy cannot hold one; `game_retention_pm` is that deadline, one instance per ended game, and it is the only reader of the window. Everything else about it is the design's: `replay_policy` has no analogue here, but a rebuilt instance archives a game whose window has passed, once, from the end event's own `at_ms`.
- [x] **The rules NIF is a cdylib whose pure half is a separate module** (WP4). Rustler's `enif_*` calls are resolved by the BEAM at load time and do not exist in a test binary, so a crate that mixes the NIF registration into the code under test cannot run `cargo test` at all. `rules.rs` holds the chess and `nif.rs` (compiled out under `cfg(test)`) holds the translation, which is what lets perft run as a normal test rather than as a test that never runs. The alternative, a second crate in a workspace, buys nothing this crate needs.
- [x] **The NIF builds in the ordinary builder stage, and the image copies what the hook needs** (WP4). The pinned `macula-ci-otp` image already carries Rust (1.98.1), so there is no toolchain stage; but compiling runs the pre_hook, so `COPY scripts` and `COPY native` sit before `rebar3 as prod release`. Without them the image build fails in the release step, three layers after the change that caused it.
- [x] **A foul move is recorded, and a stranger's is not** (WP5). A seat holder moving out of turn, illegally, or after the game ended is evidence: `move_refused_v1` is written and published, under the same ten-per-player cap the seat refusals use. A caller holding no seat, a game that never started and an archived game record nothing, because none of them says anything about anybody's conduct and a stranger must not grow a stream. The caller always gets `{error, Reason}` either way: the event is the evidence, the answer is the answer.
- [x] **The end policy decides from one event** (WP5). `move_played_v1` carries the position, the referee's halfmove count and the repetition count, so `on_move_played_v1_maybe_end_game` asks the rules engine and dispatches `end_game_v1` without reading a model or a second stream. The verdict is deliberately *not* in the event: a change of referee must not rewrite a stream.
- [x] **The read model migrates rather than assumes a fresh file** (WP5). Columns added after the table shipped are declared once in `game_read_model_store:migrations/0` and applied with an idempotent `ALTER TABLE`; the move list is a keyed table because an appended text column is not idempotent under replay. This service still has no deployed instance, so the migration is cheap now and the habit is what matters later.
- [ ] The future matchmaker's contract: which seats it pre-assigns, how it learns a game exists, and what authorizes it to pre-assign.

## Editing the diagrams

All three SVGs in [`../assets/`](../assets/) are generated by [`c4_diagrams.py`](c4_diagrams.py): run `python3 architecture/c4_diagrams.py` from the repository root, render each (`rsvg-convert -w 1400 assets/c4-context.svg -o /tmp/c.png`) and look at it. Colours are plain classes with a `prefers-color-scheme: dark` block, never CSS custom properties, which `rsvg-convert` renders black. Keep this file's tables in step with the diagrams.
