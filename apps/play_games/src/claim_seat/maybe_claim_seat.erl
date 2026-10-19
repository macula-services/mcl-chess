%% @doc Handler for `claim_seat_v1': first claim wins a colour.
%%
%% The rules, in the order they are checked, and each with a reason the caller
%% can act on:
%%
%% - an archived game is dead (`game_archived'), a game that was never
%%   initiated has no stream to grow (`not_initiated'): neither records
%%   anything, because a caller with no standing must not write to a game
%% - a node that already holds a seat cannot take a second one, its own or the
%%   other (`already_seated'). Two seats are two consenting agents; one node in
%%   both would be a game with itself. Not recorded: nobody else is involved
%% - a claim on a full game records `seat_refused_v1' with reason `game_full',
%%   and a claim on a taken colour records it with `seat_taken'. A claim is how
%%   matchmaking sees demand, and claimants are naturally bounded, so these two
%%   are the recorded refusals (mcl-chess#1, section 3.2)
%% - otherwise the colour changes hands and `seat_claimed_v1' carries the whole
%%   seats map after the claim
-module(maybe_claim_seat).

-export([handle_from_map/2, handle/2, dispatch/1]).

-spec handle_from_map(term(), map()) -> {ok, [map()]} | {error, term()}.
handle_from_map(State, #{command_type := claim_seat_v1} = Payload) ->
    handled(State, claim_seat_v1:from_map(Payload));
handle_from_map(_State, _) ->
    {error, unknown_command}.

handled(State, {ok, Cmd}) -> handle(State, Cmd);
handled(_State, {error, _} = Error) -> Error.

-spec handle(game_state:t(), claim_seat_v1:t()) ->
    {ok, [map()]} | {error, term()}.
handle(State, Cmd) ->
    Colour = game_state:colour_key(claim_seat_v1:get_color(Cmd)),
    Caller = claim_seat_v1:get_caller(Cmd),
    decided(standing(State), State, Cmd, Colour, Caller).

standing(State) ->
    checks(game_state:is_archived(State), game_state:is_initiated(State)).

checks(true, _Initiated) -> {error, game_archived};
checks(false, true) -> ok;
checks(false, false) -> {error, not_initiated}.

decided({error, _} = Refusal, _State, _Cmd, _Colour, _Caller) ->
    Refusal;
decided(ok, State, Cmd, Colour, Caller) ->
    seated(game_state:is_seated(State, Caller), State, Cmd, Colour, Caller).

seated(true, _State, _Cmd, _Colour, _Caller) ->
    {error, already_seated};
seated(false, State, Cmd, Colour, Caller) ->
    refused_or_claimed(game_state:seat(State, Colour), State, Cmd, Colour, Caller).

refused_or_claimed(<<>>, State, Cmd, Colour, Caller) ->
    claimed(State, Cmd, Colour, Caller);
refused_or_claimed(_Holder, State, Cmd, Colour, Caller) ->
    refused(taken_reason(State), State, Cmd, Colour, Caller).

%% A full game is reported as full even though the named colour is also taken:
%% it is the more useful fact to a matchmaker.
taken_reason(State) ->
    full_or_taken(game_state:both_seats_filled(State)).

full_or_taken(true) -> game_full;
full_or_taken(false) -> seat_taken.

claimed(State, Cmd, Colour, Caller) ->
    {ok, Event} = seat_claimed_v1:new(#{
        game_id => claim_seat_v1:get_game_id(Cmd),
        player_node_id => Caller,
        color => game_state:colour_wire(Colour),
        seats => (game_state:seats(State))#{Colour => Caller},
        status => game_state:status(State)}),
    {ok, [seat_claimed_v1:to_map(Event)]}.

refused(Reason, State, Cmd, Colour, Caller) ->
    capped(Reason, game_state:may_record_refusal(State, Caller),
           State, Cmd, Colour, Caller).

%% PAST THE CAP THE ANSWER IS THE SAME AND THE EVIDENCE IS NOT. A node that
%% holds no seat reaches this clause every time it asks, so without the cap one
%% stranger could write a refusal, and publish its fact, for as long as the game
%% lives. The number is the Design Gate's (answer 5) and the counter is the one
%% WP5's move_refused_v1 will use.
capped(Reason, false, _State, _Cmd, _Colour, _Caller) ->
    {error, Reason};
capped(Reason, true, State, Cmd, Colour, Caller) ->
    {ok, Event} = seat_refused_v1:new(#{
        game_id => claim_seat_v1:get_game_id(Cmd),
        player_node_id => Caller,
        color => game_state:colour_wire(Colour),
        reason => Reason,
        seats => game_state:seats(State),
        status => game_state:status(State)}),
    {ok, [seat_refused_v1:to_map(Event)]}.

%% @doc Claim the seat and hand the caller the state it produced.
-spec dispatch(claim_seat_v1:t()) ->
    {ok, non_neg_integer(), [map()], map()} | {error, term()}.
dispatch(Cmd) ->
    case claim_seat_v1:validate(Cmd) of
        ok -> do_dispatch(Cmd);
        {error, Reason} -> {error, Reason}
    end.

do_dispatch(Cmd) ->
    EvoqCmd = evoq_command:new(claim_seat_v1, game_aggregate,
                               claim_seat_v1:stream_id(Cmd),
                               claim_seat_v1:to_map(Cmd),
                               #{timestamp => erlang:system_time(millisecond)}),
    case evoq_command_router:dispatch_with_state(
           EvoqCmd, #{store_id => mcl_chess_store, consistency => eventual}) of
        {ok, Version, Events, State} ->
            {ok, Version, Events, game_state:to_wire(State)};
        {error, _} = Error ->
            Error
    end.
