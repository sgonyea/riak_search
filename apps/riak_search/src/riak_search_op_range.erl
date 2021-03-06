%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
%%
%% -------------------------------------------------------------------

-module(riak_search_op_range).
-export([
         preplan_op/2,
         chain_op/4,
         get_range_preflist/3
        ]).

-include("riak_search.hrl").
-define(STREAM_TIMEOUT, 15000).
-define(INDEX_DOCID(Term), ({element(1, Term), element(2, Term)})).

preplan_op(Op, _F) -> Op.

chain_op(Op, OutputPid, OutputRef, QueryProps) ->
    spawn_link(fun() -> start_loop(Op, OutputPid, OutputRef, QueryProps) end),
    {ok, 1}.

start_loop(Op, OutputPid, OutputRef, QueryProps) ->
    %% Get the full preflist...
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    VNodes = riak_core_ring:all_owners(Ring),

    %% Pick out the preflist of covering nodes. There are two
    %% approaches in the face of down nodes. One is to minimize the
    %% amount of duplicate data that we read. The other is maximize
    %% load distribution. We take the latter approach, because
    %% otherwise one or two down nodes could cause all range queries
    %% to take the same set of covering nodes. Works like this: rotate
    %% the ring a random amount, then clump the preflist into groups
    %% of size NVal and take the first up node in the list. If
    %% everything goes perfectly, this will be the first node in each
    %% list, and we'll have very little duplication.  If one of the
    %% nodes is down, then we'll take the next node in the list down,
    %% then just take the next vnode in the list.

    %% Figure out how many extra nodes to add to make the groups even.
    Index = element(1, Op#range.q),
    {ok, Schema} = riak_search_config:get_schema(Index),
    NVal = Schema:n_val(),

    NumExtraNodes = length(VNodes) rem NVal,
    {ExtraNodes, _} = lists:split(NumExtraNodes, VNodes),
    UpNodes = riak_core_node_watcher:nodes(riak_search),
    Preflist = get_range_preflist(NVal, VNodes ++ ExtraNodes, UpNodes),

    %% Create a #range_worker for each entry in the preflist...
    RangeWorkerOp = #range_worker { q=Op#range.q, size=Op#range.size, options=Op#range.options },
    OpList = [RangeWorkerOp#range_worker { vnode=VNode } || VNode <- Preflist],

    %% Create the iterator...
    SelectFun = fun(I1, I2) -> select_fun(I1, I2) end,
    Iterator1 = riak_search_utils:iterator_tree(SelectFun, OpList, QueryProps),
    Iterator2 = make_dedup_iterator(Iterator1),

    %% Spawn up pid to gather and send results...
    F = fun() -> gather_results(OutputPid, OutputRef, Iterator2(), []) end,
    spawn_link(F),

    %% Return.
    {ok, 1}.

%% get_range_preflist/3 - Get a list of VNodes that is guaranteed to
%% cover all of the data (it may duplicate some data.) Given nodes
%% numbered from 0 to 7, this function creates a structure like this:
%%
%% [
%%  [{0,[]}, {1,[6,7]}, {2,[7]}],
%%  [{3,[]}, {4,[1,2]}, {5,[2]}],
%%  [{6,[]}, {7,[4,5]}, {0,[5]}]
%% ]
%%
%% This means that, for example, if node 3 is down, then we need to
%% use node 4 plus either node 1 or node 2 to get complete
%% coverage. If node 3 AND 4 are down, then we need node 5 and node
%% 2. It then picks out the nodes from the structure and returns the
%% final unique preflist.
%% 
%% To create the structure, we first take the original set of X nodes,
%% figure out how many iterations we need via ceiling(
get_range_preflist(NVal, VNodes, UpNodes) ->
    %% Create an ordered set for fast repeated checking.
    UpNodesSet = ordsets:from_list(UpNodes),

    %% Randomly rotate the vnodes...
    random:seed(now()),
    RotationFactor = random:uniform(NVal),
    {Pre, Post} = lists:split(RotationFactor, VNodes),
    VNodes1 = Post ++ Pre,
    Iterations = ceiling(length(VNodes1), NVal),

    %% Create the preflist structure and then choose the preflist based on up nodes.
    Structure = create_preflist_structure(Iterations, NVal, VNodes1 ++ VNodes1),
    lists:usort(choose_preflist(Structure, UpNodesSet)).
    
create_preflist_structure(0, _NVal, _VNodes) -> 
    [];
create_preflist_structure(Iterations, NVal, VNodes) -> 
    {Backup, VNodes1} = lists:split(NVal, VNodes),
    {Primary, _} = lists:split(NVal, VNodes1),
    Group = [{hd(Primary), []}] ++ create_preflist_structure_1(tl(Primary), tl(Backup)),
    [Group|create_preflist_structure(Iterations - 1, NVal, VNodes1)].
create_preflist_structure_1([], []) -> 
    [];
create_preflist_structure_1([H|T], Backups) ->
    [{H, Backups}|create_preflist_structure_1(T, tl(Backups))].
    
%% Given a preflist structure, return the preflist.
choose_preflist([Group|Rest], UpNodesSet) ->
    choose_preflist_1(Group, UpNodesSet) ++ choose_preflist(Rest, UpNodesSet);
choose_preflist([], _) -> 
    [].
choose_preflist_1([{Primary, Backups}|Rest], UpNodesSet) ->
    {_, PrimaryNode} = Primary,
    AvailableBackups = filter_upnodes(Backups, UpNodesSet),
    case ordsets:is_element(PrimaryNode, UpNodesSet) of 
        true when AvailableBackups == [] ->
            [Primary];
        true when AvailableBackups /= [] ->
            [Primary, riak_search_utils:choose(AvailableBackups)];
        false ->
            choose_preflist_1(Rest, UpNodesSet)
    end;
choose_preflist_1([], _) -> 
    [].

%% Given a list of VNodes, filter out any that are offline.
filter_upnodes([{Index,Node}|VNodes], UpNodesSet) ->
    case ordsets:is_element(Node, UpNodesSet) of
        true -> 
            [{Index, Node}|filter_upnodes(VNodes, UpNodesSet)];
        false ->
            filter_upnodes(VNodes, UpNodesSet)
    end;
filter_upnodes([], _) ->
    [].

ceiling(Numerator, Denominator) ->
    case Numerator rem Denominator of
        0 -> Numerator div Denominator;
        _ -> (Numerator div Denominator) + 1
    end.

gather_results(OutputPid, OutputRef, {Term, Op, Iterator}, Acc)
  when length(Acc) > ?RESULTVEC_SIZE ->
    OutputPid ! {results, lists:reverse(Acc), OutputRef},
    gather_results(OutputPid, OutputRef, {Term, Op, Iterator}, []);

gather_results(OutputPid, OutputRef, {Term, _Op, Iterator}, Acc) ->
    gather_results(OutputPid, OutputRef, Iterator(), [Term|Acc]);

gather_results(OutputPid, OutputRef, {eof, _}, Acc) ->
    OutputPid ! {results, lists:reverse(Acc), OutputRef},
    OutputPid ! {disconnect, OutputRef}.


%% Given an iterator, return a new iterator that removes any
%% duplicates.
make_dedup_iterator(Iterator) ->
    fun() -> dedup_iterator(Iterator(), undefined) end.
dedup_iterator({Term, _, Iterator}, LastTerm) when ?INDEX_DOCID(Term) /= ?INDEX_DOCID(LastTerm) ->
    %% Term is different from last term, so return the iterator.
    {Term, ignore, fun() -> dedup_iterator(Iterator(), Term) end};
dedup_iterator({Term, _, Iterator}, undefined) ->
    %% We don't yet have a last term, so return the iterator.
    {Term, ignore, fun() -> dedup_iterator(Iterator(), Term) end};
dedup_iterator({Term, _, Iterator}, LastTerm) when ?INDEX_DOCID(Term) == ?INDEX_DOCID(LastTerm) ->
    %% Term is same as last term, so skip it.
    dedup_iterator(Iterator(), LastTerm);
dedup_iterator({eof, _}, _) ->
    %% No more results.
    {eof, ignore}.

%% This is very similar to logic in riak_search_op_land.erl, but
%% simplified for speed. Returns the smaller of the two iterators,
%% plus a new iterator function.
select_fun({Term1, _, Iterator1}, {Term2, _, Iterator2}) when ?INDEX_DOCID(Term1) < ?INDEX_DOCID(Term2) ->
    {Term1, ignore, fun() -> select_fun(Iterator1(), {Term2, ignore, Iterator2}) end};
select_fun({Term1, _, Iterator1}, {Term2, _, Iterator2}) when ?INDEX_DOCID(Term1) > ?INDEX_DOCID(Term2) ->
    {Term2, ignore, fun() -> select_fun({Term1, ignore, Iterator1}, Iterator2()) end};
select_fun({Term1, _, Iterator1}, {Term2, _, Iterator2}) when ?INDEX_DOCID(Term1) == ?INDEX_DOCID(Term2) ->
    {Term1, ignore, fun() -> select_fun(Iterator1(), Iterator2()) end};
select_fun({Term, _, Iterator}, {eof, _}) ->
    {Term, ignore, Iterator};
select_fun({eof, _}, {Term, _, Iterator}) ->
    {Term, ignore, Iterator};
select_fun({eof, _}, {eof, _}) ->
    {eof, ignore}.
