%% @doc Projects a game's whole lifecycle into the games row: one handler, one
%% cursor, seven events.
%%
%% WHY ONE HANDLER AND NOT SEVEN. evoq gives every subscribed handler its own
%% courier process (evoq#30), so delivery is ordered *within* a handler and not
%% across handlers. One handler per event type therefore gives one cursor per
%% event type, and two events of the same game are projected in an order nobody
%% controls. The per-event version guard alone does not survive that: it decides
%% whether a write applies to the ROW, but each event owns COLUMNS no other event
%% writes - `started_at' only comes from a start, `flagged_node_id' only from a
%% flag, the outcome columns only from an end, `to_move' only from a move - so
%% dropping an older write whole loses those columns for good. A game whose end
%% was projected first could be archived with no outcome, or carry a mate's FEN
%% next to the mover who has already replied (mcl-chess#18, Uranus r=1).
%%
%% ONE CURSOR FIXES IT BY CONSTRUCTION: evoq orders delivery within a handler, so
%% every event of a game arrives here in stream order and no column is ever
%% skipped. What is left for the guard is a redelivery - the same event delivered
%% twice after a reconnect - which must not overwrite newer columns with older
%% ones. That is exactly what `AND version < ?' now means, and it is the only
%% thing it means.
%%
%% The birth (version 0) is still the only INSERT: it creates the row with
%% `ON CONFLICT(game_id) DO NOTHING', so a redelivered birth cannot rewrite a row
%% later events have carried forward. Every other event is an UPDATE, and an
%% UPDATE that matched nothing is a real fault - a delivery out of order, or a
%% row lost - so it is checked and returned as a store error for evoq to retry
%% rather than passing as success. The archive is the one exception: it stays a
%% plain UPDATE, because an archive is the last thing a stream says and a no-op
%% there costs nothing.
%%
%% Status labels are computed HERE, from the event's own status integer, never by
%% a client (philosophy/STATUS_LABELS_IN_PROJECTIONS.md).
-module(game_lifecycle_to_games).

-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, replay_policy/0]).

interested_in() ->
    [<<"game_initiated_v1">>,
     <<"seat_claimed_v1">>,
     <<"game_started_v1">>,
     <<"move_played_v1">>,
     <<"clock_flagged_v1">>,
     <<"game_ended_v1">>,
     <<"game_archived_v1">>].

replay_policy() -> deliver.

init(_Config) ->
    {ok, #{}}.

handle_event(EventType, Event, _Metadata, State) ->
    Data = maps:get(data, Event, Event),
    case write(EventType, Data, Event) of
        ok -> {ok, State};
        {error, Reason} -> {error, {store_error, Reason}}
    end.

%% One clause per event, so each event's SQL stays in its own function: this
%% dispatcher is the only place that knows the seven names.
write(<<"game_initiated_v1">>, Data, Event) -> born(Data, Event);
write(<<"seat_claimed_v1">>, Data, Event) -> seats_claimed(Data, Event);
write(<<"game_started_v1">>, Data, Event) -> started(Data, Event);
write(<<"move_played_v1">>, Data, Event) -> moved(Data, Event);
write(<<"clock_flagged_v1">>, Data, Event) -> flagged(Data, Event);
write(<<"game_ended_v1">>, Data, Event) -> ended(Data, Event);
write(<<"game_archived_v1">>, Data, Event) -> archived(Data, Event).

%% The birth: the only INSERT, and the only event that may create a row.
born(Data, Event) ->
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
      " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, NULL, ?, ?)"
      " ON CONFLICT(game_id) DO NOTHING",
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
       version(Event)]).

%% The seats, the status and its label. A claim only follows a birth, so this is
%% an UPDATE and a missing row is a fault.
seats_claimed(Data, Event) ->
    Seats = maps:get(seats, Data),
    Status = maps:get(status, Data),
    guarded(Data, Event,
            "UPDATE games SET white_node_id = ?, black_node_id = ?,"
            " status = ?, status_label = ?, event_id = ?, version = ?"
            " WHERE game_id = ? AND version < ?",
            [maps:get(white, Seats),
             maps:get(black, Seats),
             Status,
             game_status:to_string(Status),
             maps:get(event_id, Event),
             version(Event)]).

%% The holders by colour, the start, its status and the moment the game began.
%% The holders are written again even though a claim wrote them, because this
%% event is the authority on who is playing: a game that started with a seat map
%% that disagreed with its claims would show the disagreement rather than hide
%% it. `started_at' is the event's own `at_ms', the same clock reading the
%% per-game deadline is set from, so a reader of the row and a reader of the
%% clock agree on when the game began (mcl-chess#3).
started(Data, Event) ->
    Status = maps:get(status, Data),
    guarded(Data, Event,
            "UPDATE games SET white_node_id = ?, black_node_id = ?,"
            " status = ?, status_label = ?, started_at = ?, event_id = ?, version = ?"
            " WHERE game_id = ? AND version < ?",
            [maps:get(white_node_id, Data),
             maps:get(black_node_id, Data),
             Status,
             game_status:to_string(Status),
             maps:get(at_ms, Data),
             maps:get(event_id, Event),
             version(Event)]).

%% Two writes, both idempotent: the games row takes absolute values and the move
%% goes into `moves', keyed `(game_id, ply)', so a redelivered move replaces
%% itself rather than appending twice - which is why the move list is its own
%% table and not a text column grown by concatenation. If the second write fails
%% the handler returns a store error and evoq retries the event; the first write
%% has already set the same values. A move changes no flag, so the status label
%% it writes is the one the game already had, and this is still the right place
%% to compute it.
moved(Data, Event) ->
    Status = maps:get(status, Data),
    #{white := WhiteMs, black := BlackMs} = maps:get(clocks, Data),
    written(
      guarded(Data, Event,
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
               version(Event)]),
      fun() -> move_in(Data) end).

