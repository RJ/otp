%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 1999-2013. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%
%% Purpose : Partitions assembly instructions into basic blocks and
%% optimizes them.

-module(beam_block).

-export([module/2]).
-import(lists, [mapfoldl/3,reverse/1,reverse/2,foldl/3,member/2]).

module({Mod,Exp,Attr,Fs0,Lc0}, _Opt) ->
    {Fs,Lc} = mapfoldl(fun function/2, Lc0, Fs0),
    {ok,{Mod,Exp,Attr,Fs,Lc}}.

function({function,Name,Arity,CLabel,Is0}, Lc0) ->
    try
	%% Collect basic blocks and optimize them.
	Is1 = blockify(Is0),
	Is2 = embed_lines(Is1),
	Is3 = move_allocates(Is2),
	Is4 = beam_utils:live_opt(Is3),
	Is5 = opt_blocks(Is4),
	Is6 = beam_utils:delete_live_annos(Is5),

	%% Optimize bit syntax.
	{Is,Lc} = bsm_opt(Is6, Lc0),

	%% Done.
	{{function,Name,Arity,CLabel,Is},Lc}
    catch
	Class:Error ->
	    Stack = erlang:get_stacktrace(),
	    io:fwrite("Function: ~w/~w\n", [Name,Arity]),
	    erlang:raise(Class, Error, Stack)
    end.

%% blockify(Instructions0) -> Instructions
%%  Collect sequences of instructions to basic blocks.
%%  Also do some simple optimations on instructions outside the blocks.

blockify(Is) ->
    blockify(Is, []).

blockify([{loop_rec,{f,Fail},{x,0}},{loop_rec_end,_Lbl},{label,Fail}|Is], Acc) ->
    %% Useless instruction sequence.
    blockify(Is, Acc);
blockify([{test,is_atom,{f,Fail},[Reg]}=I|
	  [{select,select_val,Reg,{f,Fail},
	    [{atom,false},{f,_}=BrFalse,
	     {atom,true}=AtomTrue,{f,_}=BrTrue]}|Is]=Is0],
	 [{block,Bl}|_]=Acc) ->
    case is_last_bool(Bl, Reg) of
	false ->
	    blockify(Is0, [I|Acc]);
	true ->
	    %% The last instruction is a boolean operator/guard BIF that can't fail.
	    %% We can convert the three-way branch to a two-way branch (eliminating
	    %% the reference to the failure label).
	    blockify(Is, [{jump,BrTrue},
			  {test,is_eq_exact,BrFalse,[Reg,AtomTrue]}|Acc])
    end;
blockify([{test,is_atom,{f,Fail},[Reg]}=I|
	  [{select,select_val,Reg,{f,Fail},
	    [{atom,true}=AtomTrue,{f,_}=BrTrue,
	     {atom,false},{f,_}=BrFalse]}|Is]=Is0],
	 [{block,Bl}|_]=Acc) ->
    case is_last_bool(Bl, Reg) of
	false ->
	    blockify(Is0, [I|Acc]);
	true ->
	    blockify(Is, [{jump,BrTrue},
			  {test,is_eq_exact,BrFalse,[Reg,AtomTrue]}|Acc])
    end;
blockify([I|Is0]=IsAll, Acc) ->
    case is_bs_put(I) of
	true ->
	    {BsPuts0,Is} = collect_bs_puts(IsAll),
	    BsPuts = opt_bs_puts(BsPuts0),
	    blockify(Is, reverse(BsPuts, Acc));
	false ->
	    case collect(I) of
		error -> blockify(Is0, [I|Acc]);
		Instr when is_tuple(Instr) ->
		    {Block,Is} = collect_block(IsAll),
		    blockify(Is, [{block,Block}|Acc])
	    end
    end;
blockify([], Acc) -> reverse(Acc).

is_last_bool([{set,[Reg],As,{bif,N,_}}], Reg) ->
    Ar = length(As),
    erl_internal:new_type_test(N, Ar) orelse erl_internal:comp_op(N, Ar)
	orelse erl_internal:bool_op(N, Ar);
is_last_bool([_|Is], Reg) -> is_last_bool(Is, Reg);
is_last_bool([], _) -> false.

collect_block(Is) ->
    collect_block(Is, []).

