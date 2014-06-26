header "More Automation"
theory Refine_Automation
imports Refine_Basic Refine_Transfer
keywords "concrete_definition" :: thy_decl
  and "prepare_code_thms" :: thy_decl
  and "uses"
begin

text {*
  This theory provides a tool for extracting definitions from terms, and
  for generating code equations for recursion combinators.
*}

ML {*
signature REFINE_AUTOMATION = sig
  type extraction = {
    pattern: term,   (* Pattern to be defined as own constant *)
    gen_thm: thm,    (* Code eq generator: [| c==rhs; ... |] ==> c == ... *)
    gen_tac: local_theory -> tactic' (* Solves remaining premises of gen_thm *)
  }

  val extract_as_def: (string * typ) list -> string -> term 
    -> local_theory -> ((term * thm) * local_theory)

  val extract_recursion_eqs: extraction list -> string -> thm 
    -> local_theory -> local_theory

  val add_extraction: string -> extraction -> theory -> theory

  val prepare_code_thms_cmd: string list -> thm -> local_theory -> local_theory

  val define_concrete_fun: extraction list option -> binding -> 
    Args.src list -> indexname list -> thm ->
    cterm list -> local_theory -> local_theory
  

  val prepare_cd_pattern: cterm -> cterm
  val add_cd_pattern: cterm -> Context.generic -> Context.generic
  val del_cd_pattern: cterm -> Context.generic -> Context.generic
  val get_cd_patterns: Proof.context -> cterm list

  val add_vc_rec_thm: thm -> Context.generic -> Context.generic
  val del_vc_rec_thm: thm -> Context.generic -> Context.generic
  val get_vc_rec_thms: Proof.context -> thm list

  val add_vc_solve_thm: thm -> Context.generic -> Context.generic
  val del_vc_solve_thm: thm -> Context.generic -> Context.generic
  val get_vc_solve_thms: Proof.context -> thm list

  val vc_solve_tac: Proof.context -> bool -> tactic'
  val vc_solve_modifiers: Method.modifier parser list

  val setup: theory -> theory
end

structure Refine_Automation :REFINE_AUTOMATION = struct

  type extraction = {
    pattern: term,   (* Pattern to be defined as own constant *)
    gen_thm: thm,    (* Code eq generator: [| c==rhs; ... |] ==> c == ... *)
    gen_tac: local_theory -> tactic' (* Solves remaining premises of gen_thm *)
  }

  structure extractions = Generic_Data (
    type T = extraction list Symtab.table
    val empty = Symtab.empty
    val extend = I
    val merge = Symtab.merge_list (op = o pairself #pattern)
  )

  fun add_extraction name ex = 
    Context.theory_map (extractions.map (
      Symtab.update_list (op = o pairself #pattern) (name,ex)))

  (*
    Define new constant name for subterm t in context bnd.
    Returns replacement for t using the new constant and definition 
    theorem.
  *)
  fun extract_as_def bnd name t lthy = let
    val loose = rev (loose_bnos t);

    val rnames = #1 (Variable.names_of lthy |> fold_map (Name.variant o #1) bnd);
    val rfrees = map (fn (name,(_,typ)) => Free (name,typ)) (rnames ~~ bnd);
    val t' = subst_bounds (rfrees,t);
    val params = map Bound (rev loose);
    
    val param_vars 
      = (Library.foldl (fn (l,i) => nth rfrees i :: l) ([],loose));
    val param_types = map fastype_of param_vars;

    val def_t = Logic.mk_equals 
      (list_comb (Free (name,param_types ---> fastype_of t'),param_vars),t');

    val ((lhs_t,(_,def_thm)),lthy) 
      = Specification.definition (NONE,(Attrib.empty_binding,def_t)) lthy;

    (*val _ = tracing "xxxx";*)
    val app_t = list_comb (lhs_t, params);
  in 
    ((app_t,def_thm),lthy)
  end;


fun mk_qualified basename q = Binding.qualify true basename (Binding.name q);

fun extract_recursion_eqs exs basename orig_def_thm lthy = let

  val thy = Proof_Context.theory_of lthy
  val cert = cterm_of thy
 
  val pat_net : extraction Item_Net.T =
    Item_Net.init (op= o pairself #pattern) (fn {pattern, ...} => [pattern])
    |> fold Item_Net.update exs

  local
    fun tr env t ctx = let
      (* Recurse for subterms *)
      val (t,ctx) = case t of
        t1$t2 => let
            val (t1,ctx) = tr env t1 ctx
            val (t2,ctx) = tr env t2 ctx
          in 
            (t1$t2,ctx)
          end
      | Abs (x,T,t) => let 
            val (t',ctx) = tr ((x,T)::env) t ctx
          in (Abs (x,T,t'),ctx) end
      | _ => (t,ctx)      

      (* Check if we match a pattern *)
      val ex = 
        Item_Net.retrieve_matching pat_net t
        |> get_first (fn ex => 
             case
               try (Pattern.first_order_match thy (#pattern ex,t)) 
                 (Vartab.empty,Vartab.empty)
             of NONE => NONE | SOME _ => SOME ex
           )
    in
      case ex of 
        NONE => (t,ctx)
      | SOME ex => let
          (* Extract as new constant *)
          val (idx,defs,lthy) = ctx
          val name = (basename ^ "_" ^ string_of_int idx)
          val ((t,def_thm),lthy) = extract_as_def env name t lthy
          val ctx = (idx+1,(def_thm,ex)::defs,lthy)
        in
          (t,ctx)
        end
    end
  in
    fun transform t lthy = let 
      val (t,(_,defs,lthy)) = tr [] t (0,[],lthy)
    in 
      ((t,defs),lthy)
    end
  end

  (* Import theorem and extract RHS *)
  val ((_,orig_def_thm'),lthy) = yield_singleton2 
    (Variable.import true) orig_def_thm lthy;
  val (lhs,rhs) = orig_def_thm' |> prop_of |> Logic.dest_equals;
  
  (* Transform RHS, generating new constants *)
  val ((rhs',defs),lthy) = transform rhs lthy;
  val def_thms = map #1 defs

  (* Register definitions of generated constants *)
  val (_,lthy) 
    = Local_Theory.note ((mk_qualified basename "defs",[]),def_thms) lthy;
  
  (* Obtain new def_thm *)
  val def_unfold_ss = 
    put_simpset HOL_basic_ss lthy addsimps (orig_def_thm::def_thms)
  val new_def_thm = Goal.prove_internal lthy
    [] (Logic.mk_equals (lhs,rhs') |> cert) (K (simp_tac def_unfold_ss 1))

  (* Obtain new theorem by folding with defs of generated constants *)
  (* TODO: Maybe cleaner to generate eq-thm and prove by "unfold, refl" *)
  (*val new_def_thm 
    = Library.foldr (fn (dt,t) => Local_Defs.fold lthy [dt] t) 
        (def_thms,orig_def_thm');*)

  (* Prepare code equations *)
  fun mk_code_thm lthy (def_thm,{gen_thm, gen_tac, ...}) = let
    val ((_,def_thm),lthy') = yield_singleton2 
      (Variable.import true) def_thm lthy;
    val thm = def_thm RS gen_thm;
    val tac = SOLVED' (gen_tac lthy')
      ORELSE' (simp_tac def_unfold_ss THEN' gen_tac lthy')

    val thm = the (SINGLE (ALLGOALS tac) thm);
    val thm = singleton (Variable.export lthy' lthy) thm;
  in
    thm
  end;
  
  val code_thms = map (mk_code_thm lthy) defs;

  val _ = if forall Thm.no_prems code_thms then () else 
    warning "Unresolved premises in code theorems"

  val (_,lthy) = Local_Theory.note 
    ((mk_qualified basename "code",@{attributes [code]}),new_def_thm::code_thms)
     lthy;

in
  lthy
end;

fun prepare_code_thms_cmd names thm lthy = let
  fun name_of (Const (n,_)) = n 
    | name_of (Free (n,_)) = n
    | name_of _ = raise (THM ("No definitional theorem",0,[thm]));

  val (lhs,_) = thm |> prop_of |> Logic.dest_equals;
  val basename = lhs |> strip_comb |> #1 
    |> name_of 
    |> Long_Name.base_name;

  val exs_tab = extractions.get (Context.Proof lthy)
  fun get_exs name = 
    case Symtab.lookup exs_tab name of
      NONE => error ("No such extraction mode: " ^ name)
    | SOME exs => exs

  val exs = case names of 
    [] => Symtab.dest_list exs_tab |> map #2
  | _ => map get_exs names |> flat

  val _ = case exs of [] => error "No extraction patterns selected" | _ => ()
  
  val lthy = extract_recursion_eqs exs basename thm lthy
in
  lthy
end;

(* Recognize pattern of conclusion and extract term to make definition of *)
fun extract_concrete_fun _ [] concl = 
  raise TERM ("Conclusion does not match any extraction pattern",[concl])
  | extract_concrete_fun thy (pat::pats) concl = (
      case Refine_Util.fo_matchp thy pat concl of
        NONE => extract_concrete_fun thy pats concl
        | SOME [t] => t
        | SOME (t::_) => (
          warning ("concrete_definition: Pattern has multiple holes, taking "
            ^ "first one: " ^ PolyML.makestring pat
          ); t)
        | _ => (warning ("concrete_definition: Ignoring invalid pattern " 
             ^ PolyML.makestring pat);
             extract_concrete_fun thy pats concl)
    )



(* Define concrete function from refinement lemma *)
fun define_concrete_fun gen_code fun_name attribs_raw param_names thm pats
  (orig_lthy:local_theory) = 
let
  val lthy = orig_lthy;
  val ((inst,thm'),lthy) = yield_singleton2 (Variable.import true) thm lthy;

  val concl = thm' |> concl_of

  (*val ((typ_subst,term_subst),lthy) 
    = Variable.import_inst true [concl] lthy;
  val concl = Term_Subst.instantiate (typ_subst,term_subst) concl;
  *)

  val term_subst = #2 inst |> map (pairself term_of) 
    |> map (apfst dest_Var);

  val param_terms = map (fn name =>
    case AList.lookup (fn (n,v) => n = #1 v) term_subst name of
      NONE => raise TERM ("No such variable: "
                           ^Term.string_of_vname name,[concl])
    | SOME t => t
  ) param_names;

  val f_term = extract_concrete_fun (Proof_Context.theory_of lthy) pats concl;

  val lhs_type = map Term.fastype_of param_terms ---> Term.fastype_of f_term;
  val lhs_term 
    = list_comb ((Free (Binding.name_of fun_name,lhs_type)),param_terms);
  val def_term = Logic.mk_equals (lhs_term,f_term) 
    |> fold Logic.all param_terms;

  val attribs = map (Attrib.check_src lthy) attribs_raw;

  val ((_,(_,def_thm)),lthy) = Specification.definition 
    (SOME (fun_name,NONE,Mixfix.NoSyn),((Binding.empty,attribs),def_term)) lthy;

  val folded_thm = Local_Defs.fold lthy [def_thm] thm';

  val (_,lthy) 
    = Local_Theory.note 
       ((mk_qualified (Binding.name_of fun_name) "refine",[]),[folded_thm]) 
       lthy;

  val lthy = case gen_code of
    NONE => lthy
  | SOME modes => 
      extract_recursion_eqs modes (Binding.name_of fun_name) def_thm lthy

in
  lthy
end;

  val cd_pat_eq = pairself (term_of #> Refine_Util.anorm_term) #> op aconv

  structure cd_patterns = Generic_Data (
    type T = cterm list
    val empty = []
    val extend = I
    val merge = merge cd_pat_eq
  ) 

  fun prepare_cd_pattern pat = 
    case term_of pat |> fastype_of of
      @{typ bool} => 
        term_of pat 
        |> HOLogic.mk_Trueprop 
        |> cterm_of (theory_of_cterm pat)
    | _ => pat

  fun add_cd_pattern pat = 
    cd_patterns.map (insert cd_pat_eq (prepare_cd_pattern pat))

  fun del_cd_pattern pat = 
    cd_patterns.map (remove cd_pat_eq (prepare_cd_pattern pat))

  val get_cd_patterns = cd_patterns.get o Context.Proof


    structure rec_thms = Named_Thms ( 
      val name = @{binding vcs_rec}
      val description = "VC-Solver: Recursive intro rules"
    )

    structure solve_thms = Named_Thms ( 
      val name = @{binding vcs_solve}
      val description = "VC-Solver: Solve rules"
    )

    val add_vc_rec_thm = rec_thms.add_thm
    val del_vc_rec_thm = rec_thms.del_thm
    val get_vc_rec_thms = rec_thms.get

    val add_vc_solve_thm = solve_thms.add_thm
    val del_vc_solve_thm = solve_thms.del_thm
    val get_vc_solve_thms = solve_thms.get

    val rec_modifiers = [
      Args.$$$ "rec" -- Scan.option Args.add -- Args.colon 
        >> K ((I,rec_thms.add):Method.modifier),
      Args.$$$ "rec" -- Scan.option Args.del -- Args.colon 
        >> K ((I,rec_thms.del):Method.modifier)
    ];

    val solve_modifiers = [
      Args.$$$ "solve" -- Scan.option Args.add -- Args.colon 
        >> K ((I,solve_thms.add):Method.modifier),
      Args.$$$ "solve" -- Scan.option Args.del -- Args.colon 
        >> K ((I,solve_thms.del):Method.modifier)
    ];

    val vc_solve_modifiers = 
      clasimp_modifiers @ rec_modifiers @ solve_modifiers;

    fun vc_solve_tac ctxt no_pre = let
      val rthms = rec_thms.get ctxt
      val sthms = solve_thms.get ctxt
      val pre_tac = if no_pre then K all_tac else clarsimp_tac ctxt
      val tac = SELECT_GOAL (auto_tac ctxt)
    in
      TRY o pre_tac
      THEN_ALL_NEW_FWD (TRY o REPEAT_ALL_NEW_FWD (resolve_tac rthms))
      THEN_ALL_NEW_FWD (TRY o SOLVED' (resolve_tac sthms THEN_ALL_NEW_FWD tac))
    end

    val setup = I
      #> rec_thms.setup 
      #> solve_thms.setup


end;
*}

setup Refine_Automation.setup

setup {*
  let
    fun parse_cpat cxt = let 
      val (t,(context,tks)) = Scan.lift Args.name_inner_syntax cxt 
      val thy = Context.theory_of context
      val ctxt = Context.proof_of context
      val t = Proof_Context.read_term_pattern ctxt t
    in
      (cterm_of thy t,(context,tks))
    end

    fun do_p f = Scan.repeat1 parse_cpat >> (fn pats => 
        Thm.declaration_attribute (K (fold f pats)))
  in
    Attrib.setup @{binding "cd_patterns"} (
       Scan.lift Args.add |-- do_p Refine_Automation.add_cd_pattern
    || Scan.lift Args.del |-- do_p Refine_Automation.del_cd_pattern
    || do_p Refine_Automation.add_cd_pattern
    )
      "Add/delete concrete_definition pattern"
  end
*}


(* Command setup *)

(* TODO: Folding of .refine-lemma seems not to work, if the function has
  parameters on which it does not depend *)

ML {* Outer_Syntax.local_theory 
  @{command_spec "concrete_definition"} 
  "Define function from refinement theorem" 
  (Parse.binding 
    -- Parse_Spec.opt_attribs
    -- Scan.optional (@{keyword "for"} |-- Scan.repeat1 Args.var) []
    --| @{keyword "uses"} -- Parse_Spec.xthm
    -- Scan.optional (@{keyword "is"} |-- Scan.repeat1 Args.name_inner_syntax) []
  >> (fn ((((name,attribs),params),raw_thm),pats) => fn lthy => let
    val thm = 
      case Attrib.eval_thms lthy [raw_thm] of
        [thm] => thm
        | _ => error "Expecting exactly one theorem";
    val thy = Proof_Context.theory_of lthy
    val pats = case pats of 
      [] => Refine_Automation.get_cd_patterns lthy
    | l => map (Proof_Context.read_term_pattern lthy #> cterm_of thy #> 
        Refine_Automation.prepare_cd_pattern) l

  in 
    Refine_Automation.define_concrete_fun 
      NONE name attribs params thm pats lthy 
  end))
*}

text {* 
  Command: 
    @{text "concrete_definition name [attribs] for params uses thm is patterns"}
  where @{text "attribs"}, @{text "for"}, and @{text "is"}-parts are optional.

  Declares a new constant @{text "name"} by matching the theorem @{text "thm"} 
  against a pattern.
  
  If the @{text "for"} clause is given, it lists variables in the theorem, 
  and thus determines the order of parameters of the defined constant. Otherwise,
  parameters will be in order of occurence.

  If the @{text "is"} clause is given, it lists patterns. The conclusion of the
  theorem will be matched against each of these patterns. For the first matching
  pattern, the constant will be declared to be the term that matches the first
  non-dummy variable of the pattern. If no @{text "is"}-clause is specified,
  the default patterns will be tried.

  Attribute: @{text "cd_patterns pats"}. Declaration attribute. Declares
    default patterns for the @{text "concrete_definition"} command.
  
*}


declare [[ cd_patterns "(?f,_)\<in>_"]]
declare [[ cd_patterns "RETURN ?f \<le> _" "nres_of ?f \<le> _"]]
declare [[ cd_patterns "(RETURN ?f,_)\<in>_" "(nres_of ?f,_)\<in>_"]]
declare [[ cd_patterns "_ = ?f" "_ == ?f" ]]

ML {* 
  let
    val modes = (Scan.optional
     (@{keyword "("} |-- Parse.list1 Parse.xname --| @{keyword ")"}) [])
  in
    Outer_Syntax.local_theory 
    @{command_spec "prepare_code_thms"} 
    "Refinement framework: Prepare theorems for code generation" 
    (modes -- Parse_Spec.xthms1
      >> (fn (modes,raw_thms) => fn lthy => let
        val thms = Attrib.eval_thms lthy raw_thms
      in
        fold (Refine_Automation.prepare_code_thms_cmd modes) thms lthy
      end)
    )
  end
*}

text {* 
  Command: 
    @{text "prepare_code_thms (modes) thm"}
  where the @{text "(mode)"}-part is optional.

  Set up code-equations for recursions in constant defined by @{text "thm"}.
  The optional @{text "modes"} is a comma-separated list of extraction modes.
*}

lemma gen_code_thm_RECT:
  fixes x
  assumes D: "f \<equiv> RECT B"
  assumes M: "mono B"
  shows "f x \<equiv> B f x"
  unfolding D
  apply (subst RECT_unfold)
  by (rule M)

lemma gen_code_thm_REC:
  fixes x
  assumes D: "f \<equiv> REC B"
  assumes M: "mono B"
  shows "f x \<equiv> B f x"
  unfolding D
  apply (subst REC_unfold)
  by (rule M)

setup {*
  Refine_Automation.add_extraction "nres" {
    pattern = term_of @{cpat "REC _"},
    gen_thm = @{thm gen_code_thm_REC},
    gen_tac = Refine_Misc.mono_prover_tac
  }
  #> 
  Refine_Automation.add_extraction "nres" {
    pattern = term_of @{cpat "RECT _"},
    gen_thm = @{thm gen_code_thm_RECT},
    gen_tac = Refine_Misc.mono_prover_tac
  }
*}

text {*
  Method @{text "vc_solve (no_pre) clasimp_modifiers
    rec (add/del): ... solve (add/del): ..."}
  Named theorems @{text vcs_rec} and @{text vcs_solve}.

  This method is specialized to
  solve verification conditions. It first clarsimps all goals, then
  it tries to apply a set of safe introduction rules (@{text "vcs_rec"}, @{text "rec add"}).
  Finally, it applies introduction rules (@{text "vcs_solve"}, @{text "solve add"}) and tries
  to discharge all emerging subgoals by auto. If this does not succeed, it
  backtracks over the application of the solve-rule.
*}

method_setup vc_solve = 
  {* Scan.lift (Args.mode "nopre") 
      --| Method.sections Refine_Automation.vc_solve_modifiers >>
  (fn (nopre) => fn ctxt => SIMPLE_METHOD (
    CHANGED (ALLGOALS (Refine_Automation.vc_solve_tac ctxt nopre))
  )) *} "Try to solve verification conditions"


end
