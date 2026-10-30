# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.8.0] - 2026-10-30

Two unreleased sections had accumulated here under the same heading; both
entries ship in this release, unchanged, with the macula 18 migration on top.

### Changed

- **macula 18 and mcl_om 1.6** (macula-services/mcl-om#42). The floors move to
  `mcl_om ~> 1.6` and `macula ~> 18.0`. macula arrives through mcl_om, but a
  top-level pin wins in rebar3, so both move together; no service code moved.
- **The caller rule was already stated here, and now the SDK enforces it.**
  All six capabilities carry `auth => open` — any identified caller that
  reaches the mesh may start a game, take a seat, play a move, resign, withdraw
  or look a game up, which is what this service has always served. macula 18
  refuses an advertise that names no call class (macula-io/macula#147) and
  mcl_om 1.6 refuses the boot of a capability that names none, so the class
  that used to be implicit is now what the substrate reads.
- **No subscription moved.** This service declares no `subscriptions/0`, so
  macula 18's requirement that a topic subscription name its sources has
  nothing to apply to here.
- Minor rather than patch: a SDK major is a deployment change, and this
  release runs only on a box carrying mcl_om 1.6.

### Added

- **macula is declared, at 18** (macula-codebase-checks#4, #14). The
  service called macula modules and compiled against `macula_response`
  without declaring the application: it arrived transitively through
  `mcl_om`, so a rebuild took whatever major the newest mcl_om carried.
  `macula` is now a direct dependency, at `~> 18.0` from this release, and
  `mcl_om` is at `~> 1.6`, the release whose own base is macula 18. 18.0
  keeps wire 1.0, so this service still speaks to every wire 1.0 box.
  This service gates no overlay and issues no endorsement.

### Fixed

- Every app the release names carries the release version (mcl-chess#11). The desk
  apps sat at 0.1.0 through v0.7.2 while the release tuple said the tag's
  version, so the release guard would refuse the next tag and every box would
  have gone on reporting the older one. `mcl_chess_release_apps_tests` now reads the release tuple,
  every app it names and each app's .app.src, and fails when they disagree.
- **A game's read model is written by one cursor, so a column can no longer be
  lost** (mcl-chess#18). This service had one `evoq_event_handler` child per
  event type, and until evoq 1.30 that was harmless because the router
  delivered to them in one pass. evoq 1.30 gave every handler its own courier,
  so delivery became ordered within a handler and not across handlers
  (evoq#30) — and the ordering this read model had relied on without saying so
  went away. evoq is declared here at `~> 1.27`, which admits 1.30, and no
  `rebar.lock` is committed, so a rebuild resolved a different evoq and the
  same commit that was green in the morning failed in the afternoon: this is
  not the SDK migration, it is a dependency that moved under it. Two symptoms
  followed. The mate's last move, landing after the end it caused, put the
  finished game back to `in progress` and left it there, which made a lost
  write read as a flaky test. And because each event owns columns no other
  event writes — `started_at` only a start, `flagged_node_id` only a flag,
  `to_move` only a move, the outcome only an end — a version guard alone did
  not help: it dropped the older write whole, and that write's columns were
  then gone for good, so an archived game could hold no outcome at all.
  The seven per-event handlers are now **one** handler,
  `game_lifecycle_to_games`, interested in all seven game events, so evoq's
  per-handler ordering is an ordering over the game's own events and no column
  is ever skipped. The `AND version < ?` guard stays, meaning only what it now
  means: a redelivered event does not overwrite newer columns. The birth is
  still the only INSERT and still does nothing on conflict.
  `read_model_out_of_order_tests` asserts the structural claim (one handler,
  all seven events) — the test that fails if anyone splits it again — checks
  that the four column groups survive one game, and checks that a flag and the
  end of the same command both land.

## [0.7.2] - 2026-10-20

### Fixed

- **Every capability refused a request shaped the way it documents
  (mcl-chess#10):** the responders read their fields with
  `maps:get(<<"key">>, Payload, Default)`, but on the wire every text key
  arrives as `{text, Bin}` and `caller` arrives under the atom key
  (`macula_station_link:with_caller/2`). Every real call answered
  `invalid_params` or `missing_required_fields` to a well-formed request, while
  two responder tests, fed the shape the handlers expected, stayed green; the
  live game harness found it on its first `initiate_game`. Reads now go through
  `mcl_om_wire:field/2,3` and `mcl_om_wire:caller/1`, which exists to resolve
  exactly this.
- **Replies carried their text as opaque byte strings (mcl-chess#10):** a plain
  binary on this wire is a CBOR byte string, so a reply's `game_id`,
  `status_label`, `outcome` and `position` reached clients as blobs and a
  client could not match a returned game id against the one it sent. Every
  capability reply now goes through `mcl_chess_wire:to_wire/1`, the same
  conversion the facts already used.
- **The verified caller is a raw node id, and text must be UTF-8
  (mcl-chess#10):** macula injects `caller` as the raw 32-byte node id, and a
  reply or a fact carrying one is refused as `invalid_text` once it is tagged
  as CBOR text, which reaches the caller as `unknown_error`. Worse, the events
  and seats would hold something no other part of the service compares
  against. The caller is now hex-encoded once, at the read boundary
  (`mcl_chess_wire:caller/1`), so events, seats, facts and replies all carry
  the same 64-character hex node id.

## [0.7.1] - 2026-10-20

### Fixed

- **A comment in `config/vm.args.src` stopped 0.7.0 from booting (mcl-chess#9):**
  the comment quoted the shell-style required-variable form inside
  dollar-brace braces. relx expands `vm.args.src` with an awk that derives its
  substitution pattern from the text between the braces, so `:?` became a
  quantifier on the colon, the pattern matched nothing, and the loop never
  advanced: the container ran at one core, printed no line, and never created
  its health socket. Comments are not skipped by that awk. The comment now says
  the same thing without a dollar-brace form, and
  `mcl_chess_service_tests:template_variable_references_are_plain_names_test_`
  refuses any non-plain token in `vm.args.src` and `sys.config.src`, comments
  included.

## [0.7.0] - 2026-10-20

### Added

- **A started game says when it started (mcl-chess#3, WP8):** the `games` row
  carries `started_at`, written by `game_started_v1`'s projection from the
  event's own `at_ms` (the reading the first deadline is set from), selected by
  `get_game_by_id` and answered as `started_at` beside `initiated_at`. The
  schema contract holds the column, its place in the desk's destructuring and
  its value in the whole game flow; the seats-and-start suite asserts the desk
  answers with the moment the store recorded, not a moment of the reader's.
  `started_at` is also declared in `migrations/0` and added with an idempotent
  `ALTER TABLE` when a file built before it exists, because such a file can
  (`deploy/docker-compose.yml` runs against a persistent data directory):
  without it every `game_started_v1` would fail to project, silently.
  `read_model_migration_tests` builds that older file and proves the boot
  migrates it and the slice still projects a start.

## [0.6.0] - 2026-10-20

### Added

- **FIDE 6.9 on the flag path (mcl-chess#6):** `mcl_chess_rules:cannot_mate/2`
  answers the one-sided question a flag has to ask, "can this side mate at all
  in this position", which `status/2`'s `insufficient_material` cannot (that one
  asks whether neither side can mate). A flag against a side that cannot mate is
  recorded as `draw` with reason `clock_flag_insufficient_material` instead of a
  forfeit, and the flagged player's own material does not count towards the
  opponent's ability to mate. "Any possible series of legal moves" includes the
  defender's own, so a lone minor piece can mate a king whose side still has a
  unit to block a flight square: that flag stands as a loss.
- **The facts contract, pinned (WP7):** every one of the nine facts now has its
  topic and its key set pinned, and a table gives the CBOR type of every key.
  `mcl_chess_facts_tests` compares each fact's wire shape against that table, so
  a key that is added, renamed or quietly changed from text to an atom reaches
  the suite instead of a subscriber in another language.
- **The read-model schema contract (mcl-chess#5):** `game_schema_contract_tests`
  parses the DDL out of `game_read_model_store:schema/0`, compares it with the
  file, with the columns `get_game_by_id` selects and destructures (one row whose
  every cell is different, read back through the desk), with the migrations, and
  with what every projection writes (each one run against the real store). Three
  modules promised this suite and none existed.
- **`scripts/fault-in-place.sh`**, the proof harness for #7: it replaces the
  rules NIF while a live VM has it mapped, in either mode, and counts the VMs
  that die.

### Changed

- `game_read_model_store:migrations/0` is exported, so the contract test can
  hold the migrations to the DDL.

### Fixed

- **The shutdown SIGSEGV (mcl-chess#7).** `scripts/build-nif.sh` installed the
  rules NIF with `cp src dst`, which truncates and rewrites the inode a running
  VM has mmap'd: the kernel serves unrelocated file content to an already
  relocated shared object, the loader's `fini_array[0]` reads as zero, and the
  VM dies inside `_dl_fini` at shutdown (or with SIGBUS part way through a copy).
  It fires whenever one checkout's pre_hook rewrites the library under another
  process in that checkout, which is what a second `rebar3` command does. The
  install now writes a temporary file and renames it, so a running VM keeps the
  inode it mapped and the next load gets the new one. Proven both ways:
  `fault-in-place.sh overwrite` crashes 5 of 5 VMs, `atomic` 0 of 5.

## [0.5.0] - 2026-10-20

### Added

- **The clock (WP6):** one `evoq_process_manager` instance per game schedules
  the deadline for the side to move and, when it fires, dispatches the internal
  `flag_clock_v1`. The desk records `clock_flagged_v1` (who ran out, the clocks,
  the status) and publishes it; `on_clock_flagged_v1_maybe_end_game` dispatches
  `end_game_v1`; the end is a forfeit, `clock_flag`, with the opponent named
  from the record. The deadline is recomputed from each event's own `at_ms` and
  the clocks it carries, never from a wall clock, so a replay rebuilds the same
  deadline and a deadline that has already passed fires once, at boot.
- **A move on an overdrawn clock is refused** (`time_expired`), never clamped to
  zero and played, and the attempt is recorded as `move_refused_v1` under the
  same ten-per-player cap (Design Gate answer 4). The move desk and the flag
  desk ask the same arithmetic, `game_state:expired/3`.
- **A flag re-judges the position before it forfeits.** `end_game` asks
  `game_verdict` when the reason is `clock_flag`, so a position the rules had
  already decided keeps its own verdict: a game left mated by a crash ends
  `checkmate`, not `clock_flag`. A resignation and every other end keep the
  decision they were sent with.
- **The death slice and the retention window (WP6):** `archive_game_v1`, and
  `game_retention_pm`, one instance per ended game, which archives it after the
  window. The window is `play_games`' `game_retention_ms`, 24 hours by default
  and set in `config/sys.config.src`; an ended game replayed after a longer
  shutdown is archived from its own `at_ms`. `game_archived_v1` keeps the reason
  `retention`, so a reader tells it from the pre-start `withdrawn`.
- **The two sequences a crash can leave half done are finished.** A claim that
  filled the second seat with no start, and a flag with no end, are caught up by
  the game's clock instance when it is rebuilt from the log: its folded state
  shows the gap, and a delayed self-message dispatches the missing
  `start_game_v1` or `end_game_v1`. The delay keeps a healthy node from
  double-dispatching, and the desks' guards make a late command a refusal rather
  than a second event.
- **The facts contract grew one fact:** `clock_flagged_v1` on
  `<realm>/mcl-chess/chess/game/clock_flagged_v1`, carrying `game_id`,
  `player_node_id`, `clocks`, `status` and `at_ms`.
- **The read model gained `flagged_node_id`**, applied to an existing file by an
  idempotent migration, and a projection for `clock_flagged_v1`.
- **`play_games_pm_registrar`** registers the division's process managers with
  evoq's PM router and registers them again if the router restarts.

### Fixed

- **A failed flag or archive dispatch is asked again.** evoq's process manager
  runtime only logs a failed dispatch, so one store timeout or Ra leader change
  during a station roll would have left a player who is out of time in a game
  that never ends. The instance now keeps its deadline after firing and repeats
  the dispatch until the event that settles it arrives; the desks' guards refuse
  a retry nobody needs.
- **An archived game stops its clock instance.** A game withdrawn before it
  started (two seats filled, no start dispatched, then the initiator withdraws)
  never produces an end, so its instance used to live for the node's lifetime and
  ask for a start on a dead game on every rebuild.

### Notes

- The retention window is a decision, not a placeholder: 24 hours, configurable
  (the design of record's open question 2).
- A deadline that passed while the node was down fires when the game's instance
  is rebuilt, so a restart or a station roll charges its downtime to the side to
  move. That is "the clock alone decides" taken literally; a clock only the
  service can see is a clock a player can stop.
- `end_game_v1`, `flag_clock_v1`, `start_game_v1` and `archive_game_v1` accept
  their payload map as well as their record in `validate/1`, because evoq's own
  router validates the payload when a process manager dispatches the command.

## [0.4.0] - 2026-10-19

### Added

### Added

- **A game played to its end (WP5):** `submit_move` and `resign_game` on the
  wire, the internal `end_game` that a policy dispatches, and
  `on_move_played_v1_maybe_end_game`, which reads a played move, asks the rules
  engine for a verdict and ends the game on `checkmate`, `stalemate`,
  `insufficient_material`, the 75 move rule or fivefold repetition. A move is
  played by the seat the caller holds, from the node id macula verified, and
  only when it is that seat's turn; a foul attempt by a seat holder (out of
  turn, illegal, or after the game ended) is written as `move_refused_v1` and
  published, on the same ten-per-player counter the seat refusals use, while a
  caller with no seat is refused and writes nothing. `game_ended_v1` carries
  the outcome (`winner`, `draw`, `forfeit`), the reason and the final position,
  and one emitter serves every way a game ends.
- **The automatic draws (mcl-chess#4, operator decision 2026-10-19):** a v1
  game ends as a draw at the 75 move rule (150 halfmoves without a pawn move or
  a capture) and on fivefold repetition. `status/2` gained the
  `seventy_five_moves` verdict; fivefold is counted by the aggregate over the
  hashes its events recorded, because it is not a function of one position. The
  50 move and threefold draws stay v2 claims.
- **The referee's own halfmove clock.** cozy-chess keeps the FEN's counter in a
  byte and clamps it at 100, so the 150 the 75 move rule fires at is
  unreachable through the FEN. `apply_move/2` now reports whether a move reset
  the counter, `game_state` keeps the uncapped count, and `move_played_v1`
  carries it. `position_hash/1` was added so the position a game starts from is
  in the repetition history too.
- **A withdraw cannot clear an ended game.** Ending clears `STARTED`, so an
  ended game looked unstarted to the withdraw desk, and the initiator could have
  archived a game that had actually been played: the archive would have replaced
  a recorded outcome with `withdrawn` and bypassed the retention slice that owns
  the death of a played game. `withdraw_game` now refuses `game_ended`.
- **The move and end projections:** the board, `to_move`, the clocks and the
  halfmove count are projected per move, the move list lives in its own
  `moves` table keyed on `(game_id, ply)` so a replay replaces rather than
  duplicates, and the end writes the outcome, the reason, the winner and
  `ended_at`. `get_game_by_id` answers with the move list, the outcome and the
  end reason; the read-model store migrates an existing file with idempotent
  `ALTER TABLE`s instead of assuming a fresh one.

- **The rules engine (WP4):** `native/mcl_chess_rules/`, a stateless Rustler
  NIF over cozy-chess 0.3.4 (MIT) exposing `validate_move/2`, `apply_move/2`
  and `status/2` through the BEAM module `mcl_chess_rules` in `play_games`.
  Moves are UCI, and a castle may be spelled `e1g1`/`e1c1` (the wire's way) or
  `e1h1`/`e1a1` (cozy-chess's Chess960 way): both are accepted and both arrive
  at the same position. `apply_move/2` returns the position's FEN and its FIDE
  Zobrist hash, in which an en passant square nobody can capture on does not
  count, so the hashes recorded in `move_played_v1` will count repetitions the
  way the rules do. `status/2` answers `active`, `checkmate`, `stalemate` or
  `insufficient_material`. Correctness is pinned by perft: the six standard
  positions walked to depths 3 to 5 against the published node counts, and the
  same trees walked again through `apply_move`. The `.so` is built by
  `scripts/build-nif.sh` from the umbrella's compile pre_hook and ships in the
  release under `lib/play_games-<vsn>/priv/lib`, where the BEAM module loads
  it. Not yet called by a desk: `submit_move` wires it in WP5.
- **Seats and start (WP3):** two agents claim a colour each and the game starts
  itself. `claim_seat` takes the caller's own verified identity and nothing
  else, so a body cannot seat a second party; first claim wins a colour, a node
  holds one seat, and a claim on a taken or full seat is recorded as
  `seat_refused_v1` (reason `seat_taken` or `game_full`) while still being
  answered as a refusal. The recording is capped at ten per player per game
  (the Design Gate's number): past it the refusal is answered exactly as
  before and nothing is written, so a node holding no seat cannot grow a game's
  stream. When the second seat is taken,
  `on_seat_claimed_v1_maybe_start_game` dispatches the internal `start_game`,
  which writes `game_started_v1` with both holders by colour, the position and
  the clocks the game starts with. Three more facts go out on
  `io.macula/mcl-chess/chess/game/` (`seat_claimed_v1`, `seat_refused_v1`,
  `game_started_v1`), and the seats and the started status are projected into
  the read model, so `get_game_by_id` answers a started game.
- **The walking skeleton (WP2):** `initiate_game` and `withdraw_game` through
  all three departments, on the real event store. A game is born by
  `game_initiated_v1` (carrying its whole initial state, seats empty and all)
  and dies before it starts by `game_archived_v1` with reason `withdrawn`, and
  both walk the CMD, PRJ and QRY path: the events land in `reckon_db`, the
  projections write the SQLite read model with the status label computed at
  projection time, and `get_game_by_id` answers from it. The two facts go out
  on `io.macula/mcl-chess/chess/game/game_initiated_v1` and
  `.../game_archived_v1`.
- `play_games` (CMD), `project_games` (PRJ) and `query_games` (QRY), on the
  mcl-bookclub template; `game_aggregate`, `game_state` and the
  `evoq_bit_flags` status in `game_status.hrl`.
- The Game aggregate's stream id is minted through `evoq_event_store:new_stream_id/1`
  (evoq 1.27.0), so the store's id contract has one definition and no desk
  names the adapter, the gateway or the store.
- Four capabilities, each with its D25 grant pending in the realm:
  `mcl-chess/initiate_game`, `mcl-chess/claim_seat`,
  `mcl-chess/withdraw_game`, `mcl-chess/get_game_by_id`.
  The internal slices (`start_game`, `flag_clock`, `end_game`, `archive_game`)
  are deliberately not on the wire.
- The C4 model (WP1): `architecture/README.md` and three generated SVGs.
- The scaffold, generated by `rebar3 new mcl_service`: an OTP release that
  boots on `mcl_om`, joins the mesh, and answers `/health` on the Unix socket `/run/mcl/health.sock`.
- `mcl_chess_service`, the six-callback `mcl_om_service` contract.
- `Containerfile` building the release in a digest-pinned builder image and
  running it on the matching digest-pinned runtime image.
- `deploy/docker-compose.yml`, the service's own run contract.
- CI: `lint-and-test` (lint, eunit, dialyzer) on every push to `main` and
  every pull request. `build-and-push` to the registry: a push to `main`
  publishes `:latest`, and a `v*` tag publishes its own version and nothing
  else.

### Notes

- In 0.4.0 the clock and retention were still WP6: the clocks in a move event
  were charged by the move desk, but nothing fired when a clock ran out. 0.5.0
  adds both.
- A draw by the 50 move rule or by threefold repetition is a claim, and claims
  are v2 (mcl-chess#1). The automatic draws (75 moves, fivefold) are v1, per
  the operator's decision on mcl-chess#4.
- `initiate_game` seats nobody: the responder does not read `seats`, so every
  call over the wire gives two empty seats. Seating is a consent claim, and
  pre-assignment belongs to the future matchmaker, which will need its own
  authorization.
- No fleet definition yet: the service is not deployed on a box, and its
  realm grants are an operator step (WP8).