collect_block([{allocate,N,R}|Is0], Acc) ->
    {Inits,Is} = lists:splitwith(fun ({init,{y,_}}) -> true;
                                     (_) -> false
                                 end, Is0),
    collect_block(Is, [{set,[],[],{alloc,R,{nozero,N,0,Inits}}}|Acc]);
collect_block([{allocate_zero,Ns,R},{test_heap,Nh,R}|Is], Acc) ->
    collect_block(Is, [{set,[],[],{alloc,R,{zero,Ns,Nh,[]}}}|Acc]);
collect_block([I|Is]=Is0, Acc) ->
    case collect(I) of
	error -> {reverse(Acc),Is0};
	Instr -> collect_block(Is, [Instr|Acc])
    end.

collect({allocate,N,R})      -> {set,[],[],{alloc,R,{nozero,N,0,[]}}};
collect({allocate_zero,N,R}) -> {set,[],[],{alloc,R,{zero,N,0,[]}}};
collect({allocate_heap,Ns,Nh,R}) -> {set,[],[],{alloc,R,{nozero,Ns,Nh,[]}}};
collect({allocate_heap_zero,Ns,Nh,R}) -> {set,[],[],{alloc,R,{zero,Ns,Nh,[]}}};
collect({init,D})            -> {set,[D],[],init};
collect({test_heap,N,R})     -> {set,[],[],{alloc,R,{nozero,nostack,N,[]}}};
collect({bif,N,F,As,D})      -> {set,[D],As,{bif,N,F}};
collect({gc_bif,N,F,R,As,D}) -> {set,[D],As,{alloc,R,{gc_bif,N,F}}};
collect({move,S,D})          -> {set,[D],[S],move};
collect({put_list,S1,S2,D})  -> {set,[D],[S1,S2],put_list};
collect({put_tuple,A,D})     -> {set,[D],[],{put_tuple,A}};
collect({put,S})             -> {set,[],[S],put};
collect({get_tuple_element,S,I,D}) -> {set,[D],[S],{get_tuple_element,I}};
collect({set_tuple_element,S,D,I}) -> {set,[],[S,D],{set_tuple_element,I}};
collect({get_list,S,D1,D2})  -> {set,[D1,D2],[S],get_list};
collect(remove_message)      -> {set,[],[],remove_message};
collect({put_map,F,Op,S,D,R,{list,Puts}}) ->
    {set,[D],[S|Puts],{alloc,R,{put_map,Op,F}}};
collect({get_map_elements,F,S,{list,Gets}}) ->
    {Ss,Ds} = beam_utils:split_even(Gets),
    {set,Ds,[S|Ss],{get_map_elements,F}};
collect({'catch'=Op,R,L}) ->
    {set,[R],[],{try_catch,Op,L}};
collect({'try'=Op,R,L}) ->
    {set,[R],[],{try_catch,Op,L}};
collect(fclearerror)         -> {set,[],[],fclearerror};
collect({fcheckerror,{f,0}}) -> {set,[],[],fcheckerror};
collect({fmove,S,D})         -> {set,[D],[S],fmove};
collect({fconv,S,D})         -> {set,[D],[S],fconv};
collect(_)                   -> error.

%% embed_lines([Instruction]) -> [Instruction]
%%  Combine blocks that would be split by line/1 instructions.
%%  Also move a line instruction before a block into the block,
%%  but leave the line/1 instruction after a block outside.

embed_lines(Is) ->
    embed_lines(reverse(Is), []).

embed_lines([{block,B2},{line,_}=Line,{block,B1}|T], Acc) ->
    B = {block,B1++[{set,[],[],Line}]++B2},
    embed_lines([B|T], Acc);
embed_lines([{block,B1},{line,_}=Line|T], Acc) ->
    B = {block,[{set,[],[],Line}|B1]},
    embed_lines([B|T], Acc);
embed_lines([I|Is], Acc) ->
    embed_lines(Is, [I|Acc]);
embed_lines([], Acc) -> Acc.

opt_blocks([{block,Bl0}|Is]) ->
    %% The live annotation at the beginning is not useful.
    [{'%live',_,_}|Bl] = Bl0,
    [{block,opt_block(Bl)}|opt_blocks(Is)];
opt_blocks([I|Is]) ->
    [I|opt_blocks(Is)];
opt_blocks([]) -> [].

opt_block(Is0) ->
    Is = find_fixpoint(fun(Is) ->
			       opt_tuple_element(opt(Is))
		       end, Is0),
    opt_alloc(Is).

