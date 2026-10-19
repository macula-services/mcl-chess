%% @doc Handler for `archive_game_v1': the death slice, after the retention
%% window.
%%
%% The game must be over before it can be archived, and it must not be archived
%% twice: the retention instance that dispatches this can be rebuilt by a replay,
%% so a second arrival is normal rather than exceptional. A game that never
%% started never reaches here either, because nothing ends it: its own death is a
%% pre-start `withdraw_game_v1', which archives.
%%
%% `ended' is asked before `started' for the reason every other desk asks it in
%% that order: ending clears STARTED, so asking the start first would call an
%% ended game unstarted.
-module(maybe_archive_game).

-export([handle_from_map/2, handle/2, dispatch/1]).

-spec handle_from_map(term(), map()) -> {ok, [map()]} | {error, term()}.
handle_from_map(State, #{command_type := archive_game_v1} = Payload) ->
    handled(State, archive_game_v1:from_map(Payload));
handle_from_map(_State, _) ->
    {error, unknown_command}.

handled(State, {ok, Cmd}) -> handle(State, Cmd);
handled(_State, {error, _} = Error) -> Error.

-spec handle(game_state:t(), archive_game_v1:t()) ->
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
    unended(game_state:is_ended(State), State, Cmd).

unended(false, _State, _Cmd) ->
    {error, not_ended};
unended(true, State, Cmd) ->
    events(State, Cmd).

events(State, Cmd) ->
    %% THE REASON IS THE POLICY'S, not the caller's: `retention' says the game
    %% was archived because time passed, which is what a reader needs to tell it
    %% from the pre-start `withdrawn' that shares this event type.
    {ok, Event} = game_archived_v1:new(#{
        game_id => archive_game_v1:get_game_id(Cmd),
        reason => <<"retention">>,
        status => game_status:archived_from(game_state:status(State))}),
    {ok, [game_archived_v1:to_map(Event)]}.

%% @doc Archive the game and hand the caller the state it produced.
-spec dispatch(archive_game_v1:t()) ->
    {ok, non_neg_integer(), [map()], map()} | {error, term()}.
dispatch(Cmd) ->
    case archive_game_v1:validate(Cmd) of
        ok -> do_dispatch(Cmd);
        {error, Reason} -> {error, Reason}
    end.

do_dispatch(Cmd) ->
    EvoqCmd = evoq_command:new(archive_game_v1, game_aggregate,
                               archive_game_v1:stream_id(Cmd),
                               archive_game_v1:to_map(Cmd),
                               #{timestamp => erlang:system_time(millisecond)}),
    case evoq_command_router:dispatch_with_state(
           EvoqCmd, #{store_id => mcl_chess_store, consistency => eventual}) of
        {ok, Version, Events, State} ->
            {ok, Version, Events, game_state:to_wire(State)};
        {error, _} = Error ->
            Error
    end.
