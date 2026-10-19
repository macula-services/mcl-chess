%% @doc Projects game_ended_v1 into the games row: the outcome, the reason, who
%% won, the final position and the clock state at the end.
%%
%% The status and its label move to `ended' here, from the event's own integer,
%% which is what makes a finished game readable at a glance: `status' says the
%% game is over, `outcome' and `end_reason' say how. A draw names no winner, and
%% its `winner_node_id' column stays empty rather than absent.
-module(game_ended_v1_to_sqlite_games).

-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, replay_policy/0]).

interested_in() -> [<<"game_ended_v1">>].

replay_policy() -> deliver.

init(_Config) ->
    {ok, #{}}.

handle_event(_EventType, Event, _Metadata, State) ->
    Data = maps:get(data, Event, Event),
    case upsert(Data, Event) of
        ok -> {ok, State};
        {error, Reason} -> {error, {store_error, Reason}}
    end.

upsert(Data, Event) ->
    GameId = maps:get(game_id, Data),
    Status = maps:get(status, Data),
    #{white := WhiteMs, black := BlackMs} = maps:get(clocks, Data),
    updated(GameId,
            game_read_model_store:exec(
              "UPDATE games SET position = ?, ply = ?, white_clock_ms = ?,"
              " black_clock_ms = ?, status = ?, status_label = ?, outcome = ?,"
              " end_reason = ?, winner_node_id = ?, ended_at = ?,"
              " event_id = ?, version = ? WHERE game_id = ?",
              [maps:get(fen_after, Data),
               maps:get(ply, Data),
               WhiteMs,
               BlackMs,
               Status,
               game_status:to_string(Status),
               text(maps:get(outcome, Data)),
               text(maps:get(reason, Data)),
               maps:get(winner_node_id, Data, <<>>),
               maps:get(at_ms, Data, 0),
               maps:get(event_id, Event),
               maps:get(version, Event, 0),
               GameId])).

%% The event stores an atom; the column is text, the same spelling a fact
%% carries.
text(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
text(Value) -> Value.

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
