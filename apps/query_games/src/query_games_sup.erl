%% @doc Supervises the QRY division: the sqlite store the desks read.
-module(query_games_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SqlitePath = filename:join(data_dir(), "mcl_chess.sqlite3"),
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
          [#{id => game_query_store,
             start => {game_query_store, start_link, [SqlitePath]},
             restart => permanent,
             shutdown => 5000,
             type => worker,
             modules => [game_query_store]}]}}.

%% The same variable the facade's store directory reads, with the same
%% default; a test in the facade pins the three together so they cannot drift.
data_dir() ->
    chosen(os:getenv("MCL_DATA_DIR")).

chosen(false) -> "/tmp/mcl_chess";
chosen("") -> "/tmp/mcl_chess";
chosen(Path) -> Path.
