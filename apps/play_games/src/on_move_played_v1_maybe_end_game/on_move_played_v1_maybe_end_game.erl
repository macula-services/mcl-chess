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
%% this handler reads one event and no read model: the rules engine answers
%% checkmate, stalemate, insufficient material and the 75 move rule, and the
%% fivefold draw is the count in the event. The 50 move and threefold draws stay
%% v2 claims, so nothing here ends a game on them.
-module(on_move_played_v1_maybe_end_game).

-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, replay_policy/0]).

interested_in() -> [<<"move_played_v1">>].

replay_policy() -> skip.

init(_Config) ->
    {ok, #{}}.

handle_event(_EventType, Event, _Metadata, State) ->
    Data = maps:get(data, Event, Event),
    ended(verdict(Data), Data),
    {ok, State}.

verdict(Data) ->
    mcl_chess_rules:status(maps:get(fen_after, Data), maps:get(halfmove_clock, Data)).

%% The rules engine's veto over the count, in its own order: a checkmate on the
%% move that reached the counter is a win, and a position that is dead on its
%% own terms reports that reason rather than the counter's.
ended(active, Data) ->
    repeated(maps:get(repetitions, Data), Data);
ended(checkmate, Data) ->
    dispatch(Data, #{outcome => winner,
                     winner_node_id => maps:get(player_node_id, Data),
                     reason => checkmate});
ended(stalemate, Data) ->
    dispatch(Data, #{outcome => draw, reason => stalemate});
ended(insufficient_material, Data) ->
    dispatch(Data, #{outcome => draw, reason => insufficient_material});
ended(seventy_five_moves, Data) ->
    dispatch(Data, #{outcome => draw, reason => seventy_five_moves});
ended({error, invalid_fen}, Data) ->
    warn_not_judged(Data, invalid_fen).

repeated(Repetitions, Data) ->
    reached(Repetitions >= game_state:repetition_draw(), Data).

reached(true, Data) ->
    dispatch(Data, #{outcome => draw, reason => fivefold_repetition});
reached(false, _Data) ->
    ok.

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
