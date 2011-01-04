%%% -------------------------------------------------------------------
%%% File    : hordad_ddb_lookup
%%% Author  : Max E. Kuznecov <mek@mek.uz.ua>
%%% Description: DDB lookup layer
%%%
%%% Created : 2010-11-01 by Max E. Kuznecov <mek@mek.uz.ua>
%%% -------------------------------------------------------------------

-module(hordad_ddb_lookup).

-behaviour(gen_server).

%% API
-export([start_link/0,
         set_successor/1,
         set_predecessor/1,
         get_self/0,
         get_successor/0,
         get_predecessor/0,
         find_successors/1
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([service_handler/2]).

-include("hordad_ddb_lookup.hrl").

-define(SERVER, ?MODULE).
-define(SERVICE_TAG, "ddb_lookup").
-define(JOIN_RETRY_INTERVAL, 5000).

-record(state, {
          self,
          successor,
          predecessor,
          finger_table,
          successor_list,
          join,
          stabilizer,
          predecessor_checker,
          finger_checker
         }).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Set current node's successor
-spec(set_successor(#node{} | undefined) -> ok).

set_successor(Node) when is_record(Node, node); Node == undefined ->
    gen_server:call(?SERVER, {set_successor, Node}).

%% @doc Set current node's predecessor
-spec(set_predecessor(#node{} | undefined) -> ok).

set_predecessor(Node) when is_record(Node, node); Node == undefined ->
    gen_server:call(?SERVER, {set_predecessor, Node}).

%% @doc Get current node
-spec(get_self() -> #node{}).

get_self() ->
    gen_server:call(?SERVER, get_self).

%% @doc Get current node's successor
-spec(get_successor() -> #node{} | undefined).

get_successor() ->
    gen_server:call(?SERVER, get_successor).

%% @doc Get current node's predecessor
-spec(get_predecessor() -> #node{} | undefined).

get_predecessor() ->
    gen_server:call(?SERVER, get_predecessor).

%% @doc Find successors for provided Ids
-spec(find_successors([node_id()]) -> {Found :: [{node_id(), #node{}}],
                                       NotFound :: [{#node{}, [node_id()]}]}).

find_successors(Ids) ->
    gen_server:call(?SERVER, {find_successors, lists:usort(Ids)}).

%% @doc Service handler callback
service_handler({"find_successors", Ids}, _Socket) ->
    find_successors(Ids);
service_handler("get_predecessor", _Socket) ->
    get_predecessor();
service_handler({"pred_change", Node}, _Socket) ->
    gen_server:call(?SERVER, {pred_change, Node}),
    ok.

%%====================================================================
%% Private functions
%%====================================================================

%% @doc Return finger table in current state
-spec(get_finger_table() -> finger_table()).

get_finger_table() ->
    gen_server:call(?SERVER, get_finger_table).

%% @doc Update finger table with new values
-spec(update_finger_table([{node_id(), #node{}}]) -> ok).

update_finger_table(Values) ->
    gen_server:call(?SERVER, {update_finger_table, Values}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([]) ->
    hordad_registrar:register(?SERVICE_TAG,
                              {hordad_service, generic_service_handler,
                               [?MODULE, service_handler, []]}),

    [IP, Port] = hordad_lcf:get_vars([{hordad, bind_ip}, {hordad, bind_port}]),
    Self = hordad_ddb_lib:make_node(IP, Port),

    {ok, #state{
       self = Self,
       successor = Self,
       predecessor = undefined,
       successor_list = [],
       join = init_join(Self),
       finger_table = init_finger_table(Self#node.id),
       stabilizer = init_stabilizer(),
       predecessor_checker = init_predecessor_checker(),
       finger_checker = init_finger_checker()
      }
    }.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({set_successor, Node}, _From, State) ->
    {reply, ok, State#state{successor=Node}};
handle_call({set_predecessor, Node}, _From, State) ->
    {reply, ok, State#state{predecessor=Node}};
handle_call(get_self, _From, #state{self=Self}=State) ->
    {reply, Self, State};
handle_call(get_successor, _From, #state{successor=Succ}=State) ->
    {reply, Succ, State};
handle_call(get_predecessor, _From, #state{predecessor=Pred}=State) ->
    {reply, Pred, State};
handle_call({pred_change, Node}, _From, State) ->
    {reply, ok, do_pred_change(Node, State)};
handle_call({find_successors, Ids}, _From, State) ->
    {reply, do_find_successors(Ids, State), State};
handle_call(get_finger_table, _From, #state{finger_table=FT}=State) ->
    {reply, FT, State};
handle_call({update_finger_table, Values}, _From,
            #state{finger_table=FT}=State) ->
    NewFT = lists:foldl(fun({Id, _Node}=Val, AccFT) ->
                              lists:keyreplace(Id, 1, AccFT, Val)
                      end, FT, Values),

    {reply, ok, State#state{finger_table=NewFT}}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({'DOWN', Ref, process, Pid, Info},
            #state{stabilizer={Pid, Ref}}=State) ->
    hordad_log:warning(?MODULE, "Stabilizer process died: ~p. Restarting",
                       [Info]),

    {noreply, State#state{stabilizer=init_stabilizer()}};
handle_info({'DOWN', Ref, process, Pid, Info},
            #state{predecessor_checker={Pid, Ref}}=State) ->
    hordad_log:warning(?MODULE, "Predecessor checker process died: ~p."
                       "Restarting", [Info]),

    {noreply, State#state{predecessor_checker=init_predecessor_checker()}};
handle_info({'DOWN', Ref, process, Pid, Info},
            #state{finger_checker={Pid, Ref}}=State) ->
    hordad_log:warning(?MODULE, "Finger checker process died: ~p."
                       "Restarting", [Info]),

    {noreply, State#state{finger_checker=init_finger_checker()}};
handle_info({'DOWN', Ref, process, Pid, Info},
            #state{join={Pid, Ref}, self=Self}=State) ->
    NewState = case Info of
                   normal ->
                       State;
                   _ ->
                       hordad_log:warning(?MODULE,
                                          "Join process died: ~p."
                                          "Restarting", [Info]),
                       State#state{join=init_join(Self)}
               end,

    {noreply, NewState};
handle_info(Msg, State) ->
    hordad_log:warning(?MODULE, "Unknown message received: ~9999p", [Msg]),

    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%% @doc Init join procedure
init_join(Self) ->
    case hordad_lcf:get_var({hordad_ddb, entry_point}, undefined) of
        undefined ->
            hordad_log:info(?MODULE, "Join: no entry point defined", []),
            undefined;
        {Ip, Port} ->
            spawn_monitor(
              fun() ->
                      join(hordad_ddb_lib:make_node(Ip, Port), Self)
              end)
    end.

%% @doc Join network
join(#node{ip=Ip, port=Port}=Entry, #node{id=Id}=Node) ->
    hordad_log:info(?MODULE, "Trying to join existing overlay network "
                    "using ~p:~p as entry point", [Ip, Port]),

    case collect_successors(Entry, [Id]) of
        {error, Reason, _, _, _} ->
            hordad_log:error(?MODULE, "Unable to join overlay network: ~p",
                             [Reason]),

            timer:sleep(?JOIN_RETRY_INTERVAL),

            join(Entry, Node);
        [{Id, Succ}] when is_record(Succ, node)  ->
            hordad_log:info(?MODULE, "Found successor: ~p", [Succ]),

            set_successor(Succ)
    end.

%% @doc Collect successors for a list of provided ids
-spec(collect_successors(#node{}, [node_id()]) ->
             {error, any(), CurrentNode :: #node{},
              Rest :: [node_id()], Found :: [{node_id(), #node{}}]} |
             [{node_id(), #node{}}]).

collect_successors(Node, Rest) ->
    collect_successors(Node, Rest, []).

collect_successors(_, [], FoundAcc) ->
    FoundAcc;
collect_successors(Node, Rest, FoundAcc) ->
    case session(Node, ?SERVICE_TAG, {"find_successors", Rest}) of
        {error, E} ->
            {error, E, Node, Rest, FoundAcc};
        {ok, {Found, NotFound}} ->
            NewFoundAcc = Found ++ FoundAcc,

            case NotFound of
                [] ->
                    NewFoundAcc;
                [{NextNode, NewRest} | _] ->
                    collect_successors(NextNode, NewRest, NewFoundAcc)
            end
    end.

%% @doc Workhouse for find_successors/1
do_find_successors(Ids, #state{self=Self, successor=Succ}=State) ->
    {Found, RawNotFound} =
        lists:foldr(
          fun(Id, {Found, NotFound}) ->
                  case hordad_ddb_lib:is_node_in_range(Self#node.id,
                                                       Succ#node.id, Id) of
                      %% Found successor
                      true ->
                          {[{Id, Succ} | Found], NotFound};
                      %% Search in finger table
                      false ->
                          Next = closest_preceding_node(Id, State),
                          Cur = hordad_lib:getv(Next, NotFound, []),

                          {Found, hordad_lib:setv(Next, [Id | Cur])}
                  end
          end, {[], []}, Ids),

    %% Sort NotFound list so that the node with maximum amount of next
    %% references is first
    {Found, lists:sort(fun({_, Ids1}, {_, Ids2}) ->
                               length(Ids1) >= length(Ids2)
                       end, RawNotFound)}.

%% @doc Find the closest preceding node according to finger table info
-spec(closest_preceding_node(node_id(), #state{}) -> #node{}).

closest_preceding_node(Id, #state{self=Self, finger_table=FT}) ->
    find_preceding_node(Id, Self#node.id, lists:reverse(FT), Self).

find_preceding_node(_, _, [], Def) ->
    Def;
find_preceding_node(Id, SelfId, [{_, Node} | T], Def)
  when is_record(Node, node) ->
    case hordad_ddb_lib:is_node_in_range(SelfId, Id, Node#node.id) of
        true ->
            Node;
        _ ->
            find_preceding_node(Id, SelfId, T, Def)
    end;
find_preceding_node(Id, SelfId, [_ | T], Def) ->
    find_preceding_node(Id, SelfId, T, Def).

%% @doc Init pred checker process
init_predecessor_checker() ->
    erlang:spawn_monitor(fun predecessor_checker/0).

%% @doc Init stabilizer process
init_stabilizer() ->
    erlang:spawn_monitor(fun stabilizer/0).

%% @doc Init finger checker process
init_finger_checker() ->
    erlang:spawn_monitor(fun finger_checker/0).

%% @doc Init finger table
-spec(init_finger_table(node_id()) -> finger_table()).

init_finger_table(Id) ->
    [{Id + round(math:pow(2, X - 1)) rem ?MODULO, undefined} ||
        X <- lists:seq(0, ?M)].

%% @doc Stabilizer function
%% Run periodically to check if new node appeared between current node and its
%% successor.

stabilizer() ->
    Interval = hordad_lcf:get_var({hordad_ddb, stabilize_interval}),

    timer:sleep(Interval),

    Self = get_self(),

    case get_successor() of
        undefined ->
            ok;
        Succ ->
            {ok, Pred} = session(Succ, ?SERVICE_TAG, "get_predecessor"),

            case hordad_ddb_lib:is_node_in_range(Self#node.id, Succ#node.id,
                                                 Pred#node.id) of
                true ->
                    {ok, ok} = session(Pred, ?SERVICE_TAG,
                                       {"pred_change", Self}),

                    hordad_log:info(?MODULE,
                                    "Stabilizer found new successor: ~p",
                                    [Pred]),

                    set_successor(Pred);
                false ->
                    ok
            end
    end,

    stabilizer().

%% @doc Predecessor checker function
%% Run periodically to check if our predecessor has failed.

predecessor_checker() ->
    Interval = hordad_lcf:get_var({hordad_ddb, pred_checker_interval}),

    timer:sleep(Interval),

    case get_predecessor() of
        undefined ->
            ok;
        Pred ->
            %% TODO: Replace ad-hoc monitoring
            case session(Pred, "aes_agent", "status") of
                {ok, available} ->
                    ok;
                %% Assume failed
                _ ->
                    hordad_log:info(?MODULE, "Predecessor is down", []),

                    set_predecessor(undefined)
            end
    end,

    predecessor_checker().

%% @doc Finger checker function
%% Run periodically to repair finger table

finger_checker() ->
    FT = get_finger_table(),
    Ids = [Id || {Id, _} <- FT],
    Succ = get_successor(),
    Interval = hordad_lcf:get_var({hordad_ddb, finger_checker_interval}),

    finger_checker(Succ, Ids, Interval).

finger_checker(_, [], _) ->
    finger_checker();
finger_checker(Node, Ids, Interval) ->
    timer:sleep(Interval),

    case collect_successors(Node, Ids) of
        {error, Reason, Node, Rest, Found} ->
            hordad_log:error(?MODULE, "Error updating finger table: ~p",
                             [Reason]),

            %% Update with values found so far
            ok = update_finger_table(Found),

            %% Continue with those not found
            Int = hordad_lcf:get_var({hordad_ddb,
                                      finger_checker_retry_interval}),
            finger_checker(Node, Rest, Int);
        Fingers ->
            ok = update_finger_table(Fingers),
            finger_checker()
    end.

%% @doc Simple session wrapper
session(#node{ip=IP, port=Port}, Tag, Service) ->
    Timeout = hordad_lcf:get_var({hordad_ddb, net_timeout}),

    hordad_lib_net:gen_session(?MODULE, IP, Port, Tag, Service, Timeout).

%% @doc Check for possible predecessor change
-spec(do_pred_change(#node{}, #state{}) -> #state{}).

do_pred_change(Node, #state{predecessor=Pred, self=Self}=State) ->
    if
        Pred == undefined ->
            State#state{predecessor=Node};
        true ->
            InRange = hordad_ddb_lib:is_node_in_range(
                        Pred#node.id,
                        Self#node.id,
                        Node#node.id),

            case InRange of
                true ->
                    State#state{predecessor=Node};
                false ->
                    State
            end
    end.