find_fixpoint(OptFun, Is0) ->
    case OptFun(Is0) of
	Is0 -> Is0;
	Is1 -> find_fixpoint(OptFun, Is1)
    end.

%% move_allocates(Is0) -> Is
%%  Move allocate instructions upwards in the instruction stream, in the
%%  hope of getting more possibilities for optimizing away moves later.
%%
%%  NOTE: Moving allocation instructions is only safe because it is done
%%  immediately after code generation so that we KNOW that if {x,X} is
%%  initialized, all x registers with lower numbers are also initialized.
%%  That assumption may not be true after other optimizations, such as
%%  the beam_utils:live_opt/1 optimization.

move_allocates([{block,Bl0}|Is]) ->
    Bl = move_allocates_1(reverse(Bl0), []),
    [{block,Bl}|move_allocates(Is)];
move_allocates([I|Is]) ->
    [I|move_allocates(Is)];
move_allocates([]) -> [].

move_allocates_1([{set,[],[],{alloc,_,_}=Alloc}|Is0], Acc0) ->
    {Is,Acc} = move_allocates_2(Alloc, Is0, Acc0),
    move_allocates_1(Is, Acc);
move_allocates_1([I|Is], Acc) ->
    move_allocates_1(Is, [I|Acc]);
move_allocates_1([], Is) -> Is.

move_allocates_2({alloc,Live,Info}, [{set,[],[],{alloc,Live0,Info0}}|Is], Acc) ->
    Live = Live0,				% Assertion.
    Alloc = {alloc,Live,combine_alloc(Info0, Info)},
    move_allocates_2(Alloc, Is, Acc);
move_allocates_2({alloc,Live,Info}=Alloc0, [I|Is]=Is0, Acc) ->
    case alloc_may_pass(I) of
	false ->
	    {Is0,[{set,[],[],Alloc0}|Acc]};
	true ->
	    Alloc = {alloc,alloc_live_regs(I, Live),Info},
	    move_allocates_2(Alloc, Is, [I|Acc])
    end;
move_allocates_2(Alloc, [], Acc) ->
    {[],[{set,[],[],Alloc}|Acc]}.

alloc_may_pass({set,_,_,{alloc,_,_}}) -> false;
alloc_may_pass({set,_,_,{set_tuple_element,_}}) -> false;
alloc_may_pass({set,_,_,{get_map_elements,_}}) -> false;
alloc_may_pass({set,_,_,put_list}) -> false;
alloc_may_pass({set,_,_,put}) -> false;
alloc_may_pass({set,_,_,_}) -> true.
    
combine_alloc({_,Ns,Nh1,Init}, {_,nostack,Nh2,[]})  ->
    {zero,Ns,beam_utils:combine_heap_needs(Nh1, Nh2),Init}.

%% opt([Instruction]) -> [Instruction]
%%  Optimize the instruction stream inside a basic block.

opt([{set,[X],[X],move}|Is]) -> opt(Is);
opt([{set,_,_,{line,_}}=Line1,
     {set,[D1],[{integer,Idx1},Reg],{bif,element,{f,0}}}=I1,
     {set,_,_,{line,_}}=Line2,
     {set,[D2],[{integer,Idx2},Reg],{bif,element,{f,0}}}=I2|Is])
  when Idx1 < Idx2, D1 =/= D2, D1 =/= Reg, D2 =/= Reg ->
    opt([Line2,I2,Line1,I1|Is]);
opt([{set,Ds0,Ss,Op}|Is0]) ->	
    {Ds,Is} = opt_moves(Ds0, Is0),
    [{set,Ds,Ss,Op}|opt(Is)];
opt([{'%live',_,_}=I|Is]) ->
    [I|opt(Is)];
opt([]) -> [].

%% opt_moves([Dest], [Instruction]) -> {[Dest],[Instruction]}
%%  For each Dest, does the optimization described in opt_move/2.

opt_moves([], Is0) -> {[],Is0};
opt_moves([D0]=Ds, Is0) ->
    case opt_move(D0, Is0) of
	not_possible -> {Ds,Is0};
	{D1,Is} -> {[D1],Is}
    end;
