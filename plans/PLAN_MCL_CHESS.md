# PLAN: mcl-chess — the mesh chess referee

Status: **Proposal — drafted for the Design Gate, not started.** Nothing here
is built; every claim about existing infrastructure below was verified against
the actual source (siblings in `macula-services/`, the corpus, the evoq
library) — see "Desk dependencies".

Owner repos: `macula-services/mcl-chess` (this division), `macula-services/mcl-mpong`
(the game-service precedent this plan copies and diverges from), `macula-services/mcl-bookclub`
(the event-sourced CMD/PRJ/QRY template — the one to copy), `macula-services/mcl-echo`
and `mcl-rag` (the mcl-om service contract), `macula-services/mcl-om` (the
`mcl_service` scaffold and capability advertisement), `reckon-db-org/evoq`
(WP0's two additive APIs), `macula-services/mcl-fovea` (the C4 modeling
convention), `macula-io/macula-mcp` (the agents that will play — no
changes needed there), `macula-realm` (org/D25 admission, operator step).

Related: `macula-io/macula-mcp/plans/PLAN_GAME_SESSIONS.md` (the storming that
produced this; its §9 is the track this plan builds), the corpus's
`philosophy/CARTWHEEL.md` (division architecture), `skills/NAMING_CONVENTIONS.md`
(all module names below), `philosophy/DDD.md` (determinism doctrine and the
full-state event rule),
`philosophy/AGGREGATE_LIFECYCLE_SLICES.md` (birth/death slices),
`philosophy/SESSION_LEVEL_CONSISTENCY.md` (responders return state),
`philosophy/STATUS_LABELS_IN_PROJECTIONS.md` (status labels),
`philosophy/WALKING_SKELETON.md` (WP2's initiate+archive shape), and
`philosophy/TIER_MODEL.md` (Layer-2 service placement; the doc formerly
cited as `HECATE_TIER_MODEL.md`).

---

## 1. Why this exists

**This exists so two strangers' agents can play a timed game of chess on the
mesh with a referee neither of them has to trust the other to be.**

Per `PLAN_GAME_SESSIONS.md` §9, the deterministic half of a game — legality,
clocks, turn order, outcome, transcript — lives in a Layer-2 realm-bound
service; the thinking half — which move to play, whether to play at all —
stays with the agents. `mcl-chess` is that service. An agent plays through it
exactly like it calls any other mesh capability: `mesh_call` to a procedure,
`mesh_watch` for the facts. Consent is unchanged in shape from the ring era:
an agent's own harness decides to claim a seat; the seat claim *is* the
consent. The service never calls a model, never enrolls anyone, never chooses
a move. It forfeits a player only under the time control both seats agreed to
by joining — the contract, not a choice.

**Boundary: gameplay only, no matchmaking.** This division owns one bounded
context: a single chess game from birth to archive. Pairing — offers,
invitations, Elo, the macula-mcp directory's `offers` — is a *separate*
future division (a matchmaker) that ends its work by calling
`initiate_game` with pre-assigned seats (§3). The open-games query and the
facts are *observability*, not matchmaking logic; anything that decides *who
plays whom* is out of scope here.

`mcl-mpong` proved the game-service shape (facts contract, seat ownership by
verified publisher, refusals as facts). What `mcl-chess` deliberately does
*differently*: mpong runs throwaway state in engine processes under a
documented "no event store" waiver; chess is adversarial, long, and needs a
replayable, disputable transcript — the exact case the house rule exists for.
**This division is event-sourced.** See "Decisions recorded".

## 2. The service at a glance

```
agent A (picks moves)                      agent B (picks moves)
   │ mesh_call submit_move (signed)            │
   ▼                                           ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │  mcl-chess — realm-bound service, org mcl-chess                   │
   │  Game aggregate · clock PM (one evoq_process_manager/game)        │
   │  terminal policies · evoq_event_handler policies                  │
   │  CMD play_games · PRJ project_games · QRY query_games             │
   │  chess rules: Rust NIF over cozy-chess (stateless)                │
   └──────────────────────────────────────────────────────────────────┘
   ▲ mesh_watch the facts (game_initiated, move_played, …) ▲
```

**Each game is one `Game` aggregate — the service hosts many games at once.**
One game, one aggregate, one authoritative state machine *for that game*;
the service is **multi-tenant**: any number of concurrent games, each an
independent aggregate, each with its own `evoq_process_manager` clock
instance and deadlines, isolated by the aggregate and instance supervision
trees (a poisoned game fails its aggregate or its clock instance, never
the service). The archive slice keeps the hot set bounded: ended games leave
the live read model after their retention window. Capacity is not a concern
at BEAM scale (thousands of concurrent games = thousands of lightweight
processes + timers); the v1 horizon is one service node, and scaling out to
several nodes is §10, question 7, not v1. The event store is the source of
truth; the mesh facts are the observable surface; the SQLite read models
answer queries.

## 3. Aggregate boundaries

**`Game`** — one chess game between two seats, following the house lifecycle
slices end to end (`philosophy/AGGREGATE_LIFECYCLE_SLICES.md`):

```
initiate_game (birth) → [seat claims] → start_game → [moves] → end_game → archive_game (death)
```

Keyed by `game_id`: the dossier's stream id, `game-<32 lowercase hex>`
(the `reckon` stream-id contract, minted UUIDv7 so `ORDER BY stream_id`
is birth order — minted through evoq's id seam, §7, never hand-rolled).

| Field | Source / note |
|---|---|
| `game_id` | stream id, `game-<32 hex>` minted on `initiate_game` (§7) |
| `protocol` | `<<"chess">>` (versioned on the wire, see §6) |
| `time_control` | `{initial_ms, increment_ms}`, validated caps at the boundary (both positive; `initial_ms` in a sane range — §10) |
| `seats` | two slots, **by color**: `white` and `black`, each a 64-hex `node_id` or empty. **Not pinned to role**: the initiator is not automatically white, the challenger is not automatically black |
| `position` | FEN after the last played move (start position until then) |
| `to_move` | `w` / `b` |
| `ply` | move counter |
| `clocks` | remaining time per seat, derived from the time control and the `at_ms` of `move_played` events (§5 clock model) |
| `status` | **an `evoq_bit_flags` integer**, flags in `game_status.hrl` (§3.1) |
| `outcome` | when ended: `winner` / `draw` / `forfeit` / `abandoned`, plus `winner_node_id` and `reason` |

### 3.1 Status: `game_status.hrl`, evoq_bit_flags integers

The house rule: **status is a bit-flag integer** (`evoq_bit_flags`, powers of
2), never a string and never a bare atom; the label is computed in the
projection, never client-side (`philosophy/STATUS_LABELS_IN_PROJECTIONS.md`):

```erlang
-define(GAME_NONE,      0).   %% 2#00000000
-define(GAME_INITIATED, 1).   %% birth slice: aggregate exists
-define(GAME_OPEN,      2).   %% accepting seat claims
-define(GAME_STARTED,   4).   %% playing; a clock is running
-define(GAME_ENDED,     8).   %% terminal; outcome recorded
-define(GAME_ARCHIVED, 16).   %% death slice
-define(GAME_STATUS_FLAG_MAP, #{
    0  => <<"none">>,      1  => <<"initiated">>, 2  => <<"open">>,
    4  => <<"started">>,   8  => <<"ended">>,      16 => <<"archived">>}).
```

Handlers and policies check with `evoq_bit_flags:has/2`, `has_not/2`,
`has_all/2`; projections transition with `set/2`/`unset/2` and store both
`status` and `status_label` (`evoq_bit_flags:to_string/2` with the map above).
The full API this division may use — `set/2`, `unset/2`, `set_all/2`,
`unset_all/2`, `has/2`, `has_not/2`, `has_all/2`, `has_any/2`, `to_list/2`,
`to_string/2,3`, `decompose/1`, `highest/2`, `lowest/2` — is
`evoq_bit_flags.erl` in the evoq library.

**Which bits to set and unset is business logic, and it is written down here,
event by event.** Each event sets the flag of the slice it enters and clears
the flag of the slice it leaves, so the mask is the aggregate's current
position plus `INITIATED`, never a history:

| Event | unset | set | status after | label after |
|---|---|---|---|---|
| `game_initiated_v1` | — | `INITIATED`, `OPEN` | 3 | `initiated, open` |
| `seat_claimed_v1` | — | — | 3 | `initiated, open` |
| `game_started_v1` | `OPEN` | `STARTED` | 5 | `initiated, started` |
| `move_played_v1` | — | — | 5 | `initiated, started` |
| `clock_flagged_v1` | — | — | 5 | `initiated, started` |
| `game_ended_v1` | `STARTED` | `ENDED` | 9 | `initiated, ended` |
| `game_archived_v1` | `ENDED` | `ARCHIVED` | 17 | `initiated, archived` |

`INITIATED` is never cleared: it is the "this dossier exists" flag every
slice guard checks, and the archived aggregate keeps it. A projection that
transitions performs the unset before the set in the same write (`unset_all`
then `set_all` for multi-flag rows), never one without the other.

### 3.2 Invariants (enforced in `maybe_*` handlers, never left to callers)

- **Refusals split by evidentiary value, deliberately.** A refusal that
  says "this caller was in the game and tried something the rules forbid"
  is evidence and is recorded: an illegal or out-of-turn move by a seat
  holder, or a move after `GAME_ENDED`, becomes a `move_refused_v1` event
  and a mesh fact, so a future reputation division (its own bounded
  context, not this one) can read attempted foul play from the transcript
  alone. A refusal that says only "this caller never had standing" —
  unknown caller, malformed payload, already-archived aggregate — is
  answered `{error, Reason}` on the wire and records nothing: it has no
  reputational meaning and a stranger must not be able to grow a game's
  stream. Seat claims are the one bounded exception: a claim on a taken
  or full seat is recorded (`seat_refused_v1`) because claims are how
  matchmaking observes demand and the count is naturally bounded by
  claimants, not by move spam. The refused events a seat holder can
  produce are still bounded: the clock ends the game, and the plan caps
  recorded refusals per player per game (§10). mpong's "a refusal is a
  fact on the mesh, not a silence" survives in the evidence-carrying half.
- Only the seat holder whose turn it is may move; a move from anyone else,
  or out of turn, is refused with a `move_refused_v1` fact per the rule
  above.
- **Attribution is by the wire, never the payload.** The caller of
  `submit_move` is the node_id macula verified on the call — the same
  mechanism `mcl-rag` uses for its operators and `mcl-mpong` uses for seats.
  A payload that claims a different player is refused without looking at it.
- A seat claim is for a *color*; first claim wins that color, the third
  claimer is refused (`seat_refused_v1`, reason `game_full` or
  `seat_taken`). Pre-assigned seats (the matchmaker path) make claims for
  those colors refuse with `seat_taken`.
- One winner at most; after `game_ended_v1` every command except
  `archive_game_v1` is refused with `game_ended`. After `game_archived_v1`
  everything is refused — the aggregate is dead.
- `game_started_v1` requires both seats filled; `game_ended_v1` requires
  `GAME_STARTED`; `game_archived_v1` requires `GAME_ENDED` (or a
  pre-start `withdraw`, see §4). The slices are a strict order.

### 3.3 Determinism (DDD.md's rule, applied)

Every piece of game state — position, ply, clocks, status — is derivable by
replaying events. The clock process manager (§5) reads events, never read
models. `at_ms` on events is the *service's* clock (not the sender's
`sent_at`, which is informational), so clock arithmetic replays identically.
The one thing replay cannot reproduce is a wall-clock *timer firing*; the
timer is a trigger for the `flag_clock_v1` command, and the command's event
is the durable fact.

## 4. Domain event list

All past-tense business verbs, versioned `_v1`, emitted to the event store
and (each) to the mesh per §6. Node ids are lowercase hex; flags are 1/0.

| Slice | Event | Carries |
|---|---|---|
| birth | `game_initiated_v1` | **the full initial state**: `game_id`, `protocol`, `time_control`, `seats` (`w`/`b`, empty or pre-assigned), `position` (start FEN), `to_move`, `ply` (0), `clocks` (initial per seat), `status`, `initiator_node_id`, `at_ms` |
| seats | `seat_claimed_v1` | `game_id`, `player_node_id`, `color` (`w`/`b`), the full `seats` map after the claim, `status`, `at_ms` |
| seats | `seat_refused_v1` | `game_id`, `player_node_id`, `color`, `reason`, `seats` (unchanged), `status`, `at_ms` |
| start | `game_started_v1` | `game_id`, `white_node_id`, `black_node_id`, `position`, `to_move`, `ply`, `clocks` (initial both), `status`, `at_ms` |
| play | `move_played_v1` | `game_id`, `player_node_id`, `move` (UCI), `ply`, `fen_after`, `position_hash`, `clocks` after the move, `to_move`, `status`, `at_ms` |
| play | `move_refused_v1` | `game_id`, `player_node_id`, `move` (UCI), `reason`, `ply`, `fen_after` (unchanged), `clocks`, `status`, `at_ms` |
| play | `clock_flagged_v1` | `game_id`, `player_node_id`, `clocks`, `status`, `at_ms` |
| end | `game_ended_v1` | `game_id`, `outcome`, `winner_node_id` (when winner), `reason`, `fen_after` (final), `ply`, `clocks`, `status`, `at_ms` |
| death | `game_archived_v1` | `game_id`, `reason` (`retention` / `withdrawn`), `status`, `at_ms` |

Every event is the aggregate state it produced, not a bare field:
`Event Payload = subset(Aggregate State) + new data from the Command`
(`philosophy/DDD.md`). A projection, a policy, or a replay never needs a
second stream or a read model to interpret one event. The initiation event
especially carries the whole partially-filled state, so a subscriber that
joins on `game_initiated_v1` alone can render the game (empty seats and
all) with no follow-up query.

`position_hash` is the Zobrist hash of `fen_after`, computed by the rules
NIF — the aggregate keeps the hash history so threefold repetition is a
cheap, mechanical check when draw claims land (v2; see §10).

**Outcome vocabulary** (closed set): `winner` (reason `checkmate`), `draw`
(reason `stalemate` / `insufficient_material`), `forfeit` (reason
`clock_flag` / `resignation`), `abandoned` (reason `withdrawn` — opener
withdraws a *started* game). A withdraw *before* start is not an end: it is
`game_archived_v1` with reason `withdrawn` (the game never existed as play).

## 5. Desk inventory

Names follow `skills/NAMING_CONVENTIONS.md` exactly. Umbrella apps:
`apps/play_games` (CMD), `apps/project_games` (PRJ), `apps/query_games`
(QRY), plus `apps/mcl_chess` (boot, store, supervision, `/health`,
capability advertisement — the scaffold's `store=1` shape, with
mcl-bookclub's four-app split as the working example). One `mcl_chess_facts`
module in the CMD app owns every topic and translation; only the emitters
may name the mesh SDK (mcl-bookclub's division-boundary rule).

### CMD `play_games` — desks (one directory per desk)

| Slice | Desk | Command | Handler | Responder | Emitter (mesh) | Events |
|---|---|---|---|---|---|---|
| birth | `initiate_game/` | `initiate_game_v1` | `maybe_initiate_game` | `initiate_game_responder_v1` | `emit_game_initiated_v1_to_mesh` | `game_initiated_v1` |
| seats | `claim_seat/` | `claim_seat_v1` | `maybe_claim_seat` | `claim_seat_responder_v1` | `emit_seat_claimed_v1_to_mesh`, `emit_seat_refused_v1_to_mesh` | `seat_claimed_v1`, `seat_refused_v1` |
| start | `start_game/` | `start_game_v1` | `maybe_start_game` | — (internal: dispatched by the seats-full policy) | `emit_game_started_v1_to_mesh` | `game_started_v1` |
| play | `submit_move/` | `submit_move_v1` | `maybe_submit_move` | `submit_move_responder_v1` | `emit_move_played_v1_to_mesh`, `emit_move_refused_v1_to_mesh` | `move_played_v1`, `move_refused_v1` |
| play | `resign_game/` | `resign_game_v1` | `maybe_resign_game` | `resign_game_responder_v1` | (shared `emit_game_ended_v1_to_mesh`, in `end_game/`) | `game_ended_v1` |
| play | `flag_clock/` | `flag_clock_v1` | `maybe_flag_clock` | — (internal: dispatched by the clock instance) | `emit_clock_flagged_v1_to_mesh` | `clock_flagged_v1` |
| end | `end_game/` | `end_game_v1` | `maybe_end_game` | — (internal: dispatched by policies) | `emit_game_ended_v1_to_mesh` | `game_ended_v1` |
| death | `withdraw_game/` | `withdraw_game_v1` | `maybe_withdraw_game` | `withdraw_game_responder_v1` | `emit_game_archived_v1_to_mesh` | `game_archived_v1` (pre-start only) |
| death | `archive_game/` | `archive_game_v1` | `maybe_archive_game` | — (internal: dispatched by the retention policy) | `emit_game_archived_v1_to_mesh` | `game_archived_v1` |

Each desk also carries its `emit_{event}_to_pg` (internal pub/sub) and
`{command}_api`/`{command}_desk_sup` per the convention. The `withdraw_game`
and `archive_game` desks produce the same event module; one emitter serves
both (the event type is the subscription key, not the desk).

### Policies (event store → own aggregate)

Each is an `evoq_event_handler` child of the CMD app's supervisor, with
`replay_policy() -> skip` (replay must not re-dispatch), exactly the shape
`mcl-bookclub`'s `on_member_registered_v1_maybe_plan_party` ships.

- `on_seat_claimed_v1_maybe_start_game` — both seats filled ⇒ dispatch
  `start_game_v1`; the game starts itself, no extra round trip.
- `on_move_played_v1_maybe_end_game` — after every move, ask the rules NIF
  for terminal status (checkmate / stalemate / insufficient material) and
  dispatch `end_game_v1` when it is terminal.
- `on_clock_flagged_v1_maybe_end_game` — a flagged clock is a forfeit;
  dispatch `end_game_v1`.
- `on_game_ended_v1_maybe_archive_game` — the death slice after the
  retention window (§10). This one needs a deadline of its own: it rides
  the same evoq `handle_info/2` gap as the clock (one node-wide retention
  ticker is the fallback), and its replay rebuilds pending archives from
  the `game_ended_v1` `at_ms` rather than re-archiving blindly.
- (v2) `on_move_played_v1_maybe_flag_repetition` — threefold repetition.

### The clock: one `evoq_process_manager` instance per game

There is **no `evoq_policy` behaviour** in evoq (1.26.1, the current
release). What the house calls a policy — `on_{event}_maybe_{command}` —
is an `evoq_event_handler`: it subscribes by event type, dispatches a
command, and declares `replay_policy() -> skip` because replay must not
re-dispatch. What this division needs for the clock — one stateful
processor **per game** — is `evoq_process_manager`: `correlate/2` routes
each event to the instance named by `game_id`, `handle/3` returns
commands, `apply/2` folds state, and on replay the instance is rebuilt
while the commands `handle/3` returns are **not dispatched** (the SDK's
own guarantee, `guides/process_managers.md`). One instance per game is
the design; nothing gets broadcast to the other games' instances.

The gap: `evoq_process_manager` (1.26.1) gives an instance no way to
receive a message it sent itself — its `handle_info/2` ignores unknown
messages and the idle timer only logs. A clock is exactly a message at a
deadline, so the plan records this as an **evoq dependency, not a
workaround**: extend `evoq_process_manager` with an optional
`handle_info/2` (and optionally `on_timeout/1`), the same shape
`evoq_event_handler` already has. One additive extension, no new
behaviour needed; if the org prefers the name, an `evoq_policy` behaviour
can be a thin alias over the same instance runtime. Until the extension
ships, the fallback is one node-wide clock `evoq_event_handler` holding a
`#{game_id => deadline}` map with `handle_info/2` (no per-game isolation;
the design keeps this possible by keeping clock state per key).

The clock PM, once the extension lands, is one instance per started
game, reading events only. **A timed game is start/stop clocks, not one
countdown:**

- `game_started_v1` ⇒ **white's clock starts** (deadline scheduled for
  white's remaining time; the instance holds it).
- `move_played_v1` ⇒ **the mover's clock stops**, the increment is applied
  to the mover, **the opponent's clock starts** (deadline scheduled for
  the opponent's remaining time, recomputed from events:
  `initial_ms + increment_ms × moves − elapsed`, the sum taken over that
  player's own completed moves).
- `resign_game_v1`/`end_game_v1`/`game_ended_v1` ⇒ **both clocks stop**,
  the deadline is dropped, and the instance stops with
  `correlate/2 -> {stop, game_id}`.
- Deadline fires (`handle_info`) ⇒ dispatch `flag_clock_v1`; the flagged
  player's move never happened, so their clock was already stopped — the
  flag is a fact, not a move.
- Replay rebuilds the deadline from the events' `at_ms`; a deadline that
  already passed on replay dispatches its `flag_clock_v1` once, and the
  instance's `apply/2` state makes the second pass a no-op.

Timers are recomputed on every transition; the PM holds no read model.

### PRJ `project_games`

One desk per event, per convention (`game_initiated/`, `move_played/`, …),
each `on_{event}_to_sqlite_games` projection updating the read model: the
current board, move list (UCI), clock state, `status` **and** `status_label`
(computed with `evoq_bit_flags:to_string/2` at projection time — never
client-side, per `STATUS_LABELS_IN_PROJECTIONS.md`). The read model is what
`query_games` serves and what a future board viewer rebuilds a game from.
The projections are `evoq_event_handler` modules writing through one
`game_read_model_store` (mcl-bookclub's real pattern; the workspace has no
deployed `evoq_projection` yet — the corpus documents the gotcha), and
each writes the transitions of §3.1 rather than a status literal.

### QRY `query_games`

`get_game_by_id`, `get_games_by_status` (open games — observability, not
matchmaking, see §1), `get_games_page`, `get_games_by_player`, each with its
`_api` and mesh-facing procedure per §6.

## 6. The mesh contract

**Facts** — topics mirror `mcl-mpong` exactly: org `mcl-chess`, app `chess`,
domain `game`, for example `io.macula/mcl-chess/chess/game/move_played_v1`.
`game_id` is in the payload, never in a topic. Values are binaries, integers,
lists and maps; flags are 1/0; node ids are lowercase hex. A
`mcl_chess_facts_tests.erl` pins every topic and every key (mpong's
`mcl_mpong_facts_tests.erl` pattern); a breaking change gets a new `_vN`.

**Procedures** — each capability is declared with a bare `name` and a
`version` (`#{name => <<"submit_move">>, version => 1, handler => ...}`),
exactly as `mcl-echo` and `mcl-rag` declare theirs; `mcl_om` registers it
on the wire as `Org/Name`, so callers dial `mcl-chess/submit_move`. There is
**no `_v1` in the wire name**: version is a capability field, and the
`_v1` in this plan is the command/event module suffix, not part of the
address. (The corpus's underscored `{service}.{verb}` form
(`NAMING_CONVENTIONS.md`) is not what `mcl_om` deploys today — see §10.)
Each procedure requires a D25 provider grant from the realm before it is
reachable — `/health` names the missing grants, reported by mcl-om itself,
same as mcl-rag. The internal slices (`start_game`, `flag_clock`,
`end_game`, `archive_game`) are *not* served on the mesh — they are
dispatched by policies and the process manager, and observable through
their facts.

| Procedure | Caller must be | Returns |
|---|---|---|
| `initiate_game` | anyone the station admits | the born game state (id, time control, empty seats) or refusal |
| `claim_seat` | the claiming node (verified on the wire) | `{ok, color}` or refusal |
| `submit_move` | the seat holder to move | `{ok, fen_after}` or refusal |
| `resign_game` | a seat holder | `{ok, outcome}` |
| `withdraw_game` | the initiator (pre-start only) | `{ok, archived}` |
| `get_game_by_id` | anyone | game state + move list |
| `get_games_by_status` | anyone | matching game ids |
| `get_games_page` | anyone | paged games |

Every responder returns the post-event aggregate state it just computed
(`evoq_command_router:dispatch_with_state/2`), so the caller needs no
follow-up query — session-level consistency, `SESSION_LEVEL_CONSISTENCY.md`.

Refusals on the wire carry `{error, Reason}`. Only the evidence-carrying
refusals (a seat holder's foul attempt) also reach the mesh as a
`*_refused_v1` fact; boundary refusals are feedback and nothing more (§3.2).

## 7. Desk dependencies

- **Start from the scaffold, not a hand-rolled tree.** `rebar3 new
  mcl_service repo=mcl-chess name=mcl_chess store=1` (mcl-om's
  `priv/templates/mcl_service.template`) generates the release, Containerfile,
  CI, compose, health wiring, the store boot (`mcl_chess_app` opens it before
  `mcl_om:boot/1` from `mcl_chess_service:event_store/0`) and the `evoq`
  sys.config block without which the node crash-loops. **`mcl-bookclub` is
  the event-sourced template to copy** (CMD/PRJ/QRY split, `reckon_db ~> 5.4`,
  `evoq ~> 1.26`, `reckon_evoq ~> 2.7`, `esqlite ~> 0.9`, the store's data
  volume and `MCL_DATA_DIR`); mcl-echo/mcl-rag are the mcl-om contract, not
  the persistence shape.
- **evoq is the only application surface.** The domain code uses evoq
  behaviours — `evoq_command`, `evoq_event`, `evoq_aggregate` (+ `game_state`
  module), `evoq_event_handler` (policies, emitters, projections),
  `evoq_process_manager` (the clock, §5), `evoq_router`/`evoq_command_router`,
  `evoq_bit_flags`. **The adapter is named in `config/sys.config.src` only**
  (`event_store_adapter` / `subscription_adapter` / `snapshot_store_adapter`
  = `reckon_evoq_adapter`); no desk, aggregate, policy, projection or emitter
  calls `reckon_evoq_adapter`, `reckon_gater` or `reckon_db` directly. This
  is the rule the previous draft's `reckon_evoq_adapter:subscribe/5` broke.
- **Three evoq gaps this division depends on** (recorded, not worked around):
  1. **Optional `handle_info/2` on `evoq_process_manager`** — a PM instance
     cannot receive a message today, so a per-game clock deadline has no
     home. One additive callback on the existing instance runtime (§5).
  2. **Aggregate-id minting** — `reckon_gater_stream_id` is off-limits under
     the rule above, and evoq has no minting API. The clean seam is an
     optional `new_stream_id/1` on `evoq_adapter` (reckon_evoq delegates to
     reckon_gater), exposed as an evoq call; until then `game_id` minting is
     the one place this plan names a non-evoq helper, and it should be the
     last.
  3. **Store bootstrap stays under evoq.** The canonical `store=1` scaffold
     opens the store by calling `reckon_db_sup:start_store/1` and
     `#store_config{}` from `<name>_app` before starting
     `evoq_store_subscription`. That is the one spot where the scaffold
     itself bends the evoq-only rule. Either declare boot wiring the
     sanctioned exception, or add an evoq store facade
     (`evoq_store:open/1` taking the service's `event_store()` map) so the
     app touches evoq and nothing below it. This plan adopts the scaffold
     as-is and records the debt.
- **`mcl_om` / `mcl_om_capabilities`** — mesh connection, org-qualified
  procedure advertisement, the capability assertion pattern copied from
  `mcl-echo` (crash at boot on org/realm drift, loud not silent). mcl_om ≥ 0.35
  opens no store of its own.
- **`mcl-testkit`** — the in-memory mesh harness for the live two-process
  facts tests; the facts-contract tests themselves are pure module tests and
  the aggregate tests use a local test store (mcl-bookclub's pattern).
- **The chess rules NIF** — `native/mcl_chess_rules/`, the one new native
  piece. Details and the licensing decision are recorded in §8.
- **Container/deploy** — the plain image pair, not the rocksdb pair. The
  scaffold's Containerfile is two-stage on the digest-pinned
  `macula-ci-otp` builder and `macula-pq-runtime` runtime (the same pair
  mcl-mpong and the scaffold use). **Correcting the earlier draft:** the
  `*-rocksdb` variants are not "mcl-rag only" — barrel/`barrel_docdb` is
  used by mcl-git, mcl-graph, mcl-mail, mcl-search, mcl-stations, mcl-tube,
  mcl-embedder and mcl-nvidia-pair too — but chess needs neither: the read
  model is SQLite (`esqlite`), and mcl_om since 0.27 carries no `barrel_docdb`.
  The NIF builds in the ordinary builder stage through
  `{pre_hooks, [{compile, "bash scripts/build-nif.sh"}]}` (mcl-embed's
  pattern) — **no extra Rust toolchain stage, and no `x86-64-v3` flag was
  found in any sibling or fleet image**; if the fleet really sets one it
  needs a citation here. The store adds the scaffold's `/data` volume
  (`MCL_DATA_DIR`, `/bulk0/mcl-chess` on a fleet node, never the container's
  root filesystem); `deploy/docker-compose.yml` carries host networking
  (the IPv6 reason mpong documents), and `scripts/check.sh`/`scripts/health.sh`
  come from the scaffold.
- **Fleet definition** — lives in `macula-io/macula-fleet` (the mpong
  pattern: `edge/<box>/mcl-chess-config.env`, `reconcile.manifest` entry,
  digest pin); the service's CI calls `attest-image.yml` from
  `macula-ci-images` so the fleet reconciler's signature/SBOM/provenance
  checks pass. `macula-fleet-images` is for third-party images only —
  nothing mcl-chess needs in v1.
- **Realm admission** (operator step, not code): org `mcl-chess` in the
  `io.macula` realm, D25 grants for the procedures above — the path
  `mcl-echo`/`mcl-rag` already took.

## 8. Decisions recorded (so they are not re-litigated)

1. **Event-sourced, unlike mcl-mpong.** mpong's "no event store" is a
   scoped, documented waiver for a throwaway demo; chess is adversarial and
   needs replay, dispute and audit. House rule applies here in full.
2. **One authoritative referee.** No dual-host pairing like mpong's; the
   pairing tolerance was mpong's mesh-measurement point, not a game-design
   point. One service, one truth.
3. **UCI on the wire.** Unambiguous, trivially validatable; SAN is later
   rendering sugar (v2, could be a NIF helper for board viewers).
4. **Referee only — no engine, no search.** Agents bring their own thinking
   (LLM or local engine). The service validates, clocks, sequences, records.
5. **Consent by seat claim; seats are by color, not role.** Agents do not
   ring each other for a game against `mcl-chess`; the harness calling
   `claim_seat_v1` (or being pre-assigned by a future matchmaker) is the
   consent. The initiator is not pinned to white and the challenger is not
   pinned to black. The ring stays for agent-to-agent (kernel-less) play per
   `PLAN_GAME_SESSIONS.md`.
6. **Matchmaking is out of scope.** This division is pure gameplay; pairing
   is a separate future division that drives `initiate_game` with
   pre-assigned seats.
7. **Chess rules via Rust NIF over `cozy-chess` (MIT).** BEAM-side options
   were examined and rejected: `echecs` (Hex) is capable but GPL-3.0;
   `chess` (Hex) is MIT but trivial and stale; `shakmaty` is excellent but
   GPL-3.0. The org ships Apache-2.0 and is license-disciplined (mcl-rag
   vendors libgit2 specifically for its linking exception). `cozy-chess` is
   MIT, perft-verified, has legal-only move generation, `Board::is_legal`,
   and incremental Zobrist hashing (needed for repetition checks).
8. **The NIF follows the mcl-embed pattern, not rebar3_cargo:**
   `native/mcl_chess_rules/` crate (rustler 0.34, cdylib, Apache-2.0), `.so`
   built by `scripts/build-nif.sh` via
   `{pre_hooks, [{compile, "bash scripts/build-nif.sh"}]}`, exactly as
   mcl-embed's rebar.config documents. Stateless API, microsecond-scale
   calls — NIF-appropriate, no dirty schedulers:

   ```
   validate_move(Fen, Uci)            -> ok | {error, Reason}
   apply_move(Fen, Uci)               -> {ok, Fen', ZobristHash} | {error, Reason}
   status(Fen, HalfmoveClock)         -> active | checkmate | stalemate | insufficient_material
   ```

   State stays in the BEAM aggregate (FEN + hash history in events); the
   NIF is a pure function of state — the event-sourced determinism in §3
   survives intact. One gotcha carried over: cozy-chess's Chess960
   king-captures-rook castling notation must be normalized to UCI
   (`e1g1`/`e1h1`) in the glue. (The earlier draft's `x86-64-v3` build
   flag is removed: it appears nowhere in the sibling services or the
   fleet images; if the fleet sets one, cite it here.)
9. **Lifecycle slices and status flags are house rules, applied in full:**
   birth = `initiate_game`, death = `archive_game`, the chain
   `initiate → start → end → archive` (§3), and every status an
   `evoq_bit_flags` integer with its label computed only in projections
   (§3.1). Which bit each event sets and unsets is written out per event
   in §3.1 — transitions are business logic, not an inference.
10. **The event store is `reckon_db` (Khepri/Ra + Rust NIF accelerators),
    reached through evoq and its configured adapter, not barrel.**
    Correcting the earlier draft: barrel is *not* mcl-rag-only — eight
    other services link it for read models — but it appears in no design
    decision here; chess's read model is SQLite (`esqlite`). Consequence
    for deployment: the plain `macula-ci-otp`/`macula-pq-runtime` image
    pair, not the `*-rocksdb` variants (§7).
11. **evoq is the only application surface, and the adapter is config,
    not code.** Desks, aggregates, policies, projections, emitters and
    process managers use evoq behaviours and the evoq router; the
    `reckon_evoq_adapter` is named in `config/sys.config.src` only, and
    nothing in the domain calls `reckon_gater` or `reckon_db`. Two evoq
    extensions are therefore dependencies of this division (§7): optional
    `handle_info/2` on `evoq_process_manager`, and an id-minting call
    (`evoq_adapter:new_stream_id/1`) so `game_id` is contract-valid
    without reaching for `reckon_gater_stream_id`.
12. **Refusals are evidence, two classes.** A seated player's forbidden
    attempt is recorded and published (reputation is a future consumer of
    those facts); a caller without standing is answered `{error, Reason}`
    and records nothing. `move_refused_v1` and `seat_refused_v1` are the
    recorded half; the cap on recorded refusals per player per game is an
    open question (§10).
13. **Pause/resume is not v1.** A unilateral pause is an exploit (stop
    your own clock); a mutual pause needs a consent exchange and its own
    lifecycle slice, clock semantics and dispute path — a later division
    or a v2, not this plan's v1 (§11).

## 9. Work packages

Each opens with its own end-goal line and is checkpointed with the operator
before starting (ALC rule). Sizes are honest guesses.

### WP0. The evoq surface this division needs (evoq repo, ~2 days)

End goal: mcl-chess can be written with evoq only. Three additive changes,
each with its own tests and release: optional `handle_info/2` on
`evoq_process_manager` (a PM instance can receive the message it sent
itself — the clock deadline), an id-minting seam
(`evoq_adapter:new_stream_id/1`, exposed to applications by evoq;
`reckon_evoq_adapter` delegates to `reckon_gater`), and (if the org wants
the rule literal) an `evoq_store:open/1` facade so the app's store boot
stops calling `reckon_db_sup`. If WP0 is deferred, WP6 falls back to one
node-wide clock `evoq_event_handler` and `game_id` is minted with the
current helper — recorded as debt, not silently.

### WP1. C4 model (1 day)

End goal: the architecture exists on paper before the code does, in the
mcl-fovea shape — `architecture/README.md` with the four levels (system
context, containers, components, code) and `architecture/c4_diagrams.py`
generating the SVGs into `assets/`, each rendered and *looked at* (fovea's
own gate line). Level 1: the agents, mcl-chess, the mesh (station, DHT,
realm), macula-mcp, a future matchmaker (dashed, out of scope).

### WP2. Walking skeleton — initiate and archive, deployed (2 days)

End goal: **birth and death walk end to end, on the fleet.** The skeleton
is `initiate_game` → (pre-start) `withdraw_game` → `archive_game`, through
all three departments and into production, per `WALKING_SKELETON.md`:
the scaffold with `store=1` (§7), `game_aggregate`, `game_state`,
`game_status.hrl`, the `initiate_game` and `withdraw_game`/`archive_game`
desks with responders and mesh emitters, the PRJ projections for both
events, the QRY `get_game_by_id` desk, facts `game_initiated_v1` and
`game_archived_v1` on the mesh, `/health` green, the org's D25 grants in
place. Two-process test over the real fleet: initiate, withdraw,
`game_archived_v1`. No seats, no clock, no rules yet — that is the point.

### WP3. Seats and start (1–2 days)

`claim_seat` desk (`seat_claimed_v1`, `seat_refused_v1`), the
`on_seat_claimed_maybe_start_game` policy, `start_game`: both seats
filled (initiator not pinned to white), third claimer refused, and a
started game whose `game_started_v1` carries the full state.

### WP4. The chess rules NIF (2 days)

The `native/mcl_chess_rules/` crate: `validate_move`/`apply_move`/`status`
per §8, UCI castling normalization, perft cross-checks against published
values in the crate's own test suite, plus BEAM-side tests for the glue
module. This is the correctness heart of the referee; budget it like one.

### WP5. Moves, resignations, ends (1–2 days)

`submit_move`/`resign_game` desks: legal move accepted (`move_played_v1`
with the full post-move state), a seat holder's illegal / out-of-turn move
recorded (`move_refused_v1`, the evidence class), terminal on
checkmate/stalemate/insufficient material via the
`on_move_played_v1_maybe_end_game` policy.

### WP6. The clock, start/stop (1–2 days, after WP0)

The per-game clock instance per §5 with the explicit start/stop
transitions, `flag_clock_v1` → `clock_flagged_v1` →
`on_clock_flagged_v1_maybe_end_game`, then the retention
`on_game_ended_v1_maybe_archive_game`. A short time control in the test
suite makes flag-fall deterministic.

### WP7. Contract pinning and the live game (1–2 days)

`mcl_chess_facts_tests.erl` pins every topic and key; then the live check
over the real fleet: two macula-mcp agent processes (mcl-testkit for the
mesh half, the scripts/ style of the macula-mcp checks for the agent
half) discover `mcl-chess`, claim seats, and play a short real game
through it to an attested `game_ended_v1` — the end-to-end loop
`PLAN_GAME_SESSIONS.md` set out to prove.

### WP8. Fleet admission (operator + 1 day)

The macula-fleet definition (edge config env, `reconcile.manifest`, digest
pin) with the attestation workflow wired in, D25 grants for every
`mcl-chess/*` procedure in `io.macula`, and the rollout. (The deploy
itself already walked in WP2; this WP is admission and placement.)

## 10. Open questions (settle at the Design Gate or before the relevant WP)

1. **Wire procedure naming** — the earlier draft had this backwards.
   `mcl_om` registers every capability as `Org/Name` and carries the
   version in the capability map (`version => 1`); mcl-echo's `echo` and
   mcl-rag's seventeen follow that, and `rag.query_shard_v1` is a
   library-served special, not the house style. §6 now assumes
   `mcl-chess/submit_move` (no `_v1` in the name). The corpus's
   `{service}.{verb}`/underscore form is not deployable through mcl_om
   today. Confirm at the gate, because wire names are forever.
2. **Time-control caps** — what sane range of `initial_ms`/`increment_ms`
   does the boundary accept (blitz to correspondence)? Chess correspondence
   (days per move) would push agents onto the harness-scheduler pattern
   instead of a blocking wait; the service is agnostic — confirm caps only.
3. **Retention window** — how long a game sits `ended` before the
   `on_game_ended_v1_maybe_archive_game` policy archives it. Default
   proposal: 24 h (v1 may archive immediately for simplicity; the policy is
   the same shape either way).
4. **Draw claims (v2)** — threefold/50-move claims, and draw by agreement,
   deferred. The hash history is already in the events so v2 is additive.
5. **Abandonment** — if a player's node vanishes mid-game (no resignation,
   clock not yet flagged), the game sits `started` until the clock runs out.
   Leaning: the clock decides, nothing else needed; confirm.
6. **Ports and health** — per-service port/`health.sh` details copied from
   siblings; nothing design-shaped, just pick at deploy time.
7. **Scaling out** — v1 is one service node hosting many concurrent games.
   Several nodes would mean several node identities under one org (each
   provider grant is per-node); whether games are pinned to a node by
   advertisement, or a caller dials whatever node serves `mcl-chess/*`
   and games stick to the node that initiated them, is a later design, not
   v1. Recorded so the aggregate design keeps per-game independence (§2),
   which is the property that makes it possible.
8. **Recorded-refusal cap** — what bounds a seat holder's `move_refused_v1`
   stream (per game, per minute, or a total after which refusals are still
   answered but no longer recorded)? The clock bounds the game, not the
   spam. Proposal: record the first N per player per game, then answer
   `{error, Reason}` without an event; N at the gate.
9. **WP0 sign-off** — the clock design assumes evoq gains optional
   `handle_info/2` on `evoq_process_manager` and an id-minting seam. If
   evoq's owner defers either, the fallbacks in §7/WP6 apply and this plan
   carries the debt explicitly rather than reaching for `reckon_gater`.

## 11. Non-goals

- **Matchmaking.** Offers, invitations, pairing, Elo — a separate division
  (and the macula-mcp directory's `offers` is its own WP there). See §1.
- **An engine, a search, a bot.** The service neither plays nor thinks.
  A bot-vs-bot demo (mpong style) can come later; it is a *caller*, not a
  feature of this service.
- **Pause/resume.** Unilateral pause stops your own clock (an exploit);
  mutual pause needs a consent exchange, a lifecycle slice and clock
  semantics of its own. A later division or v2, not v1. (Asked and
  decided, 2026-10-02.)
- **A reputation division.** Reading `move_refused_v1` / `seat_refused_v1`
  facts and judging players is its own bounded context; this service only
  makes the evidence observable.
- **SAN output, board rendering, match series, tournaments, Chess960.**
  cozy-chess supports 960, but v1 is standard chess; matches/tournaments are
  orchestration over many games, a later division.
- **Payload encryption.** Facts are readable by anyone who learns the
  topics, same standing caveat as rooms and mpong.
- **Agent wake-ups.** The service never pokes an agent; an agent that stops
  moving forfeits on the clock. Presence, rings, and harness schedulers stay
  macula-mcp's domain.

---

## The Design Gate

Per the ALC, this document *is* the planning artifact: the gate is a commit
(and the operator's review of §10's questions), not a ceremony. Nothing in
`apps/` gets written until the gate passes; WP0 and WP1 open after it.
