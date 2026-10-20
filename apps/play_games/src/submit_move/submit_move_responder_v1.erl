%% @doc The submit_move capability's handler: the wire to the desk.
%%
%% THE CALLER IS THE MOVER. `caller' arrives platform-injected, over any
%% same-named key the body sent, so it is the node id macula verified and not a
%% claim; there is no way to name a player in the body.
%%
%% The request shape, as it arrives off the wire: `game_id' and `move' (UCI,
%% e.g. `e2e4'). READ IT WITH mcl_om_wire, NEVER WITH maps:get/3: on this wire
%% every text key arrives as `{text, Bin}' and `caller' arrives under the atom
%% key, so a bare binary lookup finds neither. The reply is the game state the
%% move produced (the position after it, whose turn it is now, the clocks, the
%% ply and the count the end rules read), in wire text (see mcl_chess_wire),
%% or #{<<"error">> => R}.
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
    error_reply(invalid_request).

request(Payload) ->
    #{game_id => mcl_om_wire:field(game_id, Payload),
      caller => mcl_chess_wire:caller(Payload),
      move => mcl_om_wire:field(move, Payload)}.

answered({ok, _Version, _Events, View}) ->
    mcl_chess_wire:to_wire(View);
answered({error, Reason}) ->
    error_reply(Reason).

error_reply(Reason) ->
    mcl_chess_wire:to_wire(#{<<"error">> => reason(Reason)}).

reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason(Reason) when is_binary(Reason) -> Reason;
reason(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).
