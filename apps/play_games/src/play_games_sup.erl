%% @doc Supervises the CMD division's own processes.
%%
%% Aggregates are started on demand by evoq's own partition supervisors when
%% a command targets them; they never appear here. What lives here are the
%% things that subscribe to events: one mesh emitter per event type, each an
%% evoq_event_handler child, the policies that end and archive a game, and the
%% registrar that hands this division's process managers to evoq's PM router.
%%
%% The emitters are started even when the node has no mesh pool: an emitter
%% with no pool returns an error, evoq's retry machinery owns redelivery, and
%% a node that joins the mesh later publishes then. Starting them
%% conditionally would mean a service whose facts silently never go out.
-module(play_games_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
          [registrar(),
           %% Policies first among the subscribers: each turns an event into the
           %% command that must follow it, and they must be listening before the
           %% emitters are (the emitters are the observable half, not the rule).
           handler(on_seat_claimed_v1_maybe_start_game),
           handler(on_move_played_v1_maybe_end_game),
           handler(on_clock_flagged_v1_maybe_end_game),
           handler(emit_game_initiated_v1_to_mesh),
           handler(emit_seat_claimed_v1_to_mesh),
           handler(emit_seat_refused_v1_to_mesh),
           handler(emit_game_started_v1_to_mesh),
           handler(emit_move_played_v1_to_mesh),
           handler(emit_move_refused_v1_to_mesh),
           handler(emit_clock_flagged_v1_to_mesh),
           handler(emit_game_ended_v1_to_mesh),
           handler(emit_game_archived_v1_to_mesh)]}}.

%% The process managers (the game's clock, the retention of an ended game) are
%% registered here rather than started: evoq's PM instance supervisor owns their
%% processes, and the registrar is what keeps them registered across a restart of
%% evoq's router.
registrar() ->
    #{id => play_games_pm_registrar,
      start => {play_games_pm_registrar, start_link, []},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [play_games_pm_registrar]}.

handler(Module) ->
    #{id => Module,
      start => {evoq_event_handler, start_link, [Module, #{}]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [evoq_event_handler]}.
