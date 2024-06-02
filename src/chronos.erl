%%%-------------------------------------------------------------------
%%% @author Saad Rhoulam <saad@rhoulam.tech>
%%% @copyright (C) 2024, Saad Rhoulam
%%% @doc
%%%
%%% @end
%%% Created :  2 Jun 2024 by Saad Rhoulam <saad@rhoulam.tech>
%%%-------------------------------------------------------------------
-module(chronos).

-behaviour(application).

%% API
-export([register_action/2, deregister_action/1]).

%% Application callbacks
-export([start/2, start_phase/3, stop/1, prep_stop/1,
         config_change/3]).

%%%===================================================================
%%% API
%%%===================================================================
-spec register_action(FromName, Timestamp) -> {ok, ChronosReference} when
      Timestamp :: {non_neg_integer(), non_neg_integer(), non_neg_integer()},
      FromName :: atom(),
      ChronosReference :: binary().
register_action(FromName, CompletionTimestamp) ->
    gen_server:call(chronos_server, {register, FromName, CompletionTimestamp}).

-spec deregister_action(binary()) -> Result when
      Result :: ok | {error, Reason},
      Reason :: ref_not_found.
deregister_action(Reference) ->
    gen_server:call(chronos_server, {deregister, Reference}).

%%%===================================================================
%%% Application callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called whenever an application is started using
%% application:start/[1,2], and should start the processes of the
%% application. If the application is structured according to the OTP
%% design principles as a supervision tree, this means starting the
%% top supervisor of the tree.
%% @end
%%--------------------------------------------------------------------
-spec start(StartType :: normal |
                         {takeover, Node :: node()} |
                         {failover, Node :: node()},
            StartArgs :: term()) ->
          {ok, Pid :: pid()} |
          {ok, Pid :: pid(), State :: term()} |
          {error, Reason :: term()}.
start(_StartType, _StartArgs) ->
    ChronosArgs =
        case os:getenv("CHRONOS_PERSIST_FILEPATH") of
            false -> [];
            Path ->
                case file:consult(Path) of
                    {ok, [Ref_x_Ts, Ts_x_PidRef]} -> [{Ref_x_Ts, Ts_x_PidRef}];
                    _ -> []
                end
        end,

    case chronos_sup:start_link(ChronosArgs) of
        {ok, Pid} ->
            {ok, Pid};
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% top supervisor of the tree.
%% Starts an application with included applications, when
%% synchronization is needed between processes in the different
%% applications during startup.%% @end
%%--------------------------------------------------------------------
-spec start_phase(Phase :: atom(),
                  StartType :: normal |
                               {takeover, Node :: node()} |
                               {failover, Node :: node()},
                  PhaseArgs :: term()) -> ok | {error, Reason :: term()}.
start_phase(_Phase, _StartType, _PhaseArgs) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called whenever an application has stopped. It
%% is intended to be the opposite of Module:start/2 and should do
%% any necessary cleaning up. The return value is ignored.
%% @end
%%--------------------------------------------------------------------
-spec stop(State :: term()) -> any().
stop(_State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called when an application is about to be stopped,
%% before shutting down the processes of the application.
%% @end
%%--------------------------------------------------------------------
-spec prep_stop(State :: term()) -> NewState :: term().
prep_stop(State) ->
    {Ref_x_Ts, Ts_x_PidRef} = gen_server:call(chronos_server, export_state),

    %% NOTE: this is intentional
    %% In the default case, the timestamp will differ from the startup case.
    %% We only support persistence when a filepath is explicitly set.
    %% Otherwise, we degrade to logging state.
    TempFilePath = io_lib:format("/tmp/chronos.~b.erl", [os:system_time()]),
    StateFilePath = os:getenv("CHRONOS_PERSIST_FILEPATH", TempFilePath),
    write_terms(StateFilePath, [Ref_x_Ts, Ts_x_PidRef]),
    State.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by an application after a code replacement,
%% if the configuration parameters have changed.
%% @end
%%--------------------------------------------------------------------
-spec config_change(Changed :: [{Par :: atom(), Val :: term()}],
                    New :: [{Par :: atom(), Val :: term()}],
                    Removed :: [Par :: atom()]) -> ok.
config_change(_Changed, _New, _Removed) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================
%% https://zxq9.com/archives/1021
write_terms(Filename, List) ->
    Format = fun(Term) -> io_lib:format("~tp.~n", [Term]) end,
    Text = unicode:characters_to_binary(lists:map(Format, List)),
    file:write_file(Filename, Text).
