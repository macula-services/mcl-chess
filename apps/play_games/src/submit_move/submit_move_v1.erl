%% @doc The command that plays a move: the caller moves the seat it holds.
%%
%% THE CALLER IS THE MOVER, ALWAYS. `caller' is the node id macula verified on
%% the call, injected over any same-named key the body sent, and there is no
%% field naming a player: a payload that claims to be somebody else is a payload
%% whose claim is never read (mcl-chess#1, the attribution invariant). A node
%% holding no seat is refused before its move string is even looked at.
%%
%% The move is UCI: a from square, a to square and, for a promotion, the piece.
%% Its shape is checked here, at the boundary; whether the position allows it is
%% the rules engine's answer, in the handler.
-module(submit_move_v1).

-behaviour(evoq_command).

-export([command_type/0, new/1, to_map/1, validate/1, from_map/1]).
-export([stream_id/1, get_game_id/1, get_caller/1, get_move/1]).

-record(submit_move, {
    game_id :: binary(),
    caller  :: binary(),
    move    :: binary()
}).

-opaque t() :: #submit_move{}.
-export_type([t/0]).

-spec command_type() -> atom().
command_type() -> submit_move_v1.

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{game_id := GameId, caller := Caller, move := Move})
        when is_binary(GameId), is_binary(Caller), is_binary(Move),
             GameId =/= <<>>, Caller =/= <<>>, Move =/= <<>> ->
    {ok, #submit_move{game_id = GameId, caller = Caller, move = Move}};
new(_) ->
    {error, missing_required_fields}.

-spec validate(t()) -> ok | {error, term()}.
validate(#submit_move{game_id = GameId}) ->
    reckon_gater_stream_id:validate(GameId).

-spec to_map(t()) -> map().
to_map(#submit_move{game_id = GameId, caller = Caller, move = Move}) ->
    #{command_type => command_type(),
      game_id => GameId,
      caller => Caller,
      move => Move}.

-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(#{game_id := GameId, caller := Caller, move := Move}) ->
    new(#{game_id => GameId, caller => Caller, move => Move});
from_map(_) ->
    {error, missing_required_fields}.

-spec stream_id(t()) -> binary().
stream_id(#submit_move{game_id = GameId}) -> GameId.

-spec get_game_id(t()) -> binary().
get_game_id(#submit_move{game_id = GameId}) -> GameId.

-spec get_caller(t()) -> binary().
get_caller(#submit_move{caller = Caller}) -> Caller.

-spec get_move(t()) -> binary().
get_move(#submit_move{move = Move}) -> Move.
