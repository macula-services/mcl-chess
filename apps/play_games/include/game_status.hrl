%% @doc The Game aggregate's status flags, as evoq_bit_flags integers.
%%
%% The house rule (philosophy/STATUS_LABELS_IN_PROJECTIONS.md): status is a
%% bit-flag integer, never a string and never a bare atom, and the label is
%% computed where it is stored. Every flag is a power of two.
%%
%% Which bit an event sets and unsets is business logic and is written down
%% per event in the plan (mcl-chess#1, section 3.1), not inferred here.
-define(GAME_NONE,      0).  %% 2#00000000
-define(GAME_INITIATED, 1).  %% 2#00000001: the dossier exists
-define(GAME_OPEN,      2).  %% 2#00000010: accepting seat claims
-define(GAME_STARTED,   4).  %% 2#00000100: playing, a clock is running
-define(GAME_ENDED,     8).  %% 2#00001000: terminal, outcome recorded
-define(GAME_ARCHIVED, 16).  %% 2#00010000: the death slice ran
