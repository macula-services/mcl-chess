%% @doc OTP application entry for the CMD division.
-module(play_games_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) -> play_games_sup:start_link().

stop(_State) -> ok.
