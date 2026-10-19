%% @doc The clock of one game: the process manager that flags a player who runs
%% out of time, and catches up the sequences a crash left half done.
%%
%% One instance per game, named by the game id. A timed game is start and stop
%% clocks rather than one countdown, so the instance keeps exactly one deadline:
%% the one for the side to move. Every event that hands the turn over replaces it
%% and cancels the timer it replaced.
%%
%% THE DEADLINE IS RECOMPUTED FROM THE EVENT, NOT FROM A WALL CLOCK. Each event
%% carries the clocks after it and the service's own `at_ms', so the deadline is
%% `at_ms' plus what the side to move has left. The one thing a replay cannot
%% reproduce is a timer firing, which is why the timer is only a trigger: the
%% durable fact is the `clock_flagged_v1' the flag command appends.
%%
%% TWO SEQUENCES MUST ALWAYS FINISH, AND THIS IS WHERE THAT IS ENFORCED:
%%
%% - a claim that fills the second seat, with no `game_started_v1' after it
%% - a `clock_flagged_v1' with no `game_ended_v1' after it
%%
%% Each is a window in which the node can die between the event and the policy's
%% dispatch. The policies close both within milliseconds of a healthy node; this
%% instance is what closes them when the node was not healthy, because its
%% instances are rebuilt from the log on the next boot (`replaying => true') and
%% a rebuilt instance that still sees a gap dispatches the missing command. The
%% check is a delayed self-message rather than an immediate one so that a live
%% game is not double-dispatched: by the time it fires, the policy's command has
%% landed and the gap is gone. Both commands are idempotent, so a late one is
%% refused rather than harmful.
%%
%% The service never pokes an agent: nobody is asked whether they are still
%% there, the clock decides on its own (design of record, open question 3).
-module(game_clock_pm).

-behaviour(evoq_process_manager).

-export([interested_in/0, correlate/2, handle/3, apply/2, handle_info/2, init/1]).
-export([catch_up_ms/0]).

%% How long to wait before asking whether a sequence really is unfinished. Long
%% enough that a policy on a healthy node has dispatched and its command has been
%% projected, short enough that a game whose player is waiting does not wait on
%% it. Configuration, so a test can shorten it.
-define(DEFAULT_CATCH_UP_MS, 2000).

-type state() :: #{game_id := binary() | undefined,
                   seats := #{white := binary(), black := binary()},
                   started := boolean(),
                   flagged := boolean(),
                   ended := boolean(),
                   deadline_ms := integer() | undefined,
                   colour := white | black | undefined,
                   timer := reference() | undefined,
                   catch_up := reference() | undefined}.

-export_type([state/0]).

-spec init(binary()) -> {ok, state()}.
init(ProcessId) ->
    {ok, #{game_id => ProcessId,
           seats => #{white => <<>>, black => <<>>},
           started => false,
           flagged => false,
           ended => false,
           deadline_ms => undefined,
           colour => undefined,
           timer => undefined,
           catch_up => undefined}}.

%% @doc How long the instance waits before it catches up an unfinished sequence.
-spec catch_up_ms() -> non_neg_integer().
catch_up_ms() ->
    application:get_env(play_games, catch_up_ms, ?DEFAULT_CATCH_UP_MS).

-spec interested_in() -> [binary()].
interested_in() ->
    [<<"seat_claimed_v1">>, <<"game_started_v1">>, <<"move_played_v1">>,
     <<"clock_flagged_v1">>, <<"game_ended_v1">>, <<"game_archived_v1">>].

%% @doc Route each event to its game's instance, and stop the instance at the end
%% or at the archive: an archived game is dead, and an instance that outlived it
%% would be one nobody can reach with an event again.
%%
%% Every routing answer is total: the router calls this inside its own process and
%% a crash here would silence every process manager on the node (evoq#9), so an
%% event without a game id is `false' rather than an error.
-spec correlate(map(), map()) -> {start | continue | stop, binary()} | false.
correlate(#{event_type := Type} = Event, _Metadata)
  when Type =:= <<"game_ended_v1">>; Type =:= <<"game_archived_v1">> ->
    stopping(game_id(Event));
correlate(#{event_type := _Type} = Event, _Metadata) ->
    continuing(game_id(Event));
correlate(_Event, _Metadata) ->
    false.

stopping(undefined) -> false;
stopping(GameId) -> {stop, GameId}.

continuing(undefined) -> false;
continuing(GameId) -> {continue, GameId}.

%% @doc Fold the event, move the deadline if it moved, and keep an unfinished
%% sequence pending.
-spec handle(state(), map(), map()) -> {ok, state()}.
handle(State, Event, _Metadata) ->
    {ok, pending(timed(folded(State, Event), Event))}.

%% @doc The state is the timers, and handle/3 is where they are computed from the
%% event. Folding here as well would schedule the same deadline twice: the
%% runtime calls apply/2 on the state handle/3 returned.
-spec apply(state(), map()) -> state().
apply(State, _Event) -> State.

%% @doc A deadline arriving, or the moment to ask whether a sequence finished.
%%
%% Both messages name what they were scheduled for, so a message from a turn that
%% has since been handed over is answered with silence: the move bought the time.
-spec handle_info(term(), state()) ->
          {noreply, state()} | {noreply, state(), [tuple()]}.
handle_info({game_clock_deadline, GameId, Deadline, Colour}, State) ->
    fired(matches(State, GameId, Deadline, Colour), GameId, Colour, State);
handle_info({game_clock_catch_up, GameId}, State) ->
    caught_up(maps:get(game_id, State) =:= GameId, State);
handle_info(_Info, State) ->
    {noreply, State}.

matches(State, GameId, Deadline, Colour) ->
    maps:get(game_id, State) =:= GameId
        andalso maps:get(deadline_ms, State) =:= Deadline
        andalso maps:get(colour, State) =:= Colour.

fired(true, GameId, Colour, State) ->
    Player = seat(State, Colour),
    {noreply, rearmed(State), [flag_command(GameId, Player)]};
fired(false, _GameId, _Colour, State) ->
    {noreply, State}.

%% THE DEADLINE IS NOT FORGOTTEN WHEN IT FIRES. Dispatching the flag can fail
%% (a store timeout, a Ra leader change during a station roll) and evoq's PM
%% runtime only logs a failed dispatch: it retries nothing and there is no event
%% to re-arm the clock, so a cleared deadline would leave a player who is out of
%% time in a game that never ends. The instance keeps the deadline and asks again
%% after `catch_up_ms', and the event that settles it is what clears it: the
%% flag itself, a move that bought the time, or the end. A retry nobody needs any
%% more is refused by the desk's own guards, exactly as a late catch-up is.
rearmed(State) ->
    GameId = maps:get(game_id, State),
    Deadline = maps:get(deadline_ms, State),
    Colour = maps:get(colour, State),
    Settled = cancel(State),
    Timer = erlang:send_after(catch_up_ms(), self(),
                              {game_clock_deadline, GameId, Deadline, Colour}),
    Settled#{timer => Timer}.

caught_up(true, State) ->
    dispatched(cleared(State), catch_up_commands(State));
caught_up(false, State) ->
    {noreply, State}.

dispatched(State, []) ->
    {noreply, State};
dispatched(State, Commands) ->
    {noreply, State, Commands}.

%%====================================================================
%% Folding
%%====================================================================

folded(State, #{event_type := <<"seat_claimed_v1">>} = Event) ->
    State#{seats => maps:get(seats, data_of(Event), maps:get(seats, State))};
folded(State, #{event_type := <<"game_started_v1">>} = Event) ->
    Data = data_of(Event),
    State#{seats => #{white => maps:get(white_node_id, Data),
                      black => maps:get(black_node_id, Data)},
           started => true};
folded(State, #{event_type := <<"clock_flagged_v1">>}) ->
    State#{flagged => true};
folded(State, #{event_type := <<"game_ended_v1">>}) ->
    State#{ended => true};
folded(State, _Event) ->
    State.

%%====================================================================
%% Scheduling
%%====================================================================

%% A start or a move hands the clock to the side now to move.
timed(State, #{event_type := Type} = Event)
  when Type =:= <<"game_started_v1">>; Type =:= <<"move_played_v1">> ->
    schedule(State, data_of(Event));
%% The flag, the end and the archive all stop the clock: after any of them there
%% is no turn left to time.
timed(State, #{event_type := Type})
  when Type =:= <<"clock_flagged_v1">>; Type =:= <<"game_ended_v1">>;
       Type =:= <<"game_archived_v1">> ->
    stop_clock(State);
timed(State, _Event) ->
    State.

schedule(State, Data) ->
    At = maps:get(at_ms, Data),
    Clocks = maps:get(clocks, Data),
    Colour = colour(maps:get(to_move, Data)),
    Deadline = At + maps:get(Colour, Clocks),
    Settled = cancel(State),
    Timer = erlang:send_after(max(0, Deadline - erlang:system_time(millisecond)),
                              self(), {game_clock_deadline, maps:get(game_id, State),
                                       Deadline, Colour}),
    Settled#{deadline_ms => Deadline, colour => Colour, timer => Timer}.

%% Both the timer and the deadline it was for: an instance that kept the
%% deadline would answer a stale message with a second flag.
stop_clock(State) ->
    (cancel(State))#{deadline_ms => undefined, colour => undefined}.

cancel(#{timer := undefined} = State) ->
    State;
cancel(#{timer := Timer} = State) ->
    _ = erlang:cancel_timer(Timer),
    State#{timer => undefined}.

%%====================================================================
%% Catching up a sequence a crash left half done
%%====================================================================

%% Arm the follow-up only while something is unfinished, and drop it as soon as
%% the sequence completes: a live game arms and disarms one in the milliseconds
%% between the event and its policy's command.
pending(State) ->
    armed(unfinished(State), State).

unfinished(State) ->
    started_missing(State) orelse ended_missing(State).

started_missing(State) ->
    maps:get(started, State) =:= false
        andalso not lists:member(<<>>, maps:values(maps:get(seats, State))).

ended_missing(State) ->
    maps:get(flagged, State) =:= true andalso maps:get(ended, State) =:= false.

armed(true, #{catch_up := undefined} = State) ->
    Ref = erlang:send_after(catch_up_ms(), self(),
                            {game_clock_catch_up, maps:get(game_id, State)}),
    State#{catch_up => Ref};
armed(true, State) ->
    State;
armed(false, State) ->
    cleared(State).

cleared(#{catch_up := undefined} = State) ->
    State;
cleared(#{catch_up := Ref} = State) ->
    _ = erlang:cancel_timer(Ref),
    State#{catch_up => undefined}.

%% The commands the unfinished sequences are waiting for, in the order the game
%% needs them. Both are dispatched through the aggregate's own guards, so a gap
%% that closed while the message was in flight is refused and logged by the desk,
%% never double-applied.
catch_up_commands(State) ->
    started_command(State) ++ ended_command(State).

started_command(State) ->
    case started_missing(State) of
        true -> [start_command(maps:get(game_id, State))];
        false -> []
    end.

ended_command(State) ->
    case ended_missing(State) of
        true -> [end_command(maps:get(game_id, State))];
        false -> []
    end.

%% The claim that filled the second seat: the start the seats-full policy would
%% have dispatched, had the node been alive to dispatch it.
start_command(GameId) ->
    {ok, Cmd} = start_game_v1:new(#{game_id => GameId}),
    evoq_command:new(start_game_v1, game_aggregate, GameId,
                     start_game_v1:to_map(Cmd),
                     #{timestamp => erlang:system_time(millisecond)}).

%% The flag with no end after it. The decision is the policy's own: a forfeit
%% that `end_game' re-judges against the position, so a game left mated by a
%% crash ends checkmate and names the winner from the record.
end_command(GameId) ->
    {ok, Cmd} = end_game_v1:new(#{game_id => GameId, outcome => forfeit,
                                  reason => clock_flag}),
    evoq_command:new(end_game_v1, game_aggregate, GameId,
                     end_game_v1:to_map(Cmd),
                     #{timestamp => erlang:system_time(millisecond)}).

%% The command the deadline exists for. It names the player as well as the game,
%% and the desk checks that it is still that player's turn and that their clock
%% really is out: a deadline can fire a moment after a move landed.
flag_command(GameId, Player) ->
    {ok, Cmd} = flag_clock_v1:new(#{game_id => GameId, player_node_id => Player}),
    evoq_command:new(flag_clock_v1, game_aggregate, GameId,
                     flag_clock_v1:to_map(Cmd),
                     #{timestamp => erlang:system_time(millisecond)}).

%%====================================================================
%% Reading the events
%%====================================================================

seat(State, Colour) ->
    maps:get(Colour, maps:get(seats, State), <<>>).

colour(<<"w">>) -> white;
colour(<<"b">>) -> black.

data_of(#{data := Data}) when is_map(Data) -> Data;
data_of(Event) -> Event.

game_id(#{data := Data}) when is_map(Data) -> maps:get(game_id, Data, undefined);
game_id(#{game_id := GameId}) -> GameId;
game_id(_Event) -> undefined.
