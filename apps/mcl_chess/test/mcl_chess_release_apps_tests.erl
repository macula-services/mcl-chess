%% @doc The apps the release names, asserted against the release version.
%%
%% relx builds a release from rebar.config's `{release, {mcl_chess, "x.y.z"},
%% [app, ...]}', and each app in that list carries its own vsn in its .app.src.
%% Nothing reads the two together, so the desk apps sat at 0.1.0 through v0.7.2
%% while the release said 0.7.2 (mcl-chess#11). The release guard refuses such a
%% tag before it is signed; this fails sooner, on the eunit run that bumps the
%% release and forgets an app.
-module(mcl_chess_release_apps_tests).

-include_lib("eunit/include/eunit.hrl").

every_release_app_carries_the_release_version_test() ->
    {Vsn, Apps} = release(),
    Own = [{App, app_vsn(App)} || App <- Apps, app_vsn(App) =/= not_in_repo],
    %% A check over an empty list passes for the wrong reason, so it is asserted
    %% that the release really named this repository's apps.
    ?assert(length(Own) >= 2),
    ?assertEqual([], [{App, V} || {App, V} <- Own, V =/= Vsn]).

%%==============================================================================

%% The release tuple, and every app it names. The app list may wrap across
%% lines, which is why it is read with a pattern rather than line by line.
release() ->
    {match, [Vsn, List]} =
        re:run(read("rebar.config"),
               "\\{release, \\{mcl_chess, \"([^\"]+)\"\}[,\\s]*\\[([^]]*)\\]",
               [{capture, all_but_first, binary}]),
    {binary_to_list(Vsn),
     [list_to_atom(App) || App <- string:lexemes(binary_to_list(List), ", ")]}.

%% An app the release names that lives outside this repository, sasl above all,
%% has no .app.src here. The release guard skips those for the same reason.
app_vsn(App) ->
    Name = atom_to_list(App),
    case file:read_file(alongside(filename:join(["apps", Name, "src", Name ++ ".app.src"]))) of
        {ok, Text} ->
            {match, [V]} = re:run(Text, "\\{vsn, \"([^\"]+)\"",
                                  [{capture, all_but_first, binary}]),
            binary_to_list(V);
        {error, _} ->
            not_in_repo
    end.

read(Name) ->
    {ok, Text} = file:read_file(alongside(Name)),
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
