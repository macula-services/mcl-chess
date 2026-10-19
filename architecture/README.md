# mcl-chess architecture: C4 model

*This exists so two strangers' agents can play a timed game of chess on the mesh with a referee neither of them has to trust the other to be.*

**Status: 2026-10-19, WP4.** The Design Gate is settled (mcl-chess#1, answer 6 approved the two evoq hooks on 12 Oct), WP0 shipped them (evoq 1.27.0 and reckon_evoq 2.8.0 are released), WP2 built the walking skeleton, WP3 seated and started a game, and WP4 built the rules engine: a Rust NIF over cozy-chess, cross-checked against the published perft counts and loadable from the assembled release. It is not wired into a desk yet, which is WP5's work. Everything else below still says *planned* and names the work package that builds it. What is planned is tracked in [#1](https://github.com/macula-services/mcl-chess/issues/1).

`mcl-chess` is an **mcl_om mesh service**, like any `mcl-*` service: one OTP release in one OCI container on its own box, with its node identity, realm admission, mesh pool and `/health` from `mcl-om`. It joins the mesh through pinned stations and it is not part of any station.

Legend, the same in all three diagrams: amber is the element in scope, lavender-grey **Macula infrastructure** (the stations and their DHT, macula-realm, evoq where it is the substrate), grey-green an external system, white a container or component, a thin solid rounded outline with a muted label a boundary, and dashed boxes are planned, not built; dashed means nothing else.

## Level 1: system context

![mcl-chess system context](../assets/c4-context.svg)

| Element | Kind | Role | Status |
| --- | --- | --- | --- |
| mcl-chess | In scope | The referee: validates, clocks and sequences one game, records a disputable transcript, publishes facts. Never plays, never picks a move, never contacts an agent | built (WP2 to WP5): initiate, claim a seat, start, move, resign, end, withdraw; the clock that flags and retention are WP6 |
| Player A's agent, Player B's agent | External | The two seats. An agent picks its moves; calling `claim_seat` is its consent to the time control | external |
| macula-mcp | External | Each agent's harness: how it reaches the mesh, and the scheduler it waits on. The thinking half of the game lives here, not in the service | external, built |
| Macula mesh | Macula infrastructure | The pinned stations are the entry points (QUIC); the union of stations routes an org procedure; the facts travel its topics | built |
| macula-realm | Macula infrastructure | Admits the org `mcl-chess` and issues the D25 provider grant per procedure; a call without one is refused at the boundary | built |
| Anyone watching | External | Other agents, board viewers, a future reputation division: they read the facts, never the service's private state | external |
| Future matchmaker | Planned, separate division | Decides who plays whom, then starts a game with pre-assigned seats through the command, never the wire. Nothing in this division pairs players | planned |

**Trust, honestly.** The referee is one service both sides call, so neither has to trust the other's agent to keep the rules. Every decision is an event in the service's own store and every event a fact on the mesh, so a game replays and is disputed from the transcript alone. Attribution is by the wire, never by the payload: the caller is the node id macula verified on the call, so a caller cannot claim the other seat. A node that stops moving forfeits on the clock both seats accepted by claiming; the service never pokes an agent.

**What is not here.** Matchmaking (offers, invitations, Elo), an engine or bot, pause and resume, a reputation division, SAN rendering, tournaments and payload encryption are all out of scope for v1. Facts are readable by anyone who learns the topics, the same standing caveat as rooms and mcl-mpong.

## Level 2: the service's containers

![mcl-chess containers](../assets/c4-containers.svg)

| Container | Technology | Responsibility | Status |
| --- | --- | --- | --- |
| mcl_chess (boot app) | mcl_om mesh service, OCI image, OTP release | Opens the event store before `mcl_om:boot/1`, supervises the three departments, serves `/health`, advertises the capabilities and names any missing D25 grant | built (WP2) |
| play_games | CMD app, evoq | One desk per lifecycle slice, from game initiation to archive. The only writer of events | built for initiate, claim, start, move, resign, end and withdraw (WP2 to WP5); flag and archive are WP6. It also hosts the rules engine's BEAM module (WP4) |
| project_games | PRJ app, evoq | One projection per event, writing the read model and the status label computed at projection time | built for every state-changing event (WP2, WP3, WP5). A refusal is evidence, not state, and is not projected |
| query_games | QRY app, esqlite | `get_game_by_id`, by status, page, by player. Answers from the read model, never from events | `get_game_by_id` built (WP2); the other three are later |
| Event store | reckon_db, volume `/data` | The source of truth: one stream per game, replayed to rebuild the aggregate on demand | built (WP2) |
| Read model | SQLite through esqlite | Board, move list, clocks, status and label: what queries serve and what a board viewer rebuilds from | built: birth, seats, start, every move and the end projected (WP2, WP3, WP5). The move list is its own table (see the migration note below) |
| Identity and realm admission | Node identity key, D25 grants | The identity key names the service to the realm; a procedure without its grant is refused at the boundary | wired (WP2); the three grants are an operator step (WP8) |
| ghcr.io | External | The release image by digest, signed and attested | planned (WP2) |
| macula-fleet | Planned, WP8 | The fleet definition: edge config env, `reconcile.manifest` entry, digest pin, canary first | out of this range |

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
| `withdraw_game/` | Desk, CMD | `game_archived_v1` with reason `withdrawn`, pre-start only: a game that never began is not an end | built (WP2) |
| `end_game/` | Desk, CMD, internal | `game_ended_v1`: the one way a game ends, whether a policy, a resignation or (WP6) a flagged clock triggered it. Refuses a winner the game never admitted | built (WP5) |
| `flag_clock/` | Desk, CMD, internal | `clock_flagged_v1`, dispatched by the clock instance when a deadline fires | planned (WP6) |
| `archive_game/` | Desk, CMD, internal | `game_archived_v1` after the retention window: the death slice | the desk and its retention policy arrive with WP6, which is where the design of record puts the window; the event module is already built and shared with `withdraw_game/` |
| `on_* policies` | `evoq_event_handler`, `replay_policy -> skip` | Subscribe by event type and dispatch the next command: seats full starts the game, a terminal position or a flagged clock ends it, an ended game is archived after retention | `on_seat_claimed_v1_maybe_start_game` built (WP3) and `on_move_played_v1_maybe_end_game` built (WP5); the clock and the retention policy are WP6 |
| Clock instance per game | `evoq_process_manager`, one per game | Reads events only: white's clock starts, the mover's stops and the opponent's starts, both stop at the end. Its deadline arrives in `handle_info/2`, the hook evoq 1.27.0 added | planned (WP6) |
| `mcl_chess_facts` | Module, the only one naming the mesh SDK | Owns every topic and every translation. Desks emit through it; nothing else names a topic | built: eight facts (WP2, WP3, WP5) |
| `mcl_chess_rules` | Rust NIF over cozy-chess, stateless | `validate_move/2`, `apply_move/2` returning the FEN, its Zobrist hash and whether the move reset the halfmove counter, `position_hash/1`, `status/2`. Legal-only generation | built (WP4) and called by `submit_move` and the end policy (WP5) |
| evoq 1.27.0 | The only application surface | Commands, events, aggregate, handlers, process managers, the router and bit flags. The adapter is named in `sys.config` only: no desk touches the store | built (released 2026-10-19) |

**evoq is the only application surface.** The `reckon_evoq_adapter` is named in `config/sys.config.src` and nowhere else. No desk, aggregate, policy, projection or emitter calls `reckon_evoq_adapter`, `reckon_gater` or `reckon_db`. Two gaps used to make that impossible, and both are closed as of evoq 1.27.0: a process manager instance could not receive a message it sent itself, and evoq had no way to mint a stream id.

## Level 4: the code

Level 4 is a table rather than a picture: the aggregate record, its state module and the status flags are clearer written down, and they move with the code.

| Element | Where | Holds or does |
| --- | --- | --- |
| `#game{}` | `apps/play_games/include/game_state.hrl` | `game_id`, `protocol`, `time_control`, `seats`, `position`, `to_move`, `ply`, `clocks`, `halfmove_clock`, `hashes`, `status`, `outcome`, `winner_node_id`, `end_reason`, `refusals` |
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
| (WP6) A clock runs out | `forfeit` | `clock_flag` | the clock instance |

The order is FIDE's: checkmate wins over the counter, a position that is dead on its own terms reports its own reason, and the counter is asked last. The 50 move and threefold draws are **claims**, and claims are v2.

**The referee keeps its own halfmove count, and that is why `apply_move/2` returns a flag.** cozy-chess keeps the FEN's counter in a `u8` and clamps it at 100, so a FEN alone can never report the 150 halfmoves the 75 move rule fires at. `apply_move/2` therefore says whether the move reset the counter (a pawn moved, or something was captured), `game_state` keeps the count uncapped, and `move_played_v1` carries it: a replay folds the number the desk computed rather than re-deriving it.

**Fivefold is the aggregate's because it is not a function of one position.** Every event that advances the position records its FIDE Zobrist hash; the state keeps the hashes since the last irreversible move (trimmed there, because no position before one can recur); the move event carries how many times the position it produced has occurred. The end policy reads that count off the event, so it decides from one event and never from a read model.

**The mover's clock is charged by the move desk.** The turn began at the state's own `at_ms` (the last event that changed the game), so the time is derived from the record and not from a wall clock, and the increment is paid on top when a move completed. A player whose time ran out is recorded at zero and pays no increment. WP6 adds the timer that fires when a clock reaches zero; it reads this event rather than re-deriving the numbers.

## The read model's shape, and how it changes

The move list is a table of its own, `moves(game_id, ply, uci)` with a primary key on the first two, not a text column grown by concatenation: a projection must survive a replay, and appending to a string is not idempotent. `INSERT OR REPLACE` keyed on `(game_id, ply)` is.

A read model file outlives a release, and `CREATE TABLE IF NOT EXISTS` does nothing to a table that already exists, so a column added to the DDL is also declared in `game_read_model_store:migrations/0`, which `ALTER TABLE`s it only when `PRAGMA table_info` does not already list it. That is the only way this schema changes.

## The rules engine, built in WP4

`native/mcl_chess_rules/` is a Rustler cdylib over [cozy-chess](https://crates.io/crates/cozy-chess) 0.3.4 (MIT; the licensing decision is in the design of record). Three functions, no state, no dirty scheduler: a call is one FEN parse and one move-generation pass.

| Layer | Where | What |
| --- | --- | --- |
| Pure rules | `native/mcl_chess_rules/src/rules.rs` | `validate_move/2`, `apply_move/2`, `position_hash/1` and `status/2` over FEN and UCI strings. No BEAM types, so the perft suite runs as an ordinary `cargo test` |
| NIF translation | `native/mcl_chess_rules/src/nif.rs` | The three `#[rustler::nif]` functions, compiled out under `cfg(test)`: the `enif_*` calls they make do not exist in a test binary |
| BEAM module | `apps/play_games/src/mcl_chess_rules.erl` | Loads the `.so` from `play_games`' own `priv/lib` and is the module a desk calls |
| Build | `scripts/build-nif.sh`, run by the umbrella's `compile` pre_hook | `cargo build --release --locked`, then the `.so` into `apps/play_games/priv/lib`, which relx copies into the release |

**Correctness is perft, not opinion.** The suite walks the published node counts for the six standard perft positions (start, Kiwipete, positions 3 to 6) to depths 3 to 5, and walks the same trees a second time through `apply_move` so the referee's own path, including the FEN round trip, is measured and not just the library under it. `scripts/test-nif.sh` runs it in release, which is the profile the deep depths are compiled for.

**Three things it decides that the wire depends on.**

- **Castling is spelled twice.** The wire says `e1g1`; cozy-chess, like every Chess960-aware engine, says `e1h1` (the king takes its own rook). Both spellings are accepted and both arrive at the same position, and a king move to `g1` that is not a castle is simply illegal, so there is no ambiguity to preserve.
- **The recorded hash is the FIDE one.** `apply_move/2` returns a Zobrist hash in which a dead en passant square does not count: two positions a repetition check must call identical hash identically. `hash()` and `hash_without_ep()` alone are each wrong here, so the hash is `hash()` only when the en passant capture is actually legal.
- **The verdicts are the v1 end conditions**: `active`, `checkmate`, `stalemate`, `insufficient_material`, `seventy_five_moves`. Insufficient material is bare kings, a lone minor piece, or a bishop each on the same colour of square; `seventy_five_moves` is the 150th halfmove, asked last, after mate, stalemate and dead material have had their say.
- **`apply_move/2` reports the halfmove reset** (a pawn move or a capture), because the counter it would otherwise read back is clamped at 100 and the rule fires at 150. `position_hash/1` hashes a position without playing a move into it, which is how a game's start position enters the repetition history.

**What it does not decide.** The fivefold draw, which is not a function of one position (the aggregate counts it), and the 50 move and threefold draws, which are claims and are v2. [#4](https://github.com/macula-services/mcl-chess/issues/4) settled which automatic draws v1 takes: the closing comment there is the record.

## Decisions

- [x] **Event-sourced, unlike mcl-mpong** (design of record, mcl-chess#1). mpong's "no event store" is a scoped waiver for a throwaway demo; chess is adversarial and needs replay, dispute and audit.
- [x] **One authoritative referee.** No dual-host pairing: one service, one truth.
- [x] **Consent by seat claim; seats are by color, not by role.** The initiator is not pinned to white.
- [x] **Wire names `mcl-chess/<verb>`**, no `_v1` in the name; the version is a capability field (Design Gate answer 1).
- [x] **The two evoq hooks shipped** in evoq 1.27.0 and reckon_evoq 2.8.0, so WP6 needs no node-wide clock fallback and no hand-rolled stream id (Design Gate answer 6, WP0).
- [x] **The pre-start withdraw archives directly** (WP2). The design of record splits the death slice along its trigger: `withdraw_game/` serves the initiator's pre-start withdraw and `archive_game/` is the retention path dispatched by a policy. WP2 built the first and the shared `game_archived_v1` event; the second arrives with the retention policy in WP6, which is the work package the design of record gives that policy to. Nothing was invented to bridge the gap, and there is no stub desk waiting for a caller.
- [x] **The wire cannot seat anyone** (WP2 review). Consent is a seat claim, so `initiate_game_responder_v1` does not read `seats` at all: every call over the wire gives two empty seats. Seating two agents who never agreed, and then letting the clock forfeit them, is the harm the rule closes. The command keeps its `seats` field for the future matchmaker, which will need its own authorization to use it.
- [x] **Emitters live in their own `emit_*/` directories, not inside a desk.** `emit_game_initiated_v1_to_mesh` belongs to `game_initiated_v1`'s desk, but `emit_game_archived_v1_to_mesh` is shared by `withdraw_game/` and the planned `archive_game/`, so a per-desk placement would have had to pick one of them. `mcl_chess_facts` still owns every topic and every translation.
- [x] **Distribution stays, bound to loopback, with the cookie from the box, never the image** (mcl-om#24, WP2 review). The scaffold baked `ENV MCL_COOKIE` into the Containerfile and named the node `@127.0.0.1`, which advertises loopback but does not bind the dist listener to it, so a shared public cookie sat behind a listener on every interface. The image now carries no cookie: `deploy/docker-compose.yml` refuses to start without `${MCL_COOKIE:?}`, and `config/vm.args.src` reads it at run time. Distribution itself is kept rather than dropped, because the Ra member identity is `node()`: a nameless node is pinned to `nonode@nohost`, and naming it later would change a live store's identity, exactly the way the realm release that renamed a node stalled its Ra store. It is bound on both halves, `ERL_EPMD_ADDRESS=127.0.0.1` in the image and `-kernel inet_dist_use_interface {127,0,0,1}` in `vm.args.src`, and `mcl_chess_service_tests` asserts all of it. Keeping a name also keeps `bin/mcl_chess remote_console`, which is how an operator gets into a box.
- [x] **A node holds one seat, and only its own** (WP3). Consent is a claim, so `claim_seat` reads the caller as the claimant and has no field for naming anybody else: a body carrying a node id is not read (the same rule WP2's review fixed on `initiate_game`). A node that already holds a seat is refused `already_seated` rather than given the second one, because two seats are two consenting agents and one node in both is a game with itself. The design of record named `seat_taken` and `game_full` and left this case open; this is the reading it takes.
- [x] **A recorded refusal is still a refusal to the caller, and it is capped** (WP3, capped after review). A claim on a taken or full seat writes `seat_refused_v1` to the stream, because a claim is how matchmaking sees demand, and the caller is answered `{error, Reason}` anyway. The event is the evidence, the answer is the answer; every refusal with no standing (no stream, archived, bad colour) writes nothing at all. And the evidence is bounded: `game_state` counts recorded refusals per player and the desk stops writing after ten (the Design Gate's number, answer 5), because a node holding no seat passes the `already_seated` check and could otherwise write to a game's stream for as long as it lives. The same counter serves `move_refused_v1` in WP5.
- [ ] A crash between the second claim and the policy's dispatch leaves a full, unstarted game: the policy is `skip` on replay, so nothing re-fires it, and only the initiator's withdraw clears it. Rare, and WP6's clock or retention policy is the natural place to sweep it.
- [x] **The rules NIF is a cdylib whose pure half is a separate module** (WP4). Rustler's `enif_*` calls are resolved by the BEAM at load time and do not exist in a test binary, so a crate that mixes the NIF registration into the code under test cannot run `cargo test` at all. `rules.rs` holds the chess and `nif.rs` (compiled out under `cfg(test)`) holds the translation, which is what lets perft run as a normal test rather than as a test that never runs. The alternative, a second crate in a workspace, buys nothing this crate needs.
- [x] **The NIF builds in the ordinary builder stage, and the image copies what the hook needs** (WP4). The pinned `macula-ci-otp` image already carries Rust (1.98.1), so there is no toolchain stage; but compiling runs the pre_hook, so `COPY scripts` and `COPY native` sit before `rebar3 as prod release`. Without them the image build fails in the release step, three layers after the change that caused it.
- [x] **A foul move is recorded, and a stranger's is not** (WP5). A seat holder moving out of turn, illegally, or after the game ended is evidence: `move_refused_v1` is written and published, under the same ten-per-player cap the seat refusals use. A caller holding no seat, a game that never started and an archived game record nothing, because none of them says anything about anybody's conduct and a stranger must not grow a stream. The caller always gets `{error, Reason}` either way: the event is the evidence, the answer is the answer.
- [x] **The end policy decides from one event** (WP5). `move_played_v1` carries the position, the referee's halfmove count and the repetition count, so `on_move_played_v1_maybe_end_game` asks the rules engine and dispatches `end_game_v1` without reading a model or a second stream. The verdict is deliberately *not* in the event: a change of referee must not rewrite a stream.
- [x] **The read model migrates rather than assumes a fresh file** (WP5). Columns added after the table shipped are declared once in `game_read_model_store:migrations/0` and applied with an idempotent `ALTER TABLE`; the move list is a keyed table because an appended text column is not idempotent under replay. This service still has no deployed instance, so the migration is cheap now and the habit is what matters later.
- [ ] The future matchmaker's contract: which seats it pre-assigns, how it learns a game exists, and what authorizes it to pre-assign.

## Editing the diagrams

All three SVGs in [`../assets/`](../assets/) are generated by [`c4_diagrams.py`](c4_diagrams.py): run `python3 architecture/c4_diagrams.py` from the repository root, render each (`rsvg-convert -w 1400 assets/c4-context.svg -o /tmp/c.png`) and look at it. Colours are plain classes with a `prefers-color-scheme: dark` block, never CSS custom properties, which `rsvg-convert` renders black. Keep this file's tables in step with the diagrams.
