%% @doc The retention of one ended game: the process manager that archives it
%% once the window has passed.
%%
%% One instance per game, named by the game id, created by `game_ended_v1' and
%% stopped by `game_archived_v1'. It holds one deadline: `at_ms' of the end plus
%% the retention window. A game withdrawn before it started never reaches this
%% instance, because a withdraw before play archives itself.
%%
%% THE WINDOW IS CONFIGURATION, NOT A CONSTANT: `play_games' application
%% environment, `game_retention_ms', default 24 hours. Archiving a game by hand
%% is not a slice, so the number lives where an operator can change it.
%%
%% Replay rebuilds pending archives from the events' own `at_ms' rather than
%% re-archiving blindly, exactly as the clock does: an ended game whose window
%% has passed by the time the node boots is archived once, when its rebuilt
%% deadline fires, and a game still inside its window waits out what is left.
-module(game_retention_pm).

-behaviour(evoq_process_manager).

-export([interested_in/0, correlate/2, handle/3, apply/2, handle_info/2, init/1]).
-export([window_ms/0]).

%% A day. Long enough that an agent, its operator or a reviewer can still read a
%% finished game, short enough that the store does not keep every game forever
%% (mcl-chess#1, open question 2).
-define(DEFAULT_RETENTION_MS, 86400000).

-type state() :: #{game_id := binary() | undefined,
                   deadline_ms := integer() | undefined,
                   timer := reference() | undefined}.

-export_type([state/0]).

-spec init(binary()) -> {ok, state()}.
init(ProcessId) ->
    {ok, #{game_id => ProcessId, deadline_ms => undefined, timer => undefined}}.

%% @doc The retention window in milliseconds.
-spec window_ms() -> non_neg_integer().
window_ms() ->
    application:get_env(play_games, game_retention_ms, ?DEFAULT_RETENTION_MS).

-spec interested_in() -> [binary()].
interested_in() ->
    [<<"game_ended_v1">>, <<"game_archived_v1">>].

%% @doc Every routing answer is total: a crash in this callback would silence
%% every process manager on the node (evoq#9).
-spec correlate(map(), map()) -> {start | continue | stop, binary()} | false.
correlate(#{event_type := <<"game_archived_v1">>} = Event, _Metadata) ->
    stopping(game_id(Event));
correlate(#{event_type := _Type} = Event, _Metadata) ->
    continuing(game_id(Event));
correlate(_Event, _Metadata) ->
    false.

stopping(undefined) -> false;
stopping(GameId) -> {stop, GameId}.

continuing(undefined) -> false;
continuing(GameId) -> {continue, GameId}.

-spec handle(state(), map(), map()) -> {ok, state()}.
handle(State, #{event_type := <<"game_ended_v1">>} = Event, _Metadata) ->
    {ok, schedule(State, maps:get(at_ms, data_of(Event)))};
handle(State, #{event_type := <<"game_archived_v1">>}, _Metadata) ->
    {ok, stop(State)};
handle(State, _Event, _Metadata) ->
    {ok, State}.

%% @doc The state is the timer, computed in handle/3 from the event: folding it
%% here as well would schedule the same deadline twice.
-spec apply(state(), map()) -> state().
apply(State, _Event) -> State.

-spec handle_info(term(), state()) ->
          {noreply, state()} | {noreply, state(), [tuple()]}.
handle_info({game_retention_expired, GameId, Deadline}, State) ->
    fired(matches(State, GameId, Deadline), GameId, State);
handle_info(_Info, State) ->
    {noreply, State}.

matches(State, GameId, Deadline) ->
    maps:get(game_id, State) =:= GameId
        andalso maps:get(deadline_ms, State) =:= Deadline.

fired(true, GameId, State) ->
    {noreply, rearmed(State), [archive_command(GameId)]};
fired(false, _GameId, State) ->
    {noreply, State}.

%% THE SAME RULE AS THE CLOCK'S: a failed dispatch is only logged by evoq's PM
%% runtime, so the deadline is kept and asked again rather than cleared. What
%% clears it is `game_archived_v1', the event that says the death slice ran. A
%% game therefore outlives its window only while the store refuses the write.
rearmed(State) ->
    GameId = maps:get(game_id, State),
    Deadline = maps:get(deadline_ms, State),
    Settled = cancel(State),
    Timer = erlang:send_after(retry_ms(), self(),
                              {game_retention_expired, GameId, Deadline}),
    Settled#{timer => Timer}.

%% The interval a failed archive is tried again at. The clock's own setting, so
%% an operator has one number to reason about, not two.
retry_ms() ->
    game_clock_pm:catch_up_ms().

archive_command(GameId) ->
    {ok, Cmd} = archive_game_v1:new(#{game_id => GameId}),
    evoq_command:new(archive_game_v1, game_aggregate, GameId,
                     archive_game_v1:to_map(Cmd),
                     #{timestamp => erlang:system_time(millisecond)}).

%%====================================================================
%% Scheduling
%%====================================================================

schedule(State, EndedAt) ->
    Deadline = EndedAt + window_ms(),
    Settled = cancel(State),
    Timer = erlang:send_after(max(0, Deadline - erlang:system_time(millisecond)),
                              self(), {game_retention_expired, maps:get(game_id, State),
                                       Deadline}),
    Settled#{deadline_ms => Deadline, timer => Timer}.

%% Both the timer and the deadline it was for, so a stale message asks for
%% nothing.
stop(State) ->
    (cancel(State))#{deadline_ms => undefined}.

cancel(#{timer := undefined} = State) ->
    State;
cancel(#{timer := Timer} = State) ->
    _ = erlang:cancel_timer(Timer),
    State#{timer => undefined}.

data_of(#{data := Data}) when is_map(Data) -> Data;
data_of(Event) -> Event.

game_id(#{data := Data}) when is_map(Data) -> maps:get(game_id, Data, undefined);
game_id(#{game_id := GameId}) -> GameId;
game_id(_Event) -> undefined.
