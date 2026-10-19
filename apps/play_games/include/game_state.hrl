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
    status = 0 :: non_neg_integer(),
    initiator_node_id = <<>> :: binary(),
    at_ms = 0 :: non_neg_integer()
}).
