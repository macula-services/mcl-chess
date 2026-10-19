%% @doc The Game aggregate: one chess game, from birth to archive.
%%
%% One stream per game, born by initiate_game_v1 and killed by
%% withdraw_game_v1 (or, later, archived after a retention window). The
%% aggregate owns the lifecycle guard: a command on an archived stream is
%% refused before any desk sees it. Slice rules (who may move, whose turn it
%% is) live in the desk's maybe_ module, where the business rule belongs.
%%
%% The stream id IS the game id, minted through evoq's own seam by
%% initiate_game_v1:mint_game_id/0.
-module(game_aggregate).

-behaviour(evoq_aggregate).

-include("game_status.hrl").

-export([init/1, execute/2, apply/2]).
-export([state_module/0, snapshot/1, from_snapshot/1]).

-spec state_module() -> module().
state_module() -> game_state.

init(AggregateId) ->
    {ok, game_state:new(AggregateId)}.

%% evoq calls execute(State, Payload), State FIRST.
execute(State, #{command_type := initiate_game_v1} = Payload) ->
    Guarded = fun(InnerState, InnerPayload) ->
                      refused_if_present(InnerState, InnerPayload)
              end,
    guard_then(Guarded, State, Payload, fun maybe_initiate_game:handle_from_map/2);
execute(State, #{command_type := withdraw_game_v1} = Payload) ->
    guard_then(fun(_S, _P) -> ok end, State, Payload,
               fun maybe_withdraw_game:handle_from_map/2);
execute(State, #{command_type := claim_seat_v1} = Payload) ->
    guard_then(fun(_S, _P) -> ok end, State, Payload,
               fun maybe_claim_seat:handle_from_map/2);
execute(State, #{command_type := start_game_v1} = Payload) ->
    guard_then(fun(_S, _P) -> ok end, State, Payload,
               fun maybe_start_game:handle_from_map/2);
execute(_State, _Unknown) ->
    {error, unknown_command}.

%% An initiated game cannot be initiated again: the stream id is minted per
%% game, so a second initiation on it is a caller reusing an id.
refused_if_present(State, _Payload) ->
    case game_state:status(State) of
        ?GAME_NONE -> ok;
        _ -> {error, already_initiated}
    end.

guard_then(Guard, State, Payload, Desk) ->
    case Guard(State, Payload) of
        ok -> Desk(State, Payload);
        {error, _} = Error -> Error
    end.

apply(State, Event) ->
    game_state:apply_event(State, Event).

snapshot(State) -> game_state:to_map(State).

from_snapshot(Map) ->
    {ok, State} = game_state:from_map(Map),
    State.
