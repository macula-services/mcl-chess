%% @doc The PRJ division's sqlite store: one gen_server owning one esqlite
%% connection.
%%
%% A NIF connection belongs to the process that opened it, so every write goes
%% through this process. The DDL lives here and ONLY here; the QRY division
%% reads the schema this module creates, and a schema-contract test pins the
%% columns QRY selects to the columns declared below.
%%
%% All writes are single statements. A projected event is one INSERT OR
%% REPLACE: atomic by itself and idempotent by construction, which is what
%% makes replays safe.
-module(game_read_model_store).

-behaviour(gen_server).

-export([start_link/1, exec/2, q/2, schema/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    conn :: esqlite3:esqlite3()
}).

%% @doc The schema, in creation order. The one place the read model's shape is
%% written down.
%%
%% Columns the mesh facts and the queries both need are kept apart on purpose:
%% `status' is the integer, `status_label' the name computed at projection
%% time, so a query never recomputes a label and never disagrees with the
%% record.
-spec schema() -> [string()].
schema() ->
    ["CREATE TABLE IF NOT EXISTS games ("
     " game_id       TEXT PRIMARY KEY,"
     " protocol      TEXT NOT NULL,"
     " initial_ms    INTEGER NOT NULL,"
     " increment_ms  INTEGER NOT NULL,"
     " white_node_id TEXT NOT NULL,"
     " black_node_id TEXT NOT NULL,"
     " position      TEXT NOT NULL,"
     " to_move       TEXT NOT NULL,"
     " ply           INTEGER NOT NULL,"
     " white_clock_ms INTEGER NOT NULL,"
     " black_clock_ms INTEGER NOT NULL,"
     " status        INTEGER NOT NULL,"
     " status_label  TEXT NOT NULL,"
     " initiator     TEXT NOT NULL,"
     " archive_reason TEXT,"
     " initiated_at  INTEGER NOT NULL,"
     " archived_at   INTEGER,"
     " event_id      TEXT NOT NULL,"
     " version       INTEGER NOT NULL)"].

-spec start_link(string()) -> {ok, pid()} | {error, term()}.
start_link(SqlitePath) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, SqlitePath, []).

%% @doc One parameterised write. Returns ok, or {error, Reason}: a projection
%% turns that into {error, {store_error, Reason}} and evoq's retry machinery
%% takes over, because a store error is a retryable condition, never a crash.
-spec exec(string(), list()) -> ok | {error, term()}.
exec(Sql, Args) ->
    gen_server:call(?MODULE, {exec, Sql, Args}, 5000).

%% @doc One parameterised read, for tests and inspection.
-spec q(string(), list()) -> [list()] | {error, term()}.
q(Sql, Args) ->
    gen_server:call(?MODULE, {q, Sql, Args}, 5000).

%%====================================================================
%% gen_server
%%====================================================================

init(SqlitePath) ->
    ok = filelib:ensure_dir(SqlitePath),
    opened(esqlite3:open(SqlitePath)).

opened({ok, Conn}) ->
    schemed(Conn, create_schema(Conn, schema()));
opened({error, Reason}) ->
    {stop, {open_failed, Reason}}.

schemed(Conn, ok) ->
    {ok, #state{conn = Conn}};
schemed(_Conn, {error, Reason}) ->
    {stop, {schema_failed, Reason}}.

handle_call({exec, Sql, Args}, _From, #state{conn = Conn} = State) ->
    {reply, do_exec(Conn, Sql, Args), State};
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

%%====================================================================
%% Internal
%%====================================================================

create_schema(Conn, [Sql | Rest]) ->
    case esqlite3:exec(Conn, Sql) of
        ok -> create_schema(Conn, Rest);
        {error, Reason} -> {error, Reason}
    end;
create_schema(_Conn, []) ->
    ok.

do_exec(Conn, Sql, Args) ->
    case esqlite3:q(Conn, Sql, Args) of
        [] -> ok;
        {error, Reason} -> {error, Reason};
        Rows -> {error, {unexpected_rows, Rows}}
    end.
