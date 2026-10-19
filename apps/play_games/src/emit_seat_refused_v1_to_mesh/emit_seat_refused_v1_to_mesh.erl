%% @doc Emitter: each `seat_refused_v1' becomes one fact on the mesh.
%%
%% A refusal is a fact, not a silence: this is the recorded half of the refusal
%% design, and the future reputation consumer reads attempted matchmaking from
%% it. `replay_policy/0' is `skip' for the same reason as every emitter here.
-module(emit_seat_refused_v1_to_mesh).

-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, replay_policy/0]).

interested_in() -> [<<"seat_refused_v1">>].

replay_policy() -> skip.

init(_Config) ->
    {ok, #{}}.

handle_event(_EventType, Event, _Metadata, State) ->
    Data = maps:get(data, Event, Event),
    publish(mcl_chess_facts:to_wire(mcl_chess_facts:seat_refused(Data)),
            seat_refused, State).

publish(Fact, Kind, State) ->
    case mcl_om:mesh_handles() of
        {ok, Pool, Realm} -> publish_on(Pool, Realm, Fact, Kind, State);
        {error, _} = Error -> Error
    end.

publish_on(Pool, Realm, Fact, Kind, State) ->
    case macula:publish(Pool, Realm,
                        mcl_chess_facts:topic(mcl_chess_facts:realm_name(), Kind),
                        Fact) of
        ok -> {ok, State};
        {error, _} = Error -> Error
    end.
