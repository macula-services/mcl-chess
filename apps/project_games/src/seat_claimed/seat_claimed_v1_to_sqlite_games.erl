%% @doc Projects seat_claimed_v1 into the games row: the seats, the status and
%% its label.
%%
%% An UPDATE rather than an upsert, because a claim only ever follows a birth:
%% the birth event is what creates the row. That also means an UPDATE that
%% matched nothing is a real fault (a delivery out of order, or a row lost), so
%% it is checked and returned as a store error for evoq to retry rather than
%% passing as success. A projection that silently wrote nothing is how a read
%% model drifts from its stream.
%%
%% The label is computed HERE, from the event's own status integer, never by a
%% client (philosophy/STATUS_LABELS_IN_PROJECTIONS.md).
-module(seat_claimed_v1_to_sqlite_games).

-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, replay_policy/0]).

interested_in() -> [<<"seat_claimed_v1">>].

%% The write is idempotent (the same event writes the same row), so a replay
%% may deliver it: a read model rebuilt from history is the point of one.
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
    Seats = maps:get(seats, Data),
    Status = maps:get(status, Data),
    updated(GameId,
            game_read_model_store:exec(
              "UPDATE games SET white_node_id = ?, black_node_id = ?,"
              " status = ?, status_label = ?, event_id = ?, version = ?"
              " WHERE game_id = ?",
              [maps:get(white, Seats),
               maps:get(black, Seats),
               Status,
               game_status:to_string(Status),
               maps:get(event_id, Event),
               maps:get(version, Event, 0),
               GameId])).

%% An UPDATE that matched no row returns ok as far as sqlite is concerned. Ask
%% whether the row is there, so a missing one is a retryable fault and not a
%% silent gap.
updated(GameId, ok) ->
    case game_read_model_store:q("SELECT 1 FROM games WHERE game_id = ?",
                                 [GameId]) of
        [] -> {error, {no_row_for, GameId}};
        {error, Reason} -> {error, Reason};
        [_ | _] -> ok
    end;
updated(_GameId, {error, _} = Error) ->
    Error.
