%% @doc OTP application entry for the PRJ division.
-module(project_games_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) -> project_games_sup:start_link().

stop(_State) -> ok.
