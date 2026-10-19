%% @doc Shared store boot for the desk suites and the walking skeleton.
%%
%% Opens the same store a running node has, through the same call the facade's
%% boot makes (reckon_db_sup:start_store/1 with the service's store config),
%% so a test's dispatch, aggregate, event and stream are the ones production
%% sees, and the whole slice runs against the real reckon-db rather than a
%% double.
-module(play_games_test_store).

-export([start/0, stop/1, store/0, strings/1, stream/1]).

-include_lib("reckon_db/include/reckon_db.hrl").
-include_lib("reckon_gater/include/reckon_gater_types.hrl").

-spec store() -> atom().
store() -> mcl_chess_store.

-spec start() -> {string(), [atom()]}.
start() ->
    Dir = filename:join(["/tmp", "mcl_chess_tests",
                         integer_to_list(erlang:unique_integer([positive]))]),
    %% evoq may already be loaded in the eunit VM; either way it must accept
    %% the env below.
    load_app(evoq),
    [ok = application:set_env(evoq, K, V)
     || {K, V} <- [{event_store_adapter, reckon_evoq_adapter},
                   {subscription_adapter, reckon_evoq_adapter},
                   {snapshot_store_adapter, reckon_evoq_adapter},
                   {store_id, store()}]],
    {ok, Started} = application:ensure_all_started([reckon_db, evoq, reckon_evoq]),
    ok = start_store(Dir),
    {Dir, Started}.

%% Idempotent: an earlier suite in the same eunit VM may have started this
%% store already, and a store that is up is what the test needs.
start_store(Dir) ->
    started(reckon_db_sup:start_store(
              #store_config{store_id = store(),
                            data_dir = filename:join(Dir, "store"),
                            mode = single})).

started({ok, _Pid}) -> ok;
started({error, {already_started, _Pid}}) -> ok;
started({error, Reason}) -> error({store_start_failed, Reason}).

-spec stop({string(), [atom()]}) -> ok.
stop({Dir, Started}) ->
    [application:stop(App) || App <- lists:reverse(Started)],
    file:del_dir_r(Dir).

%% @doc The event types on a game's stream, in order. The smallest assertion
%% that says "this is what the store holds".
-spec strings(binary()) -> [binary()].
strings(GameId) ->
    [E#event.event_type || E <- stream(GameId)].

-spec stream(binary()) -> [#event{}].
stream(GameId) ->
    events(reckon_db_streams:read(store(), GameId, 0, 1000, forward)).

events({ok, Events}) -> Events;
events({error, {stream_not_found, _}}) -> [];
events({error, _} = Error) -> error(Error).

load_app(App) ->
    case application:load(App) of
        ok -> ok;
        {error, {already_loaded, App}} -> ok
    end.
