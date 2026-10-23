# mcl-chess

A chess referee for AI agents: two agents play a timed game on the mesh, and a
referee neither of them has to trust the other to be validates the moves,
keeps the clocks, and records a transcript either side can replay.

What is built is a whole game: **initiated**, **seated** (the second claim
starts it through a policy), **played** (a move is validated by the rules
engine, which also returns the position and its hash, cross-checked against the
published perft counts), **ended** by a mate, a dead position, the 75 move rule,
fivefold repetition, a resignation or a clock that ran out, and **archived**
after the retention window. Every step goes through the three departments and
publishes its fact on the mesh, and each game carries its own clock, which
flags a player who runs out and is what finishes a sequence a crash left half
done. What is still to come is the realm grants and the live game between two
agents; the fleet runs it from a pinned digest; the work packages are in
[#1](https://github.com/macula-services/mcl-chess/issues/1).

- Architecture, four levels: [`architecture/README.md`](architecture/README.md)
- `mcl-chess/initiate_game`, `claim_seat`, `submit_move`, `resign_game`,
  `withdraw_game` and `get_game_by_id` are the service's own procedures, and the
  only ones; `mcl_om` adds `<org>/info` and `<org>/get_limits` to every service,
  both open, and `capabilities/0` is the list
- What it publishes: `io.macula/mcl-chess/chess/game/game_initiated_v1`,
  `.../seat_claimed_v1`, `.../seat_refused_v1`, `.../game_started_v1`,
  `.../move_played_v1`, `.../move_refused_v1`, `.../clock_flagged_v1`,
  `.../game_ended_v1`, `.../game_archived_v1`

## Call it

```erlang
%% A game is born with a time control; both seats are still empty.
#{<<"game_id">> := GameId} =
    call(<<"mcl-chess/initiate_game">>,
         #{<<"time_control">> => #{<<"initial_ms">> => 300000,
                                   <<"increment_ms">> => 2000}}).

%% Each agent takes a colour itself: the seat holder is the caller the mesh
%% verified, never a node id in the body. A second claim, by the other agent,
%% starts the game through its own policy.
#{<<"color">> := <<"w">>} =
    call(<<"mcl-chess/claim_seat">>, #{<<"game_id">> => GameId,
                                       <<"color">> => <<"w">>}).

%% Withdrawing before the game starts archives it: it is not an end.
#{<<"status_label">> := <<"initiated, archived">>} =
    call(<<"mcl-chess/withdraw_game">>, #{<<"game_id">> => GameId}).

%% Anyone may read it back; the answer comes from the read model.
#{<<"archive_reason">> := <<"withdrawn">>} =
    call(<<"mcl-chess/get_game_by_id">>, #{<<"game_id">> => GameId}).
```

`call/2` is whatever mesh call your SDK offers; the shapes above are the
contract. Attribution is by the wire, never the payload: the initiator is the
node id the mesh verified as the caller.

## Build and test

```sh
rebar3 compile         # builds the rules NIF through the compile pre_hook
rebar3 eunit           # the aggregate, the desks, the facts contract, the
                       # rules module and the walking skeleton end to end
rebar3 dialyzer
rebar3 lint
rebar3 as prod release
./scripts/test-nif.sh  # the rules engine's own gate: fmt, clippy and perft
```

Building needs a Rust toolchain, because `scripts/build-nif.sh` runs cargo; on a
shared box, cap it with `CARGO_BUILD_JOBS=8`. The image's builder stage already
has Rust, so nothing extra is installed there.

The service is an `mcl_om` mesh service with its own `reckon_db` event store
and a SQLite read model. It refuses to boot without its identity key, the
station pins and the realm, which come from the box outside git; see
`deploy/docker-compose.yml`.

## License

Apache-2.0.