opt_moves([X0,Y0], Is0) ->
    {X,Is2} = case opt_move(X0, Is0) of
		  not_possible -> {X0,Is0};
		  {Y0,_} -> {X0,Is0};
		  {_X1,_Is1} = XIs1 -> XIs1
	      end,
    case opt_move(Y0, Is2) of
	not_possible -> {[X,Y0],Is2};
	{X,_} -> {[X,Y0],Is2};
	{Y,Is} -> {[X,Y],Is}
    end;
opt_moves(Ds, Is) ->
    %% multiple destinations -> pass through
    {Ds,Is}.


%% opt_move(Dest, [Instruction]) -> {UpdatedDest,[Instruction]} | not_possible
%%  If there is a {move,Dest,FinalDest} instruction
%%  in the instruction stream, remove the move instruction
%%  and let FinalDest be the destination.

opt_move(Dest, Is) ->
    opt_move_1(Dest, Is, []).

opt_move_1(R, [{set,[D],[R],move}|Is0], Acc) ->
    %% Provided that the source register is killed by instructions
    %% that follow, the optimization is safe.
    case eliminate_use_of_from_reg(Is0, R, D, []) of
	{yes,Is} -> opt_move_rev(D, Acc, Is);
	no -> not_possible
    end;
opt_move_1({x,_}, [{set,_,_,{alloc,_,_}}|_], _) ->
    %% The optimization is not possible. If the X register is not
    %% killed by allocation, the optimization would not be safe.
    %% If the X register is killed, it means that there cannot
    %% follow a 'move' instruction with this X register as the
    %% source.
    not_possible;
opt_move_1(R, [{set,_,_,_}=I|Is], Acc) ->
    %% If the source register is either killed or used by this
    %% instruction, the optimimization is not possible.
    case is_killed_or_used(R, I) of
	true -> not_possible;
	false -> opt_move_1(R, Is, [I|Acc])
    end;
opt_move_1(_, _, _) ->
    not_possible.

%% opt_tuple_element([Instruction]) -> [Instruction]
%%  If possible, move get_tuple_element instructions forward
%%  in the instruction stream to a move instruction, eliminating
%%  the move instruction. Example:
%%
%%    get_tuple_element Tuple Pos Dst1
%%    ...
%%    move Dst1 Dst2
%%
%%  This code may be possible to rewrite to:
%%
%%    %%(Moved get_tuple_element instruction)
%%    ...
%%    get_tuple_element Tuple Pos Dst2
%%

opt_tuple_element([{set,[D],[S],{get_tuple_element,_}}=I|Is0]) ->
    case opt_tuple_element_1(Is0, I, {S,D}, []) of
	no ->
	    [I|opt_tuple_element(Is0)];
	{yes,Is} ->
	    opt_tuple_element(Is)
    end;
opt_tuple_element([I|Is]) ->
    [I|opt_tuple_element(Is)];
opt_tuple_element([]) -> [].

opt_tuple_element_1([{set,_,_,{alloc,_,_}}|_], _, _, _) ->
    no;
opt_tuple_element_1([{set,_,_,{try_catch,_,_}}|_], _, _, _) ->
    no;
opt_tuple_element_1([{set,[D],[S],move}|Is0], I0, {_,S}, Acc) ->
    case eliminate_use_of_from_reg(Is0, S, D, []) of
	no ->
	    no;
	{yes,Is} ->
	    {set,[S],Ss,Op} = I0,
	    I = {set,[D],Ss,Op},
	    {yes,reverse(Acc, [I|Is])}
    end;
opt_tuple_element_1([{set,Ds,Ss,_}=I|Is], MovedI, {S,D}=Regs, Acc) ->
    case member(S, Ds) orelse member(D, Ss) of
	true ->
	    no;
	false ->
	    opt_tuple_element_1(Is, MovedI, Regs, [I|Acc])
    end;
opt_tuple_element_1(_, _, _, _) -> no.

%% Reverse the instructions, while checking that there are no
%% instructions that would interfere with using the new destination
%% register (D).

opt_move_rev(D, [I|Is], Acc) ->
    case is_killed_or_used(D, I) of
	true -> not_possible;
	false -> opt_move_rev(D, Is, [I|Acc])
    end;
opt_move_rev(D, [], Acc) -> {D,Acc}.

%% is_killed_or_used(Register, {set,_,_,_}) -> bool()
%%  Test whether the register is used by the instruction.

is_killed_or_used(R, {set,Ss,Ds,_}) ->
    member(R, Ds) orelse member(R, Ss).

