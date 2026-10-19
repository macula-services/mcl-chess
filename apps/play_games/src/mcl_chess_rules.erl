%%% @doc The chess rules the referee calls.
%%%
%%% A thin wrapper over `native/mcl_chess_rules', a Rust NIF built on
%%% cozy-chess (MIT; the licensing decision is recorded in the design of
%%% record, mcl-chess#1). Every function is a pure function of a position: the
%%% referee's state lives in its aggregate and its event stream, never here, so
%%% a replay gives the same answers as the live game.
%%%
%%% The `.so` is built by `scripts/build-nif.sh' and lives in this app's
%%% `priv/lib', which relx copies into the release.
%%%
%%% Moves are UCI on the wire: a from square, a to square and, for a promotion,
%%% the piece. Castling may be spelled the ordinary way (`e1g1', `e1c1',
%%% `e8g8', `e8c8') or the Chess960 way (`e1h1', `e1a1'); both are accepted.
-module(mcl_chess_rules).

-export([validate_move/2, apply_move/2, status/2]).

-on_load(init/0).

%% Every export falls through to this until the NIF is loaded. Erlang refuses
%% to load the module at all if the NIF fails, so a missing library is loud at
%% boot rather than a surprise on the first move.
-define(NOT_LOADED, erlang:nif_error({nif_not_loaded, ?MODULE})).

-type move_error() :: invalid_fen | invalid_move | illegal_move.

%% @doc Is this UCI move legal in this position?
-spec validate_move(binary(), binary()) -> ok | {error, move_error()}.
validate_move(_Fen, _Uci) ->
    ?NOT_LOADED.

%% @doc Play this UCI move.
%%
%% Returns the position after the move as a FEN and the FIDE Zobrist hash of
%% it: two positions hash the same when the same moves are available from
%% them, which is the definition threefold repetition is counted with.
-spec apply_move(binary(), binary()) ->
          {ok, binary(), non_neg_integer()} | {error, move_error()}.
apply_move(_Fen, _Uci) ->
    ?NOT_LOADED.

%% @doc The verdict on this position.
%%
%% `HalfmoveClock' is the referee's own count rather than the FEN's field. No
%% v1 verdict depends on it: a draw by the move counter is a claim, and claims
%% are v2 (mcl-chess#1). It is here because the Design Gate fixed the signature
%% and the v2 claim reads it.
-spec status(binary(), non_neg_integer()) ->
          active | checkmate | stalemate | insufficient_material
              | {error, invalid_fen}.
status(_Fen, _HalfmoveClock) ->
    ?NOT_LOADED.

init() ->
    Dir = case code:priv_dir(play_games) of
              {error, _} -> filename:join(filename:dirname(filename:dirname(code:which(?MODULE))), "priv");
              Priv -> Priv
          end,
    erlang:load_nif(filename:join([Dir, "lib", "libmcl_chess_rules"]), 0).
