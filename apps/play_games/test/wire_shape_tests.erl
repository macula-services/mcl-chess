%% @doc The red proof behind the six responder tests (mcl-om#31).
%%
%% The responder tests now send their requests through `mcl_om_wire_test:call/3',
%% which delivers them as a station does: text keys as `{text, Bin}', the
%% verified caller under the atom key as a raw 32-byte node id, and the reply
%% read back the way a client reads it. This module puts a responder in
%% mcl-chess 0.7.1's shape under that same helper, so the fault those six tests
%% exist to catch cannot quietly come back: the helper sees it refuse, exactly
%% as every real caller was refused (mcl-chess#10).
%%
%% The proof is a green test asserting the refusal on purpose. A test that went
%% red would only be found once it was already breaking the build; this one says
%% what the killing power is, and says it every time the suite runs.
-module(wire_shape_tests).

-include_lib("eunit/include/eunit.hrl").

%% A caller as macula delivers one: the raw 32-byte node id, never the hex form.
-define(CALLER_RAW, crypto:hash(sha256, <<"wire-shape-tests caller">>)).
-define(GAME_ID, <<"game-01a158037b817682ab3c7490dc5588b7">>).

%% A well-formed request, exactly what a converted responder test sends, against
%% the 0.7.1 shape. The responder finds neither field and refuses.
a_responder_that_reads_bare_binary_keys_refuses_a_wire_request_test() ->
    View = mcl_om_wire_test:call(legacy_shape_responder,
                                 #{game_id => ?GAME_ID, move => <<"e2e4">>},
                                 ?CALLER_RAW),
    ?assertEqual(#{<<"error">> => <<"missing_required_fields">>}, View).

%% And this is why no converted test can pass on it: the assertion every one of
%% them makes about a reply, applied here, finds the refusal instead.
a_new_style_assertion_finds_no_game_on_the_071_shape_test() ->
    View = mcl_om_wire_test:call(legacy_shape_responder,
                                 #{game_id => ?GAME_ID},
                                 ?CALLER_RAW),
    ?assertEqual(error, maps:find(<<"game_id">>, View)).
