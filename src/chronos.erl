%%%-------------------------------------------------------------------
%%% @author Saad Rhoulam <saad@rhoulam.tech>
%%% @copyright (C) 2022, Saad Rhoulam
%%% @doc
%%%
%%% @end
%%% Created : 19 Oct 2022 by Saad Rhoulam <saad@rhoulam.tech>
%%%-------------------------------------------------------------------
-module(chronos).

-behaviour(gen_server).

%% API
-export([start_link/1, register_action/2, deregister_action/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/2]).

-define(SERVER, ?MODULE).

-record(state, { persist_filename :: string()
               , next_ts :: { non_neg_integer()
                            , non_neg_integer()
                            , non_neg_integer()
                            } | nothing
               , next_timer :: reference() | nothing
               , next_ref :: binary() | nothing
               , next_pid :: atom() | nothing
               , ts_x_pid_ref
                 :: orddict:orddict(binary(), {atom(), binary()})
               , ref_x_ts :: map()
               }).

%%%===================================================================
%%% API
%%%===================================================================

-spec register_action(FromName, Timestamp) -> {ok, ChronosReference} when
      Timestamp :: {non_neg_integer(), non_neg_integer(), non_neg_integer()},
      FromName :: atom(),
      ChronosReference :: binary().
register_action(FromName, CompletionTimestamp) ->
    gen_server:call(?MODULE, {register, FromName, CompletionTimestamp}).

-spec deregister_action(binary()) -> Result when
      Result :: ok | {error, Reason},
      Reason :: ref_not_found.
deregister_action(Reference) ->
    gen_server:call(?MODULE, {deregister, Reference}).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%% @end
%%--------------------------------------------------------------------
-spec start_link(list()) -> {ok, Pid :: pid()} |
          {error, Error :: {already_started, pid()}} |
          {error, Error :: term()} |
          ignore.
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Args, []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%% @end
%%--------------------------------------------------------------------
-spec init(Args :: term()) -> {ok, State :: term()} |
          {ok, State :: term(), Timeout :: timeout()} |
          {ok, State :: term(), hibernate} |
          {stop, Reason :: term()} |
          ignore.
