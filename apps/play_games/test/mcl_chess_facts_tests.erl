%% @doc The facts contract, pinned: topics and keys, and the two rules that
%% make a fact a fact.
%%
%% mpong's mcl_mpong_facts_tests is the pattern. A breaking change gets a new
%% `_vN' and a new topic; this suite is what makes "breaking" visible before
%% a consumer finds out.
-module(mcl_chess_facts_tests).

-include_lib("eunit/include/eunit.hrl").

topic_test_() ->
    [?_assertEqual(<<"io.macula/mcl-chess/chess/game/game_initiated_v1">>,
                   mcl_chess_facts:topic(mcl_chess_facts:realm_name(), game_initiated)),
     ?_assertEqual(<<"io.macula/mcl-chess/chess/game/seat_claimed_v1">>,
                   mcl_chess_facts:topic(mcl_chess_facts:realm_name(), seat_claimed)),
     ?_assertEqual(<<"io.macula/mcl-chess/chess/game/seat_refused_v1">>,
                   mcl_chess_facts:topic(mcl_chess_facts:realm_name(), seat_refused)),
     ?_assertEqual(<<"io.macula/mcl-chess/chess/game/game_started_v1">>,
                   mcl_chess_facts:topic(mcl_chess_facts:realm_name(), game_started)),
     ?_assertEqual(<<"io.macula/mcl-chess/chess/game/game_archived_v1">>,
                   mcl_chess_facts:topic(mcl_chess_facts:realm_name(), game_archived)),
     ?_assertEqual(<<"io.macula/mcl-chess/chess/game/move_played_v1">>,
                   mcl_chess_facts:topic(mcl_chess_facts:realm_name(), move_played)),
     ?_assertEqual(<<"io.macula/mcl-chess/chess/game/move_refused_v1">>,
                   mcl_chess_facts:topic(mcl_chess_facts:realm_name(), move_refused)),
     ?_assertEqual(<<"io.macula/mcl-chess/chess/game/clock_flagged_v1">>,
                   mcl_chess_facts:topic(mcl_chess_facts:realm_name(), clock_flagged)),
     ?_assertEqual(<<"io.macula/mcl-chess/chess/game/game_ended_v1">>,
                   mcl_chess_facts:topic(mcl_chess_facts:realm_name(), game_ended)),
     %% The id is in the payload, never the topic: one subscription serves
     %% every game.
     ?_assertEqual(nomatch, binary:match(mcl_chess_facts:topic(
                                           mcl_chess_facts:realm_name(), game_initiated),
                                         <<"game-">>)),
     ?_assertEqual(<<"io.macula">>, mcl_chess_facts:realm_name())].

keys_test_() ->
    Initiated = mcl_chess_facts:game_initiated(initiated_event()),
    Archived = mcl_chess_facts:game_archived(archived_event()),
    Claimed = mcl_chess_facts:seat_claimed(claimed_event()),
    ClaimRefused = mcl_chess_facts:seat_refused(claim_refused_event()),
    Started = mcl_chess_facts:game_started(started_event()),
    Played = mcl_chess_facts:move_played(played_event()),
    Refused = mcl_chess_facts:move_refused(refused_event()),
    Flagged = mcl_chess_facts:clock_flagged(flagged_event()),
    Ended = mcl_chess_facts:game_ended(ended_event()),
    [?_assertEqual([at_ms, clocks, game_id, initiator_node_id, ply, position,
                    protocol, seats, status, time_control, to_move],
                   lists:sort(maps:keys(Initiated))),
     ?_assertEqual([at_ms, game_id, reason, status],
                   lists:sort(maps:keys(Archived))),
     %% A claim names the node that took the seat and the seats after it, so a
     %% spectator can follow who is playing without asking the service.
     ?_assertEqual([at_ms, color, game_id, player_node_id, seats, status],
                   lists:sort(maps:keys(Claimed))),
     ?_assertEqual([at_ms, color, game_id, player_node_id, reason, seats,
                    status],
                   lists:sort(maps:keys(ClaimRefused))),
     ?_assertEqual([at_ms, black_node_id, clocks, game_id, ply, position,
                    position_hash, status, to_move, white_node_id],
                   lists:sort(maps:keys(Started))),
     %% A move is published with the counts the referee judged on, so a
     %% consumer that re-derives a verdict and one that reads the record agree.
     ?_assertEqual([at_ms, clocks, fen_after, game_id, halfmove_clock, move,
                    player_node_id, ply, position_hash, repetitions, status,
                    to_move],
                   lists:sort(maps:keys(Played))),
     ?_assertEqual([at_ms, clocks, fen_after, game_id, move, player_node_id,
                    ply, reason, status],
                   lists:sort(maps:keys(Refused))),
     %% A flag names whose clock ran out and the clocks as the flag recorded
     %% them, so a consumer can tell a loss on time from any other forfeit.
     ?_assertEqual([at_ms, clocks, game_id, player_node_id, status],
                   lists:sort(maps:keys(Flagged))),
     ?_assertEqual([at_ms, clocks, fen_after, game_id, outcome, ply, reason,
                    status, winner_node_id],
                   lists:sort(maps:keys(Ended)))].

%% Every fact's wire shape, key by key: the CBOR type each key carries. The key
%% lists above say which keys exist; this says what a consumer will actually
%% receive, which is what a subscriber in another language is written against.
%%
%% A new key, a renamed key, or a key that quietly changes from text to an atom
%% reaches a consumer as a surprise. Here it reaches a red test first.
shape_test_() ->
    [?_assertEqual(declared(Fact), actual(Fact)) || Fact <- facts()].

%% Kept in one place so the table below and the fixtures cannot drift apart.
facts() ->
    [{game_initiated, fun() -> mcl_chess_facts:game_initiated(initiated_event()) end},
     {seat_claimed, fun() -> mcl_chess_facts:seat_claimed(claimed_event()) end},
     {seat_refused, fun() -> mcl_chess_facts:seat_refused(claim_refused_event()) end},
     {game_started, fun() -> mcl_chess_facts:game_started(started_event()) end},
     {move_played, fun() -> mcl_chess_facts:move_played(played_event()) end},
     {move_refused, fun() -> mcl_chess_facts:move_refused(refused_event()) end},
     {clock_flagged, fun() -> mcl_chess_facts:clock_flagged(flagged_event()) end},
     {game_ended, fun() -> mcl_chess_facts:game_ended(ended_event()) end},
     {game_archived, fun() -> mcl_chess_facts:game_archived(archived_event()) end}].

actual({_Fact, Build}) ->
    wire_shape(mcl_chess_facts:to_wire(Build())).

declared({Fact, _Build}) ->
    maps:get(Fact, declared_shapes()).

%% The contract. Text is CBOR text, numbers are numbers, flags are 1/0 (and so
%% are integers on the wire), and the two maps say what every value in them is.
declared_shapes() ->
    #{game_initiated =>
          #{game_id => text, protocol => text,
            time_control => {map, [integer]}, seats => {map, [text]},
            position => text, to_move => text, ply => integer,
            clocks => {map, [integer]}, status => integer,
            initiator_node_id => text, at_ms => integer},
      seat_claimed =>
          #{game_id => text, player_node_id => text, color => text,
            seats => {map, [text]}, status => integer, at_ms => integer},
      seat_refused =>
          #{game_id => text, player_node_id => text, color => text,
            seats => {map, [text]}, status => integer, at_ms => integer,
            reason => text},
      game_started =>
          #{game_id => text, white_node_id => text, black_node_id => text,
            position => text, position_hash => integer, to_move => text,
            ply => integer, clocks => {map, [integer]}, status => integer,
            at_ms => integer},
      move_played =>
          #{game_id => text, player_node_id => text, move => text,
            ply => integer, fen_after => text, position_hash => integer,
            halfmove_clock => integer, repetitions => integer, to_move => text,
            clocks => {map, [integer]}, status => integer, at_ms => integer},
      move_refused =>
          #{game_id => text, player_node_id => text, move => text,
            ply => integer, fen_after => text, clocks => {map, [integer]},
            status => integer, at_ms => integer, reason => text},
      clock_flagged =>
          #{game_id => text, player_node_id => text,
            clocks => {map, [integer]}, status => integer, at_ms => integer},
      game_ended =>
          #{game_id => text, winner_node_id => text, fen_after => text,
            ply => integer, clocks => {map, [integer]}, status => integer,
            at_ms => integer, outcome => text, reason => text},
      game_archived =>
          #{game_id => text, reason => text, status => integer,
            at_ms => integer}}.

wire_shape(Fact) ->
    maps:map(fun(_Key, Value) -> wire_type(Value) end, Fact).

wire_type({text, _}) -> text;
wire_type(Value) when is_integer(Value) -> integer;
wire_type(Value) when is_list(Value) -> list;
wire_type(Value) when is_map(Value) -> {map, sorted_types(maps:values(Value))}.

sorted_types([]) -> [];   %% an empty map promises nothing about its values
sorted_types(Values) -> lists:usort([wire_type(Value) || Value <- Values]).

%% The reasons travel as text, the spelling the caller was answered with, and
%% the outcome does too: a subscriber switches on a string, never an Erlang atom
%% it would have to know.
reason_text_test() ->
    Refused = mcl_chess_facts:move_refused(refused_event()),
    ?assertEqual({text, <<"illegal_move">>},
                 mcl_chess_facts:to_wire(maps:get(reason, Refused))),
    Ended = mcl_chess_facts:game_ended(ended_event()),
    ?assertEqual({text, <<"checkmate">>},
                 mcl_chess_facts:to_wire(maps:get(reason, Ended))),
    ?assertEqual({text, <<"winner">>},
                 mcl_chess_facts:to_wire(maps:get(outcome, Ended))).

wire_test_() ->
    Initiated = mcl_chess_facts:to_wire(mcl_chess_facts:game_initiated(initiated_event())),
    [%% Text as CBOR text, flags as 1/0, numbers as they are.
     ?_assertEqual({text, <<"game-0123456789abcdef0123456789abcdef">>},
                   maps:get(game_id, Initiated)),
     ?_assertEqual({text, <<"a1b2">>}, maps:get(initiator_node_id, Initiated)),
     ?_assertEqual(60000, maps:get(white, maps:get(clocks, Initiated))),
     ?_assertEqual(3, maps:get(status, Initiated)),
     ?_assertEqual(#{initial_ms => 60000, increment_ms => 0},
                   maps:get(time_control, Initiated))].

%% An event read back from the store is binary-keyed, and the fact must not
%% depend on which shape it was handed.
binary_keyed_test() ->
    Atom = mcl_chess_facts:game_archived(archived_event()),
    Binary = mcl_chess_facts:game_archived(#{
        <<"game_id">> => <<"game-0123456789abcdef0123456789abcdef">>,
        <<"reason">> => <<"withdrawn">>,
        <<"status">> => 17,
        <<"at_ms">> => 1792435657965}),
    ?assertEqual(Atom, Binary).

%%====================================================================
%% Fixtures
%%====================================================================

initiated_event() ->
    #{game_id => <<"game-0123456789abcdef0123456789abcdef">>,
      protocol => <<"chess">>,
      time_control => {60000, 0},
      seats => #{white => <<>>, black => <<>>},
      position => <<"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1">>,
      to_move => <<"w">>,
      ply => 0,
      clocks => #{white => 60000, black => 60000},
      status => 3,
      initiator_node_id => <<"a1b2">>,
      at_ms => 1792435657965}.

claimed_event() ->
    #{game_id => <<"game-0123456789abcdef0123456789abcdef">>,
      player_node_id => <<"b2c3">>,
      color => <<"b">>,
      seats => #{white => <<"a1b2">>, black => <<"b2c3">>},
      status => 5,
      at_ms => 1792435657965}.

claim_refused_event() ->
    #{game_id => <<"game-0123456789abcdef0123456789abcdef">>,
      player_node_id => <<"c3d4">>,
      color => <<"w">>,
      reason => seat_taken,
      seats => #{white => <<"a1b2">>, black => <<"b2c3">>},
      status => 5,
      at_ms => 1792435657965}.

started_event() ->
    #{game_id => <<"game-0123456789abcdef0123456789abcdef">>,
      white_node_id => <<"a1b2">>,
      black_node_id => <<"b2c3">>,
      position => <<"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1">>,
      position_hash => 123456789,
      to_move => <<"w">>,
      ply => 0,
      clocks => #{white => 60000, black => 60000},
      status => 5,
      at_ms => 1792435657965}.

played_event() ->
    #{game_id => <<"game-0123456789abcdef0123456789abcdef">>,
      player_node_id => <<"a1b2">>,
      move => <<"e2e4">>,
      ply => 1,
      fen_after => <<"rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1">>,
      position_hash => 123456789,
      halfmove_clock => 0,
      repetitions => 1,
      to_move => <<"b">>,
      clocks => #{white => 59000, black => 60000},
      status => 5,
      at_ms => 1792435657965}.

refused_event() ->
    #{game_id => <<"game-0123456789abcdef0123456789abcdef">>,
      player_node_id => <<"a1b2">>,
      move => <<"e1e8">>,
      reason => illegal_move,
      ply => 0,
      fen_after => <<"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1">>,
      clocks => #{white => 60000, black => 60000},
      status => 5,
      at_ms => 1792435657965}.

ended_event() ->
    #{game_id => <<"game-0123456789abcdef0123456789abcdef">>,
      outcome => winner,
      winner_node_id => <<"a1b2">>,
      reason => checkmate,
      fen_after => <<"rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3">>,
      ply => 4,
      clocks => #{white => 58000, black => 57000},
      status => 9,
      at_ms => 1792435657965}.

flagged_event() ->
    #{game_id => <<"game-0123456789abcdef0123456789abcdef">>,
      player_node_id => <<"a1b2">>,
      clocks => #{white => 0, black => 60000},
      status => 5,
      at_ms => 1792435657965}.

archived_event() ->
    #{game_id => <<"game-0123456789abcdef0123456789abcdef">>,
      reason => <<"withdrawn">>,
      status => 17,
      at_ms => 1792435657965}.
