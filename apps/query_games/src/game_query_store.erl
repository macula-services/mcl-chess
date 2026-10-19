%% @doc The QRY division's sqlite store: one gen_server owning one esqlite
%% connection.
%%
%% READ-ONLY BY API: only q/2 is exposed, so a query desk cannot write and a
%% write path can never slip into the read division. The schema itself is
%% owned by the PRJ division (game_read_model_store:schema/0); this process
%% opens the same file and assumes that schema exists. A schema-contract test
%% pins the columns these desks select to the columns PRJ declares, so the
%% two sides cannot drift apart silently.
-module(game_query_store).

-behaviour(gen_server).

-export([start_link/1, q/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    conn :: esqlite3:esqlite3()
}).

-spec start_link(string()) -> {ok, pid()} | {error, term()}.
start_link(SqlitePath) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, SqlitePath, []).

%% @doc One parameterised read: rows as lists of cells in SELECT order, or
%% {error, Reason}, which the desks surface as {error, {store_error, _}}.
-spec q(string(), list()) -> [list()] | {error, term()}.
q(Sql, Args) ->
    gen_server:call(?MODULE, {q, Sql, Args}, 5000).

%%====================================================================
%% gen_server
%%====================================================================

init(SqlitePath) ->
    ok = filelib:ensure_dir(SqlitePath),
    case esqlite3:open(SqlitePath) of
        {ok, Conn} ->
            {ok, #state{conn = Conn}};
        {error, Reason} ->
            {stop, {open_failed, Reason}}
    end.

handle_call({q, Sql, Args}, _From, #state{conn = Conn} = State) ->
    {reply, esqlite3:q(Conn, Sql, Args), State};
handle_call(ping, _From, State) ->
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
