# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

- The clock and retention are WP6, so the clocks in a move event are charged by
  the move desk from the aggregate's own timestamps, but nothing yet fires when
  a clock runs out: a game ends by mate, a dead position, the 75 move rule,
  fivefold repetition or a resignation.
- A draw by the 50 move rule or by threefold repetition is a claim, and claims
  are v2 (mcl-chess#1). The automatic draws (75 moves, fivefold) are v1, per
  the operator's decision on mcl-chess#4.
- `initiate_game` seats nobody: the responder does not read `seats`, so every
  call over the wire gives two empty seats. Seating is a consent claim, and
  pre-assignment belongs to the future matchmaker, which will need its own
  authorization.
- No fleet definition yet: the service is not deployed on a box, and its
  realm grants are an operator step (WP8).
