//! The chess rules, pure and stateless.
//!
//! Every function here is a pure function of a position (a FEN string) and, for
//! a move, a UCI string. Nothing is remembered between calls. That is not an
//! accident of implementation: the referee's state lives in the aggregate and
//! in its event stream, and a rules engine with a memory of its own would make
//! a replay depend on how many times it had been called.
//!
//! The wire speaks ordinary UCI (`e1g1` casts short). cozy-chess speaks
//! Chess960 UCI, where a castle is the king moving onto its own rook
//! (`e1h1`), so [`resolve`] translates the two standard spellings before it
//! asks whether the move is legal. Both spellings are accepted.

use cozy_chess::{Board, File, Move, Piece, Rank, Square};
use std::str::FromStr;

/// Why the rules refused a move, or could not read the position.
///
/// A closed set, because these strings end up in a `move_refused_v1` event on
/// the mesh and a subscriber must be able to switch on them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MoveError {
    /// The FEN does not describe a legal position.
    InvalidFen,
    /// The string is not a UCI move at all: not four squares-plus-promotion
    /// shaped, or a promotion piece that does not exist.
    InvalidMove,
    /// A well-formed move that this position does not allow.
    IllegalMove,
}

impl MoveError {
    /// The wire name, as it appears in an event.
    pub fn as_str(self) -> &'static str {
        match self {
            MoveError::InvalidFen => "invalid_fen",
            MoveError::InvalidMove => "invalid_move",
            MoveError::IllegalMove => "illegal_move",
        }
    }
}

impl std::fmt::Display for MoveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// The four verdicts the referee acts on. A closed set by design (plan §8.7):
/// the 50 move and 75 move draws are claims, not verdicts, and arrive in v2.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    /// Legal moves exist and neither side is dead: play on.
    Active,
    /// The side to move is in check and has no legal move.
    Checkmate,
    /// The side to move is not in check and has no legal move.
    Stalemate,
    /// Neither side can ever deliver mate with the material on the board.
    InsufficientMaterial,
}

impl Verdict {
    /// The wire name, as it appears in an event.
    pub fn as_str(self) -> &'static str {
        match self {
            Verdict::Active => "active",
            Verdict::Checkmate => "checkmate",
            Verdict::Stalemate => "stalemate",
            Verdict::InsufficientMaterial => "insufficient_material",
        }
    }
}

/// Read a position. Both standard and Shredder FEN parse.
pub fn board(fen: &str) -> Result<Board, MoveError> {
    Board::from_str(fen).map_err(|_| MoveError::InvalidFen)
}

/// Is `uci` a legal move in this position?
pub fn validate_move(fen: &str, uci: &str) -> Result<(), MoveError> {
    let position = board(fen)?;
    resolve(&position, uci).map(|_| ())
}

/// Play `uci` in this position.
///
/// Returns the position after the move as a FEN and its Zobrist hash. The hash
/// is what the referee records for repetition, so it is the FIDE one: two
/// positions hash the same when the same moves are available from them (see
/// [`position_hash`]).
pub fn apply_move(fen: &str, uci: &str) -> Result<(String, u64), MoveError> {
    let mut position = board(fen)?;
    let mv = resolve(&position, uci)?;
    position.try_play(mv).map_err(|_| MoveError::IllegalMove)?;
    let hash = position_hash(&position);
    Ok((position.to_string(), hash))
}

/// The Zobrist hash the referee records in `move_played_v1`.
///
/// FIDE counts two positions as the same when the same player is to move, the
/// pieces stand the same, and the moves available are the same. An en passant
/// square left on the board by a double pawn push is only a difference if
/// somebody can actually capture on it, so a position whose en passant right is
/// dead hashes as if the square were not there.
///
/// This matters now, not in v2: the hash is written into the event stream and
/// the threefold check reads those recorded hashes. A hash that told two
/// identical positions apart would under-count a repetition.
pub fn position_hash(position: &Board) -> u64 {
    if playable_en_passant(position).is_some() {
        position.hash()
    } else {
        position.hash_without_ep()
    }
}

/// The en passant file, if a pawn of the side to move can legally capture onto
/// it. cozy-chess's own `same_position` uses this same definition.
fn playable_en_passant(position: &Board) -> Option<File> {
    let ep_file = position.en_passant()?;
    let color = position.side_to_move();
    let ep_square = Square::new(ep_file, Rank::Sixth.relative_to(color));
    cozy_chess::get_pawn_attacks(ep_square, !color)
        .into_iter()
        .find(|&from| {
            position.is_legal(Move {
                from,
                to: ep_square,
                promotion: None,
            })
        })
        .map(|_| ep_file)
}

