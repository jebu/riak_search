-module(riak_search_preplan).

-include("riak_search.hrl").

-export([preplan/2]).

-define(VISITOR(FUNNAME, ARGS), fun(N) -> FUNNAME(N, ARGS) end).

preplan([{lnot, _}], _Schema) ->
    [];
preplan(AST, Schema) ->
    %% pass 1 - Convert field & terms
    AST1 = visit(AST, ?VISITOR(convert_terms, Schema), true),
    %% pass 2 - Flatten and consolidate boolean ops
    AST2 = visit(AST1, ?VISITOR(flatten_bool, Schema), false),
    %% pass 3 - Inject node weights for terms
    AST3 = visit(AST2, ?VISITOR(insert_inline_or_weight, Schema), true),
    %% pass 4 - convert range and wildcard expressions
    AST4 = visit(AST3, ?VISITOR(wildcard_and_range, Schema), true),
    %% pass 5 - pick node for boolean ops
    AST5 = visit(AST4, ?VISITOR(select_node, Schema), true),
    %% Return.
    AST5.


%% Internal functions

%% AST Transformers

%% Select weightiest node for ANDs & ORs
select_node(#land{ops=Ops}=Op, _Schema) ->
    Node = find_heaviest_node(Ops),
    #node{node=Node, ops=Op};
select_node(#lor{ops=Ops}=Op, _Schema) ->
    Node = find_heaviest_node(Ops),
    #node{node=Node, ops=Op};
select_node(Op, _Schema) ->
    Op.

%% Convert wildcards and ranges into lor operations
wildcard_and_range(#field{field=FieldName, ops=Ops}, Schema)
  when is_record(Ops, inclusive_range);
       is_record(Ops, exclusive_range)->
    Field = Schema:find_field(FieldName),
    normalize_range({Schema:name(), FieldName, range_start(Ops)},
                    {Schema:name(), FieldName, range_end(Ops)},
                    range_type(Ops) =:= inclusive,
                    Schema:field_type(Field));
wildcard_and_range(Op, _Schema) when is_record(Op, term) ->
    IsWildcardOne = ?IS_TERM_WILDCARD_ONE(Op),
    IsWildcardAll = ?IS_TERM_WILDCARD_ALL(Op),
    if 
        IsWildcardOne ->
            normalize_range(Op#term.q, wildcard_one, ignored, ignored);
        IsWildcardAll ->
            normalize_range(Op#term.q, wildcard_all, ignored, ignored);
        true ->
            Op
    end;
wildcard_and_range(Op, _Schema) ->
    %% ?PRINT({unhandled_range, Op}),
    Op.

%% wildcard_range_to_or({field, FieldName, T, _}=F, Schema) when is_record(T, term) ->
%%     #term{q=Q, options=Opts}=T,
%%     Field = Schema:find_field(FieldName),
%%     case proplists:get_value(wildcard, Opts) of
%%         undefined ->
%%             F;
%%         all ->
%%             Sz = size(Q),
%%             {Start, End} = {<<Q:Sz/binary>>, <<Q:Sz/binary, 255:8/integer>>},
%%             case range_to_terms(Schema:name(), FieldName, Start,
%%                                 End, all, Schema:field_type(Field)) of
%%                 [] ->
%%                     skip;
%%                 Results ->
%%                     #lor{ops=terms_from_range_results(Schema, FieldName, Results)}
%%             end;
%%         one ->
%%             Sz = size(Q),
%%             {Start, End} = {<<Q:Sz/binary>>, <<Q:Sz/binary, 255:8/integer>>},
%%             case range_to_terms(Schema:name(), FieldName, Start,
%%                                 End, Sz + 1, Schema:field_type(Field)) of
%%                 [] ->
%%                     skip;
%%                 Results ->
%%                     #lor{ops=terms_from_range_results(Schema, FieldName, Results)}
%%             end
%%     end;
%% wildcard_range_to_or(#term{q={Index, FieldName, Q}, options=Opts}=T, Schema) ->
%%     Field = Schema:find_field(FieldName),
%%     case proplists:get_value(wildcard, Opts) of
%%         undefined ->
%%             T;
%%         all ->
%%             Sz = size(Q),
%%             {Start, End} = {<<Q:Sz/binary>>, <<Q:Sz/binary, 255:8/integer>>},
%%             case range_to_terms(Index, FieldName, Start,
%%                                 End, all, Schema:field_type(Field)) of
%%                 [] ->
%%                     skip;
%%                 Results ->
%%                     #lor{ops=terms_from_range_results(Schema, FieldName, Results)}
%%             end;
%%         one ->
%%             Sz = size(Q),
%%             {Start, End} = {<<Q:Sz/binary>>, <<Q:Sz/binary, 255:8/integer>>},
%%             case range_to_terms(Index, FieldName, Start,
%%                                 End, Sz + 1, Schema:field_type(Field)) of
%%                 [] ->
%%                     skip;
%%                 Results ->
%%                     #lor{ops=terms_from_range_results(Schema, FieldName, Results)}
%%             end
%%     end;
%% wildcard_range_to_or(Op, _Schema) ->
%%     Op.

%% Detect and annotate inline fields & node weights
insert_inline_or_weight(T, Schema) when is_record(T, term) ->
    FieldName = Schema:default_field(),
    add_inline_or_weight(T, {FieldName, Schema});
insert_inline_or_weight(#field{field=FieldName, ops=T}, Schema) when is_record(T, term) ->
    T1 = add_inline_or_weight(T, {FieldName, Schema}),
    #field{field=FieldName, ops=T1};
insert_inline_or_weight(#field{field=FieldName, ops=Ops}=F, Schema) when is_list(Ops) ->
    NewOps = visit(Ops, ?VISITOR(add_inline_or_weight, {FieldName, Schema}), true),
    F#field{ops=NewOps};
insert_inline_or_weight(Op, _Schema) ->
    Op.

add_inline_or_weight(#term{q=Q, options=Opts}=T, {FieldName, Schema}) ->
    Field = Schema:find_field(FieldName),
    NewOpts = case Schema:is_field_inline(Field) of
                  true ->
                      case proplists:get_value(inline, Opts) of
                          undefined ->
                              [inline|Opts];
                          _ ->
                              Opts
                      end;
                  false ->
                      Text = case Q of
                                 {_, _, Q1} ->
                                     Q1;
                                 _ ->
                                     Q
                             end,
                      node_weights_for_term(Schema:name(), FieldName, Text) ++ Opts
              end,
    T#term{options=NewOpts};
add_inline_or_weight(Op, _) ->
    Op.

%% Nested bool flattening
flatten_bool(#land{}=Bool, Schema) ->
    %% Collapse nested #land operations...
    F = fun(X = #land {}, {_, Acc}) -> 
                {loop, X#land.ops ++ Acc};
           (X, {Again, Acc}) -> 
                NewX = flatten_bool(X, Schema),
                {Again, [NewX|Acc]} end,
    {Continue, NewOps} = lists:foldl(F, {stop, []}, Bool#land.ops),
    
    %% If anything has changed, do another round of collapsing.
    NewBool = Bool#land { ops = NewOps },
    case Continue of
        stop -> 
            NewBool;
        loop ->
            flatten_bool(NewBool, Schema)
    end;
flatten_bool(#lor{}=Bool, Schema) ->
    %% Collapse nested #lor operations...
    F = fun(X = #lor {}, {_, Acc}) -> 
                {loop, X#lor.ops ++ Acc};
           (X, {Again, Acc}) -> 
                NewX = flatten_bool(X, Schema),
                {Again, [NewX|Acc]} end,
    {Continue, NewOps} = lists:foldl(F, {stop, []}, Bool#lor.ops),
    
    %% If anything has changed, do another round of collapsing.
    NewBool = Bool#lor { ops = NewOps },
    case Continue of
        stop -> 
            NewBool;
        loop ->
            flatten_bool(NewBool, Schema)
    end;
flatten_bool(Op, _Schema) ->
    Op.

%% Term conversion
convert_terms({field, Name, Body, _Opts}, Schema) when is_list(Body) ->
    visit(Body, ?VISITOR(convert_field_terms, {Name, Schema}), true);
convert_terms({field, Name, Body, _Opts}, Schema) when is_record(Body, phrase) ->
    convert_field_terms(Body, {Name, Schema});
convert_terms({field, Name, {term, Body, Opts}, _}, Schema) ->
    #term{q={Schema:name(), Name, Body}, options=Opts};
convert_terms({field, Name, Body, _}, _Schema) ->
    #field{field=Name, ops=Body};
convert_terms({term, Body, Opts}, Schema) ->
    #term{q={Schema:name(), Schema:default_field(), Body}, options=Opts};
convert_terms(#phrase{phrase=Phrase0, props=Props}=Op, Schema) ->
    Phrase = list_to_binary([C || C <- binary_to_list(Phrase0),
                                  C /= 34]), %% double quotes
    BQ = proplists:get_value(base_query, Props),
    {Mod, BQ1} = case is_tuple(BQ) of
                     true ->
                         {riak_search_op_term, BQ};
                     false ->
                         case hd(BQ) of
                             {land, [Term]} ->
                                 {riak_search_op_term, Term};
                             {land, Terms} ->
                                 {riak_search_op_node, {land, Terms}}
                         end
                 end,
    [BQ2] = preplan([BQ1], Schema),
    Props1 = proplists:delete(base_query, Props),
    Props2 = [{base_query, BQ2},
              {op_mod, Mod}] ++ Props1,
    Op#phrase{phrase=Phrase, props=Props2};
convert_terms(Node, _Schema) ->
    Node.

convert_field_terms({term, Body, Opts}, {FieldName, Schema}) ->
    #term{q={Schema:name(), FieldName, Body}, options=Opts};
convert_field_terms({phrase, Phrase0, Props}=Op, {FieldName, Schema}) ->
    Phrase = list_to_binary([C || C <- binary_to_list(Phrase0),
                                  C /= 34]), %% double quotes
    BQ = proplists:get_value(base_query, Props),
    {Mod, BQ1} = case is_tuple(BQ) of
                     true ->
                         {riak_search_op_term, {field, FieldName, BQ, Props}};
                     false ->
                         case hd(BQ) of
                             {land, [T]} ->
                                 {riak_search_op_term, {field, FieldName, T, Props}};
                             {land, Terms} ->
                                 F = fun(Term) -> {field, FieldName, Term, Props} end,
                                 {riak_search_op_node, {land, [F(T) || T <- Terms]}}
                         end
                 end,
    [BQ2] = preplan([BQ1], Schema),
    Props1 = proplists:delete(base_query, Props),
    Props2 = [{base_query, BQ2},
              {op_mod, Mod}] ++ Props1,
    Op#phrase{phrase=Phrase, props=Props2};
convert_field_terms(Op, _) ->
    Op.


%% AST traversal logic
visit(AST, Callback, FollowSubTrees) ->
    visit(AST, Callback, FollowSubTrees, []).

visit([], _Callback, _FollowSubTrees, Accum) ->
    lists:flatten(lists:reverse(Accum));
visit([{Type, Nodes}|T], Callback, FollowSubTrees, Accum) when Type =:= land;
                                                               Type =:= lor ->
    NewNodes = case FollowSubTrees of
                   true ->
                       visit(Nodes, Callback, FollowSubTrees, []);
                   false ->
                       Nodes
               end,
    case Callback({Type, NewNodes}) of
        skip ->
            visit(T, Callback, FollowSubTrees, Accum);
        H1 ->
            visit(T, Callback, FollowSubTrees, [H1|Accum])
    end;
visit([{Type, MaybeNodeList}|T], Callback, FollowSubTrees, Accum) when Type =:= lnot ->
    NewNodes = case is_list(MaybeNodeList) =:= true andalso FollowSubTrees =:= true of
                   true ->
                       visit(MaybeNodeList, Callback, FollowSubTrees, []);
                   false ->
                       MaybeNodeList
               end,
    case Callback({Type, NewNodes}) of
        skip ->
            visit(T, Callback, FollowSubTrees, Accum);
        H1 ->
            visit(T, Callback, FollowSubTrees, [H1|Accum])
    end;
visit([H|T], Callback, FollowSubTrees, Accum) ->
    case Callback(H) of
        skip ->
            visit(T, Callback, FollowSubTrees, Accum);
        H1 ->
            visit(T, Callback, FollowSubTrees, [H1|Accum])
    end;
visit(AST, _, _, Accum) ->
    throw({unexpected_ast, AST, Accum}).

%% Misc. helper functions

%% TODO - Add support for negative ranges.
normalize_range({Index, Field, StartTerm}, {Index, Field, EndTerm}, Inclusive, _Type) ->
    %% If this is an exclusive range, then bump the StartTerm in by one
    %% bit, and the EndTerm out by one bit.
    {StartTerm1, EndTerm1} = case Inclusive of
        true -> {StartTerm, EndTerm};
        false ->{binary_inc(StartTerm, +1), binary_inc(EndTerm, -1)}
    end,
    #range { q={Index, Field, StartTerm1, EndTerm1}, size=all};
normalize_range({Index, Field, StartTerm}, wildcard_all, _Inclusive, _Type) ->
    EndTerm = binary_last(StartTerm),
    #range { q={Index, Field, StartTerm, EndTerm}, size=all};
normalize_range({Index, Field, StartTerm}, wildcard_one, _Inclusive, _Type) ->
    EndTerm = binary_last(StartTerm),
    Size = size(StartTerm) + 1,
    #range { q={Index, Field, StartTerm, EndTerm}, size=Size};
normalize_range(A, B, C, D) ->
    ?PRINT({unhandled_range, A, B, C, D}),
    throw({unhandled_range, A, B, C, D}).

binary_inc(Term, Amt) when is_list(Term) ->
    NewTerm = binary_inc(list_to_binary(Term), Amt),
    binary_to_list(NewTerm);
binary_inc(Term, Amt) when is_binary(Term) ->
    Bits = size(Term) * 8,
    <<Int:Bits/integer>> = Term,
    NewInt = binary_inc(Int, Amt),
    <<NewInt:Bits/integer>>;
binary_inc(Term, Amt) when is_integer(Term) ->
    Term + Amt;
binary_inc(Term, _) ->
    throw({unhandled_type, binary_inc, Term}).

binary_last(Term) when is_list(Term) ->
    Term ++ [255];
binary_last(Term) when is_binary(Term) ->
    <<Term/binary, 255/integer>>;
binary_last(Term) ->
    throw({unhandled_type, binary_end, Term}).


range_start(#inclusive_range{start_op=Op}) ->
    Op;
range_start(#exclusive_range{start_op=Op}) ->
    Op.

range_end(#inclusive_range{end_op=Op}) ->
    Op;
range_end(#exclusive_range{end_op=Op}) ->
    Op.

range_type(#inclusive_range{}) ->
    inclusive;
range_type(#exclusive_range{}) ->
    exclusive.

%% terms_from_range_results(Schema, FieldName, Results) ->
%%     F = fun({Term, Node, Count}, Acc) ->
%%                 Opt = {node_weight, Node, Count},
%%                 case gb_trees:lookup(Term, Acc) of
%%                     none ->
%%                         gb_trees:insert(Term, [Opt], Acc);
%%                     {value, Options} ->
%%                         gb_trees:update(Term, [Opt|Options], Acc)
%%                 end
%%         end,
%%     Results1 = lists:foldl(F, gb_trees:empty(), lists:flatten(Results)),
%%     Results2 = gb_trees:to_list(Results1),
%%     Field = Schema:find_field(FieldName),
%%     IsInline = Schema:is_field_inline(Field),
%%     F1 = fun({Q, Options}) ->
%%                  Options1 = if
%%                                 IsInline =:= true ->
%%                                     [inline|Options];
%%                                 true ->
%%                                     node_weights_for_term(Schema:name(),
%%                                                           FieldName, Q) ++ Options
%%                             end,
%%                  #term{q={Schema:name(), FieldName, Q}, options=Options1} end,
%%     [F1(X) || X <- Results2].

node_weights_for_term(IndexName, FieldName, Term) ->
    Weights0 = info(IndexName, FieldName, Term),
    [{node_weight, {Node, Count}} || {_, Node, Count} <- Weights0].

find_heaviest_node(Ops) ->
    NodeWeights = collect_node_weights(Ops, []),
    %% Sort weights in descending order
    F = fun({_, Weight1}, {_, Weight2}) ->
                Weight1 >= Weight2 end,
    case NodeWeights of
        [] ->
            case hd(Ops) of
                Node when is_record(Node, node) ->
                    Node#node.node;
                _ ->
                    node()
            end;
        _ ->
            {Node, _Weight} = hd(lists:sort(F, NodeWeights)),
            Node
    end.

collect_node_weights([], Accum) ->
    Accum;
collect_node_weights([#term{options=Opts}|T], Accum) ->
    Weights = proplists:get_all_values(node_weight, Opts),
    F = fun(W, Acc) ->
                case lists:member(W, Acc) of
                    false ->
                        [W|Acc];
                    true ->
                        Acc
                end end,
    collect_node_weights(T, lists:foldl(F, Accum, Weights));
collect_node_weights([#lnot{ops=Ops}|T], Accum) ->
    NewAccum = collect_node_weights(Ops, Accum),
    collect_node_weights(T, NewAccum);
collect_node_weights([_Other|T], Accum) ->
    collect_node_weights(T, Accum).

info(Index, Field, Term) ->
    %% Get the primary preflist, minus any down nodes. (We don't use
    %% secondary nodes since we ultimately read results from one node
    %% anyway.)
    DocIdx = riak_search_utils:calc_partition(Index, Field, Term),
    {ok, Schema} = riak_search_config:get_schema(Index),
    NVal = Schema:n_val(),
    Preflist = riak_core_apl:get_primary_apl(DocIdx, NVal, riak_search),
    
    {ok, Ref} = riak_search_vnode:info(Preflist, Index, Field, Term, self()),
    {ok, Results} = riak_search_backend:collect_info_response(length(Preflist), Ref, []),
    Results.
