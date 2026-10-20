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

-export([to_wire/1]).

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
