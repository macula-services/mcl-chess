%% @doc Handler for `start_game_v1': the game is playing once both seats are
%% taken, and never twice.
%%
%% Both refusals record nothing: one is a caller with no standing (a game that
%% does not exist, an archived game), the other is a state refusal that carries
%% no evidence about anybody's conduct. A second `start_game_v1' is the case
%% that matters, because the seats-full policy is `skip' on replay but can still
%% be handed the same claim twice on a restart; the guard, not the policy, is
%% what makes that safe.
-module(maybe_start_game).

-include("game_status.hrl").

-export([handle_from_map/2, handle/2, dispatch/1]).

-spec handle_from_map(term(), map()) -> {ok, [map()]} | {error, term()}.
handle_from_map(State, #{command_type := start_game_v1} = Payload) ->
    handled(State, start_game_v1:from_map(Payload));
handle_from_map(_State, _) ->
    {error, unknown_command}.

handled(State, {ok, Cmd}) -> handle(State, Cmd);
handled(_State, {error, _} = Error) -> Error.

-spec handle(game_state:t(), start_game_v1:t()) ->
    {ok, [map()]} | {error, term()}.
handle(State, Cmd) ->
    decided(standing(State), State, Cmd).

standing(State) ->
    checks(game_state:is_archived(State), game_state:is_initiated(State)).

checks(true, _Initiated) -> {error, game_archived};
checks(false, true) -> ok;
checks(false, false) -> {error, not_initiated}.

decided({error, _} = Refusal, _State, _Cmd) ->
    Refusal;
decided(ok, State, Cmd) ->
    started(game_state:is_started(State), State, Cmd).

started(true, _State, _Cmd) ->
    {error, already_started};
started(false, State, Cmd) ->
    filled(game_state:both_seats_filled(State), State, Cmd).

filled(false, _State, _Cmd) ->
    {error, seats_not_filled};
filled(true, State, Cmd) ->
    events(State, Cmd).

events(State, Cmd) ->
    Seats = game_state:seats(State),
    {ok, Event} = game_started_v1:new(#{
        game_id => start_game_v1:get_game_id(Cmd),
        white_node_id => maps:get(white, Seats),
        black_node_id => maps:get(black, Seats),
        position => game_state:position(State),
        to_move => game_state:to_move(State),
        ply => game_state:ply(State),
        clocks => game_state:clocks(State),
        status => game_status:started_from(game_state:status(State))}),
    {ok, [game_started_v1:to_map(Event)]}.

%% @doc Start the game and hand the caller the state it produced.
-spec dispatch(start_game_v1:t()) ->
    {ok, non_neg_integer(), [map()], map()} | {error, term()}.
dispatch(Cmd) ->
    case start_game_v1:validate(Cmd) of
        ok -> do_dispatch(Cmd);
        {error, Reason} -> {error, Reason}
    end.

do_dispatch(Cmd) ->
    EvoqCmd = evoq_command:new(start_game_v1, game_aggregate,
                               start_game_v1:stream_id(Cmd),
                               start_game_v1:to_map(Cmd),
                               #{timestamp => erlang:system_time(millisecond)}),
    case evoq_command_router:dispatch_with_state(
           EvoqCmd, #{store_id => mcl_chess_store, consistency => eventual}) of
        {ok, Version, Events, State} ->
            {ok, Version, Events, game_state:to_wire(State)};
        {error, _} = Error ->
            Error
    end.
