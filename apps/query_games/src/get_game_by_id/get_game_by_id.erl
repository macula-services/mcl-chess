%% @doc get_game_by_id: one game, by its stream id.
%%
%% A query desk is a pure module answered by the query store: no state, no
%% framework, no mesh. An archived game is still answerable by id, with its
%% status visible, because an archived game is inspectable (that is what the
%% retention window is for).
-module(get_game_by_id).

-export([find/1]).

%% @doc One game, or not_found. The row's cells arrive in SELECT order; the
%% schema-contract test keeps that order aligned with the PRJ division's DDL.
-spec find(binary()) -> {ok, map()} | {error, term()}.
find(GameId) when is_binary(GameId) ->
    found(game_query_store:q(
            "SELECT game_id, protocol, initial_ms, increment_ms, white_node_id,"
            " black_node_id, position, to_move, ply, white_clock_ms,"
            " black_clock_ms, status, status_label, initiator, archive_reason,"
            " initiated_at, archived_at"
            " FROM games WHERE game_id = ?", [GameId]));
find(_) ->
    {error, missing_game_id}.

%% @private
%% The row is turned straight into the wire shape: binary keys, 1/0 flags.
found([[GameId, Protocol, Initial, Increment, White, Black, Position, ToMove,
        Ply, WhiteMs, BlackMs, Status, Label, Initiator, ArchiveReason,
        InitiatedAt, ArchivedAt] | _]) ->
    {ok, game(GameId, Protocol, Initial, Increment, White, Black, Position,
              ToMove, Ply, WhiteMs, BlackMs, Status, Label, Initiator,
              ArchiveReason, InitiatedAt, ArchivedAt)};
found([]) ->
    {error, not_found};
found({error, Reason}) ->
    {error, {store_error, Reason}}.

%% @private
game(GameId, Protocol, Initial, Increment, White, Black, Position, ToMove,
     Ply, WhiteMs, BlackMs, Status, Label, Initiator, ArchiveReason,
     InitiatedAt, ArchivedAt) ->
    #{<<"game_id">> => GameId,
      <<"protocol">> => Protocol,
      <<"status">> => Status,
      <<"status_label">> => Label,
      <<"time_control">> => #{<<"initial_ms">> => Initial,
                              <<"increment_ms">> => Increment},
      <<"seats">> => #{<<"white">> => White, <<"black">> => Black},
      <<"position">> => Position,
      <<"to_move">> => ToMove,
      <<"ply">> => Ply,
      <<"clocks">> => #{<<"white">> => WhiteMs, <<"black">> => BlackMs},
      <<"initiator">> => Initiator,
      <<"archive_reason">> => ArchiveReason,
      <<"initiated_at">> => InitiatedAt,
      <<"archived_at">> => ArchivedAt}.
