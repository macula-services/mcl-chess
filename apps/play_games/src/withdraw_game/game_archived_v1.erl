%% @doc The death event: the game is archived and holds no more state.
%%
%% Two paths produce it and they share this event, because the event type is
%% the subscription key, not the desk: a pre-start withdrawal (reason
%% `withdrawn'), and the retention archive of an ended game (reason
%% `retention'), which arrives with the retention policy in WP6.
-module(game_archived_v1).

-behaviour(evoq_event).

-export([event_type/0, new/1, to_map/1, from_map/1]).
-export([get_game_id/1, get_reason/1, get_status/1]).

-record(game_archived, {
    game_id :: binary(),
    reason  :: binary(),
    status  :: non_neg_integer(),
    at_ms   :: non_neg_integer()
}).

-opaque t() :: #game_archived{}.
-export_type([t/0]).

-spec event_type() -> binary().
event_type() -> <<"game_archived_v1">>.

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{game_id := GameId, reason := Reason, status := Status} = Params)
        when is_binary(GameId), is_binary(Reason) ->
    {ok, #game_archived{game_id = GameId,
                        reason = Reason,
                        status = Status,
                        at_ms = maps:get(at_ms, Params,
                                         erlang:system_time(millisecond))}};
new(_) ->
    {error, missing_required_fields}.

-spec to_map(t()) -> map().
to_map(#game_archived{} = Event) ->
    #{event_type => event_type(),
      game_id => Event#game_archived.game_id,
      reason => Event#game_archived.reason,
      status => Event#game_archived.status,
      at_ms => Event#game_archived.at_ms}.

-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(#{game_id := GameId, reason := Reason, status := Status} = Map) ->
    {ok, #game_archived{game_id = GameId,
                        reason = Reason,
                        status = Status,
                        at_ms = maps:get(at_ms, Map, 0)}};
from_map(_) ->
    {error, missing_required_fields}.

-spec get_game_id(t()) -> binary().
get_game_id(#game_archived{game_id = GameId}) -> GameId.

-spec get_reason(t()) -> binary().
get_reason(#game_archived{reason = Reason}) -> Reason.

-spec get_status(t()) -> non_neg_integer().
get_status(#game_archived{status = Status}) -> Status.
