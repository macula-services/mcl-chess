%% @doc Registers this division's process managers with evoq's PM router, and
%% registers them again if the router restarts.
%%
%% `evoq_process_manager:start/2' only calls `evoq_pm_router:register_pm/1' and
%% answers `ok' with no process of its own, so there is nothing to put under a
%% supervisor directly. This child is that: it owns the registrations for the
%% division, and it watches the router.
%%
%% WHY THE WATCH. Registrations live in the router's memory, so a router restart
%% comes back with none of them and every process manager on the node stays
%% silent (evoq#9). For this division that means no clock ever flags a player and
%% no ended game is ever archived: a silence nobody would notice until a game
%% hung. Re-registering is the whole remedy, and it is cheap.
-module(play_games_pm_registrar).

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% The process managers this division runs, one entry each.
-define(PMS, [game_clock_pm, game_retention_pm]).

-define(ROUTER, evoq_pm_router).

%% How long to wait before asking again whether the router is back. The router is
%% restarted by evoq's own supervisor, so this is a short wait, not a policy.
-define(RETRY_MS, 1000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, registered(#{router => watch()})}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, _Pid, _Reason}, #{router := Ref} = State) ->
    %% The router is gone: nothing is registered until it is back, and it may not
    %% be back yet when this runs, so ask again shortly rather than crash.
    erlang:send_after(?RETRY_MS, self(), register),
    {noreply, State#{router => undefined}};
handle_info(register, State) ->
    {noreply, registered(State#{router => watch()})};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% Register every PM, when the router is there to take them.
registered(State) ->
    case whereis(?ROUTER) of
        undefined -> ok;
        _Pid -> [ok = evoq_process_manager:start(PM, #{}) || PM <- ?PMS]
    end,
    State.

%% Watching a name that is not registered produces a DOWN with reason `noproc'
%% immediately, which is exactly the retry this needs.
watch() ->
    erlang:monitor(process, ?ROUTER).
