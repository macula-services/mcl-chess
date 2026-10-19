%% @doc submit_move_api: the entry point, pure and total.
%%
%% A RECORDED REFUSAL IS STILL A REFUSAL TO THE CALLER, the same rule
%% `claim_seat_api' applies to a refused seat: the event is the evidence on the
%% stream, and the answer is `{error, Reason}' either way. Every other refusal
%% (no standing, a move string that is not a move) never becomes an event.
-module(submit_move_api).

-export([handle/1]).

-spec handle(map()) ->
    {ok, non_neg_integer(), [map()], map()} | {error, term()}.
handle(Params) ->
    handled(submit_move_v1:new(#{game_id => maps:get(game_id, Params, undefined),
                                 caller => maps:get(caller, Params, undefined),
                                 move => maps:get(move, Params, undefined)})).

handled({ok, Cmd}) -> played(maybe_submit_move:dispatch(Cmd));
handled({error, _} = Error) -> Error.

played({ok, Version, Events, View}) ->
    recorded_refusal(Events, Version, View);
played({error, _} = Error) ->
    Error.

recorded_refusal([#{event_type := <<"move_refused_v1">>, reason := Reason}],
                 _Version, _View) ->
    {error, Reason};
recorded_refusal(Events, Version, View) ->
    {ok, Version, Events, View}.