/// The verdict on a position, given the referee's halfmove clock.
///
/// `halfmove_clock` is the referee's own count, not the FEN's.
///
/// It is taken and documented rather than read, and that is the honest
/// statement of where this stands: no v1 verdict depends on it, because a draw
/// by the move counter is a claim in v2 (plan §10.4), not an automatic verdict
/// in v1. The parameter is in the Design Gate's signature (plan §8.7) and the
/// v2 claim path reads it, so it is not removed here; see mcl-chess#4, which
/// records the consequence: a v1 game whose position stays playable is `active`
/// however long the counter runs, and nothing ends it.
pub fn status(fen: &str, halfmove_clock: u8) -> Result<Verdict, MoveError> {
    let position = board(fen)?;
    Ok(verdict(&position, halfmove_clock))
}

fn verdict(position: &Board, _halfmove_clock: u8) -> Verdict {
    if !position.generate_moves(|_| true) {
        return if position.checkers().is_empty() {
            Verdict::Stalemate
        } else {
            Verdict::Checkmate
        };
    }
    if is_insufficient_material(position) {
        Verdict::InsufficientMaterial
    } else {
        Verdict::Active
    }
}

/// Resolve a UCI string against a position, translating a standard castle
/// spelling into the one cozy-chess uses.
fn resolve(position: &Board, uci: &str) -> Result<Move, MoveError> {
    let mv = parse_uci(uci)?;
    if let Some(castle) = standard_castling(position, mv) {
        if position.is_legal(castle) {
            return Ok(castle);
        }
    }
    if position.is_legal(mv) {
        Ok(mv)
    } else {
        Err(MoveError::IllegalMove)
    }
}

/// A move string is exactly a from square, a to square and an optional
/// promotion piece. Rejecting the shape here rather than leaning on the
/// library means `e7e8k` is `invalid_move`, not a mysterious illegal move.
fn parse_uci(uci: &str) -> Result<Move, MoveError> {
    let bytes = uci.as_bytes();
    let promotion = match bytes.len() {
        4 => true,
        5 => matches!(bytes[4], b'q' | b'r' | b'b' | b'n'),
        _ => false,
    };
    if !promotion {
        return Err(MoveError::InvalidMove);
    }
    Move::from_str(uci).map_err(|_| MoveError::InvalidMove)
}

/// `e1g1` is how the wire spells a short castle; `e1h1` is how cozy-chess
/// spells it. Translate the first into the second when the position really has
/// that castle available, and leave everything else alone.
///
/// A quiet king move to g1 is not a thing that exists (a king moves one
/// square), so there is no ambiguity to preserve: `e1g1` with no castle
/// available is simply illegal, which is what the final legality check says.
fn standard_castling(position: &Board, mv: Move) -> Option<Move> {
    if mv.promotion.is_some() {
        return None;
    }
    let color = position.side_to_move();
    let king = position.king(color);
    if mv.from != king {
        return None;
    }
    let back = Rank::First.relative_to(color);
    let rights = position.castle_rights(color);
    let rook = match mv.to {
        square if square == Square::new(File::G, back) => rights.short?,
        square if square == Square::new(File::C, back) => rights.long?,
        _ => return None,
    };
    Some(Move {
        from: king,
        to: Square::new(rook, back),
        promotion: None,
    })
}

/// No pawn, rook or queen anywhere, and one of the dead-material shapes:
/// bare kings, a lone minor piece, or one bishop each on the same colour.
///
/// The last shape is the one that catches people: two bishops on the same
/// colour of square never meet, so neither side can mate. Two bishops on
/// opposite colours, or a bishop against a knight, can mate with help and are
/// therefore not dead.
fn is_insufficient_material(position: &Board) -> bool {
    let has_piece = |piece: Piece| position.pieces(piece).into_iter().next().is_some();
    if [Piece::Pawn, Piece::Rook, Piece::Queen]
        .iter()
        .any(|&piece| has_piece(piece))
    {
        return false;
    }
    let knights = count(position.pieces(Piece::Knight));
    let bishops = count(position.pieces(Piece::Bishop));
    match knights + bishops {
        0 | 1 => true,
        _ => bishops == 2 && knights == 0 && bishops_share_a_colour(position),
    }
}

fn count(squares: cozy_chess::BitBoard) -> usize {
    squares.into_iter().count()
}

fn bishops_share_a_colour(position: &Board) -> bool {
    let mut squares = position.pieces(Piece::Bishop).into_iter();
    match (squares.next(), squares.next()) {
        (Some(first), Some(second)) => square_colour(first) == square_colour(second),
        _ => false,
    }
}

fn square_colour(square: Square) -> usize {
    (square.file() as usize + square.rank() as usize) % 2
}
