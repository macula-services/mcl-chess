%% @doc The move event: a legal move by the seat that was to move.
%%
%% It carries the whole position the move produced (the FEN, its FIDE hash, the
%% side now to move, the ply, the clocks) so a projection, a clock instance or
%% a replay reads one event and never a second stream.
%%
%% TWO FIELDS ARE THE REFEREE'S OWN COUNT, and both are here because the end
%% policy is a pure function of one event:
%%
%% - `halfmove_clock' is the count since the last pawn move or capture, kept
%%   here rather than read from the FEN, whose field the rules library clamps
%%   to 100. The 75 move rule fires at 150.
%% - `repetitions' is how many times the position after this move has occurred.
%%   Five is the automatic draw (mcl-chess#4).
%%
%% The verdict itself is not in the event: the end policy asks the rules engine
%% for it, so a change of referee never rewrites a stream.
-module(move_played_v1).

-behaviour(evoq_event).

-export([event_type/0, new/1, to_map/1, from_map/1]).
-export([get_game_id/1, get_player_node_id/1, get_move/1, get_ply/1,
         get_fen_after/1, get_status/1]).

-record(move_played, {
    game_id          :: binary(),
    player_node_id   :: binary(),
    move             :: binary(),
    ply              :: non_neg_integer(),
    fen_after        :: binary(),
    position_hash    :: non_neg_integer(),
    halfmove_clock   :: non_neg_integer(),
    repetitions      :: non_neg_integer(),
    to_move          :: binary(),
    clocks           :: map(),
    status           :: non_neg_integer(),
    at_ms            :: non_neg_integer()
}).

-opaque t() :: #move_played{}.
-export_type([t/0]).

-spec event_type() -> binary().
event_type() -> <<"move_played_v1">>.

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{game_id := GameId, player_node_id := Player, move := Move, ply := Ply,
      fen_after := Fen, position_hash := Hash, halfmove_clock := Clock,
      repetitions := Repetitions, to_move := ToMove, clocks := Clocks,
      status := Status} = Params)
        when is_binary(GameId), is_binary(Player), Player =/= <<>>,
             is_binary(Move), Move =/= <<>>, is_binary(Fen),
             is_integer(Hash), is_integer(Clock), is_integer(Repetitions),
             is_map(Clocks) ->
    {ok, #move_played{game_id = GameId,
                      player_node_id = Player,
                      move = Move,
                      ply = Ply,
                      fen_after = Fen,
                      position_hash = Hash,
                      halfmove_clock = Clock,
                      repetitions = Repetitions,
                      to_move = ToMove,
                      clocks = Clocks,
                      status = Status,
                      at_ms = maps:get(at_ms, Params,
                                       erlang:system_time(millisecond))}};
new(_) ->
    {error, missing_required_fields}.

-spec to_map(t()) -> map().
to_map(#move_played{} = Event) ->
    #{event_type => event_type(),
      game_id => Event#move_played.game_id,
      player_node_id => Event#move_played.player_node_id,
      move => Event#move_played.move,
      ply => Event#move_played.ply,
      fen_after => Event#move_played.fen_after,
      position_hash => Event#move_played.position_hash,
      halfmove_clock => Event#move_played.halfmove_clock,
      repetitions => Event#move_played.repetitions,
      to_move => Event#move_played.to_move,
      clocks => Event#move_played.clocks,
      status => Event#move_played.status,
      at_ms => Event#move_played.at_ms}.

-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(#{game_id := GameId, player_node_id := Player, move := Move,
           ply := Ply, fen_after := Fen, position_hash := Hash,
           halfmove_clock := Clock, repetitions := Repetitions,
           to_move := ToMove, clocks := Clocks, status := Status} = Map) ->
    {ok, #move_played{game_id = GameId,
                      player_node_id = Player,
                      move = Move,
                      ply = Ply,
                      fen_after = Fen,
                      position_hash = Hash,
                      halfmove_clock = Clock,
                      repetitions = Repetitions,
                      to_move = ToMove,
                      clocks = Clocks,
                      status = Status,
                      at_ms = maps:get(at_ms, Map, 0)}};
from_map(_) ->
    {error, missing_required_fields}.

-spec get_game_id(t()) -> binary().
get_game_id(#move_played{game_id = GameId}) -> GameId.

-spec get_player_node_id(t()) -> binary().
get_player_node_id(#move_played{player_node_id = Player}) -> Player.

-spec get_move(t()) -> binary().
get_move(#move_played{move = Move}) -> Move.

-spec get_ply(t()) -> non_neg_integer().
get_ply(#move_played{ply = Ply}) -> Ply.

-spec get_fen_after(t()) -> binary().
get_fen_after(#move_played{fen_after = Fen}) -> Fen.

-spec get_status(t()) -> non_neg_integer().
get_status(#move_played{status = Status}) -> Status.
