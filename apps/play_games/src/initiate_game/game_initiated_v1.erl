%% @doc The birth event: a game exists and accepts seat claims.
%%
%% It carries the whole initial state, not just what changed. A subscriber
%% that joins on this event alone can render the game, empty seats and all,
%% with no follow-up query, and a replay never needs a second stream to
%% interpret it.
-module(game_initiated_v1).

-behaviour(evoq_event).

-include("game_status.hrl").

-export([event_type/0, new/1, to_map/1, from_map/1]).
-export([get_game_id/1, get_status/1]).

-record(game_initiated, {
    game_id           :: binary(),
    protocol = <<"chess">> :: binary(),
    time_control      :: {integer(), integer()},
    seats             :: map(),
    position          :: binary(),
    to_move           :: binary(),
    ply               :: non_neg_integer(),
    clocks            :: map(),
    status            :: non_neg_integer(),
    initiator_node_id :: binary(),
    at_ms             :: non_neg_integer()
}).

-opaque t() :: #game_initiated{}.
-export_type([t/0]).

%% The standard chess starting position, as FEN.
-define(START_FEN, <<"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1">>).

-spec event_type() -> binary().
event_type() -> <<"game_initiated_v1">>.

%% @doc Build the event from the command's parameters.
%%
%% The clocks start at the time control, and both seats start empty unless the
%% command pre-assigned them. Only the future matchmaker may pre-assign, and
%% that path never comes off the wire: the responder does not read `seats'.
%% `AtMs' is the service's own clock: the sender's `sent_at' is informational
%% and never used for clock arithmetic.
-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{game_id := GameId, time_control := {Initial, Increment}, initiator := Initiator}
    = Params) when is_binary(GameId), is_binary(Initiator) ->
    {ok, #game_initiated{
        game_id = GameId,
        protocol = maps:get(protocol, Params, <<"chess">>),
        time_control = {Initial, Increment},
        seats = maps:get(seats, Params, #{white => <<>>, black => <<>>}),
        position = maps:get(position, Params, ?START_FEN),
        to_move = maps:get(to_move, Params, <<"w">>),
        ply = maps:get(ply, Params, 0),
        clocks = #{white => Initial, black => Initial},
        status = maps:get(status, Params, ?GAME_INITIATED bor ?GAME_OPEN),
        initiator_node_id = Initiator,
        at_ms = maps:get(at_ms, Params, erlang:system_time(millisecond))}};
new(_) ->
    {error, missing_required_fields}.

-spec to_map(t()) -> map().
to_map(#game_initiated{} = Event) ->
    #{event_type => event_type(),
      game_id => Event#game_initiated.game_id,
      protocol => Event#game_initiated.protocol,
      time_control => Event#game_initiated.time_control,
      seats => Event#game_initiated.seats,
      position => Event#game_initiated.position,
      to_move => Event#game_initiated.to_move,
      ply => Event#game_initiated.ply,
      clocks => Event#game_initiated.clocks,
      status => Event#game_initiated.status,
      initiator_node_id => Event#game_initiated.initiator_node_id,
      at_ms => Event#game_initiated.at_ms}.

-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(#{game_id := GameId, time_control := TimeControl} = Map) ->
    {ok, #game_initiated{
        game_id = GameId,
        protocol = maps:get(protocol, Map, <<"chess">>),
        time_control = TimeControl,
        seats = maps:get(seats, Map),
        position = maps:get(position, Map),
        to_move = maps:get(to_move, Map),
        ply = maps:get(ply, Map),
        clocks = maps:get(clocks, Map),
        status = maps:get(status, Map),
        initiator_node_id = maps:get(initiator_node_id, Map, <<>>),
        at_ms = maps:get(at_ms, Map, 0)}};
from_map(_) ->
    {error, missing_required_fields}.

-spec get_game_id(t()) -> binary().
get_game_id(#game_initiated{game_id = GameId}) -> GameId.

-spec get_status(t()) -> non_neg_integer().
get_status(#game_initiated{status = Status}) -> Status.
