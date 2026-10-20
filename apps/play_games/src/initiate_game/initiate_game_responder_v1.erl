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
%% The request shape, as it arrives off the wire:
%%
%%   the key `time_control', whose value carries `initial_ms' and `increment_ms'
%%
%% READ IT WITH mcl_om_wire, NEVER WITH maps:get/3. On this wire every text key
%% arrives as `{text, Bin}' and `caller' arrives under the atom key, so a bare
%% binary lookup finds neither and a handler that uses one sees an empty
%% request in production while its unit test, fed the shape it expected, stays
%% green. That is how 0.7.1 answered `invalid_params' to every real caller.
%%
%% The reply is the game state the event produced, in wire text (see
%% mcl_chess_wire), or #{<<"error">> => R}.
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
    error_reply(invalid_request).

initiated({ok, _Version, _Events, View}) -> mcl_chess_wire:to_wire(View);
initiated({error, Reason}) -> error_reply(Reason).

%% The platform injects `caller' over any same-named key the caller sent, so
%% this is the verified node id and not a claim.
request(Payload) ->
    #{initiator => mcl_chess_wire:caller(Payload),
      time_control => time_control(Payload)}.

time_control(Payload) ->
    Control = mcl_om_wire:field(time_control, Payload, #{}),
    control(mcl_om_wire:field(initial_ms, Control),
            mcl_om_wire:field(increment_ms, Control)).

control(Initial, Increment) when is_integer(Initial), is_integer(Increment) ->
    {Initial, Increment};
control(_Initial, _Increment) ->
    undefined.

error_reply(Reason) ->
    mcl_chess_wire:to_wire(#{<<"error">> => reason(Reason)}).

%% Atoms are a service-internal detail; the wire carries text.
reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason(Reason) when is_binary(Reason) -> Reason;
reason(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).
