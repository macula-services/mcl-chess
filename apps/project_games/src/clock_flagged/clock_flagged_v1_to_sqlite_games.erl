%% @doc Projects clock_flagged_v1 into the games row: whose clock ran out, and
%% the clocks as the flag recorded them.
%%
%% An UPDATE, like every projection after the birth: the game already exists. The
%% end event of the same command follows immediately and writes the outcome, so
%% this row is only readable in the state it describes if a reader arrives between
%% the two, and then it is right: the game is still `started' and a clock is at
%% zero.
%%
%% `flagged_node_id' is a column of its own rather than a status bit: a flag is a
%% moment in a game, not a state the game rests in, and the end follows at once.
-module(clock_flagged_v1_to_sqlite_games).

-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, replay_policy/0]).

interested_in() -> [<<"clock_flagged_v1">>].

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
    #{white := WhiteMs, black := BlackMs} = maps:get(clocks, Data),
    game_read_model_store:exec(
      "UPDATE games SET white_clock_ms = ?, black_clock_ms = ?,"
      " flagged_node_id = ?, event_id = ?, version = ? WHERE game_id = ?",
      [WhiteMs,
       BlackMs,
       maps:get(player_node_id, Data),
       maps:get(event_id, Event),
       maps:get(version, Event, 0),
       maps:get(game_id, Data)]).
