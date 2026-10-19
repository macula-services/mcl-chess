%% @doc The Game aggregate's status names, computed in one place.
%%
%% The integers live in game_status.hrl; this module is the only place a
%% status becomes a label, and the projections call it rather than writing a
%% literal of their own (philosophy/STATUS_LABELS_IN_PROJECTIONS.md). A
%% client that computes a label from an integer is a client that can disagree
%% with the record.
-module(game_status).

-include("game_status.hrl").

-export([initiated/0, open/0, started/0, ended/0, archived/0]).
-export([birth/0, started_from/1, archived_from/1, to_string/1]).

-define(LABELS, #{?GAME_NONE => <<"none">>,
                  ?GAME_INITIATED => <<"initiated">>,
                  ?GAME_OPEN => <<"open">>,
                  ?GAME_STARTED => <<"started">>,
                  ?GAME_ENDED => <<"ended">>,
                  ?GAME_ARCHIVED => <<"archived">>}).

-spec initiated() -> non_neg_integer().
initiated() -> ?GAME_INITIATED.

-spec open() -> non_neg_integer().
open() -> ?GAME_OPEN.

-spec started() -> non_neg_integer().
started() -> ?GAME_STARTED.

-spec ended() -> non_neg_integer().
ended() -> ?GAME_ENDED.

-spec archived() -> non_neg_integer().
archived() -> ?GAME_ARCHIVED.

%% @doc The status a game is born with: it exists and it accepts seat claims.
-spec birth() -> non_neg_integer().
birth() -> ?GAME_INITIATED bor ?GAME_OPEN.

%% @doc The status after the start slice, from whatever the game had.
%%
%% Starting closes the game to claims, so OPEN is cleared and STARTED set.
%% INITIATED stays: the dossier still exists, and every later guard checks it.
-spec started_from(non_neg_integer()) -> non_neg_integer().
started_from(Status) ->
    Cleared = evoq_bit_flags:unset(Status, ?GAME_OPEN),
    evoq_bit_flags:set(Cleared, ?GAME_STARTED).

%% @doc The status after the death slice, from whatever the game had.
%%
%% A pre-start withdrawal archives from OPEN and an ended game archives from
%% ENDED, so both are cleared and then ARCHIVED is set: unset before set, in
%% one expression. INITIATED is never cleared, because it is the "this
%% dossier exists" flag every slice guard checks.
-spec archived_from(non_neg_integer()) -> non_neg_integer().
archived_from(Status) ->
    Cleared = evoq_bit_flags:unset_all(Status, [?GAME_OPEN, ?GAME_ENDED]),
    evoq_bit_flags:set(Cleared, ?GAME_ARCHIVED).

%% @doc The label for a status mask, as stored beside it.
-spec to_string(non_neg_integer()) -> binary().
to_string(Status) ->
    evoq_bit_flags:to_string(Status, ?LABELS).