%% eliminate_use_of_from_reg([Instruction], FromRegister, ToRegister, Acc) ->
%%       {yes,Is} | no
%%  Eliminate any use of FromRegister in the instruction sequence
%%  by replacing uses of FromRegister with ToRegister. If FromRegister
%%  is referenced by an allocation instruction, return 'no' to indicate
%%  that FromRegister is still used and that the optimization is not
%%  possible.

eliminate_use_of_from_reg([{set,_,_,{alloc,Live,_}}|_]=Is0, {x,X}, _, Acc) ->
    if
	X < Live ->
	    no;
	true ->
	    {yes,reverse(Acc, Is0)}
    end;
eliminate_use_of_from_reg([{set,Ds,Ss0,Op}=I0|Is], From, To, Acc) ->
    I = case member(From, Ss0) of
	    true ->
		Ss = [case S of
			  From -> To;
			  _ -> S
		      end || S <- Ss0],
		{set,Ds,Ss,Op};
	    false ->
		I0
	end,
    case member(From, Ds) of
	true ->
	    {yes,reverse(Acc, [I|Is])};
	false ->
	    eliminate_use_of_from_reg(Is, From, To, [I|Acc])
    end;
eliminate_use_of_from_reg([I]=Is, From, _To, Acc) ->
    case beam_utils:is_killed_block(From, [I]) of
	true ->
	    {yes,reverse(Acc, Is)};
	false ->
	    no
    end.

%% opt_alloc(Instructions) -> Instructions'
%%  Optimises all allocate instructions.

opt_alloc([{set,[],[],{alloc,R,{_,Ns,Nh,[]}}}|Is]) ->
    [{set,[],[],opt_alloc(Is, Ns, Nh, R)}|Is];
opt_alloc([I|Is]) -> [I|opt_alloc(Is)];
opt_alloc([]) -> [].
	
%% opt_alloc(Instructions, FrameSize, HeapNeed, LivingRegs) -> [Instr]
%%  Generates the optimal sequence of instructions for
%%  allocating and initalizing the stack frame and needed heap.

opt_alloc(_Is, nostack, Nh, LivingRegs) ->
    {alloc,LivingRegs,{nozero,nostack,Nh,[]}};
opt_alloc(Is, Ns, Nh, LivingRegs) ->
    InitRegs = init_yreg(Is, 0),
    case count_ones(InitRegs) of
	N when N*2 > Ns ->
	    {alloc,LivingRegs,{nozero,Ns,Nh,gen_init(Ns, InitRegs)}};
	_ ->
	    {alloc,LivingRegs,{zero,Ns,Nh,[]}}
    end.

gen_init(Fs, Regs) -> gen_init(Fs, Regs, 0, []).

gen_init(SameFs, _Regs, SameFs, Acc) -> reverse(Acc);
gen_init(Fs, Regs, Y, Acc) when Regs band 1 =:= 0 ->
    gen_init(Fs, Regs bsr 1, Y+1, [{init,{y,Y}}|Acc]);
gen_init(Fs, Regs, Y, Acc) ->
    gen_init(Fs, Regs bsr 1, Y+1, Acc).

%% init_yreg(Instructions, RegSet) -> RegSetInitialized
%%  Calculate the set of initialized y registers.

init_yreg([{set,_,_,{bif,_,_}}|_], Reg) -> Reg;
init_yreg([{set,_,_,{alloc,_,{gc_bif,_,_}}}|_], Reg) -> Reg;
init_yreg([{set,_,_,{alloc,_,{put_map,_,_}}}|_], Reg) -> Reg;
init_yreg([{set,Ds,_,_}|Is], Reg) -> init_yreg(Is, add_yregs(Ds, Reg));
init_yreg(_Is, Reg) -> Reg.

add_yregs(Ys, Reg) -> foldl(fun(Y, R0) -> add_yreg(Y, R0) end, Reg, Ys).
    
add_yreg({y,Y}, Reg) -> Reg bor (1 bsl Y);
add_yreg(_, Reg)     -> Reg.

count_ones(Bits) -> count_ones(Bits, 0).
count_ones(0, Acc) -> Acc;
count_ones(Bits, Acc) ->
    count_ones(Bits bsr 1, Acc + (Bits band 1)).

