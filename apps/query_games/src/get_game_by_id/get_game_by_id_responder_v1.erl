%% @doc The get_game_by_id capability's handler: the wire to the query desk.
%%
%% Anyone may read a game: this is observability, not matchmaking. The
%% request shape is #{<<"game_id">> => GameId}; the reply is the game, or
%% #{<<"error">> => <<"not_found">>}.
-module(get_game_by_id_responder_v1).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

-spec init([]) -> {ok, undefined}.
init([]) ->
    {ok, undefined}.

-spec handle_request(term(), undefined) -> {reply, term(), undefined}.
handle_request(Payload, State) ->
    {reply, answer(Payload), State}.

answer(Payload) when is_map(Payload) ->
    answered(get_game_by_id:find(maps:get(<<"game_id">>, Payload, undefined)));
answer(_) ->
    #{<<"error">> => <<"invalid_request">>}.

answered({ok, Game}) -> Game;
answered({error, not_found}) -> #{<<"error">> => <<"not_found">>};
answered({error, missing_game_id}) -> #{<<"error">> => <<"missing_game_id">>};
%% A store error is ours, not the caller's: it is named, and its detail stays
%% in the log rather than going out over the wire.
answered({error, {store_error, _}}) -> #{<<"error">> => <<"store_error">>}.
