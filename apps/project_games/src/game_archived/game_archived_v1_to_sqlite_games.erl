%% @doc Projects game_archived_v1 into the games row: the death slice.
%%
%% An UPDATE rather than an INSERT: the game already exists, and an archive
%% event that arrived before its birth event (a store replay can deliver in
%% any order after a long outage) must not create a phantom row. The update
%% is a no-op then, and the redelivered birth fills the row in.
-module(game_archived_v1_to_sqlite_games).

-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, replay_policy/0]).

interested_in() -> [<<"game_archived_v1">>].

replay_policy() -> deliver.

init(_Config) ->
    {ok, #{}}.

handle_event(_EventType, Event, _Metadata, State) ->
    Data = maps:get(data, Event, Event),
    case update(Data, Event) of
        ok -> {ok, State};
        {error, Reason} -> {error, {store_error, Reason}}
    end.

update(Data, Event) ->
    Status = maps:get(status, Data),
    game_read_model_store:exec(
      "UPDATE games SET status = ?, status_label = ?, archive_reason = ?,"
      " archived_at = ?, event_id = ?, version = ? WHERE game_id = ?",
      [Status,
       game_status:to_string(Status),
       maps:get(reason, Data),
       maps:get(at_ms, Data),
       maps:get(event_id, Event),
       maps:get(version, Event, 0),
       maps:get(game_id, Data)]).
