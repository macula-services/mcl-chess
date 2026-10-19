%% @doc Supervises the CMD division's own processes.
%%
%% Aggregates are started on demand by evoq's own partition supervisors when
%% a command targets them; they never appear here. What lives here are the
%% things that subscribe to events: one mesh emitter per event type, each an
%% evoq_event_handler child.
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
          [%% Policies first among the subscribers: the seats-full policy turns a
           %% second claim into a start, and it must be listening before any
           %% emitter is (the emitters are the observable half, not the rule).
           handler(on_seat_claimed_v1_maybe_start_game),
           %% The end policy sits beside the start policy and for the same
           %% reason: the rule that a terminal position ends the game must be
           %% listening before the emitters that publish the move are.
           handler(on_move_played_v1_maybe_end_game),
           handler(emit_game_initiated_v1_to_mesh),
           handler(emit_seat_claimed_v1_to_mesh),
           handler(emit_seat_refused_v1_to_mesh),
           handler(emit_game_started_v1_to_mesh),
           handler(emit_move_played_v1_to_mesh),
           handler(emit_move_refused_v1_to_mesh),
           handler(emit_game_ended_v1_to_mesh),
           handler(emit_game_archived_v1_to_mesh)]}}.

handler(Module) ->
    #{id => Module,
      start => {evoq_event_handler, start_link, [Module, #{}]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [evoq_event_handler]}.
