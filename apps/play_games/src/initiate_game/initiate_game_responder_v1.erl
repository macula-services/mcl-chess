%% @doc The initiate_game capability's handler: the wire to the desk.
%%
%% ATTRIBUTION IS BY THE WIRE, NEVER THE PAYLOAD. The initiator is the node
%% id macula verified on the call, which arrives platform-injected as
%% `caller'; a body that names someone else is not read at all.
%%
%% CONSENT IS A SEAT CLAIM, SO THE WIRE CANNOT SEAT ANYONE. A body that names
%% node ids under `seats' is not read: every call over the wire gives two
%% empty seats. Seating two agents who never agreed, and then letting the
%% clock forfeit them, is the harm this closes. Pre-assignment is the future
%% matchmaker's own path through the command, and it will need its own
%% authorization when it is built.
%%
%% The request shape, binary keys because it came off the wire:
%%
%%   #{<<"time_control">> => #{<<"initial_ms">> => N, <<"increment_ms">> => M}}
%%
%% The reply is the game state the event produced, or #{<<"error">> => R}.
-module(initiate_game_responder_v1).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

-spec init([]) -> {ok, undefined}.
init([]) ->
    {ok, undefined}.

-spec handle_request(term(), undefined) -> {reply, term(), undefined}.
handle_request(Payload, State) ->
    {reply, initiate(Payload), State}.

initiate(Payload) when is_map(Payload) ->
    initiated(initiate_game_api:handle(request(Payload)));
initiate(_) ->
    #{<<"error">> => <<"invalid_request">>}.

initiated({ok, _Version, _Events, View}) -> View;
initiated({error, Reason}) -> #{<<"error">> => reason(Reason)}.

%% The platform injects `caller' over any same-named key the caller sent, so
%% this is the verified node id and not a claim.
request(Payload) ->
    #{initiator => maps:get(<<"caller">>, Payload, <<>>),
      time_control => time_control(Payload)}.

time_control(#{<<"time_control">> := #{<<"initial_ms">> := Initial,
                                       <<"increment_ms">> := Increment}}) ->
    {Initial, Increment};
time_control(_) ->
    undefined.

%% Atoms are a service-internal detail; the wire carries text.
reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason(Reason) when is_binary(Reason) -> Reason;
reason(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).
