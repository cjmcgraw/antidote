-module(logging_vnode).

-behaviour(riak_core_vnode).

-include("floppy.hrl").
-include_lib("riak_core/include/riak_core_vnode.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([start_vnode/1,
         dread/2,
         dappend/4,
         repair/2,
         read/2,
         append/3]).

-export([init/1,
         terminate/2,
         handle_command/3,
         is_empty/1,
         delete/1,
         handle_handoff_command/3,
         handoff_starting/2,
         handoff_cancelled/1,
         handoff_finished/2,
         handle_handoff_data/2,
         encode_handoff_item/2,
         handle_coverage/4,
         handle_exit/3]).

-ignore_xref([start_vnode/1]).

-record(state, {partition, log}).

%% API
start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

%% @doc Sends a `read' syncrhonous command to the Log in `Node' 
read(Node, Key) ->
    riak_core_vnode_master:sync_command(Node, {read, Key}, ?LOGGINGMASTER).

%% @doc Sends a `read' asynchronous command to the Logs in `Preflist' 
dread(Preflist, Key) ->
    riak_core_vnode_master:command(Preflist, {read, Key}, {fsm, undefined, self()},?LOGGINGMASTER).

%% @doc Sends an `append' asyncrhonous command to the Logs in `Preflist' 
dappend(Preflist, Key, Op, LClock) ->
    riak_core_vnode_master:command(Preflist, {append, Key, Op, LClock},{fsm, undefined, self()}, ?LOGGINGMASTER).

%% @doc Sends a `repair' syncrhonous command to the Log in `Node'.
%%	This should be part of the append command. Conceptually, a Log should
%%	not have a repair operation. 
repair(Node, Ops) ->
    riak_core_vnode_master:sync_command(Node,
                                        {repair, Ops},
                                        ?LOGGINGMASTER).

%% @doc Sends an `append' syncrhonous command to the Log in `Node' 
append(Node, Key, Op) ->
    riak_core_vnode_master:sync_command(Node, {append, Key, Op}, ?LOGGINGMASTER).


%% @doc Opens the persistent copy of the Log.
%%	The name of the Log in disk is a combination of the the word `log' and
%%	the partition identifier.
init([Partition]) ->
    LogFile = string:concat(integer_to_list(Partition), "log"),
    LogPath = filename:join(
            app_helper:get_env(riak_core, platform_data_dir), LogFile),
    case dets:open_file(LogFile, [{file, LogPath}, {type, bag}]) of
        {ok, Log} ->
            {ok, #state{partition=Partition, log=Log}};
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Read command: Returns the operations logged for Key
%%	Input: Key of the object to read
%%	Output: {vnode_id, Operations} | {error, Reason}
handle_command({read, Key}, _Sender, #state{partition=Partition, log=Log}=State) ->
    case dets:lookup(Log, Key) of
        [] ->
            {reply, {{Partition, node()}, []}, State};
        [H|T] ->
            {reply, {{Partition, node()}, [H|T]}, State};
        {error, Reason}->
            {reply, {error, Reason}, State}
    end;

%% @doc Repair command: Appends the Ops to the Log
%%	Input: Ops: Operations to append
%%	Output: ok | {error, Reason}
handle_command({repair, Ops}, _Sender, #state{log=Log}=State) ->
    Result = dets:insert(Log, Ops),
    {reply, Result, State};

%% @doc Append command: Appends a new op to the Log of Key
%%	Input:	Key of the object
%%		Payload of the operation
%%		OpId: Unique operation id	      	
%%	Output: {ok, op_id} | {error, Reason}
handle_command({append, Key, Payload, OpId}, _Sender,
               #state{log=Log}=State) ->
    Result = dets:insert(Log,
                         {Key, #operation{op_number=OpId,
                                          payload=Payload}}),
    Response = case Result of
        ok ->
            {ok, OpId};
        {error, Reason} ->
            {error, Reason, OpId}
    end,
    {reply, Response, State};

handle_command(Message, _Sender, State) ->
    ?PRINT({unhandled_command_logging, Message}),
    {noreply, State}.

handle_handoff_command(?FOLD_REQ{foldfun=FoldFun, acc0=Acc0}, _Sender,
                       #state{log=Log}=State) ->
    F = fun({Key, Operation}, Acc) -> FoldFun(Key, Operation, Acc) end,
    Acc = dets:foldl(F, Acc0, Log),
    {reply, Acc, State}.

handoff_starting(_TargetNode, State) ->
    {true, State}.

handoff_cancelled(State) ->
    {ok, State}.

handoff_finished(_TargetNode, State) ->
    {ok, State}.

handle_handoff_data(Data, #state{log=Log}=State) ->
    {Key, Operation} = binary_to_term(Data),
    Response = dets:insert_new(Log, {Key, Operation}),
    {reply, Response, State}.

encode_handoff_item(Key, Operation) ->
    term_to_binary({Key, Operation}).

is_empty(State) ->
    {true, State}.

delete(State) ->
    {ok, State}.

handle_coverage(_Req, _KeySpaces, _Sender, State) ->
    {stop, not_implemented, State}.

handle_exit(_Pid, _Reason, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
