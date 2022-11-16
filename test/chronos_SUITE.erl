%%%-------------------------------------------------------------------
%%% @author Saad Rhoulam <saad@rhoulam.tech>
%%% @copyright (C) 2022, Saad Rhoulam
%%% @doc
%%%
%%% @end
%%% Created :  2 Nov 2022 by Saad Rhoulam <saad@rhoulam.tech>
%%%-------------------------------------------------------------------
-module(chronos_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").

%%--------------------------------------------------------------------
%% @spec suite() -> Info
%% Info = [tuple()]
%% @end
%%--------------------------------------------------------------------
suite() ->
    [{timetrap,{seconds,30}}].

%%--------------------------------------------------------------------
%% @spec init_per_suite(Config0) ->
%%     Config1 | {skip,Reason} | {skip_and_save,Reason,Config1}
%% Config0 = Config1 = [tuple()]
%% Reason = term()
%% @end
%%--------------------------------------------------------------------
init_per_suite(Config) ->
    Config.

%%--------------------------------------------------------------------
%% @spec end_per_suite(Config0) -> term() | {save_config,Config1}
%% Config0 = Config1 = [tuple()]
%% @end
%%--------------------------------------------------------------------
end_per_suite(_Config) ->
    ok.

%%--------------------------------------------------------------------
%% @spec init_per_group(GroupName, Config0) ->
%%               Config1 | {skip,Reason} | {skip_and_save,Reason,Config1}
%% GroupName = atom()
%% Config0 = Config1 = [tuple()]
%% Reason = term()
%% @end
%%--------------------------------------------------------------------
init_per_group(_GroupName, Config) ->
    Config.

%%--------------------------------------------------------------------
%% @spec end_per_group(GroupName, Config0) ->
%%               term() | {save_config,Config1}
%% GroupName = atom()
%% Config0 = Config1 = [tuple()]
%% @end
%%--------------------------------------------------------------------
end_per_group(_GroupName, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% @spec init_per_testcase(TestCase, Config0) ->
%%               Config1 | {skip,Reason} | {skip_and_save,Reason,Config1}
%% TestCase = atom()
%% Config0 = Config1 = [tuple()]
%% Reason = term()
%% @end
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config)
  when TestCase =:= case_main_complex; TestCase =:= case_main_simple ->
    process_flag(trap_exit, true),
    StartTs = erlang:timestamp(),
    ChronosStateFile =
        io_lib:format("/tmp/chronos.test.~B.~B.~B.erl", tuple_to_list(StartTs)),
    chronos:start_link([ChronosStateFile]),
    Config;
init_per_testcase(_TestCase, Config) ->
    Config.

%%--------------------------------------------------------------------
%% @spec end_per_testcase(TestCase, Config0) ->
%%               term() | {save_config,Config1} | {fail,Reason}
%% TestCase = atom()
%% Config0 = Config1 = [tuple()]
%% Reason = term()
%% @end
%%--------------------------------------------------------------------
end_per_testcase(TestCase, _Config)
  when TestCase =:= case_main_complex; TestCase =:= case_main_simple ->
    gen_server:stop(chronos),
    receive {'EXIT', _, _} -> ok end;
end_per_testcase(_TestCase, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% @spec groups() -> [Group]
%% Group = {GroupName,Properties,GroupsAndTestCases}
%% GroupName = atom()
%% Properties = [parallel | sequence | Shuffle | {RepeatType,N}]
%% GroupsAndTestCases = [Group | {group,GroupName} | TestCase]
%% TestCase = atom()
%% Shuffle = shuffle | {shuffle,{integer(),integer(),integer()}}
%% RepeatType = repeat | repeat_until_all_ok | repeat_until_all_fail |
%%              repeat_until_any_ok | repeat_until_any_fail
%% N = integer() | forever
%% @end
%%--------------------------------------------------------------------
groups() ->
    [].

%%--------------------------------------------------------------------
%% @spec all() -> GroupsAndTestCases | {skip,Reason}
%% GroupsAndTestCases = [{group,GroupName} | TestCase]
%% GroupName = atom()
%% TestCase = atom()
%% Reason = term()
%% @end
%%--------------------------------------------------------------------
all() ->
    [ case_main_simple
    , case_main_complex
    , case_persistence
    ].



case_main_simple() ->
    ["Simple test of registration and timeouts."].
case_main_simple(_Config) ->
    register(test, self()),
    {Mega, Secs, Micro} = erlang:timestamp(),
    {ok, Ref0} = chronos:register_action(test, {Mega, Secs, Micro + 100000}),
    {ok, Ref1} = chronos:register_action(test, {Mega, Secs + 2, Micro}),
    {ok, Ref2} = chronos:register_action(test, {Mega, Secs + 4, Micro}),
    receive
        {chronos_timeout, Ref0} -> ok
    after
        200 -> exit("Ref0 took too long.")
    end,
    receive
        {chronos_timeout, Ref1} -> ok
    after
        2800 -> exit("Ref1 took too long.")
    end,
    receive
        {chronos_timeout, Ref2} -> ok
    after
        3000 -> exit("Ref2 took too long.")
    end,
    unregister(test),
    receive
        {chronos_timeout, _} -> exit("Fourth timeout received from Chronos.")
    after
        1000 -> ok
    end.



case_main_complex() ->
    ["Complex test of registration, deregistration, and timeouts."].
case_main_complex(_Config) ->
    register(test, self()),
    {Mega, Secs, Micro} = erlang:timestamp(),
    {ok, Ref0} = chronos:register_action(test, {Mega, Secs, Micro + 100000}),
    {ok, Ref1} = chronos:register_action(test, {Mega, Secs + 2, Micro}),
    {ok, Ref2} = chronos:register_action(test, {Mega, Secs + 4, Micro}),
    chronos:deregister_action(Ref1),
    receive
        {chronos_timeout, Ref0} -> ok
    after
        200 -> exit("Ref0 took too long.")
    end,
    receive
        {chronos_timeout, Ref2} -> ok
    after
        4800 -> exit("Ref2 took too long.")
    end,
    unregister(test),
    receive
        {chronos_timeout, _} -> exit("Third timeout received from Chronos.")
    after
        1000 -> ok
    end.



case_persistence() ->
    ["A test of Chronos persistence across restarts."].
case_persistence(_Config) ->
    process_flag(trap_exit, true),

    StartTs = erlang:timestamp(),
    ChronosStateFile =
        io_lib:format("/tmp/chronos.test.~B.~B.~B.erl", tuple_to_list(StartTs)),
    chronos:start_link([ChronosStateFile]),
    register(test, self()),

    {Mega, Secs, Micro} = erlang:timestamp(),
    {ok, Ref0} = chronos:register_action(test, {Mega, Secs, Micro + 100000}),
    {ok, Ref1} = chronos:register_action(test, {Mega, Secs + 2, Micro}),
    {ok, Ref2} = chronos:register_action(test, {Mega, Secs + 4, Micro}),
    {ok, Ref3} = chronos:register_action(test, {Mega, Secs + 6, Micro}),
    {ok, Ref4} = chronos:register_action(test, {Mega, Secs + 8, Micro}),

    gen_server:stop(chronos),
    receive {'EXIT', _, _} -> ok end,
    chronos:start_link([ChronosStateFile]),
    receive
        {chronos_timeout, Ref0} -> ok
    end,
    receive
        {chronos_timeout, Ref1} -> ok
    after
        2900 -> exit("Ref1 took too long.")
    end,
    receive
        {chronos_timeout, Ref2} -> ok
    after
        3000 -> exit("Ref2 took too long.")
    end,
    receive
        {chronos_timeout, Ref3} -> ok
    after
        3000 -> exit("Ref3 took too long.")
    end,
    receive
        {chronos_timeout, Ref4} -> ok
    after
        3000 -> exit("Ref4 took too long.")
    end,
    unregister(test),
    receive
        {chronos_timeout, _} -> exit("Third timeout received from Chronos.")
    after
        1000 -> ok
    end,

    gen_server:stop(chronos),
    receive {'EXIT', _, _} -> ok end.


%%--------------------------------------------------------------------
%% @spec TestCase() -> Info
%% Info = [tuple()]
%% @end
%%--------------------------------------------------------------------
%% my_test_case() ->
%%     [].

%%--------------------------------------------------------------------
%% @spec TestCase(Config0) ->
%%               ok | exit() | {skip,Reason} | {comment,Comment} |
%%               {save_config,Config1} | {skip_and_save,Reason,Config1}
%% Config0 = Config1 = [tuple()]
%% Reason = term()
%% Comment = term()
%% @end
%%--------------------------------------------------------------------
%% my_test_case(_Config) ->
%%     ok.
