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
     %% The id is in the payload, never the topic: one subscription serves
     %% every game.
     ?_assertEqual(nomatch, binary:match(mcl_chess_facts:topic(
                                           mcl_chess_facts:realm_name(), game_initiated),
                                         <<"game-">>)),
     ?_assertEqual(<<"io.macula">>, mcl_chess_facts:realm_name())].

keys_test_() ->
    Initiated = mcl_chess_facts:game_initiated(initiated_event()),
    Archived = mcl_chess_facts:game_archived(archived_event()),
    [?_assertEqual([at_ms, clocks, game_id, initiator_node_id, ply, position,
                    protocol, seats, status, time_control, to_move],
                   lists:sort(maps:keys(Initiated))),
     ?_assertEqual([at_ms, game_id, reason, status],
                   lists:sort(maps:keys(Archived)))].

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

archived_event() ->
    #{game_id => <<"game-0123456789abcdef0123456789abcdef">>,
      reason => <<"withdrawn">>,
      status => 17,
      at_ms => 1792435657965}.
