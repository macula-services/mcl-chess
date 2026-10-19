%% @doc mcl-chess's public contract on the mesh: the facts a game publishes.
%%
%%   game_initiated_v1 on `<realm>/mcl-chess/chess/game/game_initiated_v1'
%%   seat_claimed_v1   on `<realm>/mcl-chess/chess/game/seat_claimed_v1'
%%   seat_refused_v1   on `<realm>/mcl-chess/chess/game/seat_refused_v1'
%%   game_started_v1   on `<realm>/mcl-chess/chess/game/game_started_v1'
%%   move_played_v1    on `<realm>/mcl-chess/chess/game/move_played_v1'
%%   move_refused_v1   on `<realm>/mcl-chess/chess/game/move_refused_v1'
%%   game_ended_v1     on `<realm>/mcl-chess/chess/game/game_ended_v1'
%%   game_archived_v1  on `<realm>/mcl-chess/chess/game/game_archived_v1'
%%
%% One topic per fact kind; the game id is in the payload, never in the topic
%% name, so a consumer subscribes once and filters. The domain event stays
%% internal; what leaves is a fact, and this module is the only place the two
%% shapes meet. Text travels as CBOR text, flags as 1/0.
%%
%% This module and the emit_* desks are the ONLY play_games modules that may
%% name the mesh SDK; a division-boundary test enforces it.
-module(mcl_chess_facts).

-export([game_initiated/1, seat_claimed/1, seat_refused/1, game_started/1,
         move_played/1, move_refused/1, game_ended/1,
         game_archived/1, to_wire/1, topic/2, realm_name/0]).

-define(ORG, <<"mcl-chess">>).
-define(APP, <<"chess">>).
-define(DOMAIN, <<"game">>).
-define(VERSION, 1).

-define(ARCHIVED_FIELDS, [game_id, reason, status, at_ms]).
-define(SEAT_FIELDS, [game_id, player_node_id, color, seats, status, at_ms]).

%% @doc The fact for a game_initiated_v1 event, whose keys may be atoms or
%% binaries (an event read back from the store is binary-keyed).
%%
%% `time_control' is written out as a map rather than passed through: the
%% event carries it as a tuple, and a tuple has no wire encoding.
-spec game_initiated(map()) -> map().
game_initiated(Event) ->
    {Initial, Increment} = field(time_control, Event),
    #{game_id => field(game_id, Event),
      protocol => field(protocol, Event),
      time_control => #{initial_ms => Initial, increment_ms => Increment},
      seats => field(seats, Event),
      position => field(position, Event),
      to_move => field(to_move, Event),
      ply => field(ply, Event),
      clocks => field(clocks, Event),
      status => field(status, Event),
      initiator_node_id => field(initiator_node_id, Event),
      at_ms => field(at_ms, Event)}.

-spec game_archived(map()) -> map().
game_archived(Event) ->
    maps:from_list([{Field, field(Field, Event)} || Field <- ?ARCHIVED_FIELDS]).

%% @doc The fact for a seat_claimed_v1 event: which node took which colour, and
%% the seats map after the claim.
-spec seat_claimed(map()) -> map().
seat_claimed(Event) ->
    maps:from_list([{Field, field(Field, Event)} || Field <- ?SEAT_FIELDS]).

%% @doc The fact for a seat_refused_v1 event. The reason travels as text, the
%% same spelling the caller was answered with, so a consumer that saw the
%% refusal and one that reads the fact agree.
-spec seat_refused(map()) -> map().
seat_refused(Event) ->
    (maps:from_list([{Field, field(Field, Event)} || Field <- ?SEAT_FIELDS]))
        #{reason => text(field(reason, Event))}.

%% The event's reason and outcome are atoms, the wire carries text: one
%% conversion, here, rather than in every consumer. An atom would reach CBOR as
%% an atom, which is not a thing the mesh encodes.
text(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
text(Value) -> Value.

%% @doc The fact for a move_played_v1 event: the move, the position it
%% produced and the counts the end rules read.
%%
%% `move' travels as the UCI text the caller sent, and the position as the FEN
%% the rules engine produced, so a viewer rebuilds the game from the facts
%% alone. `position_hash', `halfmove_clock' and `repetitions' are published
%% because they are what the referee judged on: a consumer that re-derives a
%% verdict from the board and one that reads the record agree.
-spec move_played(map()) -> map().
move_played(Event) ->
    maps:from_list([{Field, field(Field, Event)}
                    || Field <- [game_id, player_node_id, move, ply, fen_after,
                                 position_hash, halfmove_clock, repetitions,
                                 to_move, clocks, status, at_ms]]).

