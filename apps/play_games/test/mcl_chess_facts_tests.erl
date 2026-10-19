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
     ?_assertEqual(<<"io.macula/mcl-chess/chess/game/game_archived_v1">>,
                   mcl_chess_facts:topic(mcl_chess_facts:realm_name(), game_archived)),
     ?_assertEqual(<<"io.macula/mcl-chess/chess/game/move_played_v1">>,
                   mcl_chess_facts:topic(mcl_chess_facts:realm_name(), move_played)),
     ?_assertEqual(<<"io.macula/mcl-chess/chess/game/move_refused_v1">>,
                   mcl_chess_facts:topic(mcl_chess_facts:realm_name(), move_refused)),
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
    Played = mcl_chess_facts:move_played(played_event()),
    Refused = mcl_chess_facts:move_refused(refused_event()),
    Ended = mcl_chess_facts:game_ended(ended_event()),
    [?_assertEqual([at_ms, clocks, game_id, initiator_node_id, ply, position,
                    protocol, seats, status, time_control, to_move],
                   lists:sort(maps:keys(Initiated))),
     ?_assertEqual([at_ms, game_id, reason, status],
                   lists:sort(maps:keys(Archived))),
     %% A move is published with the counts the referee judged on, so a
     %% consumer that re-derives a verdict and one that reads the record agree.
     ?_assertEqual([at_ms, clocks, fen_after, game_id, halfmove_clock, move,
                    player_node_id, ply, position_hash, repetitions, status,
                    to_move],
                   lists:sort(maps:keys(Played))),
     ?_assertEqual([at_ms, clocks, fen_after, game_id, move, player_node_id,
                    ply, reason, status],
                   lists:sort(maps:keys(Refused))),
     ?_assertEqual([at_ms, clocks, fen_after, game_id, outcome, ply, reason,
                    status, winner_node_id],
                   lists:sort(maps:keys(Ended)))].

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

archived_event() ->
    #{game_id => <<"game-0123456789abcdef0123456789abcdef">>,
      reason => <<"withdrawn">>,
      status => 17,
      at_ms => 1792435657965}.
