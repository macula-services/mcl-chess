%% @doc Supervises the PRJ division: the sqlite read-model store and one
%% evoq_event_handler child per projection desk.
%%
%% A projection registers itself with evoq's event-type registry when it
%% starts; delivery comes from the store subscription the facade boots, so
%% this supervisor never touches the store or the adapter.
-module(project_games_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SqlitePath = filename:join(data_dir(), "mcl_chess.sqlite3"),
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
          [%% The store FIRST: a projection child crashing is restarted
           %% against a store that exists.
           #{id => game_read_model_store,
             start => {game_read_model_store, start_link, [SqlitePath]},
             restart => permanent,
             shutdown => 5000,
             type => worker,
             modules => [game_read_model_store]},
           %% ONE handler for all seven game events, so one cursor for the whole
           %% row. Since evoq 1.30 each handler has its own courier and delivery
           %% is ordered within a handler and NOT across them (evoq#30); one
           %% handler per event type therefore ordered nothing against the game's
           %% own events, and because each event owns columns no other event
           %% writes, a dropped older write lost those columns for good
           %% (mcl-chess#18). Do not split this back into one handler per event
           %% type: the ordering is what makes the row correct, not the guard.
           projection(game_lifecycle_to_games)]}}.

projection(Module) ->
    #{id => Module,
      start => {evoq_event_handler, start_link, [Module, #{}]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [evoq_event_handler]}.

%% The same variable the facade's store directory reads, with the same
%% default; a test in the facade pins the two together so they cannot drift.
data_dir() ->
    chosen(os:getenv("MCL_DATA_DIR")).

chosen(false) -> "/tmp/mcl_chess";
chosen("") -> "/tmp/mcl_chess";
chosen(Path) -> Path.
