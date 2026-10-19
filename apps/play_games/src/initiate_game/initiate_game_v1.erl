%% @doc The command that starts a game: one of the two seats opens it.
%%
%% The game id is a reckon stream id, minted through evoq's own seam
%% (`evoq_event_store:new_stream_id/1`), never hand-rolled and never derived
%% from a name. Payload keys are ATOMS, because evoq reads command_type with
%% an atom lookup.
%%
%% The initiator is the node id macula verified on the call. A caller cannot
%% name a different one: the responder reads it from the platform-injected
%% `caller', never from the caller's own body.
-module(initiate_game_v1).

-behaviour(evoq_command).

-export([command_type/0, new/1, to_map/1, validate/1, from_map/1]).
-export([mint_game_id/0, stream_id/1, get_game_id/1, get_time_control/1,
         get_seats/1, get_initiator/1, validate_time_control/1]).

%% The time-control caps the Design Gate settled (mcl-chess#1, answer 2):
%% one second to one day per side, and a zero increment stays legal, so 5+0,
%% 3+0 and 1+0 controls are all valid.
-define(MIN_INITIAL_MS, 1000).
-define(MAX_INITIAL_MS, 86400000).
-define(MIN_INCREMENT_MS, 0).
-define(MAX_INCREMENT_MS, 86400000).

-record(initiate_game, {
    game_id      :: binary(),
    time_control :: {integer(), integer()},
    seats = #{white => <<>>, black => <<>>} :: #{white := binary(), black := binary()},
    initiator    :: binary()
}).

-opaque t() :: #initiate_game{}.
-export_type([t/0]).

-spec command_type() -> atom().
command_type() -> initiate_game_v1.

%% @doc Mint a game's stream id, in the store's own contract.
%%
%% This is the call evoq 1.27.0's new_stream_id/1 exists for: the format
%% (`game-<32 lowercase hex>', UUIDv7 so ORDER BY stream_id is birth order)
%% stays the store's, defined once in the adapter.
-spec mint_game_id() -> binary().
mint_game_id() ->
    evoq_event_store:new_stream_id(game).

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{game_id := GameId, time_control := TimeControl, initiator := Initiator} = Params) ->
    Seats = maps:get(seats, Params, #{white => <<>>, black => <<>>}),
    built(valid_id(GameId), valid_initiator(Initiator), TimeControl, GameId, Seats,
          Initiator);
new(_) ->
    {error, missing_required_fields}.

built(true, true, TimeControl, GameId, Seats, Initiator) ->
    {ok, #initiate_game{game_id = GameId, time_control = TimeControl,
                        seats = Seats, initiator = Initiator}};
built(_, _, _, _, _, _) ->
    {error, invalid_params}.

valid_id(GameId) ->
    is_binary(GameId) andalso reckon_gater_stream_id:is_valid(GameId).

valid_initiator(Initiator) ->
    is_binary(Initiator) andalso Initiator =/= <<>>.

%% @doc Checks about the world, not the shape: the stream contract and the
%% time-control caps. A control outside the caps is refused here, at the
%% boundary, so no aggregate ever holds one.
-spec validate(t()) -> ok | {error, term()}.
validate(#initiate_game{game_id = GameId, time_control = TimeControl}) ->
    valid_stream(reckon_gater_stream_id:validate(GameId), TimeControl).

valid_stream(ok, TimeControl) -> validate_time_control(TimeControl);
valid_stream({error, Reason}, _TimeControl) -> {error, Reason}.

-spec validate_time_control(term()) -> ok | {error, term()}.
validate_time_control({Initial, Increment}) ->
    capped(is_integer(Initial) andalso is_integer(Increment),
           Initial, Increment);
validate_time_control(_) ->
    {error, invalid_time_control}.

capped(true, Initial, Increment) ->
    in_range(Initial >= ?MIN_INITIAL_MS andalso Initial =< ?MAX_INITIAL_MS,
             Initial, Increment);
capped(false, _Initial, _Increment) ->
    {error, invalid_time_control}.

in_range(true, _Initial, Increment) ->
    increment_ok(Increment >= ?MIN_INCREMENT_MS andalso Increment =< ?MAX_INCREMENT_MS);
in_range(false, _Initial, _Increment) ->
    {error, initial_ms_out_of_range}.

increment_ok(true) -> ok;
increment_ok(false) -> {error, increment_ms_out_of_range}.

-spec to_map(t()) -> map().
to_map(#initiate_game{game_id = GameId, time_control = TimeControl,
                      seats = Seats, initiator = Initiator}) ->
    #{command_type => command_type(),
      game_id => GameId,
      time_control => TimeControl,
      seats => Seats,
      initiator => Initiator}.

-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(#{game_id := GameId, time_control := TimeControl,
           initiator := Initiator} = Map) ->
    new(#{game_id => GameId, time_control => TimeControl,
          seats => maps:get(seats, Map, #{white => <<>>, black => <<>>}),
          initiator => Initiator});
from_map(_) ->
    {error, missing_required_fields}.

%% @doc The stream the command is addressed to: the game's own id.
-spec stream_id(t()) -> binary().
stream_id(#initiate_game{game_id = GameId}) -> GameId.

-spec get_game_id(t()) -> binary().
get_game_id(#initiate_game{game_id = GameId}) -> GameId.

-spec get_time_control(t()) -> {integer(), integer()}.
get_time_control(#initiate_game{time_control = TimeControl}) -> TimeControl.

-spec get_seats(t()) -> map().
get_seats(#initiate_game{seats = Seats}) -> Seats.

-spec get_initiator(t()) -> binary().
get_initiator(#initiate_game{initiator = Initiator}) -> Initiator.