%% @doc The fact for a move_refused_v1 event: a seat holder's foul attempt, with
%% the same evidence role as a refused seat and the reason as text.
-spec move_refused(map()) -> map().
move_refused(Event) ->
    (maps:from_list([{Field, field(Field, Event)}
                     || Field <- [game_id, player_node_id, move, ply, fen_after,
                                  clocks, status, at_ms]]))
        #{reason => text(field(reason, Event))}.

%% @doc The fact for a game_ended_v1 event: who won, why, and the final
%% position. `winner_node_id' is absent for a draw in the sense that it is the
%% empty text, not a missing key: a consumer can switch on `outcome' alone.
-spec game_ended(map()) -> map().
game_ended(Event) ->
    (maps:from_list([{Field, field(Field, Event)}
                     || Field <- [game_id, winner_node_id, fen_after, ply,
                                  clocks, status, at_ms]]))
        #{outcome => text(field(outcome, Event)),
          reason => text(field(reason, Event))}.

%% @doc The fact for a game_started_v1 event: both holders by colour, the
%% position the game starts from, and the clocks it starts with.
-spec game_started(map()) -> map().
game_started(Event) ->
    maps:from_list([{Field, field(Field, Event)}
                    || Field <- [game_id, white_node_id, black_node_id,
                                 position, position_hash, to_move, ply, clocks,
                                 status, at_ms]]).

field(Field, Event) ->
    maps:get(Field, Event, maps:get(atom_to_binary(Field, utf8), Event, undefined)).

%% @doc Text as CBOR text, booleans as 1/0, numbers and shapes as they are.
-spec to_wire(term()) -> term().
to_wire(B) when is_binary(B) -> {text, B};
to_wire(true) -> 1;
to_wire(false) -> 0;
to_wire(L) when is_list(L) -> [to_wire(E) || E <- L];
to_wire(M) when is_map(M) -> maps:map(fun(_K, V) -> to_wire(V) end, M);
to_wire(Other) -> Other.

-spec topic(binary(), game_initiated | seat_claimed | seat_refused |
                         game_started | move_played | move_refused |
                         game_ended | game_archived) -> binary().
topic(RealmName, game_initiated) ->
    macula_topic:app_fact(RealmName, ?ORG, ?APP, ?DOMAIN, <<"game_initiated">>,
                          ?VERSION);
topic(RealmName, seat_claimed) ->
    macula_topic:app_fact(RealmName, ?ORG, ?APP, ?DOMAIN, <<"seat_claimed">>,
                          ?VERSION);
topic(RealmName, seat_refused) ->
    macula_topic:app_fact(RealmName, ?ORG, ?APP, ?DOMAIN, <<"seat_refused">>,
                          ?VERSION);
topic(RealmName, game_started) ->
    macula_topic:app_fact(RealmName, ?ORG, ?APP, ?DOMAIN, <<"game_started">>,
                          ?VERSION);
topic(RealmName, move_played) ->
    macula_topic:app_fact(RealmName, ?ORG, ?APP, ?DOMAIN, <<"move_played">>,
                          ?VERSION);
topic(RealmName, move_refused) ->
    macula_topic:app_fact(RealmName, ?ORG, ?APP, ?DOMAIN, <<"move_refused">>,
                          ?VERSION);
topic(RealmName, game_ended) ->
    macula_topic:app_fact(RealmName, ?ORG, ?APP, ?DOMAIN, <<"game_ended">>,
                          ?VERSION);
topic(RealmName, game_archived) ->
    macula_topic:app_fact(RealmName, ?ORG, ?APP, ?DOMAIN, <<"game_archived">>,
                          ?VERSION).

%% @doc The realm whose name the topics carry: io.macula for this fleet.
-spec realm_name() -> binary().
realm_name() -> <<"io.macula">>.