%% Calculate the new number of live registers when we move an allocate
%% instruction upwards, passing a 'set' instruction.

alloc_live_regs({set,Ds,Ss,_}, Regs0) ->
    Rset = x_live(Ss, x_dead(Ds, (1 bsl Regs0)-1)),
    live_regs(Rset).

live_regs(Regs) ->
    live_regs_1(0, Regs).

live_regs_1(N, 0) -> N;
live_regs_1(N, Regs) -> live_regs_1(N+1, Regs bsr 1).

x_dead([{x,N}|Rs], Regs) -> x_dead(Rs, Regs band (bnot (1 bsl N)));
x_dead([_|Rs], Regs) -> x_dead(Rs, Regs);
x_dead([], Regs) -> Regs.

x_live([{x,N}|Rs], Regs) -> x_live(Rs, Regs bor (1 bsl N));
x_live([_|Rs], Regs) -> x_live(Rs, Regs);
x_live([], Regs) -> Regs.

%%%
%%% Evaluation of constant bit fields.
%%%

is_bs_put({bs_put,_,{bs_put_integer,_,_},_}) -> true;
is_bs_put({bs_put,_,{bs_put_float,_,_},_}) -> true;
is_bs_put(_) -> false.

collect_bs_puts(Is) ->
    collect_bs_puts_1(Is, []).
    
collect_bs_puts_1([I|Is]=Is0, Acc) ->
    case is_bs_put(I) of
	false -> {reverse(Acc),Is0};
	true -> collect_bs_puts_1(Is, [I|Acc])
    end.
    
opt_bs_puts(Is) ->
    opt_bs_1(Is, []).

opt_bs_1([{bs_put,Fail,
	   {bs_put_float,1,Flags0},[{integer,Sz},Src]}=I0|Is], Acc) ->
    try eval_put_float(Src, Sz, Flags0) of
	<<Int:Sz>> ->
	    Flags = force_big(Flags0),
	    I = {bs_put,Fail,{bs_put_integer,1,Flags},
		 [{integer,Sz},{integer,Int}]},
	    opt_bs_1([I|Is], Acc)
    catch
	error:_ ->
	    opt_bs_1(Is, [I0|Acc])
    end;
opt_bs_1([{bs_put,_,{bs_put_integer,1,_},[{integer,8},{integer,_}]}|_]=IsAll,
	 Acc0) ->
    {Is,Acc} = bs_collect_string(IsAll, Acc0),
    opt_bs_1(Is, Acc);
opt_bs_1([{bs_put,Fail,{bs_put_integer,1,F},[{integer,Sz},{integer,N}]}=I|Is0],
	 Acc) when Sz > 8 ->
    case field_endian(F) of
	big ->
	    %% We can do this optimization for any field size without risk
	    %% for code explosion.
	    case bs_split_int(N, Sz, Fail, Is0) of
		no_split -> opt_bs_1(Is0, [I|Acc]);
		Is -> opt_bs_1(Is, Acc)
	    end;
	little when Sz < 128 ->
	    %% We only try to optimize relatively small fields, to avoid
	    %% an explosion in code size.
	    <<Int:Sz>> = <<N:Sz/little>>,
	    Flags = force_big(F),
	    Is = [{bs_put,Fail,{bs_put_integer,1,Flags},
		   [{integer,Sz},{integer,Int}]}|Is0],
	    opt_bs_1(Is, Acc);
	_ -> 					%native or too wide little field
	    opt_bs_1(Is0, [I|Acc])
    end;
opt_bs_1([{bs_put,Fail,{Op,U,F},[{integer,Sz},Src]}|Is], Acc) when U > 1 ->
    opt_bs_1([{bs_put,Fail,{Op,1,F},[{integer,U*Sz},Src]}|Is], Acc);
opt_bs_1([I|Is], Acc) ->
    opt_bs_1(Is, [I|Acc]);
opt_bs_1([], Acc) -> reverse(Acc).

eval_put_float(Src, Sz, Flags) when Sz =< 256 -> %Only evaluate if Sz is reasonable.
    Val = value(Src),
    case field_endian(Flags) of
	little -> <<Val:Sz/little-float-unit:1>>;
	big -> <<Val:Sz/big-float-unit:1>>
        %% native intentionally not handled here - we can't optimize it.
    end.

value({integer,I}) -> I;
value({float,F}) -> F.

