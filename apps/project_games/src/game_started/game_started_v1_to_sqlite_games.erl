%% @doc Projects game_started_v1 into the games row: the status, its label, and
%% the two holders by colour.
%%
%% The holders are written again even though a claim wrote them, because this
%% event is the authority on who is playing: a game that started with a seat map
%% that disagreed with its claims would show the disagreements rather than hide
%% them.
%%
%% The label is computed HERE, from the event's own status integer
%% (philosophy/STATUS_LABELS_IN_PROJECTIONS.md).
-module(game_started_v1_to_sqlite_games).

-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, replay_policy/0]).

interested_in() -> [<<"game_started_v1">>].

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
    updated(GameId,
            game_read_model_store:exec(
              "UPDATE games SET white_node_id = ?, black_node_id = ?,"
              " status = ?, status_label = ?, event_id = ?, version = ?"
              " WHERE game_id = ?",
              [maps:get(white_node_id, Data),
               maps:get(black_node_id, Data),
               Status,
               game_status:to_string(Status),
               maps:get(event_id, Event),
               maps:get(version, Event, 0),
               GameId])).

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
