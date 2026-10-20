%% @doc The withdraw_game capability's handler: the wire to the desk.
%%
%% The caller is the node id macula verified on the call, platform-injected
%% as `caller'. A body naming a different node is not read: the initiator
%% check is against the wire, never against a claim.
%%
%% The request shape, as it arrives off the wire: `game_id'. READ IT WITH
%% mcl_om_wire, NEVER WITH maps:get/3: on this wire every text key arrives as
%% `{text, Bin}' and `caller' arrives under the atom key, so a bare binary
%% lookup finds neither. The reply is the archived game state, in wire text
%% (see mcl_chess_wire), or #{<<"error">> => R}.
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
    error_reply(invalid_request).

withdrawn({ok, _Version, _Events, View}) -> mcl_chess_wire:to_wire(View);
withdrawn({error, Reason}) -> error_reply(Reason).

request(Payload) ->
    #{game_id => mcl_om_wire:field(game_id, Payload),
      caller => mcl_chess_wire:caller(Payload)}.

error_reply(Reason) ->
    mcl_chess_wire:to_wire(#{<<"error">> => reason(Reason)}).

reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason(Reason) when is_binary(Reason) -> Reason;
reason(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).
