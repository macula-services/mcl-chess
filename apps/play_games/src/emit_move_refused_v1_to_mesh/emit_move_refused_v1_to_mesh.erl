%% @doc Emitter: each `move_refused_v1' becomes one fact on the mesh.
%%
%% A refusal is published for the same reason it is recorded: it is evidence a
%% future reputation division reads from the transcript alone, and evidence on a
%% stream nobody can hear is not evidence.
%%
%% `replay_policy/0' is `skip': a restart's replay must not re-publish facts
%% that already went out. A failed publish is an ERROR RETURN rather than a
%% swallowed log line, so evoq's retry machinery owns redelivery.
-module(emit_move_refused_v1_to_mesh).

-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, replay_policy/0]).

interested_in() -> [<<"move_refused_v1">>].

replay_policy() -> skip.

init(_Config) ->
    {ok, #{}}.

handle_event(_EventType, Event, _Metadata, State) ->
    Data = maps:get(data, Event, Event),
    publish(mcl_chess_facts:to_wire(mcl_chess_facts:move_refused(Data)),
            move_refused, State).

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
