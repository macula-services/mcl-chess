%% @doc The refusal event: a seat holder tried something the rules forbid.
%%
%% This is the evidence class the design of record splits out (mcl-chess#1):
%% "this caller was in the game and tried a foul move" is worth recording — a
%% future reputation division reads attempted foul play from the transcript —
%% while "this caller never had standing" is answered on the wire and records
%% nothing. It changes no game state: the position is the one the game already
%% stood in, `fen_after' is echoed rather than advanced.
%%
%% The count of these per player is bounded by `game_state''s one refusal
%% counter, the same one `seat_refused_v1' uses, so a seat holder cannot grow
%% the stream without limit either.
-module(move_refused_v1).

-behaviour(evoq_event).

-export([event_type/0, new/1, to_map/1, from_map/1]).
-export([get_game_id/1, get_player_node_id/1, get_reason/1]).

-record(move_refused, {
    game_id        :: binary(),
    player_node_id :: binary(),
    move           :: binary(),
    reason         :: atom(),
    ply            :: non_neg_integer(),
    fen_after      :: binary(),
    clocks         :: map(),
    status         :: non_neg_integer(),
    at_ms          :: non_neg_integer()
}).

-opaque t() :: #move_refused{}.
-export_type([t/0]).

-spec event_type() -> binary().
event_type() -> <<"move_refused_v1">>.

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{game_id := GameId, player_node_id := Player, move := Move, reason := Reason,
      ply := Ply, fen_after := Fen, clocks := Clocks, status := Status} = Params)
        when is_binary(GameId), is_binary(Player), Player =/= <<>>,
             is_binary(Move), is_atom(Reason), is_binary(Fen), is_map(Clocks) ->
    {ok, #move_refused{game_id = GameId,
                       player_node_id = Player,
                       move = Move,
                       reason = Reason,
                       ply = Ply,
                       fen_after = Fen,
                       clocks = Clocks,
                       status = Status,
                       at_ms = maps:get(at_ms, Params,
                                        erlang:system_time(millisecond))}};
new(_) ->
    {error, missing_required_fields}.

-spec to_map(t()) -> map().
to_map(#move_refused{} = Event) ->
    #{event_type => event_type(),
      game_id => Event#move_refused.game_id,
      player_node_id => Event#move_refused.player_node_id,
      move => Event#move_refused.move,
      reason => Event#move_refused.reason,
      ply => Event#move_refused.ply,
      fen_after => Event#move_refused.fen_after,
      clocks => Event#move_refused.clocks,
      status => Event#move_refused.status,
      at_ms => Event#move_refused.at_ms}.

-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(#{game_id := GameId, player_node_id := Player, move := Move,
           reason := Reason, ply := Ply, fen_after := Fen, clocks := Clocks,
           status := Status} = Map) ->
    {ok, #move_refused{game_id = GameId,
                       player_node_id = Player,
                       move = Move,
                       reason = Reason,
                       ply = Ply,
                       fen_after = Fen,
                       clocks = Clocks,
                       status = Status,
                       at_ms = maps:get(at_ms, Map, 0)}};
from_map(_) ->
    {error, missing_required_fields}.

-spec get_game_id(t()) -> binary().
get_game_id(#move_refused{game_id = GameId}) -> GameId.

-spec get_player_node_id(t()) -> binary().
get_player_node_id(#move_refused{player_node_id = Player}) -> Player.

-spec get_reason(t()) -> atom().
get_reason(#move_refused{reason = Reason}) -> Reason.
