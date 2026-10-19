%% @doc The submit_move capability's handler: the wire to the desk.
%%
%% THE CALLER IS THE MOVER. `caller' arrives platform-injected, over any
%% same-named key the body sent, so it is the node id macula verified and not a
%% claim; there is no way to name a player in the body.
%%
%% The request shape: #{<<"game_id">> => GameId, <<"move">> => <<"e2e4">>}.
%% The reply is the game state the move produced — the position after it, whose
%% turn it is now, the clocks, the ply and the count the end rules read — or
%% #{<<"error">> => R}.
-module(submit_move_responder_v1).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

-spec init([]) -> {ok, undefined}.
init([]) ->
    {ok, undefined}.

-spec handle_request(term(), undefined) -> {reply, term(), undefined}.
handle_request(Payload, State) ->
    {reply, submit(Payload), State}.

submit(Payload) when is_map(Payload) ->
    answered(submit_move_api:handle(request(Payload)));
submit(_) ->
    #{<<"error">> => <<"invalid_request">>}.

request(Payload) ->
    #{game_id => maps:get(<<"game_id">>, Payload, undefined),
      caller => maps:get(<<"caller">>, Payload, <<>>),
      move => maps:get(<<"move">>, Payload, <<>>)}.

answered({ok, _Version, _Events, View}) ->
    View;
answered({error, Reason}) ->
    #{<<"error">> => reason(Reason)}.

reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason(Reason) when is_binary(Reason) -> Reason;
reason(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).
