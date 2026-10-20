%% @doc The service contract, asserted locally.
%%
%% mcl_om resolves its six callbacks BY NAME at startup, on a live node, so a
%% service that forgets one dies with `undef' where nobody is watching. The
%% primary defence is the `-behaviour(mcl_om_service)' attribute on the
%% service module, which turns a missing callback into a compile error under
%% warnings_as_errors.
%%
%% What this suite adds is everything the compiler cannot see: that the attribute
%% has not been quietly dropped, that the values inside those callbacks are the
%% shapes mcl_om will destructure, and that the names and version this service
%% reports are the ones it actually has. Nothing local boots mcl_om, so
%% asserting the shape by hand is the closest available thing to a rehearsal.
-module(mcl_chess_service_tests).

-include_lib("eunit/include/eunit.hrl").

-define(APP, mcl_chess).
-define(SERVICE, mcl_chess_service).

%% Belt and braces with the behaviour attribute, and it survives the attribute
%% being removed. If mcl_om ever adds a SEVENTH required callback this test
%% keeps passing and the deploy still breaks, which is the honest limit of a
%% local assertion about a remote contract.
exports_every_required_callback_test() ->
    _ = code:ensure_loaded(?SERVICE),
    Required = [{info, 0}, {start, 1}, {stop, 1},
                {health, 0}, {capabilities, 0}, {identity_spec, 0}],
    Missing = [F || {N, A} = F <- Required,
                    not erlang:function_exported(?SERVICE, N, A)],
    ?assertEqual([], Missing).

