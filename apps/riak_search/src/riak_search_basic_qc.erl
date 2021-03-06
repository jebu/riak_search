%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
%%
%% -------------------------------------------------------------------

-module(riak_search_basic_qc).
-ifdef(EQC).

-export([
    test/0, 
    test/1,
    test_index_search/1
]).
-import(riak_search_utils, [to_list/1]).
-include_lib("eqc/include/eqc.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("riak_search.hrl").


test() -> 
    test(100).
test(N) ->
    eqc:quickcheck(numtests(N, prop_index())),
    eqc:quickcheck(numtests(N, prop_index_search())),
    eqc:quickcheck(numtests(N, prop_index_search_delete())),
    ok.

test_index_search(N) ->
    eqc:quickcheck(numtests(N, prop_index_search())).
    
%% Generators...

index() -> 
    elements(["search"]).

%% any() ->
%%     oneof([binary(6), string(), int()]).

string() ->
    oneof([
        [letter(), letter(), letter()],
        [letter()|?LAZY(string())]
    ]).

letter() ->
    oneof([
        choose($a, $z)
    ]).

props() -> 
    oneof([
        [],
        [{string(), string()}|?LAZY(props())]
    ]).

%% Properties...


%% Test 
prop_index() ->
    {ok, Client} = get_client(),
    ?FORALL(
        {Index, Field, Term, Value, Props}, 
        {index(), string(), string(), string(), props()}, 
        ?WHENFAIL(?PRINT({"Failed:", Index, Field, Term, Value, Props}),
            begin
                ok == Client:index_term(Index, Field, Term, Value, Props)
            end)).

prop_index_search() ->
    {ok, Client} = get_client(),
    ?FORALL(
        {Index, Field, Term, Value, Props}, 
        {index(), string(), string(), string(), props()}, 
        ?WHENFAIL(?PRINT({"Failed:", Index, Field, Term, Value, Props}),
            begin
                Client:index_term(Index, Field, Term, Value, Props),
                QueryOps = #term { q={Index, Field, Term} },
                F = fun() ->
                    {Length, Results} = Client:search(Index, QueryOps, 0, infinity, 5000),
                    (Length > 0) andalso (lists:keymember(to_list(Value), 1, Results))
                end,
                run_until_true(F, 3)
            end)).

prop_index_search_delete() ->
    {ok, Client} = get_client(),
    ?FORALL(
        {Index, Field, Term, Value, Props}, 
        {index(), string(), string(), string(), props()}, 
        ?WHENFAIL(?PRINT({"Failed:", Index, Field, Term, Value, Props}),
            begin
                Client:index_term(Index, Field, Term, Value, Props),
                QueryOps = #term { q={Index, Field, Term} },
                F = fun() ->
                    {Length, Results} = Client:search(Index, QueryOps, 0, infinity, 5000),
                    (Length > 0) andalso (lists:keymember(to_list(Value), 1, Results))
                end,
                run_until_true(F, 3),
                Client:delete_term(Index, Field, Term, Value),
                Result = run_until_true(fun() -> not F() end, 3),
                Result
            end)).

get_client() ->
    case get(client) of
        undefined -> 
            put(client, riak_search:local_client());
        _ -> ignore
    end,
    get(client).
            

run_until_true(_, 0) -> 
    false;
run_until_true(F, Count) ->
    case F() of
        true ->  true;
        false -> 
            timer:sleep(100),
            run_until_true(F, Count - 1)
    end.

-endif. %EQC

