%% @doc Policy: the second seat starts the game, with nobody asking it to.
%%
%% A policy is an `evoq_event_handler' with a command as its effect, not an
%% `evoq_process_manager': there is no per-process instance to correlate and no
%% timer involved, only "this event happened, so dispatch that command".
%%
%% `replay_policy/0' is `skip'. Replaying the store must not re-dispatch a
%% command, and while the aggregate's own guard makes a second start harmless,
%% a policy that re-fires on restart is a policy whose effect depends on how
%% often the node restarted.
%%
%% THE DISPATCH RESULT IS THE ONLY ERROR CHANNEL, and a refusal is logged rather
%% than thrown: the game may have been archived a moment ago, and this handler
%% must never take delivery of every later event down with it. The stream is the
%% authority on whether the game started, not this module.
-module(on_seat_claimed_v1_maybe_start_game).

-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, replay_policy/0]).

interested_in() -> [<<"seat_claimed_v1">>].

replay_policy() -> skip.

init(_Config) ->
    {ok, #{}}.

handle_event(_EventType, Event, _Metadata, State) ->
    Data = maps:get(data, Event, Event),
    started(maps:get(seats, Data), maps:get(game_id, Data)),
    {ok, State}.

%% Both seats filled is the whole condition: the claim event carries the seats
%% map after the claim, so no second stream is read to decide.
started(#{white := <<>>}, _GameId) ->
    ok;
started(#{black := <<>>}, _GameId) ->
    ok;
started(_Seats, GameId) ->
    dispatch_start(GameId).

dispatch_start(GameId) ->
    case start_game_api:handle(#{game_id => GameId}) of
        {ok, _Version, _Events, _View} -> ok;
        {error, Reason} -> warn_not_started(GameId, Reason)
    end.

warn_not_started(GameId, Reason) ->
    logger:warning(#{what => game_not_started,
                     game_id => GameId,
                     reason => Reason}).