bs_collect_string(Is, [{bs_put,_,{bs_put_string,Len,{string,Str}},[]}|Acc]) ->
    bs_coll_str_1(Is, Len, reverse(Str), Acc);
bs_collect_string(Is, Acc) ->
    bs_coll_str_1(Is, 0, [], Acc).
    
bs_coll_str_1([{bs_put,_,{bs_put_integer,U,_},[{integer,Sz},{integer,V}]}|Is],
	      Len, StrAcc, IsAcc) when U*Sz =:= 8 ->
    Byte = V band 16#FF,
    bs_coll_str_1(Is, Len+1, [Byte|StrAcc], IsAcc);
bs_coll_str_1(Is, Len, StrAcc, IsAcc) ->
    {Is,[{bs_put,{f,0},{bs_put_string,Len,{string,reverse(StrAcc)}},[]}|IsAcc]}.

field_endian({field_flags,F}) -> field_endian_1(F).

field_endian_1([big=E|_]) -> E;
field_endian_1([little=E|_]) -> E;
field_endian_1([native=E|_]) -> E;
field_endian_1([_|Fs]) -> field_endian_1(Fs).

force_big({field_flags,F}) ->
    {field_flags,force_big_1(F)}.

force_big_1([big|_]=Fs) -> Fs;
force_big_1([little|Fs]) -> [big|Fs];
force_big_1([F|Fs]) -> [F|force_big_1(Fs)].

bs_split_int(0, Sz, _, _) when Sz > 64 ->
    %% We don't want to split in this case because the
    %% string will consist of only zeroes.
    no_split;
bs_split_int(-1, Sz, _, _) when Sz > 64 ->
    %% We don't want to split in this case because the
    %% string will consist of only 255 bytes.
    no_split;
bs_split_int(N, Sz, Fail, Acc) ->
    FirstByteSz = case Sz rem 8 of
		      0 -> 8;
		      Rem -> Rem
		  end,
    bs_split_int_1(N, FirstByteSz, Sz, Fail, Acc).

bs_split_int_1(-1, _, Sz, Fail, Acc) when Sz > 64 ->
    I = {bs_put,Fail,{bs_put_integer,1,{field_flags,[big]}},
	 [{integer,Sz},{integer,-1}]},
    [I|Acc];
bs_split_int_1(0, _, Sz, Fail, Acc) when Sz > 64 ->
    I = {bs_put,Fail,{bs_put_integer,1,{field_flags,[big]}},
	 [{integer,Sz},{integer,0}]},
    [I|Acc];
bs_split_int_1(N, ByteSz, Sz, Fail, Acc) when Sz > 0 ->
    Mask = (1 bsl ByteSz) - 1,
    I = {bs_put,Fail,{bs_put_integer,1,{field_flags,[big]}},
	 [{integer,ByteSz},{integer,N band Mask}]},
    bs_split_int_1(N bsr ByteSz, 8, Sz-ByteSz, Fail, [I|Acc]);
bs_split_int_1(_, _, _, _, Acc) -> Acc.


%%%
%%% Optimization of new bit syntax matching: get rid
%%% of redundant bs_restore2/2 instructions across select_val
%%% instructions, as well as a few other simple peep-hole optimizations.
%%%

bsm_opt(Is0, Lc0) ->
    {Is1,D0,Lc} = bsm_scan(Is0, [], Lc0, []),
    Is2 = case D0 of
	      [] ->
		  Is1;
	     _ ->
		  D = gb_trees:from_orddict(orddict:from_list(D0)),
		  bsm_reroute(Is1, D, none, [])
	 end,
    Is = beam_clean:bs_clean_saves(Is2),
    {bsm_opt_2(Is, []),Lc}.

bsm_scan([{label,L}=Lbl,{bs_restore2,_,Save}=R|Is], D0, Lc, Acc0) ->
    D = [{{L,Save},Lc}|D0],
    Acc = [{label,Lc},R,Lbl|Acc0],
    bsm_scan(Is, D, Lc+1, Acc);
bsm_scan([I|Is], D, Lc, Acc) ->
    bsm_scan(Is, D, Lc, [I|Acc]);
bsm_scan([], D, Lc, Acc) ->
    {reverse(Acc),D,Lc}.

bsm_reroute([{bs_save2,Reg,Save}=I|Is], D, _, Acc) ->
    bsm_reroute(Is, D, {Reg,Save}, [I|Acc]);
