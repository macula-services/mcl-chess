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
          [handler(emit_game_initiated_v1_to_mesh),
           handler(emit_game_archived_v1_to_mesh)]}}.

handler(Module) ->
    #{id => Module,
      start => {evoq_event_handler, start_link, [Module, #{}]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [evoq_event_handler]}.
