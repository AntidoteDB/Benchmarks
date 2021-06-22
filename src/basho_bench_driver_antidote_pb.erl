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
-module(basho_bench_driver_antidote_pb).

-export([new/1,
         run/4]).

-include("basho_bench.hrl").
-include_lib("kernel/include/logger.hrl").

-define(BUCKET, <<"antidote_bench_bucket">>).

-define(TIMEOUT, 20000).
-record(state, {worker_id,
                time,
                type_dict,
                last_read,
                pb_pid,
                set_size,
                commit_time,
                num_reads,
                num_updates,
                pb_port,
                target_node,
                measure_staleness,
                temp_num_reads,
                temp_num_updates,
                sequential_reads,
                sequential_writes}).

%% ====================================================================
%% API
%% ====================================================================

new(Id) ->

    rand:seed(exsplus, erlang:timestamp()),

    IPs = basho_bench_config:get(antidote_pb_ips),
    PbPorts = basho_bench_config:get(antidote_pb_port),
    Types  = basho_bench_config:get(antidote_types),
    SetSize = basho_bench_config:get(set_size),
    NumUpdates  = basho_bench_config:get(num_updates),
    NumReads = basho_bench_config:get(num_reads),
    MeasureStaleness = basho_bench_config:get(staleness),
    SequentialReads = basho_bench_config:get(sequential_reads),
    SequentialWrites = basho_bench_config:get(sequential_writes),
    %% Choose the node using our ID as a modulus
    TargetNode = lists:nth((Id rem length(IPs)+1), IPs),
    ?LOG_INFO("Using target node ~p for worker ~p", [TargetNode, Id]),
    TargetPort = lists:nth((Id rem length(IPs)+1), PbPorts),
    ?LOG_INFO("Using target port ~p for worker ~p", [TargetPort, Id]),
    {ok, Pid} = antidotec_pb_socket:start_link(TargetNode, TargetPort),
    TypeDict = dict:from_list(Types),
    {ok, #state{time = {1, 1, 1}, worker_id = Id,
        pb_pid = Pid,
        last_read = {undefined, undefined},
        set_size = SetSize,
        type_dict = TypeDict, pb_port = TargetPort,
        target_node = TargetNode, commit_time = ignore,
        num_reads = NumReads, num_updates = NumUpdates,
        temp_num_reads = NumReads, temp_num_updates = NumUpdates,
        measure_staleness = MeasureStaleness,
        sequential_reads = SequentialReads,
        sequential_writes = SequentialWrites}}.
%% @doc A general transaction.
%% it first performs reads to a number of objects defined by the
%% {num_reads, X} parameter in the config file.
%% Then, it updates {num_updates, X}.

