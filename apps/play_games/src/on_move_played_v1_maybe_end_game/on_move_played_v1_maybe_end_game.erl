%% @doc Policy: a move that ends the game ends it, with nobody asking it to.
%%
%% A policy is an `evoq_event_handler' with a command as its effect, not an
%% `evoq_process_manager': there is no per-process instance to correlate and no
%% timer involved, only "this move happened, so ask the rules and dispatch the
%% end".
%%
%% `replay_policy/0' is `skip'. Replaying the store must not re-dispatch a
%% command; the aggregate's own guard makes a second end harmless, but a policy
%% that re-fires on restart is a policy whose effect depends on how often the
%% node restarted.
%%
%% THE EVENT IS ENOUGH TO DECIDE. `move_played_v1' carries the position, the
%% referee's own halfmove count and the repetition count of that position, so
%% this handler reads one event and no read model: `game_verdict:after_move/1'
%% asks the rules engine and applies the repetition count, and the same module
%% answers the flag desk's version of the question. The 50 move and threefold
%% draws stay v2 claims, so nothing here ends a game on them.
-module(on_move_played_v1_maybe_end_game).

-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, replay_policy/0]).

interested_in() -> [<<"move_played_v1">>].

replay_policy() -> skip.

init(_Config) ->
    {ok, #{}}.

handle_event(_EventType, Event, _Metadata, State) ->
    Data = maps:get(data, Event, Event),
    ended(game_verdict:after_move(Data), Data),
    {ok, State}.

ended(active, _Data) ->
    ok;
ended({over, Decision}, Data) ->
    dispatch(Data, Decision);
ended({error, invalid_fen}, Data) ->
    warn_not_judged(Data, invalid_fen).

dispatch(Data, Decision) ->
    dispatched(end_game_api:handle(Decision#{game_id => maps:get(game_id, Data)}),
               Data, Decision).

dispatched({ok, _Version, _Events, _View}, _Data, _Decision) ->
    ok;
dispatched({error, Reason}, Data, Decision) ->
    warn_not_ended(Data, Reason, Decision).

%% A refusal is logged, never thrown: the game may have ended a moment ago (two
%% policies can see the same move), and this handler must not take delivery of
%% every later event down with it. The stream is the authority on whether the
%% game ended, not this module.
warn_not_ended(Data, Reason, Decision) ->
    logger:warning(#{what => game_not_ended,
                     game_id => maps:get(game_id, Data),
                     reason => Reason,
                     decision => Decision}).

warn_not_judged(Data, Why) ->
    logger:warning(#{what => move_not_judged,
                     game_id => maps:get(game_id, Data),
                     reason => Why}).
