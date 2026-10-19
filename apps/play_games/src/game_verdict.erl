%% @doc The referee's verdict on a position: is the game over, and how.
%%
%% Two callers ask the same question of the same rules engine and must not
%% answer it two ways: the end policy, which asks after a move (one event is
%% enough to decide, because the move event carries the position, the referee's
%% halfmove count and the repetition count), and the flag desk, which asks before
%% it forfeits a player whose clock ran out. The flag's question matters because
%% a game can be left started by a crash between a mating move and the policy's
%% dispatch: the clock is then the only thing that ever looks at the game again,
%% and it must record checkmate rather than a forfeit (mcl-chess#2, WP6).
%%
%% The order is FIDE's, and it is the same in both places: the engine's own
%% verdict first (a move that mates also reaches the counter, and a mate on that
%% move is a win), then the fivefold count, which is not a function of one
%% position and so is not the engine's to judge (mcl-chess#4). The 50 move and
%% threefold draws are v2 claims and nothing here ends a game on them.
-module(game_verdict).

-export([after_move/1, of_state/1]).

%% The decision is what `end_game_v1' takes: the outcome, who won (`<<>>' for a
%% draw) and why, in the closed vocabulary of `game_ended_v1'.
-type decision() :: #{outcome := winner | draw,
                      winner_node_id => binary(),
                      reason := atom()}.

-type verdict() :: active | {over, decision()} | {error, invalid_fen}.

-export_type([decision/0, verdict/0]).

%% @doc The verdict on the position this move produced, from the move event
%% alone: the mover delivered whatever it is, so the mover is the winner.
-spec after_move(map()) -> verdict().
after_move(Data) ->
    judged(status(Data), maps:get(repetitions, Data),
           maps:get(player_node_id, Data)).

%% @doc The verdict on the position the game stands in, from the aggregate
%% state: the side to move is the one the verdict is about, so a mate there is
%% a win for the other seat.
-spec of_state(game_state:t()) -> verdict().
of_state(State) ->
    judged(mcl_chess_rules:status(game_state:position(State),
                                  game_state:halfmove_clock(State)),
           game_state:repetition_count(State),
           winner_of(State)).

status(Data) ->
    mcl_chess_rules:status(maps:get(fen_after, Data), maps:get(halfmove_clock, Data)).

winner_of(State) ->
    game_state:seat(State, other(game_state:colour_key(game_state:to_move(State)))).

other(white) -> black;
other(black) -> white;
other(_) -> invalid.

judged({error, invalid_fen}, _Repetitions, _Winner) ->
    {error, invalid_fen};
judged(active, Repetitions, _Winner) ->
    repeated(Repetitions);
judged(checkmate, _Repetitions, Winner) ->
    {over, #{outcome => winner, winner_node_id => Winner, reason => checkmate}};
judged(stalemate, _Repetitions, _Winner) ->
    {over, #{outcome => draw, reason => stalemate}};
judged(insufficient_material, _Repetitions, _Winner) ->
    {over, #{outcome => draw, reason => insufficient_material}};
judged(seventy_five_moves, _Repetitions, _Winner) ->
    {over, #{outcome => draw, reason => seventy_five_moves}}.

repeated(Repetitions) ->
    reached(Repetitions >= game_state:repetition_draw()).

reached(true) ->
    {over, #{outcome => draw, reason => fivefold_repetition}};
reached(false) ->
    active.
