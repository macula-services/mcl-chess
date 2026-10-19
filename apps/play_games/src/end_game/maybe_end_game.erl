%% @doc Handler for `end_game_v1': the one way a game ends, whoever triggered it.
%%
%% The slices are a strict order (mcl-chess#1): an end needs a started game, so
%% a pre-start withdraw is an archive and not an end; and a game ends once, so a
%% second end is refused rather than rewriting the outcome. Neither refusal
%% records anything: a caller with no standing must not grow the stream, and an
%% already-ended game has nothing left to say.
%%
%% THE WINNER MUST BE ONE OF THE SEATS. The command comes from a policy this
%% service runs, and the handler still checks it: an end naming a stranger would
%% put a node id in the record that the game never admitted.
-module(maybe_end_game).

-export([handle_from_map/2, handle/2, dispatch/1]).

-spec handle_from_map(term(), map()) -> {ok, [map()]} | {error, term()}.
handle_from_map(State, #{command_type := end_game_v1} = Payload) ->
    handled(State, end_game_v1:from_map(Payload));
handle_from_map(_State, _) ->
    {error, unknown_command}.

handled(State, {ok, Cmd}) -> handle(State, Cmd);
handled(_State, {error, _} = Error) -> Error.

-spec handle(game_state:t(), end_game_v1:t()) ->
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

%% Ended before started: ending clears STARTED, so asking the start first would
%% answer "not started" to a game that is over, and the caller who ended it
%% would read that as a fault in the referee.
unended(true, _State, _Cmd) ->
    {error, already_ended};
unended(false, State, Cmd) ->
    playing(game_state:is_started(State), State, Cmd).

playing(false, _State, _Cmd) ->
    {error, not_started};
playing(true, State, Cmd) ->
    eligible(winner_stands(State, end_game_v1:get_outcome(Cmd),
                           end_game_v1:get_winner_node_id(Cmd)),
             State, Cmd).

%% A draw and an abandonment name nobody; a win and a forfeit name a seat. Both
%% are checked here rather than trusted: the policy decides who won, and the
%% aggregate decides whether that is a thing it could have said.
winner_stands(_State, Outcome, <<>>) when Outcome =:= draw;
                                         Outcome =:= abandoned ->
    true;
winner_stands(_State, _Outcome, <<>>) ->
    false;
winner_stands(State, Outcome, Winner) when Outcome =:= winner;
                                           Outcome =:= forfeit ->
    game_state:is_seated(State, Winner);
winner_stands(_State, _Outcome, _Winner) ->
    false.

eligible(true, State, Cmd) ->
    events(State, Cmd);
eligible(false, _State, _Cmd) ->
    {error, winner_not_seated}.

events(State, Cmd) ->
    {ok, Event} = game_ended_v1:new(#{
        game_id => end_game_v1:get_game_id(Cmd),
        outcome => end_game_v1:get_outcome(Cmd),
        winner_node_id => end_game_v1:get_winner_node_id(Cmd),
        reason => end_game_v1:get_reason(Cmd),
        fen_after => game_state:position(State),
        ply => game_state:ply(State),
        clocks => game_state:clocks(State),
        status => game_status:ended_from(game_state:status(State))}),
    {ok, [game_ended_v1:to_map(Event)]}.

%% @doc End the game and hand the caller the state it produced.
-spec dispatch(end_game_v1:t()) ->
    {ok, non_neg_integer(), [map()], map()} | {error, term()}.
dispatch(Cmd) ->
    case end_game_v1:validate(Cmd) of
        ok -> do_dispatch(Cmd);
        {error, Reason} -> {error, Reason}
    end.

do_dispatch(Cmd) ->
    EvoqCmd = evoq_command:new(end_game_v1, game_aggregate,
                               end_game_v1:stream_id(Cmd),
                               end_game_v1:to_map(Cmd),
                               #{timestamp => erlang:system_time(millisecond)}),
    case evoq_command_router:dispatch_with_state(
           EvoqCmd, #{store_id => mcl_chess_store, consistency => eventual}) of
        {ok, Version, Events, State} ->
            {ok, Version, Events, game_state:to_wire(State)};
        {error, _} = Error ->
            Error
    end.
