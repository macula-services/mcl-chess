%% @doc Handler for `withdraw_game_v1': the death slice, before start.
%%
%% Only the initiator may withdraw, and only while the game has not started.
%% Both refusals are answered on the wire and record nothing: the caller here
%% is a device the plan calls "no standing" (a stranger) or a legitimate
%% refusal of state, neither of which is evidence about a player's conduct
%% (mcl-chess#1, section 3.2).
-module(maybe_withdraw_game).

-include("game_status.hrl").

-export([handle_from_map/2, handle/2, dispatch/1]).

-spec handle_from_map(term(), map()) -> {ok, [map()]} | {error, term()}.
handle_from_map(State, #{command_type := withdraw_game_v1} = Payload) ->
    handled(State, withdraw_game_v1:from_map(Payload));
handle_from_map(_State, _) ->
    {error, unknown_command}.

handled(State, {ok, Cmd}) -> handle(State, Cmd);
handled(_State, {error, _} = Error) -> Error.

%% @doc The business rules, stated against the aggregate state: the caller
%% must be the initiator, and the game must not have started.
-spec handle(game_state:t(), withdraw_game_v1:t()) ->
    {ok, [map()]} | {error, term()}.
handle(State, Cmd) ->
    withdrawn(not game_state:is_archived(State),
              game_state:initiator_node_id(State) =:= withdraw_game_v1:get_caller(Cmd),
              game_state:is_started(State), State, Cmd).

withdrawn(false, _Initiator, _Started, _State, _Cmd) ->
    {error, game_archived};
withdrawn(_Archived, false, _Started, _State, _Cmd) ->
    {error, not_initiator};
withdrawn(_Archived, _Initiator, true, _State, _Cmd) ->
    %% A started game is ended, not withdrawn: that path is WP5's.
    {error, game_started};
withdrawn(_Archived, _Initiator, false, State, Cmd) ->
    events(State, Cmd).

events(State, Cmd) ->
    {ok, Event} = game_archived_v1:new(#{
        game_id => withdraw_game_v1:get_game_id(Cmd),
        reason => <<"withdrawn">>,
        status => game_status:archived_from(game_state:status(State))}),
    {ok, [game_archived_v1:to_map(Event)]}.

%% @doc Withdraw the game and hand the caller the state it produced.
-spec dispatch(withdraw_game_v1:t()) ->
    {ok, non_neg_integer(), [map()], map()} | {error, term()}.
dispatch(Cmd) ->
    case withdraw_game_v1:validate(Cmd) of
        ok -> do_dispatch(Cmd);
        {error, Reason} -> {error, Reason}
    end.

do_dispatch(Cmd) ->
    EvoqCmd = evoq_command:new(withdraw_game_v1, game_aggregate,
                               withdraw_game_v1:stream_id(Cmd),
                               withdraw_game_v1:to_map(Cmd),
                               #{timestamp => erlang:system_time(millisecond)}),
    case evoq_command_router:dispatch_with_state(
           EvoqCmd, #{store_id => mcl_chess_store, consistency => eventual}) of
        {ok, Version, Events, State} ->
            {ok, Version, Events, game_state:to_wire(State)};
        {error, _} = Error ->
            Error
    end.
