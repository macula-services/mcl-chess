%% @doc The resign_game capability's handler: the wire to the desk.
%%
%% THE CALLER IS THE RESIGNER. `caller' arrives platform-injected, over any
%% same-named key the body sent, so it is the node id macula verified and not a
%% claim.
%%
%% The request shape, as it arrives off the wire: `game_id'. READ IT WITH
%% mcl_om_wire, NEVER WITH maps:get/3: on this wire every text key arrives as
%% `{text, Bin}' and `caller' arrives under the atom key, so a bare binary
%% lookup finds neither. The reply is the game state the resignation produced,
%% with `outcome' and `winner' naming what happened, in wire text (see
%% mcl_chess_wire), or #{<<"error">> => R}.
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
    error_reply(invalid_request).

request(Payload) ->
    #{game_id => mcl_om_wire:field(game_id, Payload),
      caller => mcl_om_wire:caller(Payload)}.

answered({ok, _Version, _Events, View}) ->
    mcl_chess_wire:to_wire(View);
answered({error, Reason}) ->
    error_reply(Reason).

error_reply(Reason) ->
    mcl_chess_wire:to_wire(#{<<"error">> => reason(Reason)}).

reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason(Reason) when is_binary(Reason) -> Reason;
reason(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).
