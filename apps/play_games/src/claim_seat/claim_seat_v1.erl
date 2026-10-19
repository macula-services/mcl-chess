%% @doc The command that takes a seat: the caller claims one colour for itself.
%%
%% THE CALLER IS THE CLAIMANT, ALWAYS. `caller' is the node id macula verified
%% on the call, and there is no field for naming anybody else, so a body cannot
%% seat a second party (the rule WP2's review fixed on initiate_game). Consent
%% is a claim, and only its own node can give it.
%%
%% A colour is `<<"w">>' or `<<"b">>', the text `to_move' and the wire already
%% use. Anything else is refused at the boundary and never reaches the
%% aggregate.
-module(claim_seat_v1).

-behaviour(evoq_command).

-export([command_type/0, new/1, to_map/1, validate/1, from_map/1]).
-export([stream_id/1, get_game_id/1, get_caller/1, get_color/1]).

-record(claim_seat, {
    game_id :: binary(),
    caller  :: binary(),
    color   :: binary()
}).

-opaque t() :: #claim_seat{}.
-export_type([t/0]).

-spec command_type() -> atom().
command_type() -> claim_seat_v1.

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{game_id := GameId, caller := Caller, color := Color})
        when is_binary(GameId), is_binary(Caller), GameId =/= <<>>,
             Caller =/= <<>> ->
    coloured(GameId, Caller, Color);
new(_) ->
    {error, missing_required_fields}.

coloured(GameId, Caller, <<"w">>) ->
    {ok, #claim_seat{game_id = GameId, caller = Caller, color = <<"w">>}};
coloured(GameId, Caller, <<"b">>) ->
    {ok, #claim_seat{game_id = GameId, caller = Caller, color = <<"b">>}};
coloured(_GameId, _Caller, _Color) ->
    {error, invalid_color}.

-spec validate(t()) -> ok | {error, term()}.
validate(#claim_seat{game_id = GameId}) ->
    reckon_gater_stream_id:validate(GameId).

-spec to_map(t()) -> map().
to_map(#claim_seat{game_id = GameId, caller = Caller, color = Color}) ->
    #{command_type => command_type(),
      game_id => GameId,
      caller => Caller,
      color => Color}.

-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(#{game_id := GameId, caller := Caller, color := Color}) ->
    new(#{game_id => GameId, caller => Caller, color => Color});
from_map(_) ->
    {error, missing_required_fields}.

-spec stream_id(t()) -> binary().
stream_id(#claim_seat{game_id = GameId}) -> GameId.

-spec get_game_id(t()) -> binary().
get_game_id(#claim_seat{game_id = GameId}) -> GameId.

-spec get_caller(t()) -> binary().
get_caller(#claim_seat{caller = Caller}) -> Caller.

-spec get_color(t()) -> binary().
get_color(#claim_seat{color = Color}) -> Color.