run(txn, KeyGen, ValueGen, State=#state{pb_pid=Pid, worker_id=Id,
    pb_port=_Port, target_node=_Node,
    num_reads=NumReads,
    num_updates=NumUpdates,
    type_dict=TypeDict,
    set_size=SetSize,
    commit_time=OldCommitTime,
    measure_staleness=MS,
    sequential_writes=SeqWrites,
    sequential_reads=SeqReads})->
    StartTime = erlang:system_time(micro_seconds), %% For staleness calc
    case antidotec_pb:start_transaction(Pid, OldCommitTime, [{static, false}]) of
        {ok, TxId}->
            %% Perform reads, if this is not a write only transaction.
            {ReadResult, IntKeys}=case NumReads>0 of
                true->
                    IntegerKeys = generate_keys(NumReads, KeyGen),
                    BoundObjects=[{list_to_binary(integer_to_list(K)), get_key_type(K, TypeDict), ?BUCKET}||K<-IntegerKeys],
                    case create_read_operations(Pid, BoundObjects, TxId, SeqReads) of
                        {ok, RS}->
                            {RS, IntegerKeys};
                        Error->
                            {{error, {Id, Error}, State}, IntegerKeys}
                    end;
                false->
                    {no_reads, no_reads}
            end,
            case ReadResult of
                %% if reads failed, return immediately.
                {error, {ID, ERROR}, STATE}->
                    {error, {ID, ERROR}, STATE};
                _->
                    %% if reads succeeded, perform updates.
                    UpdateIntKeys = case IntKeys of
                        no_reads ->
                            %% write only transaction
                            generate_keys(NumUpdates, KeyGen);
                        _->
                            %%                    The following selects the latest reads for updating.
                            lists:sublist(IntKeys, NumReads-NumUpdates+1, NumUpdates)
                    end,
                    BObjs = multi_get_random_param_new(UpdateIntKeys, TypeDict, ValueGen(), undefined, SetSize),
                    case create_update_operations(Pid, BObjs, TxId, SeqWrites) of
                        ok->
                            case antidotec_pb:commit_transaction(Pid, TxId) of
                                {ok, BCommitTime}->
                                    report_staleness(MS, BCommitTime, StartTime),
                                    CommitTime= BCommitTime,
                                    {ok, State#state{commit_time=CommitTime}};
                                E->
                                    {error, {Id, E}, State}
                            end;
                        E1->
                            {error, {Id, E1}, State}
                    end
            end
    end;


%% @doc This transaction will only perform update operations,
%% by calling the static update_objects interface of antidote.
%% the number of operations is defined by the {num_updates, x}
%% parameter in the config file.
run(update_only_txn, KeyGen, ValueGen, State=#state{pb_pid=Pid, worker_id=Id,
    pb_port=_Port, target_node=_Node,
    num_updates=NumUpdates,
    type_dict=TypeDict,
    set_size=SetSize,
    commit_time=OldCommitTime,
    measure_staleness=MS,
    sequential_writes=SeqWrites})->
    StartTime = erlang:system_time(micro_seconds), %% For staleness calc
    case antidotec_pb:start_transaction(Pid, OldCommitTime, [{static, true}]) of
        {ok, TxId}->
            UpdateIntKeys = generate_keys(NumUpdates, KeyGen),
            BObjs = multi_get_random_param_new(UpdateIntKeys, TypeDict, ValueGen(), undefined, SetSize),
            case create_update_operations(Pid, BObjs, TxId, SeqWrites) of
                ok->
                    case antidotec_pb:commit_transaction(Pid, TxId) of
                        {ok, BCommitTime}->
                            report_staleness(MS, BCommitTime, StartTime),
                            CommitTime = BCommitTime,
                            {ok, State#state{commit_time=CommitTime}};
                        Error ->
                            {error, {Id, Error}, State}
                    end;
                Error ->
                    {error, {Id, Error}, State}
            end;
        Error->
            {error, {Id, Error}, State}
    end;
%% @doc This transaction will only perform read operations in
%% an antidote's read/only transaction.
%% the number of operations is defined by the {num_reads, x}
%% parameter in the config file.
run(read_only_txn, KeyGen, _ValueGen, State=#state{pb_pid=Pid, worker_id=Id,
    pb_port=_Port, target_node=_Node,
    num_reads=NumReads,
    sequential_reads = SeqReads,
    type_dict=TypeDict,
    measure_staleness = MS,
    commit_time = OldCommitTime}) ->
    StartTime = erlang:system_time(micro_seconds), %% For staleness calc
    ReadResult = case NumReads > 0 of
        true ->
            {ok, TxId} = antidotec_pb:start_transaction(Pid, OldCommitTime, [{static, true}]),
            IntegerKeys = generate_keys(NumReads, KeyGen),
            BoundObjects = [{list_to_binary(integer_to_list(K)), get_key_type(K, TypeDict), ?BUCKET} || K <- IntegerKeys],
            case create_read_operations(Pid, BoundObjects, TxId, SeqReads) of
                {ok, RS} ->
                    {RS, IntegerKeys};
                Error ->
                    {{error, {Id, Error}, State}, IntegerKeys}
            end;
        false ->
            no_reads
    end,
    case ReadResult of
        %% if reads failed, return immediately.
        no_reads ->
            {error, read_failed};
        _ ->
            case antidotec_pb_socket:get_last_commit_time(Pid) of
                {ok, BCommitTime} ->
                    report_staleness(MS, BCommitTime, StartTime),
                    CommitTime = BCommitTime,
                    {ok, State#state{commit_time = CommitTime}};
                E ->
                    {error, {Id, E}, State}
            end
    end;

%% @doc the append command will run a transaction with a single update, and no reads.
run(append, KeyGen, ValueGen, State) ->
    run(txn, KeyGen, ValueGen, State#state{num_reads=0,num_updates=1});
%% @doc the read command will run a transaction with a single read, and no updates.
run(read, KeyGen, ValueGen, State) ->
    run(txn, KeyGen, ValueGen, State#state{num_reads=1,num_updates=0}).


create_read_operations(Pid, BoundObjects, TxInfo, IsSeq) ->
    case IsSeq of
        true->
            Result = lists:map(fun(BoundObj)->
                {ok, [Value]} = antidotec_pb:read_objects(Pid, [BoundObj], TxInfo),
                        Value
                end,BoundObjects),
            {ok, Result};
        false ->
                antidotec_pb:read_objects(Pid, BoundObjects, TxInfo)
    end.

create_update_operations(_Pid, [], _TxInfo, _IsSeq) ->
    ok;
create_update_operations(Pid, BoundObjects, TxInfo, IsSeq) ->
    case IsSeq of
        true ->
            lists:map(fun(BoundObj) ->
                antidotec_pb:update_objects(Pid, [BoundObj], TxInfo)
                               end, BoundObjects),
            ok;
        false ->
            antidotec_pb:update_objects(Pid, BoundObjects, TxInfo)
    end.


get_key_type(Key, Dict) ->
    Keys = dict:fetch_keys(Dict),
    RanNum = Key rem length(Keys),
    lists:nth(RanNum+1, Keys).


multi_get_random_param_new(KeyList, Dict, Value, Objects, SetSize) ->
  multi_get_random_param_new(KeyList, Dict, Value, Objects, SetSize, []).

multi_get_random_param_new([], _Dict, _Value, _Objects, _SetSize, Acc)->
  Acc;
multi_get_random_param_new([Key|Rest], Dict, Value, Objects, SetSize, Acc)->
  Type = get_key_type(Key, Dict),
  case Objects of
    undefined ->
      Obj = undefined,
      ObjRest = undefined;
    [H|T] ->
      Obj = H,
      ObjRest = T
  end,
  [Param] = get_random_param_new(Key, Dict, Type, Value, Obj, SetSize),
  multi_get_random_param_new(Rest, Dict, Value, ObjRest, SetSize, [Param|Acc]).

get_random_param_new(Key, Dict, Type, Value, Obj, SetSize)->
    Params=dict:fetch(Type, Dict),
    Num=rand:uniform(length(Params)),
    BKey=list_to_binary(integer_to_list(Key)),
    NewVal=case Value of
        Value when is_integer(Value)->
            integer_to_list(Value);
        Value when is_binary(Value)->
            Value
    end,
    case Type of
        antidote_crdt_counter_pn->
            case lists:nth(Num, Params) of
                {increment, Ammount}->
                    [{{BKey, Type, ?BUCKET}, increment, Ammount}];
                {decrement, Ammount}->
                    [{{BKey, Type, ?BUCKET}, decrement, Ammount}];
                increment->
                    [{{BKey, Type, ?BUCKET}, increment, 1}];
                decrement->
                    [{{BKey, Type, ?BUCKET}, decrement, 1}]
            end;

        RegisterType when ((RegisterType==antidote_crdt_register_mv) orelse (RegisterType==antidote_crdt_register_lww))->
            [{{BKey, Type, ?BUCKET}, assign, NewVal}];

        SetType when ((SetType==antidote_crdt_set_aw) orelse (SetType==antidote_crdt_set_go))->
            Set=
                case Obj of
                    undefined->
                        [];
                     _ ->
                        antidotec_set:value(Obj)
                end,
            %%Op = lists:nth(Num, Params),
            NewOp=case length(Set)=<SetSize of
                true->
                    add;
                false->
                    remove
            end,
            case NewOp of
                remove->
                    case Set of
                        []->
                            [{{BKey, Type, ?BUCKET}, add_all, [NewVal]}];
                        _ ->
                            [{{BKey, Type, ?BUCKET}, remove_all, [lists:nth(rand:uniform(length(Set)), Set)]}]
                    end;
                _->
                    [{{BKey, Type, ?BUCKET}, add_all, [NewVal]}]
            end
    end.
%%
%%get_random_param(Dict, Type, Value) ->
%%  Params = dict:fetch(Type, Dict),
%%  rand:seed(exsplus, erlang:timestamp()),
%%  Num = rand:uniform(length(Params)),
%%  case Type of
%%    riak_dt_pncounter ->
%%      {antidotec_counter, lists:nth(Num, Params), 1};
%%    riak_dt_orset ->
%%      {antidotec_set, lists:nth(Num, Params), Value}
%%  end.
%%
%%get_random_param(Dict, Type, Value, Obj, SetSize) ->
%%  Params = dict:fetch(Type, Dict),
%%  Num = rand:uniform(length(Params)),
%%  case Type of
%%    riak_dt_pncounter ->
%%      {antidotec_counter, lists:nth(Num, Params), 1};
%%    riak_dt_orset ->
%%      Set = antidotec_set:value(Obj),
%%      %%Op = lists:nth(Num, Params),
%%      NewOp = case sets:size(Set) =< SetSize of
%%                true ->
%%                  add;
%%                false ->
%%                  remove
%%              end,
%%      case NewOp of
%%        remove ->
%%          case sets:to_list(Set) of
%%            [] -> {antidotec_set, add, Value};
%%            [H | _T] -> {antidotec_set, remove, H}
%%          end;
%%        _ ->
%%          {antidotec_set, NewOp, Value}
%%      end
%%  end.



report_staleness(true, CT, CurTime) ->
    SS = binary_to_term(CT), %% Binary to dict
    %% Here it is assumed the stable snapshot has entries for all remote DCs
    SSL = lists:keysort(1, dict:to_list(SS)),
    Staleness = lists:map(fun({_Dc, Time}) ->
                                  max(1, CurTime - Time) %% it should be max(0, ..), but 0 is causing some crash in stats generation
                          end, SSL),
    HistName = atom_to_list(staleness),
    report_staleness_rec(Staleness, HistName, 1);

report_staleness(_,_,_) ->
     ok.

report_staleness_rec([],_,_) -> ok;
report_staleness_rec([H|T], HistName, Iter) ->
    Op=list_to_atom(string:concat(HistName, integer_to_list(Iter))),
    folsom_metrics:notify({latencies, {Op, Op}}, H),
    folsom_metrics:notify({units, {Op, Op}}, {inc, 1}),
    report_staleness_rec(T, HistName, Iter+1).


%% @doc generate NumReads unique keys using the KeyGen
generate_keys(NumKeys, KeyGen) ->
  Seq = lists:seq(1, NumKeys),
  S = lists:foldl(fun(_, Set) ->
    N = unikey(KeyGen, Set),
    sets:add_element(N, Set)
                  end, sets:new(), Seq),
  sets:to_list(S).


unikey(KeyGen, Set) ->
  R = KeyGen(),
  case sets:is_element(R, Set) of
    true ->
      unikey(KeyGen, Set);
    false ->
      R
  end.


%%random_string(Len) ->
%%    Chrs = list_to_tuple("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"),
%%    ChrsSize = size(Chrs),
%%    F = fun(_, R) -> [element(rand:uniform(ChrsSize), Chrs) | R] end,
%%    lists:foldl(F, "", lists:seq(1, Len)).
%%
%%now_microsec() ->
%%    {MegaSecs, Secs, MicroSecs} = os:timestamp(),
%%    (MegaSecs * 1000000 + Secs) * 1000000 + MicroSecs.
%%
%%k_unique_numes(Num, Range) ->
%%    Seq = lists:seq(1, Num),
%%    S = lists:foldl(fun(_, Set) ->
%%        N = uninum(Range, Set),
%%        sets:add_element(N, Set)
%%    end, sets:new(), Seq),
%%    sets:to_list(S).
%%
%%report_staleness(true, CT, CurTime) ->
%%    SS1 = binary_to_term(CT), %% Binary to dict
%%    SS = binary_to_list(CT),
%%    ?LOG_INFO("CT = ",[CT]),
%%    ?LOG_INFO("Bynary to term = ",[SS1]),
%%    ?LOG_INFO("Bynary to list = ",[SS]),
%%
%%    %% Here it is assumed the stable snapshot has entries for all remote DCs
%%    %%    SSL = lists:keysort(1, dict:to_list(SS)),
%%    SSL = lists:keysort(1, SS),
%%    Staleness = lists:map(fun({_Dc, Time}) ->
%%        max(1, CurTime - Time) %% it should be max(0, ..), but 0 is causing some crash in stats generation
%%    end, SSL),
%%    HistName = atom_to_list(staleness),
%%    report_staleness_rec(Staleness, HistName, 1);
%%
%%report_staleness(_,_,_) ->
%%    ok.
