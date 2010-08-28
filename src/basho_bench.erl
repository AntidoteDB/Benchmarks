%% -------------------------------------------------------------------
%%
%% basho_bench: Benchmarking Suite
%%
%% Copyright (c) 2009-2010 Basho Techonologies
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.    
%%
%% -------------------------------------------------------------------
-module(basho_bench).

-export([main/1]).

-include("basho_bench.hrl").

%% ====================================================================
%% API
%% ====================================================================

main([]) ->
    io:format("Usage: basho_bench CONFIG_FILE~n");

main([Config]) ->
    %% Load baseline config
    ok = application:load(basho_bench),

    %% Load the config file
    basho_bench_config:load(Config),

    %% Init code path
    add_code_paths(basho_bench_config:get(code_paths, [])),

    %% Setup working directory for this test. All logs, stats, and config
    %% info will be placed here
    {ok, Cwd} = file:get_cwd(),
    TestId = id(),
    TestDir = filename:join([Cwd, basho_bench_config:get(test_dir), TestId]),
    ok = filelib:ensure_dir(filename:join(TestDir, "foobar")),
    basho_bench_config:set(test_id, TestId),

    %% Create a link to the test dir for convenience
    TestLink = filename:join([Cwd, basho_bench_config:get(test_dir), "current"]),
    [] = os:cmd(?FMT("rm -f ~s; ln -sf ~s ~s", [TestLink, TestDir, TestLink])),

    %% Copy the config into the test dir for posterity
    {ok, _} = file:copy(Config, filename:join(TestDir, filename:basename(Config))),

    %% Set our CWD to the test dir
    ok = file:set_cwd(TestDir),

    log_dimensions(),

    %% Spin up the application
    ok = basho_bench_app:start(),

    %% Pull the runtime duration from the config and sleep until that's passed OR
    %% the supervisor process exits
    Mref = erlang:monitor(process, whereis(basho_bench_sup)),
    DurationMins = basho_bench_config:get(duration),
    wait_for_stop(Mref, DurationMins).





%% ====================================================================
%% Internal functions
%% ====================================================================

wait_for_stop(Mref, infinity) ->
    receive
        {'DOWN', Mref, _, _, Info} ->
            ?CONSOLE("Test stopped: ~p\n", [Info])
    end;
wait_for_stop(Mref, DurationMins) ->
    Duration = timer:minutes(DurationMins) + timer:seconds(1),
    receive
        {'DOWN', Mref, _, _, Info} ->
            ?CONSOLE("Test stopped: ~p\n", [Info])

    after Duration ->
            basho_bench_app:stop(),
            ?CONSOLE("Test completed after ~p mins.\n", [DurationMins])
    end.



%%
%% Construct a string suitable for use as a unique ID for this test run
%%
id() ->
    {{Y, M, D}, {H, Min, S}} = calendar:local_time(), 
    ?FMT("~w~2..0w~2..0w_~2..0w~2..0w~2..0w", [Y, M, D, H, Min, S]).


add_code_paths([]) ->
    ok;
add_code_paths([Path | Rest]) ->
    Absname = filename:absname(Path),
    case filename:basename(Absname) of
        "ebin" ->
            true = code:add_path(Absname);
        _ ->
            true = code:add_path(filename:join(Absname, "ebin"))
    end,
    add_code_paths(Rest).


%%
%% Convert a number of bytes into a more user-friendly representation
%%
user_friendly_bytes(Size) ->
    lists:foldl(fun(Desc, {Sz, SzDesc}) ->
                        case Sz > 1000 of
                            true ->
                                {Sz / 1024, Desc};
                            false ->
                                {Sz, SzDesc}
                        end
                end,
                {Size, bytes}, ['KB', 'MB', 'GB']).

log_dimensions() ->
    Keyspace = basho_bench_keygen:dimension(basho_bench_config:get(key_generator)),
    Valspace = basho_bench_valgen:dimension(basho_bench_config:get(value_generator), Keyspace),
    {Size, Desc} = user_friendly_bytes(Valspace),
    ?INFO("Est. data size: ~.2f ~s\n", [Size, Desc]).