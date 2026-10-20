%% @doc The claim_seat capability's handler: the wire to the desk.
%%
%% THE CALLER IS THE CLAIMANT. `caller' arrives platform-injected, over any
%% same-named key the body sent, so it is the node id macula verified and not a
%% claim. There is deliberately NO way to name a player in the body: a body
%% carrying `node_id' or `player_node_id' is not read, because consent is
%% something a node gives for itself. (WP2's review fixed the same fault on
%% initiate_game, where a caller could pre-seat two strangers.)
%%
%% The request shape, as it arrives off the wire: `game_id' and `color'
%% (`w' or `b'). READ IT WITH mcl_om_wire, NEVER WITH maps:get/3: on this wire
%% every text key arrives as `{text, Bin}' and `caller' arrives under the atom
%% key, so a bare binary lookup finds neither. The reply is the game state the
%% claim produced, with `color' naming the seat this caller now holds, in wire
%% text (see mcl_chess_wire), or #{<<"error">> => R}.
-module(claim_seat_responder_v1).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

-spec init([]) -> {ok, undefined}.
init([]) ->
    {ok, undefined}.

-spec handle_request(term(), undefined) -> {reply, term(), undefined}.
handle_request(Payload, State) ->
    {reply, claim(Payload), State}.

claim(Payload) when is_map(Payload) ->
    Request = request(Payload),
    claimed(claim_seat_api:handle(Request), maps:get(color, Request));
claim(_) ->
    error_reply(invalid_request).

claimed({ok, _Version, _Events, View}, Color) ->
    mcl_chess_wire:to_wire(View#{<<"color">> => Color});
claimed({error, Reason}, _Color) ->
    error_reply(Reason).

request(Payload) ->
    #{game_id => mcl_om_wire:field(game_id, Payload),
      caller => mcl_chess_wire:caller(Payload),
      color => mcl_om_wire:field(color, Payload)}.

error_reply(Reason) ->
    mcl_chess_wire:to_wire(#{<<"error">> => reason(Reason)}).

reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason(Reason) when is_binary(Reason) -> Reason;
reason(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).
