%% @doc The withdraw_game capability's handler: the wire to the desk.
%%
%% The caller is the node id macula verified on the call, platform-injected
%% as `caller'. A body naming a different node is not read: the initiator
%% check is against the wire, never against a claim.
%%
%% The request shape: #{<<"game_id">> => GameId}. The reply is the archived
%% game state, or #{<<"error">> => R}.
-module(withdraw_game_responder_v1).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

-spec init([]) -> {ok, undefined}.
init([]) ->
    {ok, undefined}.

-spec handle_request(term(), undefined) -> {reply, term(), undefined}.
handle_request(Payload, State) ->
    {reply, withdraw(Payload), State}.

withdraw(Payload) when is_map(Payload) ->
    withdrawn(withdraw_game_api:handle(request(Payload)));
withdraw(_) ->
    #{<<"error">> => <<"invalid_request">>}.

withdrawn({ok, _Version, _Events, View}) -> View;
withdrawn({error, Reason}) -> #{<<"error">> => reason(Reason)}.

request(Payload) ->
    #{game_id => maps:get(<<"game_id">>, Payload, undefined),
      caller => maps:get(<<"caller">>, Payload, <<>>)}.

reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason(Reason) when is_binary(Reason) -> Reason;
reason(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).
