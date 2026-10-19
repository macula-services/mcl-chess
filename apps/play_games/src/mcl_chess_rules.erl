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

-export([validate_move/2, apply_move/2, status/2, position_hash/1, cannot_mate/2]).

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
%% Returns the position after the move as a FEN, the FIDE Zobrist hash of it,
%% and the halfmove-reset flag: 1 when the move reset the counter (a pawn moved,
%% or something was captured), 0 when it did not. Two positions hash the same when the same moves are available
%% from them, which is the definition repetition is counted with.
%%
%% The third element is why the referee keeps its own counter: the library's
%% counter is a byte clamped to 100, and the 75 move rule fires at 150, so
%% `status/2' is handed the referee's count and this is the one bit it needs to
%% keep it.
-spec apply_move(binary(), binary()) ->
          {ok, binary(), non_neg_integer(), 0 | 1} | {error, move_error()}.
apply_move(_Fen, _Uci) ->
    ?NOT_LOADED.

%% @doc The Zobrist hash of a position, without playing a move into it.
%%
%% The aggregate records the hash a game starts from, because a repetition can
%% return to it and a count that began at the first move would miss one.
-spec position_hash(binary()) -> non_neg_integer() | {error, invalid_fen}.
position_hash(_Fen) ->
    ?NOT_LOADED.

%% @doc The verdict on this position.
%%
%% `HalfmoveClock' is the referee's own count rather than the FEN's field: the
%% library's field is a byte clamped to 100 and the 75 move rule fires at 150.
%% Reaching 150 ends the game as a draw (`seventy_five_moves'), unless the move
%% that got there was checkmate, which wins. A position that is dead on its own
%% terms reports its own reason instead.
%%
%% The fivefold draw is NOT here: it is not a function of one position, so the
%% aggregate counts it over the hashes its events recorded.
-spec status(binary(), non_neg_integer()) ->
          active | checkmate | stalemate | insufficient_material
              | seventy_five_moves | {error, invalid_fen}.
status(_Fen, _HalfmoveClock) ->
    ?NOT_LOADED.

%% @doc FIDE 6.9, asked of one colour: can it mate at all in this position?
%%
%% 1 when it cannot checkmate the other king by any possible series of legal
%% moves, 0 when it can. A flag asks this about the side that would otherwise be
%% credited with the win, because a game is drawn when that side cannot mate:
%% `status/2''s `insufficient_material' is the wrong question there, since it
%% asks whether neither side can mate.
%%
%% "Any possible series" includes the flagged player's own moves, so a lone
%% minor piece can mate a king whose side still has a piece to block a flight
%% square. The material test is the usual one: no pawn, rook or queen, and at
%% most one minor piece, against an opponent with nothing at all.
-spec cannot_mate(binary(), binary()) ->
          1 | 0 | {error, invalid_fen | invalid_move}.
cannot_mate(_Fen, _Colour) ->
    ?NOT_LOADED.

init() ->
    Dir = case code:priv_dir(play_games) of
              {error, _} -> filename:join(filename:dirname(filename:dirname(code:which(?MODULE))), "priv");
              Priv -> Priv
          end,
    erlang:load_nif(filename:join([Dir, "lib", "libmcl_chess_rules"]), 0).
