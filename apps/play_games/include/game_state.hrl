%% @doc One game's state, as the aggregate folds it out of its own stream.
%%
%% Every field is derivable by replay: position and clocks included. Nothing
%% here is read from a read model, and nothing here is a wall-clock reading;
%% `at_ms' on the events is the service's own clock.
-record(game_state, {
    game_id       :: binary(),
    protocol = <<"chess">> :: binary(),
    %% {InitialMs, IncrementMs}. Caps are validated at the boundary, not here.
    %% {0, 0} until the birth event sets it: a state record exists the moment
    %% the aggregate starts, which is before any event has been folded.
    time_control = {0, 0} :: {non_neg_integer(), non_neg_integer()},
    %% By color, not by role: the initiator is not pinned to white. An empty
    %% binary is an unfilled seat.
    seats = #{white => <<>>, black => <<>>} :: #{white := binary(), black := binary()},
    %% FEN after the last played move; the start position until then.
    position = <<"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1">> :: binary(),
    to_move = <<"w">> :: binary(),
    ply = 0 :: non_neg_integer(),
    %% Remaining milliseconds per color, derived from the time control and
    %% the events' at_ms.
    clocks = #{white => 0, black => 0} :: #{white := integer(), black := integer()},
    %% THE REFEREE'S OWN halfmove count, not the FEN's. cozy-chess keeps the
    %% FEN's field as a byte clamped to 100, and the 75 move rule fires at 150,
    %% so the count is kept here: reset to 0 by a pawn move or a capture, one
    %% more otherwise. Replay rebuilds it from the events' own field.
    halfmove_clock = 0 :: non_neg_integer(),
    %% The Zobrist hashes of the positions this game has stood in, newest
    %% first, the start position included. Trimmed at every irreversible move,
    %% because no position before one can recur. Fivefold repetition is the
    %% count of the head in this list, and it is why these are recorded.
    hashes = [] :: [non_neg_integer()],
    status = 0 :: non_neg_integer(),
    %% Set by game_ended_v1 and never undone: who won, and why the game ended.
    %% `none' until the end slice runs.
    outcome = none :: none | winner | draw | forfeit | abandoned,
    winner_node_id = <<>> :: binary(),
    end_reason = none :: none | checkmate | stalemate | insufficient_material
                       | seventy_five_moves | fivefold_repetition
                       | clock_flag | resignation | withdrawn,
    initiator_node_id = <<>> :: binary(),
    %% Recorded refusals per node id: the one piece of state that is not in the
    %% game itself, and the thing that bounds the evidence stream. Replay
    %% rebuilds it from the events, so it is part of the state, not of a desk.
    refusals = #{} :: #{binary() => non_neg_integer()},
    at_ms = 0 :: non_neg_integer()
}).