move_in(Data) ->
    game_read_model_store:exec(
      "INSERT OR REPLACE INTO moves (game_id, ply, uci) VALUES (?, ?, ?)",
      [maps:get(game_id, Data), maps:get(ply, Data), maps:get(move, Data)]).

%% Whose clock ran out, and the clocks as the flag recorded them.
%% `flagged_node_id' is a column of its own rather than a status bit: a flag is a
%% moment in a game, not a state the game rests in, and the end follows at once.
flagged(Data, Event) ->
    #{white := WhiteMs, black := BlackMs} = maps:get(clocks, Data),
    guarded(Data, Event,
            "UPDATE games SET white_clock_ms = ?, black_clock_ms = ?,"
            " flagged_node_id = ?, event_id = ?, version = ?"
            " WHERE game_id = ? AND version < ?",
            [WhiteMs,
             BlackMs,
             maps:get(player_node_id, Data),
             maps:get(event_id, Event),
             version(Event)]).

%% The outcome, the reason, who won, the final position and the clock state at
%% the end. A draw names no winner, and its `winner_node_id' column stays empty
%% rather than absent.
ended(Data, Event) ->
    Status = maps:get(status, Data),
    #{white := WhiteMs, black := BlackMs} = maps:get(clocks, Data),
    guarded(Data, Event,
            "UPDATE games SET position = ?, ply = ?, white_clock_ms = ?,"
            " black_clock_ms = ?, status = ?, status_label = ?, outcome = ?,"
            " end_reason = ?, winner_node_id = ?, ended_at = ?,"
            " event_id = ?, version = ? WHERE game_id = ? AND version < ?",
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
             version(Event)]).

%% The death slice. A plain UPDATE, unchecked: an archive is the last thing its
%% stream says, so a write that matches nothing has nothing to report.
archived(Data, Event) ->
    Status = maps:get(status, Data),
    game_read_model_store:exec(
      "UPDATE games SET status = ?, status_label = ?, archive_reason = ?,"
      " archived_at = ?, event_id = ?, version = ? WHERE game_id = ? AND version < ?",
      [Status,
       game_status:to_string(Status),
       maps:get(reason, Data),
       maps:get(at_ms, Data),
       maps:get(event_id, Event),
       version(Event),
       maps:get(game_id, Data),
       version(Event)]).

%%--------------------------------------------------------------------
%% Shared write shapes
%%--------------------------------------------------------------------

%% Every UPDATE after the birth is the same three steps: apply only when the row
%% is behind this event, and treat "matched no row" as a retryable fault rather
%% than as success. A projection that silently wrote nothing is how a read model
%% drifts from its stream.
guarded(Data, Event, Sql, Values) ->
    GameId = maps:get(game_id, Data),
    case game_read_model_store:exec(Sql, Values ++ [GameId, version(Event)]) of
        ok -> row_there(GameId);
        {error, _} = Error -> Error
    end.

row_there(GameId) ->
    case game_read_model_store:q("SELECT 1 FROM games WHERE game_id = ?",
                                 [GameId]) of
        [] -> {error, {no_row_for, GameId}};
        {error, Reason} -> {error, Reason};
        [_ | _] -> ok
    end.

%% A row write followed by a second table's write: the second only runs when the
%% first succeeded, and its failure is the handler's failure, so evoq retries the
%% event and the first write sets the same values again.
written(ok, Second) -> Second();
written({error, _} = Error, _Second) -> Error.

version(Event) -> maps:get(version, Event, 0).

%% The event stores an atom; the column is text, the same spelling a fact carries.
text(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
text(Value) -> Value.
