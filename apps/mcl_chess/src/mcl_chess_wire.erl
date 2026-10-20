%% @doc What this service's answers look like on the wire, in one place.
%%
%% A reply leaves over CBOR, and on that wire a plain `binary()' is a BYTE
%% string (major type 2), not text: a client that receives `<<"checkmate">>'
%% untagged gets an opaque blob, not the word, and a client comparing an
%% opaqued game id against the id it just sent finds no match. Text must go
%% out as `{text, Bin}' (major type 3), and booleans as 1/0, because the wire
%% carries no boolean.
%%
%% THE READS HAVE A MATCHING HAZARD, and it is `mcl_om_wire' rather than this
%% module: an inbound payload's text keys arrive as `{text, Bin}', and its
%% `caller' arrives under the atom key. `mcl_om_wire:field/2,3' and
%% `mcl_om_wire:caller/1' are how a handler reads either.
%%
%% Facts published to the mesh already went through this conversion; the
%% capability replies need exactly the same one, which is why it has a name.
-module(mcl_chess_wire).

-export([to_wire/1, caller/1]).

%% @doc Text as CBOR text, booleans as 1/0, numbers and shapes as they are.
%%
%% Recurses through lists and map values. Keys are left alone: macula encodes
%% every map key as CBOR text, so a binary key already arrives as one.
-spec to_wire(term()) -> term().
to_wire(B) when is_binary(B) -> {text, B};
to_wire(true) -> 1;
to_wire(false) -> 0;
to_wire(L) when is_list(L) -> [to_wire(E) || E <- L];
to_wire(M) when is_map(M) -> maps:map(fun(_K, V) -> to_wire(V) end, M);
to_wire(Other) -> Other.

%% @doc The caller macula verified, as the 64-character hex node id this
%% service stores, compares and publishes.
%%
%% macula injects it as the RAW 32-byte node id (macula_frame's `id256()',
%% merged by macula_station_link:with_caller/2), and a raw id cannot go back
%% out as text: CBOR text must be valid UTF-8, and 32 random bytes usually are
%% not, so a reply or a fact carrying one is refused as invalid_text and the
%% caller gets unknown_error with nothing to act on. The events, the seats and
%% the facts hold the hex form everywhere else, so the conversion happens once,
%% here, at the boundary, and everything downstream agrees.
%%
%% A 64-character caller is passed through unchanged, so this stays correct if
%% an mcl_om helper (mcl-om#30) starts handing back hex. The same convention as
%% mcl_om_guard's own wire_caller/1.
-spec caller(map()) -> binary() | undefined.
caller(Payload) ->
    hex(mcl_om_wire:caller(Payload)).

hex(undefined) -> undefined;
hex(Caller) when is_binary(Caller), byte_size(Caller) =:= 32 ->
    binary:encode_hex(Caller, lowercase);
hex(Caller) -> Caller.
