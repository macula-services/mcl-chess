%% @doc The get_game_by_id capability's handler: the wire to the query desk.
%%
%% Anyone may read a game: this is observability, not matchmaking. The request
%% shape, as it arrives off the wire, is `game_id'. READ IT WITH mcl_om_wire,
%% NEVER WITH maps:get/3: on this wire every text key arrives as `{text, Bin}',
%% so a bare binary lookup never finds one and every read answers
%% `missing_game_id'. The reply is the game, in wire text (see mcl_chess_wire),
%% or #{<<"error">> => R}.
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
    answered(get_game_by_id:find(mcl_om_wire:field(game_id, Payload)));
answer(_) ->
    error_reply(<<"invalid_request">>).

answered({ok, Game}) -> mcl_chess_wire:to_wire(Game);
answered({error, not_found}) -> error_reply(<<"not_found">>);
answered({error, missing_game_id}) -> error_reply(<<"missing_game_id">>);
%% A store error is ours, not the caller's: it is named, and its detail stays
%% in the log rather than going out over the wire.
answered({error, {store_error, _}}) -> error_reply(<<"store_error">>).

error_reply(Reason) ->
    mcl_chess_wire:to_wire(#{<<"error">> => Reason}).
