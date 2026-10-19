%% @doc The command that ends a game: INTERNAL, never served on the wire.
%%
%% It is dispatched by a policy (`on_move_played_v1_maybe_end_game' today, the
%% clock's flag policy in WP6) or by the resign desk, so no stranger can end a
%% game they are not playing. The command carries the DECISION — outcome,
%% winner and reason — and the handler builds the event from the aggregate's own
%% state, so the position, the ply and the clocks in the record are the game's,
%% not a caller's.
-module(end_game_v1).

-behaviour(evoq_command).

-export([command_type/0, new/1, to_map/1, validate/1, from_map/1]).
-export([stream_id/1, get_game_id/1, get_outcome/1, get_winner_node_id/1,
         get_reason/1]).

-record(end_game, {
    game_id        :: binary(),
    outcome        :: winner | draw | forfeit | abandoned,
    winner_node_id :: binary(),
    reason         :: atom()
}).

-opaque t() :: #end_game{}.
-export_type([t/0]).

-spec command_type() -> atom().
command_type() -> end_game_v1.

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{game_id := GameId, outcome := Outcome} = Params)
        when is_binary(GameId), GameId =/= <<>>, is_atom(Outcome) ->
    known(Outcome, GameId, Params);
new(_) ->
    {error, missing_required_fields}.

known(winner, GameId, Params) -> command(GameId, winner, Params);
known(draw, GameId, Params) -> command(GameId, draw, Params);
known(forfeit, GameId, Params) -> command(GameId, forfeit, Params);
known(abandoned, GameId, Params) -> command(GameId, abandoned, Params);
known(_Outcome, _GameId, _Params) -> {error, invalid_outcome}.

command(GameId, Outcome, Params) ->
    {ok, #end_game{game_id = GameId,
                   outcome = Outcome,
                   winner_node_id = maps:get(winner_node_id, Params, <<>>),
                   reason = maps:get(reason, Params, none)}}.

-spec validate(t()) -> ok | {error, term()}.
validate(#end_game{game_id = GameId}) ->
    reckon_gater_stream_id:validate(GameId).

-spec to_map(t()) -> map().
to_map(#end_game{} = Cmd) ->
    #{command_type => command_type(),
      game_id => Cmd#end_game.game_id,
      outcome => Cmd#end_game.outcome,
      winner_node_id => Cmd#end_game.winner_node_id,
      reason => Cmd#end_game.reason}.

-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(#{game_id := GameId, outcome := Outcome} = Map) ->
    new(#{game_id => GameId,
          outcome => Outcome,
          winner_node_id => maps:get(winner_node_id, Map, <<>>),
          reason => maps:get(reason, Map, none)});
from_map(_) ->
    {error, missing_required_fields}.

-spec stream_id(t()) -> binary().
stream_id(#end_game{game_id = GameId}) -> GameId.

-spec get_game_id(t()) -> binary().
get_game_id(#end_game{game_id = GameId}) -> GameId.

-spec get_outcome(t()) -> atom().
get_outcome(#end_game{outcome = Outcome}) -> Outcome.

-spec get_winner_node_id(t()) -> binary().
get_winner_node_id(#end_game{winner_node_id = Winner}) -> Winner.

-spec get_reason(t()) -> atom().
get_reason(#end_game{reason = Reason}) -> Reason.
