%% @doc Projects game_initiated_v1 into the games table.
%%
%% Idempotent by construction: INSERT OR REPLACE keyed on the stream id, the
%% row carrying the applied position (event_id, version). The status label is
%% computed HERE, from the event's own status integer, and never by a client.
-module(game_initiated_v1_to_sqlite_games).

-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, replay_policy/0]).

interested_in() -> [<<"game_initiated_v1">>].

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
    {Initial, Increment} = maps:get(time_control, Data),
    Seats = maps:get(seats, Data),
    Clocks = maps:get(clocks, Data),
    Status = maps:get(status, Data),
    game_read_model_store:exec(
      "INSERT OR REPLACE INTO games"
      " (game_id, protocol, initial_ms, increment_ms, white_node_id,"
      "  black_node_id, position, to_move, ply, white_clock_ms,"
      "  black_clock_ms, status, status_label, initiator, archive_reason,"
      "  initiated_at, archived_at, event_id, version)"
      " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, NULL, ?, ?)",
      [maps:get(game_id, Data),
       maps:get(protocol, Data),
       Initial,
       Increment,
       maps:get(white, Seats),
       maps:get(black, Seats),
       maps:get(position, Data),
       maps:get(to_move, Data),
       maps:get(ply, Data),
       maps:get(white, Clocks),
       maps:get(black, Clocks),
       Status,
       game_status:to_string(Status),
       maps:get(initiator_node_id, Data),
       maps:get(at_ms, Data),
       maps:get(event_id, Event),
       maps:get(version, Event, 0)]).