bsm_reroute([{bs_restore2,Reg,Save}=I|Is], D, _, Acc) ->
    bsm_reroute(Is, D, {Reg,Save}, [I|Acc]);
bsm_reroute([{label,_}=I|Is], D, S, Acc) ->
    bsm_reroute(Is, D, S, [I|Acc]);
bsm_reroute([{select,select_val,Reg,F0,Lbls0}|Is], D, {_,Save}=S, Acc0) ->
    [F|Lbls] = bsm_subst_labels([F0|Lbls0], Save, D),
    Acc = [{select,select_val,Reg,F,Lbls}|Acc0],
    bsm_reroute(Is, D, S, Acc);
bsm_reroute([{test,TestOp,F0,TestArgs}=I|Is], D, {_,Save}=S, Acc0) ->
    F = bsm_subst_label(F0, Save, D),
    Acc = [{test,TestOp,F,TestArgs}|Acc0],
    case bsm_not_bs_test(I) of
	true ->
	    %% The test instruction will not update the bit offset for the
	    %% binary being matched. Therefore the save position can be kept.
	    bsm_reroute(Is, D, S, Acc);
	false ->
	    %% The test instruction might update the bit offset. Kill our
	    %% remembered Save position.
	    bsm_reroute(Is, D, none, Acc)
    end;
bsm_reroute([{test,TestOp,F0,Live,TestArgs,Dst}|Is], D, {_,Save}, Acc0) ->
    F = bsm_subst_label(F0, Save, D),
    Acc = [{test,TestOp,F,Live,TestArgs,Dst}|Acc0],
    %% The test instruction will update the bit offset. Kill our
    %% remembered Save position.
    bsm_reroute(Is, D, none, Acc);
bsm_reroute([{block,[{set,[],[],{alloc,_,_}}]}=Bl,
	     {bs_context_to_binary,_}=I|Is], D, S, Acc) ->
    %% To help further bit syntax optimizations.
    bsm_reroute([I,Bl|Is], D, S, Acc);
bsm_reroute([I|Is], D, _, Acc) ->
    bsm_reroute(Is, D, none, [I|Acc]);
bsm_reroute([], _, _, Acc) -> reverse(Acc).

bsm_opt_2([{test,bs_test_tail2,F,[Ctx,Bits]}|Is],
	  [{test,bs_skip_bits2,F,[Ctx,{integer,I},Unit,_Flags]}|Acc]) ->
    bsm_opt_2(Is, [{test,bs_test_tail2,F,[Ctx,Bits+I*Unit]}|Acc]);
bsm_opt_2([{test,bs_skip_bits2,F,[Ctx,{integer,I1},Unit1,_]}|Is],
	  [{test,bs_skip_bits2,F,[Ctx,{integer,I2},Unit2,Flags]}|Acc]) ->
    bsm_opt_2(Is, [{test,bs_skip_bits2,F,
		    [Ctx,{integer,I1*Unit1+I2*Unit2},1,Flags]}|Acc]);
bsm_opt_2([I|Is], Acc) ->
    bsm_opt_2(Is, [I|Acc]);
bsm_opt_2([], Acc) -> reverse(Acc).

%% bsm_not_bs_test({test,Name,_,Operands}) -> true|false.
%%  Test whether is the test is a "safe", i.e. does not move the
%%  bit offset for a binary.
%%
%%  'true' means that the test is safe, 'false' that we don't know or
%%  that the test moves the offset (e.g. bs_get_integer2).

bsm_not_bs_test({test,bs_test_tail2,_,[_,_]}) -> true;
bsm_not_bs_test(Test) -> beam_utils:is_pure_test(Test).

bsm_subst_labels(Fs, Save, D) ->
    bsm_subst_labels_1(Fs, Save, D, []).

bsm_subst_labels_1([F|Fs], Save, D, Acc) ->
    bsm_subst_labels_1(Fs, Save, D, [bsm_subst_label(F, Save, D)|Acc]);
bsm_subst_labels_1([], _, _, Acc) ->
    reverse(Acc).

bsm_subst_label({f,Lbl0}=F, Save, D) ->
    case gb_trees:lookup({Lbl0,Save}, D) of
	{value,Lbl} -> {f,Lbl};
	none -> F
    end;
bsm_subst_label(Other, _, _) -> Other.
