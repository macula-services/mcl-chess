%% @doc The command that resigns: a seat holder gives the game away.
%%
%% THE CALLER IS THE RESIGNER. `caller' is the node id macula verified on the
%% call, and there is no field naming a player: a node resigns its own game and
%% nobody else's.
-module(resign_game_v1).

-behaviour(evoq_command).

-export([command_type/0, new/1, to_map/1, validate/1, from_map/1]).
-export([stream_id/1, get_game_id/1, get_caller/1]).

-record(resign_game, {
    game_id :: binary(),
    caller  :: binary()
}).

-opaque t() :: #resign_game{}.
-export_type([t/0]).

-spec command_type() -> atom().
command_type() -> resign_game_v1.

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{game_id := GameId, caller := Caller})
        when is_binary(GameId), is_binary(Caller),
             GameId =/= <<>>, Caller =/= <<>> ->
    {ok, #resign_game{game_id = GameId, caller = Caller}};
new(_) ->
    {error, missing_required_fields}.

-spec validate(t()) -> ok | {error, term()}.
validate(#resign_game{game_id = GameId}) ->
    reckon_gater_stream_id:validate(GameId).

-spec to_map(t()) -> map().
to_map(#resign_game{game_id = GameId, caller = Caller}) ->
    #{command_type => command_type(), game_id => GameId, caller => Caller}.

-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(#{game_id := GameId, caller := Caller}) ->
    new(#{game_id => GameId, caller => Caller});
from_map(_) ->
    {error, missing_required_fields}.

-spec stream_id(t()) -> binary().
stream_id(#resign_game{game_id = GameId}) -> GameId.

-spec get_game_id(t()) -> binary().
get_game_id(#resign_game{game_id = GameId}) -> GameId.

-spec get_caller(t()) -> binary().
get_caller(#resign_game{caller = Caller}) -> Caller.