%% THE ATTRIBUTE ITSELF. Dropped to silence a warning, it would leave compile
%% and the export check above green, and the next callback mcl_om requires
%% would be an `undef' at boot instead of a compile error.
declares_the_mcl_om_service_behaviour_test() ->
    Attrs = ?SERVICE:module_info(attributes),
    ?assert(lists:member(mcl_om_service, proplists:get_value(behaviour, Attrs, []))).

info_carries_the_three_keys_test() ->
    #{name := Name, version := Vsn, description := Desc} = ?SERVICE:info(),
    ?assert(is_binary(Name)),
    ?assert(is_binary(Vsn)),
    ?assert(is_binary(Desc)),
    ?assertEqual(<<"mcl-chess">>, Name).

%% THE TWO NAMES MUST AGREE. The OTP application is snake_case because it is an
%% Erlang atom; the repository, the container image and the name this service
%% answers to on the mesh are kebab-case. They describe one service, so a
%% scaffold generated with a mismatched pair is caught here on the first eunit
%% run rather than by a puzzled reader months later.
mesh_name_matches_the_application_test() ->
    #{name := Wire} = ?SERVICE:info(),
    Snake = atom_to_binary(?APP, utf8),
    ?assertEqual(binary:replace(Snake, <<"_">>, <<"-">>, [global]), Wire).

%% The version in info/0 is what a peer reads off /health, so it disagreeing with
%% the application it describes is a lie that nothing else would catch.
info_version_matches_the_application_test() ->
    _ = application:load(?APP),
    {ok, Vsn} = application:get_key(?APP, vsn),
    #{version := Reported} = ?SERVICE:info(),
    ?assertEqual(list_to_binary(Vsn), Reported).

health_is_green_test() ->
    ?assertEqual(ok, ?SERVICE:health()).

%% The capabilities the service serves on the wire. The assertion is here so
%% that adding or removing one breaks a test and makes someone write down
%% what the service can now actually do: a capability is a promise that
%% something answers, and the internal slices (start_game, flag_clock,
%% end_game, archive_game) are deliberately not on this list.
%%
%% claim_seat joined in WP3: a seat is claimed by the caller itself, from the
%% node id macula verified, and never by a body naming somebody else.
%%
%% submit_move and resign_game joined in WP5: a move is played by the seat the
%% caller holds, and a resignation is the caller's own. end_game and flag_clock
%% stay off this list, like start_game and archive_game: they are dispatched by
%% policies, not by callers.
announces_the_wire_capabilities_test() ->
    ?assertEqual([<<"claim_seat">>, <<"get_game_by_id">>, <<"initiate_game">>,
                  <<"resign_game">>, <<"submit_move">>, <<"withdraw_game">>],
                 lists:sort([maps:get(name, C) || C <- ?SERVICE:capabilities()])).

%% Every announced capability names a module that exists and implements the
%% handler contract: an entry naming nothing is worse than no entry at all.
each_capability_names_a_real_handler_test() ->
    [?assertMatch({module, _}, code:ensure_loaded(Module))
     || #{handler := {Module, _}} <- ?SERVICE:capabilities()].

identity_spec_has_the_shape_mcl_om_expects_test() ->
    #{scope := Scope, actions := Actions,
      resources := Resources, ttl_days := Ttl} = ?SERVICE:identity_spec(),
    ?assert(is_binary(Scope)),
    ?assert(is_list(Actions)),
    ?assert(is_list(Resources)),
    ?assert(is_integer(Ttl) andalso Ttl > 0).

%% The service answers four capabilities and asks the realm for exactly those
%% procedures, nothing more: popped, an attacker gains one namespace and no
%% more.
authority_matches_what_is_announced_test() ->
    #{scope := Scope, resources := Resources} = ?SERVICE:identity_spec(),
    ?assertEqual(<<"mcl-chess">>, Scope),
    ?assertEqual([], Resources),
    ?assertEqual(6, length(?SERVICE:capabilities())).

%% The supervisor starts and stops cleanly on its own, without mcl_om. It has
%% no children as generated; this asserts the tree is startable, not that it does
%% any work.
supervisor_starts_and_stops_test() ->
    {ok, Pid} = mcl_chess_sup:start_link(),
    ?assert(is_process_alive(Pid)),
    ?assertEqual([], supervisor:which_children(Pid)),
    unlink(Pid),
    exit(Pid, shutdown).

%%==============================================================================
%% The config the store cannot boot without
%%==============================================================================

%% ⚠ A SIBLING SERVICE'S FLEET CRASH-LOOPED ON TWO OF THREE NODES FOR WANT OF THE
%% `evoq' BLOCK.
%%
%% mcl_chess_app opens the store AND a per-store evoq subscription before
%% `mcl_om:boot/1'. That subscription reads through evoq, which raises
%% `{not_configured, event_store_adapter}' unless sys.config names the adapter,
%% and evoq starts as a release-boot application before any service's `start/2'
%% runs, so nothing can inject it later.
%%
%% This reads the shipped config template, because the failure is a MISSING BLOCK
%% and no amount of exercising the code can notice something that is not there.
%% It compares the Erlang side of a boundary against the config side, which is
%% what neither side's own tests can do.
the_evoq_adapter_is_configured_wherever_a_store_is_opened_test() ->
    {ok, Text} = file:read_file(alongside("config/sys.config.src")),
    ?assert(erlang:function_exported(?SERVICE, event_store, 0)),
    lists:foreach(
      fun(Needed) ->
              ?assertNotEqual(nomatch, binary:match(Text, Needed),
                              {missing_from_sys_config, Needed})
      end,
      [<<"{evoq,">>, <<"event_store_adapter">>, <<"subscription_adapter">>,
       <<"reckon_evoq_adapter">>]).

%% ⚠ AND THE STORE ID IS IN TWO PLACES, WHICH IS ONE MORE THAN IT SHOULD BE.
%% `event_store/0''s `id' is what mcl_chess_app opens; the `{store_id, ...}' in the evoq block
%% is what evoq falls back to when it resolves a dispatch before knowing there is
%% none. Nothing makes them agree, and disagreeing opens one store and addresses
%% another. Same boundary guard, other side.
the_store_id_agrees_between_erlang_and_config_test() ->
    {ok, Text} = file:read_file(alongside("config/sys.config.src")),
    Declared = atom_to_binary(maps:get(id, ?SERVICE:event_store()), utf8),
    ?assertNotEqual(nomatch, binary:match(Text, Declared),
                    {store_id_not_in_sys_config, Declared}).

