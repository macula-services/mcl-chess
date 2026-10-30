%% @doc Projects move_played_v1 into the read model: the new position, the
%% clocks and the referee's own counter in the games row, and the move itself in
%% the moves table.
%%
%% TWO WRITES, BOTH IDEMPOTENT. The games row takes absolute values, and the
%% move is `INSERT OR REPLACE' keyed on `(game_id, ply)`: a replay that delivers
%% the same move again replaces it rather than appending it twice, which is why
%% the move list is its own table and not a text column grown by concatenation.
%% If the second write fails the handler returns a store error and evoq retries
%% the event; the first write has already set the same values.
%%
%% The label is computed HERE, from the event's own status integer
%% (philosophy/STATUS_LABELS_IN_PROJECTIONS.md). A move changes no flag, so the
%% label it writes is the one the game already had, and that is still the right
%% place to compute it.
%%
%% The games row is guarded on the event's own stream version: the last move of
%% a game can be projected after the end it produced, and an unguarded write
%% put a finished game back to `in progress' (mcl-chess#18). The move row needs
%% no such guard; it is keyed by ply, and every ply is its own fact.
-module(move_played_v1_to_sqlite_games).

-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, replay_policy/0]).

interested_in() -> [<<"move_played_v1">>].

replay_policy() -> deliver.

init(_Config) ->
    {ok, #{}}.

handle_event(_EventType, Event, _Metadata, State) ->
    Data = maps:get(data, Event, Event),
    handled(stored(Data, Event), State).

stored(Data, Event) ->
    case upsert(Data, Event) of
        ok -> move_in(Data);
        {error, _} = Error -> Error
    end.

handled(ok, State) -> {ok, State};
handled({error, Reason}, _State) -> {error, {store_error, Reason}}.

move_in(Data) ->
    game_read_model_store:exec(
      "INSERT OR REPLACE INTO moves (game_id, ply, uci) VALUES (?, ?, ?)",
      [maps:get(game_id, Data), maps:get(ply, Data), maps:get(move, Data)]).

upsert(Data, Event) ->
    GameId = maps:get(game_id, Data),
    Status = maps:get(status, Data),
    Version = maps:get(version, Event, 0),
    #{white := WhiteMs, black := BlackMs} = maps:get(clocks, Data),
    updated(GameId,
            game_read_model_store:exec(
              "UPDATE games SET position = ?, to_move = ?, ply = ?,"
              " white_clock_ms = ?, black_clock_ms = ?, halfmove_clock = ?,"
              " status = ?, status_label = ?, event_id = ?, version = ?"
              " WHERE game_id = ? AND version < ?",
              [maps:get(fen_after, Data),
               maps:get(to_move, Data),
               maps:get(ply, Data),
               WhiteMs,
               BlackMs,
               maps:get(halfmove_clock, Data),
               Status,
               game_status:to_string(Status),
               maps:get(event_id, Event),
               Version,
               GameId,
               Version])).

%% An UPDATE that matched no row is a fault, not a success: ask whether the row
%% is there and hand a missing one back as a retryable store error.
updated(GameId, ok) ->
    case game_read_model_store:q("SELECT 1 FROM games WHERE game_id = ?",
                                 [GameId]) of
        [] -> {error, {no_row_for, GameId}};
        {error, Reason} -> {error, Reason};
        [_ | _] -> ok
    end;
updated(_GameId, {error, _} = Error) ->
    Error.
