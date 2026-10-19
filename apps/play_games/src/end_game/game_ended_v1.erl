%% @doc The end event: the game has an outcome, and the clock has stopped.
%%
%% ONE EVENT FOR EVERY WAY A GAME ENDS, because the event type is the
%% subscription key (mcl-chess#1, design of record). The desks differ (a
%% resignation, a terminal position, a flag) and the record does not: `outcome'
%% says who won, `reason' says why.
%%
%% Outcome vocabulary (closed set): `winner' (reason `checkmate'), `draw'
%% (`stalemate', `insufficient_material', `seventy_five_moves',
%% `fivefold_repetition'), `forfeit' (`clock_flag', `resignation'), `abandoned'
%% (`withdrawn'). A withdraw before the game started is not an end: it archives.
-module(game_ended_v1).

-behaviour(evoq_event).

-export([event_type/0, new/1, to_map/1, from_map/1]).
-export([get_game_id/1, get_outcome/1, get_reason/1, get_winner_node_id/1,
         get_status/1]).

-record(game_ended, {
    game_id        :: binary(),
    outcome        :: winner | draw | forfeit | abandoned,
    winner_node_id :: binary(),
    reason         :: atom(),
    fen_after      :: binary(),
    ply            :: non_neg_integer(),
    clocks         :: map(),
    status         :: non_neg_integer(),
    at_ms          :: non_neg_integer()
}).

-opaque t() :: #game_ended{}.
-export_type([t/0]).

-spec event_type() -> binary().
event_type() -> <<"game_ended_v1">>.

%% @doc Build the event from the state the end produced.
%%
%% A win names the node that won and a draw names nobody: an outcome of
%% `winner' with no winner is a record that cannot be read back, and an outcome
%% outside the closed set is not an end at all.
-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{game_id := GameId, outcome := Outcome, reason := Reason,
      fen_after := Fen, ply := Ply, clocks := Clocks, status := Status} = Params)
        when is_binary(GameId), is_binary(Fen), is_map(Clocks) ->
    ended(Outcome, maps:get(winner_node_id, Params, <<>>),
          {GameId, Reason, Fen, Ply, Clocks, Status, Params});
new(_) ->
    {error, missing_required_fields}.

ended(Outcome, <<>>, _Args) when Outcome =:= winner; Outcome =:= forfeit ->
    {error, invalid_winner};
ended(Outcome, Winner, {GameId, Reason, Fen, Ply, Clocks, Status, Params})
        when is_binary(Winner), (Outcome =:= winner orelse Outcome =:= forfeit
                                 orelse Outcome =:= draw
                                 orelse Outcome =:= abandoned) ->
    {ok, #game_ended{game_id = GameId,
                     outcome = Outcome,
                     winner_node_id = Winner,
                     reason = Reason,
                     fen_after = Fen,
                     ply = Ply,
                     clocks = Clocks,
                     status = Status,
                     at_ms = maps:get(at_ms, Params,
                                      erlang:system_time(millisecond))}};
ended(_Outcome, _Winner, _Args) ->
    {error, invalid_outcome}.

-spec to_map(t()) -> map().
to_map(#game_ended{} = Event) ->
    #{event_type => event_type(),
      game_id => Event#game_ended.game_id,
      outcome => Event#game_ended.outcome,
      winner_node_id => Event#game_ended.winner_node_id,
      reason => Event#game_ended.reason,
      fen_after => Event#game_ended.fen_after,
      ply => Event#game_ended.ply,
      clocks => Event#game_ended.clocks,
      status => Event#game_ended.status,
      at_ms => Event#game_ended.at_ms}.

-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(#{game_id := GameId, outcome := Outcome, reason := Reason,
           fen_after := Fen, ply := Ply, clocks := Clocks, status := Status} = Map) ->
    {ok, #game_ended{game_id = GameId,
                     outcome = Outcome,
                     winner_node_id = maps:get(winner_node_id, Map, <<>>),
                     reason = Reason,
                     fen_after = Fen,
                     ply = Ply,
                     clocks = Clocks,
                     status = Status,
                     at_ms = maps:get(at_ms, Map, 0)}};
from_map(_) ->
    {error, missing_required_fields}.

-spec get_game_id(t()) -> binary().
get_game_id(#game_ended{game_id = GameId}) -> GameId.

-spec get_outcome(t()) -> atom().
get_outcome(#game_ended{outcome = Outcome}) -> Outcome.

-spec get_reason(t()) -> atom().
get_reason(#game_ended{reason = Reason}) -> Reason.

-spec get_winner_node_id(t()) -> binary().
get_winner_node_id(#game_ended{winner_node_id = Winner}) -> Winner.

-spec get_status(t()) -> non_neg_integer().
get_status(#game_ended{status = Status}) -> Status.
