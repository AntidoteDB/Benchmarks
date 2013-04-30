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
-module(basho_bench_driver_null).

-export([new/1,
         run/4]).

-include("basho_bench.hrl").

%% ====================================================================
%% API
%% ====================================================================

new(_Id) ->
    {ok, undefined}.

run(absolutely_nothing, _KeyGen, _ValueGen, State) ->
    {ok, State};
run(do_something, KeyGen, _ValueGen, State) ->
    _Key = KeyGen(),
    {ok, State};
run(do_something_else, KeyGen, ValueGen, State) ->
    _Key = KeyGen(),
    ValueGen(),
    {ok, State};
run(an_error, KeyGen, _ValueGen, State) ->
    _Key = KeyGen(),
    {error, went_wrong, State};
run(another_error, KeyGen, _ValueGen, State) ->
    _Key = KeyGen(),
    {error, {bad, things, happened}, State}.

