%% @doc Handler for `initiate_game_v1': the birth slice.
%%
%% The aggregate calls handle_from_map/2; a caller dispatches/1. The business
%% rule is the aggregate's lifecycle guard (a game is initiated once), so what
%% is left here is validation and the event.
-module(maybe_initiate_game).

-export([handle_from_map/2, handle/2, dispatch/1]).

%% @doc The command's payload as evoq hands it to the aggregate: the map
%% initiate_game_v1:to_map/1 made, atom-keyed.
-spec handle_from_map(term(), map()) -> {ok, [map()]} | {error, term()}.
handle_from_map(State, #{command_type := initiate_game_v1} = Payload) ->
    handled(State, initiate_game_v1:from_map(Payload));
handle_from_map(_State, _) ->
    {error, unknown_command}.

handled(State, {ok, Cmd}) -> handle(State, Cmd);
handled(_State, {error, _} = Error) -> Error.

%% @doc The business rule, stated against the aggregate state.
-spec handle(game_state:t(), initiate_game_v1:t()) ->
    {ok, [map()]} | {error, term()}.
handle(_State, Cmd) ->
    case initiate_game_v1:validate(Cmd) of
        ok -> events(Cmd);
        {error, Reason} -> {error, Reason}
    end.

events(Cmd) ->
    {ok, Event} = game_initiated_v1:new(#{
        game_id => initiate_game_v1:get_game_id(Cmd),
        time_control => initiate_game_v1:get_time_control(Cmd),
        seats => initiate_game_v1:get_seats(Cmd),
        initiator => initiate_game_v1:get_initiator(Cmd),
        status => game_status:birth()}),
    {ok, [game_initiated_v1:to_map(Event)]}.

%% @doc Initiate the game on its own stream, and hand the caller the state
%% the event produced, so no follow-up query is needed.
%%
%% Validation happens here, BEFORE dispatch, and that is load-bearing: the
%% store client raises on a bad stream id, so the desk is the boundary.
%%
%% The adapter is NOT named here: it is configured in sys.config, and evoq
%% resolves it. A desk that named it would be a second place to keep in step.
-spec dispatch(initiate_game_v1:t()) ->
    {ok, non_neg_integer(), [map()], map()} | {error, term()}.
dispatch(Cmd) ->
    case initiate_game_v1:validate(Cmd) of
        ok -> do_dispatch(Cmd);
        {error, Reason} -> {error, Reason}
    end.

do_dispatch(Cmd) ->
    EvoqCmd = evoq_command:new(initiate_game_v1, game_aggregate,
                               initiate_game_v1:stream_id(Cmd),
                               initiate_game_v1:to_map(Cmd),
                               #{timestamp => erlang:system_time(millisecond)}),
    case evoq_command_router:dispatch_with_state(
           EvoqCmd, #{store_id => mcl_chess_store, consistency => eventual}) of
        {ok, Version, Events, State} ->
            {ok, Version, Events, game_state:to_wire(State)};
        {error, _} = Error ->
            Error
    end.
