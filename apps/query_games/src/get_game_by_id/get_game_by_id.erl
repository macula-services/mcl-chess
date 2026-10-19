%% @doc get_game_by_id: one game, by its stream id.
%%
%% A query desk is a pure module answered by the query store: no state, no
%% framework, no mesh. An archived game is still answerable by id, with its
%% status visible, because an archived game is inspectable (that is what the
%% retention window is for).
%%
%% THE MOVE LIST IS A SECOND READ, from the moves table, ordered by ply. That is
%% what a dispute needs: not just the position the game ended in, but the moves
%% that produced it, in the order they were played.
-module(get_game_by_id).

-export([find/1]).

%% @doc One game, or not_found. The row's cells arrive in SELECT order; the
%% schema-contract test keeps that order aligned with the PRJ division's DDL.
-spec find(binary()) -> {ok, map()} | {error, term()}.
find(GameId) when is_binary(GameId) ->
    found(game_query_store:q(
            "SELECT game_id, protocol, initial_ms, increment_ms, white_node_id,"
            " black_node_id, position, to_move, ply, white_clock_ms,"
            " black_clock_ms, halfmove_clock, status, status_label, outcome,"
            " end_reason, winner_node_id, initiator, archive_reason,"
            " initiated_at, ended_at, archived_at"
            " FROM games WHERE game_id = ?", [GameId]));
find(_) ->
    {error, missing_game_id}.

%% @private
found([[GameId, Protocol, Initial, Increment, White, Black, Position, ToMove,
        Ply, WhiteMs, BlackMs, Clock, Status, Label, Outcome, EndReason,
        Winner, Initiator, ArchiveReason, InitiatedAt, EndedAt, ArchivedAt] | _]) ->
    listed(game(GameId, Protocol, Initial, Increment, White, Black, Position,
                ToMove, Ply, WhiteMs, BlackMs, Clock, Status, Label, Outcome,
                EndReason, Winner, Initiator, ArchiveReason, InitiatedAt,
                EndedAt, ArchivedAt),
           moves(GameId));
found([]) ->
    {error, not_found};
found({error, Reason}) ->
    {error, {store_error, Reason}}.

%% The move list, oldest first. A game with none answers with an empty list
%% rather than a missing key: a board viewer renders it either way, and an agent
%% parsing the reply does not have to test for absence.
moves(GameId) ->
    game_query_store:q("SELECT uci FROM moves WHERE game_id = ? ORDER BY ply",
                       [GameId]).

listed(Game, Rows) when is_list(Rows) ->
    {ok, Game#{<<"moves">> => [Uci || [Uci] <- Rows]}};
listed(_Game, {error, Reason}) ->
    {error, {store_error, Reason}}.

%% @private
game(GameId, Protocol, Initial, Increment, White, Black, Position, ToMove,
     Ply, WhiteMs, BlackMs, Clock, Status, Label, Outcome, EndReason, Winner,
     Initiator, ArchiveReason, InitiatedAt, EndedAt, ArchivedAt) ->
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
      <<"halfmove_clock">> => Clock,
      <<"outcome">> => Outcome,
      <<"end_reason">> => EndReason,
      <<"winner">> => Winner,
      <<"initiator">> => Initiator,
      <<"archive_reason">> => ArchiveReason,
      <<"initiated_at">> => InitiatedAt,
      <<"ended_at">> => EndedAt,
      <<"archived_at">> => ArchivedAt}.