%% EVERY VARIABLE REFERENCE IN A RELX TEMPLATE IS A PLAIN NAME (mcl-chess#9).
%%
%% relx expands `vm.args.src' and `sys.config.src' with an awk whose loop is
%% `while(match($0, "[$]{[^}]*}"))' and whose replacement pattern is BUILT FROM
%% the text between the braces. A shell-style form in there (`:?` for a required
%% variable, `:-` for a default) becomes a regular expression where those
%% characters mean something else, the pattern then matches nothing, the loop
%% never advances, and the container spins at one core before printing a line.
%% That is how 0.7.0's first deployment failed, from a COMMENT in
%% `vm.args.src', so comments are checked too: the awk does not skip them.
%%
%% A `:-' default does terminate the loop, so it is only the required-variable
%% form that hangs. Both are refused here, because a default is expanded by the
%% awk's own branching and by nothing else, and one rule is easier to hold than
%% a table of which forms happen to work.
template_variable_references_are_plain_names_test_() ->
    [?_assertEqual({File, []}, {File, bad_references(shipped(File))})
     || File <- ["config/vm.args.src", "config/sys.config.src"]].

bad_references(Text) ->
    Tokens = captured(re:run(Text, "\\$\\{([^}]*)\\}", [global, {capture, all_but_first, binary}])),
    [Token || [Token] <- Tokens, not plain_name(Token)].

captured({match, Captures}) -> Captures;
captured(nomatch) -> [].

plain_name(Token) ->
    re:run(Token, "^[A-Z_][A-Z0-9_]*$", [{capture, none}]) =:= match.

%% The data directory must be somewhere, and a laptop default is fine. What is
%% not fine is shipping that default to a node, which is why the generated
%% compose file mounts a volume and sets the variable this reads.
the_data_directory_is_answerable_test() ->
    Dir = maps:get(dir, ?SERVICE:event_store()),
    ?assert(is_list(Dir)),
    ?assertNotEqual("", Dir).

%% ⚠ NOT THE OLD CONTRACT'S NAMES. mcl_om warns at every boot about a service
%% module exporting store_id/0 and data_dir/0 together, the shape of a service
%% built before 0.35; this one opens its own store and must not look like one.
no_old_store_callbacks_are_exported_test() ->
    ?assertEqual([], mcl_om:leftover_store_callbacks(?SERVICE)).

%%==============================================================================
%% No shared cookie ships, and distribution is not on every interface
%%==============================================================================

%% ⚠ THIS GUARD EXISTS BECAUSE THE TEMPLATE SHIPPED BOTH FAULTS (mcl-om#24).
%%
%% `ENV MCL_COOKIE=<the service name>' baked one public cookie into every pull
%% of the image, and `@127.0.0.1' as the node name is what epmd ADVERTISES, not
%% where the dist listener binds: with host networking the listener was on every
%% interface behind a guessable secret.
%%
%% Distribution is deliberately KEPT, because the Ra member identity is node()
%% and a nameless node is pinned to nonode@nohost forever. What must hold is
%% that the secret comes from the box at run time and that both halves of dist
%% stay on loopback. Neither half can be noticed by running the code, so this
%% reads the three shipped files, in the same spirit as the runtime pin above.
no_cookie_ships_and_distribution_stays_on_loopback_test() ->
    Containerfile = shipped("Containerfile"),
    ?assertEqual(nomatch, binary:match(Containerfile, <<"ENV MCL_COOKIE">>),
                 {cookie_baked_into_the_image, <<"ENV MCL_COOKIE">>}),
    ?assertNotEqual(nomatch,
                    binary:match(Containerfile, <<"ENV ERL_EPMD_ADDRESS=127.0.0.1">>),
                    {epmd_not_bound_to_loopback, <<"Containerfile">>}),
    VmArgs = shipped("config/vm.args.src"),
    ?assertNotEqual(nomatch, binary:match(VmArgs, <<"-setcookie ${MCL_COOKIE}">>),
                    {cookie_not_read_from_the_environment, <<"config/vm.args.src">>}),
    ?assertNotEqual(nomatch,
                    binary:match(VmArgs,
                                 <<"-kernel inet_dist_use_interface {127,0,0,1}">>),
                    {dist_listener_not_bound_to_loopback, <<"config/vm.args.src">>}),
    Compose = shipped("deploy/docker-compose.yml"),
    ?assertNotEqual(nomatch, binary:match(Compose, <<"MCL_COOKIE=${MCL_COOKIE:?">>),
                    {compose_does_not_refuse_to_start_without_a_cookie,
                     <<"deploy/docker-compose.yml">>}).
%%==============================================================================
%% The runtime is pinned in two places, and neither is the one you are running
%%==============================================================================

%% ⚠ THIS GUARD EXISTS BECAUSE A SIBLING SERVICE DID NOT HAVE IT, AND IT COST
%% THREE COMMITS AND AN IMAGE THAT SHIPPED ANYWAY.
%%
%% Its `Containerfile' said 27 while development ran on 28. So `rebar3 eunit'
%% passing locally meant "passing on 28" and nothing more, CI failed on a crash
%% that does not occur on 28 at all, and because the image build is a separate
%% workflow the image went to the fleet regardless.
%%
%% The release is pinned in TWO files, and the version actually running is a
%% third thing that agrees with neither by default. **A comment in each file
%% saying they must match is not a mechanism**, and both files carried one.
%%
%% ⚠⚠ IT FAILS RATHER THAN WARNS WHEN YOUR VM DIFFERS, AND THAT IS DELIBERATE.
%% Developing on a release you do not ship makes a green suite mean less than it
%% appears to. If you want to work on another release, move both pins and find
%% out what breaks, which is the whole point of having them.
%%
%% ⚠ TO THE PATCH, AND NOTHING FLOATS. This compared majors only, so when Docker
%% Hub moved the floating `erlang:28-alpine' on 2026-09-22 a service generated
%% from this template shipped OTP 28.5 and its guard stayed green. An image's
%% tag need not name a release, so the builder stage and lint each ASSERT one
%% in a check step; this compares those, .tool-versions and this VM, to the
%% patch.
the_runtime_agrees_between_the_image_the_ci_and_this_vm_test() ->
    Check = "\\{<<\"([0-9]+\\.[0-9]+\\.[0-9]+)\">>, true\\} -> halt\\(0\\);",
    Image = pinned("Containerfile", Check),
    CiCheck = pinned(".github/workflows/lint.yml", Check),
    Tools = pinned(".tool-versions", "^erlang ([0-9]+\\.[0-9]+\\.[0-9]+)$"),
    %% Sorted and deduplicated, so a failure prints every version rather than
    %% the first pair that happened to be compared.
    ?assertEqual([Image], lists:usort([Image, CiCheck, Tools, running_otp()])).

%% CI tests in the image that builds, and neither image can move under a tag.
%% The builder stage and lint name ONE image, so a green lint is a statement
%% about the toolchain the release is built with; both FROM lines carry a
%% digest, so a re-pushed tag cannot change what builds or what runs.
ci_builds_in_the_builder_and_both_images_are_digest_pinned_test() ->
    Digest = "@sha256:[0-9a-f]{64}",
    Builder = pinned("Containerfile", "^FROM (\\S+" ++ Digest ++ ") AS builder$"),
    ?assertMatch(<<_/binary>>, pinned("Containerfile", "^FROM (\\S+" ++ Digest ++ ")$")),
    ?assertEqual(Builder, pinned(".github/workflows/lint.yml", "^\\s+image: (\\S+)$")).

%% The full release, 28.4.3 and not 28: `otp_release' names only the major.
running_otp() ->
    {ok, Version} = file:read_file(filename:join([code:root_dir(), "releases",
                                                  erlang:system_info(otp_release),
                                                  "OTP_VERSION"])),
    string:trim(Version).

pinned(Relative, Pattern) ->
    {ok, Text} = file:read_file(alongside(Relative)),
    {match, [Version]} = re:run(Text, Pattern,
                                [multiline, {capture, all_but_first, binary}]),
    Version.

%% A shipped file, read as text: the guards above are about what the repo and
%% the image carry, not about what the running code does.
shipped(Relative) ->
    {ok, Text} = file:read_file(alongside(Relative)),
    Text.

%% Relative to the beam rather than the working directory, because eunit runs
%% from wherever the developer happens to be standing.
alongside(Name) -> climb(filename:dirname(code:which(?MODULE)), Name, 8).

climb(_Dir, Name, 0) -> Name;
climb(Dir, Name, Left) ->
    Candidate = filename:join(Dir, Name),
    found(filelib:is_regular(Candidate), Candidate, Dir, Name, Left).

found(true, Candidate, _Dir, _Name, _Left) -> Candidate;
found(false, _Candidate, Dir, Name, Left) ->
    climb(filename:dirname(Dir), Name, Left - 1).
