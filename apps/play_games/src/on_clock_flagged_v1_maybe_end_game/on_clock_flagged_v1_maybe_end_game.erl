%% @doc Policy: a flagged clock ends the game, with nobody asking it to.
%%
%% A policy is an `evoq_event_handler' with a command as its effect: the flag is
%% the evidence, and the end is the command that must follow it. The decision it
%% sends is deliberately thin - a forfeit, reason `clock_flag', no winner - and
%% `end_game' fills in the rest from the aggregate: it re-judges the position
%% (so a game left mated by a crash ends checkmate) and reads the flagged player
%% from the record to name the opponent who won.
%%
%% `replay_policy/0' is `skip'. Replaying the store must not re-dispatch a
%% command; a flag with no end after it is the one thing replay must repair, and
%% that is the clock instance's job (`game_clock_pm'), not a policy's:
%% re-dispatching here would re-fire every historical flag on every restart.
%%
%% THE DISPATCH RESULT IS THE ONLY ERROR CHANNEL, and a refusal is logged rather
%% than thrown: the game may have ended a moment ago, and this handler must never
%% take delivery of every later event down with it.
-module(on_clock_flagged_v1_maybe_end_game).

-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, replay_policy/0]).

interested_in() -> [<<"clock_flagged_v1">>].

replay_policy() -> skip.

init(_Config) ->
    {ok, #{}}.

handle_event(_EventType, Event, _Metadata, State) ->
    Data = maps:get(data, Event, Event),
    dispatched(end_game_api:handle(#{game_id => maps:get(game_id, Data),
                                     outcome => forfeit,
                                     reason => clock_flag}),
               Data),
    {ok, State}.

dispatched({ok, _Version, _Events, _View}, _Data) ->
    ok;
dispatched({error, Reason}, Data) ->
    logger:warning(#{what => game_not_ended_after_flag,
                     game_id => maps:get(game_id, Data),
                     reason => Reason}).
