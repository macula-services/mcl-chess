%% @doc The resign_game capability's handler: the wire to the desk.
%%
%% THE CALLER IS THE RESIGNER. `caller' arrives platform-injected, over any
%% same-named key the body sent, so it is the node id macula verified and not a
%% claim.
%%
%% The request shape: #{<<"game_id">> => GameId}. The reply is the game state
%% the resignation produced, with `<<"outcome">>' and `<<"winner">>' naming what
%% happened, or #{<<"error">> => R}.
-module(resign_game_responder_v1).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

-spec init([]) -> {ok, undefined}.
init([]) ->
    {ok, undefined}.

-spec handle_request(term(), undefined) -> {reply, term(), undefined}.
handle_request(Payload, State) ->
    {reply, resigned(Payload), State}.

resigned(Payload) when is_map(Payload) ->
    answered(resign_game_api:handle(request(Payload)));
resigned(_) ->
    #{<<"error">> => <<"invalid_request">>}.

request(Payload) ->
    #{game_id => maps:get(<<"game_id">>, Payload, undefined),
      caller => maps:get(<<"caller">>, Payload, <<>>)}.

answered({ok, _Version, _Events, View}) ->
    View;
answered({error, Reason}) ->
    #{<<"error">> => reason(Reason)}.

reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason(Reason) when is_binary(Reason) -> Reason;
reason(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).