init([StateFile|_]) ->
    RawState =
        case file:consult(StateFile) of
            {ok, [RefXTs, TsXPidRef]} ->
                #state{ persist_filename = StateFile
                    , next_ts = nothing
                    , next_ref = nothing
                    , next_pid = nothing
                    , next_timer = nothing
                    , ts_x_pid_ref = TsXPidRef
                    , ref_x_ts = RefXTs
                    };
            _ ->
                #state{ persist_filename = StateFile
                    , next_ts = nothing
                    , next_ref = nothing
                    , next_pid = nothing
                    , next_timer = nothing
                    , ts_x_pid_ref = orddict:new()
                    , ref_x_ts = #{}
                    }
        end,

    Now = erlang:timestamp(),
    State = fast_forward_backlog(Now, RawState),
    {ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%% @end
%%--------------------------------------------------------------------
-spec handle_call(Request :: term(), From :: {pid(), term()}, State :: term()) ->
          {reply, Reply :: term(), NewState :: term()} |
          {reply, Reply :: term(), NewState :: term(), Timeout :: timeout()} |
          {reply, Reply :: term(), NewState :: term(), hibernate} |
          {noreply, NewState :: term()} |
          {noreply, NewState :: term(), Timeout :: timeout()} |
          {noreply, NewState :: term(), hibernate} |
          {stop, Reason :: term(), Reply :: term(), NewState :: term()} |
          {stop, Reason :: term(), NewState :: term()}.

handle_call({register, FromName, ActionTs}, _From, #state{ next_ts=NextTs }=State)
  when ActionTs < NextTs; NextTs =:= nothing ->
    Reference = mk_opaque_token(),
    ActionTsBin = ts_to_bits(ActionTs),
    NewRefXTs = (State#state.ref_x_ts)#{ Reference => ActionTsBin },
    NewTsXPid = orddict:store(
                  ActionTsBin,
                  {FromName, Reference},
                  State#state.ts_x_pid_ref),

    case State#state.next_timer of
        nothing -> noop;
        TRef -> erlang:cancel_timer(TRef)
    end,
    NewTimerRef =
        erlang:start_timer(
          max(0, floor(timer:now_diff(ActionTs, erlang:timestamp()) / 1000)),
          self(),
          Reference),

    NewState = State#state{ ref_x_ts = NewRefXTs
                          , ts_x_pid_ref = NewTsXPid
                          , next_ref = Reference
                          , next_ts = ActionTs
                          , next_pid = FromName
                          , next_timer = NewTimerRef
                          },

    Reply = {ok, Reference},
    {reply, Reply, NewState};

handle_call({register, FromName, ActionTs}, _From, State) ->
    Reference = mk_opaque_token(),
    ActionTsBin = ts_to_bits(ActionTs),
    NewRefXTs = (State#state.ref_x_ts)#{ Reference => ActionTsBin },
    NewTsXPid = orddict:store(
                  ActionTsBin,
                  {FromName, Reference},
                  State#state.ts_x_pid_ref),
    NewState = State#state{ ref_x_ts = NewRefXTs, ts_x_pid_ref = NewTsXPid },

    Reply = {ok, Reference},
    {reply, Reply, NewState};

handle_call({deregister, Reference}, _From, #state{ next_ref = CurrReference }=State)
  when Reference =:= CurrReference ->
    RefXTs = State#state.ref_x_ts,
    case maps:find(Reference, RefXTs) of
        {ok, Timestamp} ->
            NewRefXTs = maps:remove(Reference, RefXTs),
            NewTsXPid = orddict:erase(Timestamp, State#state.ts_x_pid_ref),
            erlang:cancel_timer(State#state.next_timer),
            NewState =
                case NewTsXPid of
                    [{NextTimestampBin, {NextPid, NextRef}}|_] ->

                        NextTimestamp = bits_to_ts(NextTimestampBin),
                        NewTimerRef =
                            erlang:start_timer(
                              max(0, floor(timer:now_diff(NextTimestamp, erlang:timestamp()) / 1000)),
                              self(),
                              NextRef),

                        State#state{ ref_x_ts = NewRefXTs
                                   , ts_x_pid_ref = NewTsXPid
                                   , next_ts = NextTimestamp
                                   , next_pid = NextPid
                                   , next_ref = NextRef
                                   , next_timer = NewTimerRef
                                   };
                    [] ->
                        State#state{ ref_x_ts = NewRefXTs
                                   , ts_x_pid_ref = NewTsXPid
                                   , next_ts = nothing
                                   , next_pid = nothing
                                   , next_ref = nothing
                                   , next_timer = nothing
                                   }
                end,

            {reply, ok, NewState};
        error ->
            {reply, {error, ref_not_found}, State}
    end;

handle_call({deregister, Reference}, _From, State) ->
    RefXTs = State#state.ref_x_ts,
    case maps:find(Reference, RefXTs) of
        {ok, Timestamp} ->
            NewTsXPid = orddict:erase(Timestamp, State#state.ts_x_pid_ref),
            NewState = State#state{ ref_x_ts = maps:remove(Reference, RefXTs)
                                  , ts_x_pid_ref = NewTsXPid
                                  },
            {reply, ok, NewState};
        error ->
            {reply, {error, ref_not_found}, State}
    end;

handle_call(_Request, _From, State) ->
    Reply = unrecognized,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(Request :: term(), State :: term()) ->
          {noreply, NewState :: term()} |
          {noreply, NewState :: term(), Timeout :: timeout()} |
          {noreply, NewState :: term(), hibernate} |
          {stop, Reason :: term(), NewState :: term()}.
handle_cast(_Request, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_info(Info :: timeout() | term(), State :: term()) ->
          {noreply, NewState :: term()} |
          {noreply, NewState :: term(), Timeout :: timeout()} |
          {noreply, NewState :: term(), hibernate} |
          {stop, Reason :: normal | term(), NewState :: term()}.
handle_info({timeout, TimerRef, Reference}, State)
  when TimerRef =:= State#state.next_timer ->
    State#state.next_pid ! {chronos_timeout, Reference},

    NewTsXPid =
        orddict:erase(ts_to_bits(State#state.next_ts), State#state.ts_x_pid_ref),
    NewState =
        case NewTsXPid of
            [{NextTimestampBin, {NextPid, NextRef}}|_] ->
                NextTimestamp = bits_to_ts(NextTimestampBin),

                NewTimerRef =
                    erlang:start_timer(
                      max(0, floor(timer:now_diff(NextTimestamp, erlang:timestamp()) / 1000)),
                      self(),
                      NextRef),

                State#state{ ref_x_ts = maps:remove(Reference, State#state.ref_x_ts)
                           , ts_x_pid_ref = NewTsXPid
                           , next_ts = NextTimestamp
                           , next_pid = NextPid
                           , next_ref = NextRef
                           , next_timer = NewTimerRef
                           };
            [] ->
                State#state{ ref_x_ts = maps:remove(Reference, State#state.ref_x_ts)
                           , ts_x_pid_ref = NewTsXPid
                           , next_ts = nothing
                           , next_pid = nothing
                           , next_ref = nothing
                           , next_timer = nothing
                           }
        end,

    {noreply, NewState};

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%% @end
%%--------------------------------------------------------------------
-spec terminate(Reason :: normal | shutdown | {shutdown, term()} | term(),
                State :: term()) -> any().
terminate(_Reason, State) ->
    NextTimer = State#state.next_timer,
    if
        NextTimer =/= nothing ->
            erlang:cancel_timer(State#state.next_timer);
        true -> {}
    end,
    write_terms(State#state.persist_filename,
                [ State#state.ref_x_ts
                , State#state.ts_x_pid_ref
                ]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn :: term() | {down, term()},
                  State :: term(),
                  Extra :: term()) -> {ok, NewState :: term()} |
          {error, Reason :: term()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called for changing the form and appearance
%% of gen_server status when it is returned from sys:get_status/1,2
%% or when it appears in termination error logs.
%% @end
%%--------------------------------------------------------------------
-spec format_status(Opt :: normal | terminate,
                    Status :: list()) -> Status :: term().
format_status(_Opt, Status) ->
    Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================
ts_to_bits({Mega, Secs, Micro}) ->
    <<Mega:16,Secs:20,Micro:20>>.

bits_to_ts(<<Mega:16,Secs:20,Micro:20>>) ->
    {Mega, Secs, Micro}.

mk_opaque_token() ->
    RandomComponent = rand:uniform(floor(math:pow(2,24))),
    TimestampBits = ts_to_bits(erlang:timestamp()),
    <<TimestampBits/binary, RandomComponent:24>>.

%% https://zxq9.com/archives/1021
write_terms(Filename, List) ->
    Format = fun(Term) -> io_lib:format("~tp.~n", [Term]) end,
    Text = unicode:characters_to_binary(lists:map(Format, List)),
    file:write_file(Filename, Text).

fast_forward_backlog(Now, State) ->
    NowBin = ts_to_bits(Now),
    {FFJobs, NewTsXPidRef} = lists:partition(
                               fun({Ts, _}) -> Ts =< NowBin end,
                               State#state.ts_x_pid_ref),
    NewRefXTs =
        lists:foldl(fun fast_forward_job/2, State#state.ref_x_ts, FFJobs),

    {NextJobTimer, NextJobTs, NextJobFrom, NextJobRef} =
        case NewTsXPidRef of
            [{NextJobTsBin1, {NextJobFrom1, NextJobRef1}}|_] ->
                NextJobTs1 = bits_to_ts(NextJobTsBin1),
                NextJobTimer1 =
                    erlang:start_timer(
                      max(0, floor(timer:now_diff(NextJobTs1, erlang:timestamp()) / 1000)),
                      self(),
                      NextJobRef1),
                {NextJobTimer1, NextJobTs1, NextJobFrom1, NextJobRef1};
            _ -> {nothing, nothing, nothing, nothing}
        end,

    State#state{
      ts_x_pid_ref = NewTsXPidRef
     , ref_x_ts = NewRefXTs
     , next_ts = NextJobTs
     , next_pid = NextJobFrom
     , next_ref = NextJobRef
     , next_timer = NextJobTimer
     }.

fast_forward_job({_, {From, Ref}}, RefXTs) ->
    From ! {chronos_timeout, Ref},
    maps:remove(Ref, RefXTs).
