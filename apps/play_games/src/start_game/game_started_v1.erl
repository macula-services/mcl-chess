%% @doc The start event: the game is playing, and the clocks are live.
%%
%% It carries the whole started state (both holders, the position, the clocks)
%% so a projection or a clock instance reads one event and never a read model.
%% The holders are named BY COLOUR, because nothing in this division pins the
%% initiator to white: whoever claimed white is white.
-module(game_started_v1).

-behaviour(evoq_event).

-include("game_status.hrl").

-export([event_type/0, new/1, to_map/1, from_map/1]).
-export([get_game_id/1, get_white_node_id/1, get_black_node_id/1,
         get_status/1]).

-record(game_started, {
    game_id       :: binary(),
    white_node_id :: binary(),
    black_node_id :: binary(),
    position      :: binary(),
    %% The hash of the position the game starts from. Recorded here, not
    %% derived later, because a repetition can return to this position and a
    %% fivefold count that began at the first move would miss one.
    position_hash :: non_neg_integer(),
    to_move       :: binary(),
    ply           :: non_neg_integer(),
    clocks        :: map(),
    status        :: non_neg_integer(),
    at_ms         :: non_neg_integer()
}).

-opaque t() :: #game_started{}.
-export_type([t/0]).

-spec event_type() -> binary().
event_type() -> <<"game_started_v1">>.

%% @doc Build the event from the state the seats produced.
%%
%% `at_ms' is the service's own clock, and it is what the clock instance starts
%% white's deadline from: the sender's `sent_at' is informational and never used
%% for clock arithmetic.
-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{game_id := GameId, white_node_id := White, black_node_id := Black,
      position := Position, position_hash := Hash, to_move := ToMove, ply := Ply,
      clocks := Clocks, status := Status} = Params)
        when is_binary(GameId), is_binary(White), is_binary(Black),
             White =/= <<>>, Black =/= <<>>, is_map(Clocks), is_integer(Hash) ->
    {ok, #game_started{game_id = GameId,
                       white_node_id = White,
                       black_node_id = Black,
                       position = Position,
                       position_hash = Hash,
                       to_move = ToMove,
                       ply = Ply,
                       clocks = Clocks,
                       status = Status,
                       at_ms = maps:get(at_ms, Params,
                                        erlang:system_time(millisecond))}};
new(_) ->
    {error, missing_required_fields}.

-spec to_map(t()) -> map().
to_map(#game_started{} = Event) ->
    #{event_type => event_type(),
      game_id => Event#game_started.game_id,
      white_node_id => Event#game_started.white_node_id,
      black_node_id => Event#game_started.black_node_id,
      position => Event#game_started.position,
      position_hash => Event#game_started.position_hash,
      to_move => Event#game_started.to_move,
      ply => Event#game_started.ply,
      clocks => Event#game_started.clocks,
      status => Event#game_started.status,
      at_ms => Event#game_started.at_ms}.

-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(#{game_id := GameId, white_node_id := White, black_node_id := Black,
           position := Position, position_hash := Hash, to_move := ToMove,
           ply := Ply, clocks := Clocks, status := Status} = Map) ->
    {ok, #game_started{game_id = GameId,
                       white_node_id = White,
                       black_node_id = Black,
                       position = Position,
                       position_hash = Hash,
                       to_move = ToMove,
                       ply = Ply,
                       clocks = Clocks,
                       status = Status,
                       at_ms = maps:get(at_ms, Map, 0)}};
from_map(_) ->
    {error, missing_required_fields}.

-spec get_game_id(t()) -> binary().
get_game_id(#game_started{game_id = GameId}) -> GameId.

-spec get_white_node_id(t()) -> binary().
get_white_node_id(#game_started{white_node_id = White}) -> White.

-spec get_black_node_id(t()) -> binary().
get_black_node_id(#game_started{black_node_id = Black}) -> Black.

-spec get_status(t()) -> non_neg_integer().
get_status(#game_started{status = Status}) -> Status.
