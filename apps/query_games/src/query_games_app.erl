%% @doc OTP application entry for the QRY division.
-module(query_games_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) -> query_games_sup:start_link().

stop(_State) -> ok.
