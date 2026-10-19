%% @doc Emitter: each `game_ended_v1' becomes one fact on the mesh.
%%
%% ONE EMITTER FOR EVERY END: a resignation, a terminal position and (WP6) a
%% flagged clock all produce this event, and the event type is the subscription
%% key, so there is one fact to subscribe to and `outcome' plus `reason' say
%% which happened.
%%
%% `replay_policy/0' is `skip': a restart's replay must not re-publish facts
%% that already went out. A failed publish is an ERROR RETURN rather than a
%% swallowed log line, so evoq's retry machinery owns redelivery: an agent that
%% missed the end of its own game is waiting for something that will not come.
-module(emit_game_ended_v1_to_mesh).

-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, replay_policy/0]).

interested_in() -> [<<"game_ended_v1">>].

replay_policy() -> skip.

init(_Config) ->
    {ok, #{}}.

handle_event(_EventType, Event, _Metadata, State) ->
    Data = maps:get(data, Event, Event),
    publish(mcl_chess_facts:to_wire(mcl_chess_facts:game_ended(Data)),
            game_ended, State).

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
