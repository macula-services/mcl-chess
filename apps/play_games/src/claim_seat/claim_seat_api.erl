%% @doc claim_seat_api: the entry point, pure and total.
%%
%% A RECORDED REFUSAL IS STILL A REFUSAL TO THE CALLER. A claim on a taken or
%% full seat writes `seat_refused_v1' to the stream, because a claim is how
%% matchmaking sees demand (mcl-chess#1, section 3.2), and the caller is told
%% `{error, Reason}' anyway. The two are not in conflict: the event is the
%% evidence, the answer is the answer. Every other refusal writes nothing and
%% arrives here as an error from the dispatch.
-module(claim_seat_api).

-export([handle/1]).

-spec handle(map()) ->
    {ok, non_neg_integer(), [map()], map()} | {error, term()}.
handle(Params) ->
    handled(claim_seat_v1:new(#{game_id => maps:get(game_id, Params, undefined),
                                caller => maps:get(caller, Params, undefined),
                                color => maps:get(color, Params, undefined)})).

handled({ok, Cmd}) -> claimed(maybe_claim_seat:dispatch(Cmd));
handled({error, _} = Error) -> Error.

claimed({ok, Version, Events, View}) ->
    recorded_refusal(Events, Version, View);
claimed({error, _} = Error) ->
    Error.

recorded_refusal([#{event_type := <<"seat_refused_v1">>, reason := Reason}], _Version, _View) ->
    {error, Reason};
recorded_refusal(Events, Version, View) ->
    {ok, Version, Events, View}.
