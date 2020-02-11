(*
 * Core lifting algorithm
 *)

open Util
open Constr
open Environ
open Zooming
open Lifting
open Debruijn
open Utilities
open Indexing
open Hypotheses
open Names
open Caching
open Declarations
open Specialization
open Inference
open Typehofs
open Indutils
open Apputils
open Reducers
open Envutils
open Funutils
open Constutils
open Stateutils
open Hofs
open Desugarprod
open Ornerrors
open Promotion
open Liftconfig
open Liftrules
open Sigmautils

(*
 * The top-level lifting algorithm
 *)

(* --- Convenient shorthand --- *)

let dest_sigT_type = on_red_type_default (ignore_env dest_sigT)

(* --- Lifting the induction principle --- *)

(*
 * This implements the rules for lifting the eliminator.
 * The rules here look a bit different because of de Bruijn indices,
 * some optimizations, and non-primitive eliminators.
 *)

(*
 * In LIFT-ELIM, this is what gets a or the projection of b
 * The one difference is that there are extra arguments because of
 * non-primitve eliminators, and also parameters
 *)
let lift_elim_args env sigma c npms args =
  let l = get_lifting c in
  match l.orn.kind with
  | Algebraic (indexer, off) ->
     let arg = map_backward last_arg l (last args) in
     let sigma, typ_args = non_index_typ_args off env sigma arg in
     let sigma, lifted_arg = lift env l arg typ_args sigma in
     let value_off = List.length args - 1 in
     let orn = { l.orn with kind = Algebraic (indexer, off - npms) } in
     let l = { l with orn } in (* no parameters here *)
     if l.is_fwd then
       (* project and index *)
       let b_sig = lifted_arg in
       let b_sig_typ = dest_sigT_type env sigma b_sig in
       let i_b = project_index b_sig_typ b_sig in
       let b = project_value b_sig_typ b_sig in
       sigma, index l i_b (reindex value_off b args)
     else
       (* don't project and deindex *)
       let a = lifted_arg in
       sigma, deindex l (reindex value_off a args)
  | CurryRecord ->
     let arg = last args in
     let sigma, typ_args = type_from_args c env arg sigma in
     let sigma, lifted_arg = lift env l arg typ_args sigma in
     sigma, [lifted_arg]

(*
 * MOTIVE
 *)
let lift_motive env sigma c npms parameterized_elim p =
  let l = get_lifting c in
  let sigma, parameterized_elim_type = reduce_type env sigma parameterized_elim in
  let (_, p_to_typ, _) = destProd parameterized_elim_type in
  let env_p_to = zoom_env zoom_product_type env p_to_typ in
  let nargs = new_rels2 env_p_to env in
  let p = shift_by nargs p in
  let args = mk_n_rels nargs in
  let sigma, arg =
    map_backward
      (fun (sigma, t) -> pack env_p_to (flip_dir l) t sigma)
      (flip_dir l)
      (sigma, last args)
  in
  let sigma, typ_args = type_from_args (reverse c) env_p_to arg sigma in
  let sigma, lifted_arg = lift env_p_to (flip_dir l) arg typ_args sigma in
  let args =
    match l.orn.kind with
    | Algebraic (indexer, off) ->
       let value_off = nargs - 1 in
       let orn = { l.orn with kind = Algebraic (indexer, off - npms) } in
       let l = { l with orn } in (* no parameters here *)
       if l.is_fwd then
         (* forget packed b to a, don't project, and deindex *)
         let a = lifted_arg in
         deindex l (reindex value_off a args)
       else
         (* promote a to packed b, project, and index *)
         let b_sig = lifted_arg in
         let b_sig_typ = dest_sigT_type env_p_to sigma b_sig in
         let i_b = project_index b_sig_typ b_sig in
         let b = project_value b_sig_typ b_sig in
         index l i_b (reindex value_off b args)
    | CurryRecord ->
       [lifted_arg]
  in
  let p_app = reduce_stateless reduce_term env_p_to sigma (mkAppl (p, args)) in
  sigma, reconstruct_lambda_n env_p_to p_app (nb_rel env)

(*
 * The argument rules for lifting eliminator cases in the promotion direction.
 * Note that since we save arguments and reduce at the end, this looks a bit
 * different, and the call to new is no longer necessary.
 *)
let promote_case_args env sigma c args =
  let l = get_lifting c in
  match l.orn.kind with
  | Algebraic (_, off) ->
     let b_typ = get_elim_type (reverse c) in
     let rec lift_args sigma args i_b =
       match args with
       | n :: tl ->
          if equal n i_b then
            (* DROP-INDEX *)
            Util.on_snd
              (fun tl -> shift n :: tl)
              (lift_args sigma (shift_all tl) i_b)
          else
            let sigma, t = reduce_type env sigma n in
            if is_or_applies b_typ t then
              (* FORGET-ARG *)
              let sigma, n = pack env (flip_dir l) n sigma in
              let sigma, typ_args = type_from_args (reverse c) env n sigma in
              let sigma, a = lift env (flip_dir l) n typ_args sigma in
              Util.on_snd
                (fun tl -> a :: tl)
                (lift_args sigma tl (get_arg off t))
            else
              (* ARG *)
              Util.on_snd (fun tl -> n :: tl) (lift_args sigma tl i_b)
       | _ ->
          (* CONCL in inductive case *)
          sigma, []
     in Util.on_snd List.rev (lift_args sigma (List.rev args) (mkRel 0))
  | _ -> raise NotAlgebraic

(*
 * The argument rules for lifting eliminator cases in the forgetful direction.
 * Note that since we save arguments and reduce at the end, this looks a bit
 * different, and the call to new is no longer necessary.
 *)
let forget_case_args env_c_b env sigma c args =
  let l = get_lifting c in
  match l.orn.kind with
  | Algebraic (_, off)->
     let b_typ = get_elim_type c in
     let rec lift_args sigma args (i_b, proj_i_b) =
       match args with
       | n :: tl ->
          if equal n i_b then
            (* ADD-INDEX *)
            Util.on_snd
              (fun tl -> proj_i_b :: tl)
              (lift_args sigma (unshift_all tl) (i_b, proj_i_b))
          else
            let sigma, t = reduce_type env_c_b sigma n in
            if is_or_applies b_typ t then
              (* PROMOTE-ARG *)
              let sigma, typ_args = type_from_args (reverse c) env n sigma in
              let sigma, b_sig = lift env (flip_dir l) n typ_args sigma in
              let b_sig_typ = dest_sigT_type env sigma b_sig in
              let proj_b = project_value b_sig_typ b_sig in
              let proj_i_b = project_index b_sig_typ b_sig in
              Util.on_snd
                (fun tl -> proj_b :: tl)
                (lift_args sigma tl (get_arg off t, proj_i_b))
            else
              (* ARG *)
              Util.on_snd
                (fun tl -> n :: tl)
                (lift_args sigma tl (i_b, proj_i_b))
       | _ ->
          (* CONCL in inductive case *)
          sigma, []
     in Util.on_snd List.rev (lift_args sigma (List.rev args) (mkRel 0, mkRel 0))
  | _ ->
     raise NotAlgebraic

(*
 * Lift the arguments of a case of an eliminator
 *)
let lift_case_args c env_c_b env_c to_c_typ npms nargs sigma =
  let l = get_lifting c in
  let to_typ = get_elim_type (reverse c) in
  match l.orn.kind with
  | Algebraic _ ->
     let nihs = num_ihs env_c sigma to_typ to_c_typ in
     let nargs_lifted = if l.is_fwd then nargs - nihs else nargs + nihs in
     let args = mk_n_rels nargs_lifted in
     if l.is_fwd then
       promote_case_args env_c sigma c args
     else
       forget_case_args env_c_b env_c sigma c args
  | CurryRecord ->
     let args = mk_n_rels nargs in
     if l.is_fwd then
       let c_args, b_args = take_split 2 args in
       let sigma, args_tl = prod_projections_rec env_c (List.hd (List.tl c_args)) sigma in
       sigma, List.append (List.hd c_args :: args_tl) b_args
     else
       let (ind, _) = destInd to_typ in
       let sigma, c_typ = reduce_type env_c sigma (mkConstruct (ind, 1)) in
       let nargs_lifted = arity c_typ in
       let c_args, b_args = take_split (nargs_lifted - npms) args in
       let sigma, arg_pair = pack_pair_rec env_c (List.tl c_args) sigma in
       sigma, List.append [List.hd c_args; arg_pair] b_args

(*
 * CASE
 *)
let lift_case env c npms c_elim constr sigma =
  let sigma, c_elim_type = reduce_type env sigma c_elim in
  let (_, to_c_typ, _) = destProd c_elim_type in
  let env_c = zoom_env zoom_product_type env to_c_typ in
  let nargs = new_rels2 env_c env in
  if nargs = 0 then
    (* no need to get arguments *)
    sigma, constr
  else
    (* get arguments *)
    let sigma, c_eta = expand_eta env sigma constr in
    let c_eta = shift_by nargs c_eta in
    let (env_c_b, c_body) = zoom_lambda_term env_c c_eta in
    let (c_f, _) = destApp c_body in
    let sigma, args = lift_case_args c env_c_b env_c (shift_by nargs to_c_typ) npms nargs sigma in
    let f = unshift_by (new_rels2 env_c_b env_c) c_f in
    let body = reduce_stateless reduce_term env_c sigma (mkAppl (f, args)) in
    sigma, reconstruct_lambda_n env_c body (nb_rel env)

(* Lift cases *)
let lift_cases env c npms p_elim cs =
  bind
    (fold_left_state
       (fun (c_elim, cs) constr sigma ->
         let sigma, constr = lift_case env c npms c_elim constr sigma in
         let c_elim = mkAppl (c_elim, [constr]) in
         sigma, (c_elim, snoc constr cs))
       (p_elim, [])
       cs)
    (fun (_, cs) -> ret cs)

(*
 * LIFT-ELIM steps before recursing into the rest of the algorithm
 * This takes the lifted parameters as arguments, since they are computed
 * when determining whether this rule is a match
 *)
let lift_elim env sigma c trm_app pms =
  let to_typ = get_elim_type (reverse c) in
  let elim = type_eliminator env (fst (destInd to_typ)) in
  let npms = List.length pms in
  let param_elim = mkAppl (elim, pms) in
  let sigma, p = lift_motive env sigma c npms param_elim trm_app.p in
  let p_elim = mkAppl (param_elim, [p]) in
  let sigma, cs = lift_cases env c npms p_elim trm_app.cs sigma in
  let sigma, final_args = lift_elim_args env sigma c npms trm_app.final_args in
  sigma, apply_eliminator { elim; pms; p; cs; final_args }

(*
 * REPACK
 *
 * This is to deal with non-primitive projections
 *)
let repack c env lifted typ sigma =
  match (get_lifting c).orn.kind with
  | Algebraic _ ->
     let lift_typ = dest_sigT (shift typ) in
     let n = project_index lift_typ (mkRel 1) in
     let b = project_value lift_typ (mkRel 1) in
     let index_type = lift_typ.index_type in
     let packer = lift_typ.packer in
     let e = pack_existT {index_type; packer; index = n; unpacked = b} in
     sigma, mkLetIn (Anonymous, lifted, typ, e)
  | CurryRecord ->
     let f = first_fun typ in
     let args = unfold_args typ in
     let sigma, typ_red = specialize_delta_f env f args sigma in
     sigma, mkLetIn (Anonymous, lifted, typ, eta_prod_rec (mkRel 1) (shift typ_red))

(*
 * Sometimes we must repack because of non-primitive projections.
 * For sigma types, we pack into an existential, and for products, we pack
 * into a pair. It remains to be seen how this generalizes to other types.
 *
 * We are strategic about when we repack in order to avoid slowing down
 * the code too much and producing ugly terms.
 *)
let maybe_repack lift_rec c env trm lifted is_from try_repack sigma =
  if try_repack then
    let sigma_typ, typ = infer_type env sigma trm in
    let typ = reduce_stateless reduce_nf env sigma_typ typ in
    let sigma_typ, is_from_typ = is_from c env typ sigma in
    if is_from_typ then
      let lifted_red = reduce_stateless reduce_nf env sigma lifted in
      let optimize_ignore_repack =
        (* Don't bother repacking when the result would reduce *)
        match (get_lifting c).orn.kind with
        | Algebraic (_, _) ->
           is_or_applies existT lifted_red
        | CurryRecord ->
           is_or_applies pair lifted_red
      in
      if not optimize_ignore_repack then
        let sigma, lifted_typ = lift_rec env sigma_typ c typ in
        repack c env lifted lifted_typ sigma
      else
        sigma, lifted
    else
      sigma, lifted
  else
    sigma, lifted

(* --- Optimization implementations, besides packing --- *)

(*
 * When we see a packed projection, simplify early rather than wait for Coq 
 *)
let lift_simplify_project_packed c env reduce f args lift_rec sigma =
  let sigma, args' = map_rec_args lift_rec env sigma c args in
  let arg' = last (Array.to_list args') in
  let arg'' = reduce_stateless reduce_term env sigma arg' in
  if is_packed c arg'' then
    reduce env sigma arg''
  else
    let sigma, f' = lift_rec env sigma c f in
    (sigma, mkApp (f', args'))
                          
(*
 * Lift applications, possibly being lazy about delta if we can get away with it
 *)
let lift_app_lazy_delta c env f args lift_rec sigma =
  let l = get_lifting c in
  let sigma, f' = lift_rec env sigma c f in
  let sigma, args' = map_rec_args lift_rec env sigma c args in
  if (not (equal f f')) || l.is_fwd || Array.length args = 0 || is_opaque c f then
    let lifted = mkApp (f', args') in
    maybe_repack lift_rec c env (mkApp (f, args)) lifted (fun c env typ sigma -> Util.on_snd Option.has_some (is_from c env typ sigma)) l.is_fwd sigma
  else
    match kind f with
    | Const (c, u) when Option.has_some (inductive_of_elim env (c, u)) ->
       sigma, mkApp (f', args')
    | _ ->
       if not (equal f f') then
         sigma, mkApp (f', args')
       else
         let sigma, app' = specialize_delta_f env f (Array.to_list args) sigma in
         if equal (mkApp (f, args)) app' then
           sigma, mkApp (f', args')
         else
           let sigma, lifted_red = lift_rec env sigma c app' in
           if equal lifted_red app' then
             sigma, mkApp (f', args')
           else
             let sigma, app'' = specialize_delta_f env f' (Array.to_list args') sigma in
             if equal lifted_red app'' then
               sigma, mkApp (f', args')
             else
               sigma, lifted_red

(*
 * Lift constants, possibly being lazy about delta if we can get away with it
 *)
let lift_const_lazy_delta c env (co, u) lift_rec sigma =
  let trm = mkConstU (co, u) in
  let sigma, lifted =
    (try
       if Option.has_some (inductive_of_elim env (co, u)) then
         sigma, trm
       else
         let def = lookup_definition env (mkConstU (co, u)) in
         let sigma, try_lifted = lift_rec env sigma c def in
         if equal def try_lifted then
           sigma, trm
         else
           reduce_term env sigma try_lifted
     with _ ->
       (* axiom *)
       sigma, trm)
  in smart_cache c trm lifted; (sigma, lifted)

(*
 * Lift constructors when we can do something faster than lifting all of
 * the arguments
 *)
let lift_smart_lift_constr c env lifted_constr args lift_rec sigma =
  let sigma, constr_app = reduce_term env sigma (mkAppl (lifted_constr, args)) in
  match (get_lifting c).orn.kind with
  | Algebraic (_, _) ->
     let lifted_inner = last_arg constr_app in
     let (f', args') = destApp lifted_inner in
     let sigma, args'' = map_rec_args lift_rec env sigma c args' in
     let b = mkApp (f', args'') in
     let ex = dest_existT constr_app in
     let sigma, n = lift_rec env sigma c ex.index in
     let sigma, packer = lift_rec env sigma c ex.packer in
     (sigma, pack_existT { ex with packer; index = n; unpacked = b })
  | CurryRecord ->
     let open Produtils in
     let pair = dest_pair constr_app in
     let sigma, typ1 = lift_rec env sigma c pair.typ1 in
     let sigma, typ2 = lift_rec env sigma c pair.typ2 in
     let sigma, trm1 = lift_rec env sigma c pair.trm1 in
     let sigma, trm2 = lift_rec env sigma c pair.trm2 in
     (sigma, apply_pair {typ1; typ2; trm1; trm2})
             
(* --- Core algorithm --- *)
    
(*
 * Core lifting algorithm.
 * A few extra rules to deal with real Coq terms as opposed to CIC,
 * including caching.
 *)
let lift_core env c trm sigma =
  let l = get_lifting c in
  let (a_typ, _) = get_types c in
  let sigma, a_typ_eta = expand_eta env sigma a_typ in
  let a_arity = arity a_typ_eta in
  let rec lift_rec en sigma c tr : types state =
    let sigma, lift_rule = determine_lift_rule c en tr sigma in
    match lift_rule with
    | Optimization (GlobalCaching lifted) | Optimization (LocalCaching lifted) ->
       sigma, lifted
    | Optimization OpaqueConstant ->
       sigma, tr
    | Optimization (LazyEta tr_eta) ->
       lift_rec en sigma c tr_eta
    | Section | Retraction | Internalize ->
       lift_rec en sigma c (last_arg tr)
    | Coherence (to_proj, p, args) ->
       let sigma, projected = reduce_term en sigma (mkAppl (p, snoc to_proj args)) in
       lift_rec en sigma c projected
    | Equivalence args ->
       let (_, b_typ) = get_types c in
       let sigma, lifted_args = map_rec_args lift_rec en sigma c (Array.of_list args) in
       if l.is_fwd then
         if Array.length lifted_args = 0 then
           sigma, b_typ
         else
           reduce_term en sigma (mkApp (b_typ, lifted_args))
       else
         if Array.length lifted_args = 0 then
           sigma, a_typ
         else
           (sigma, mkApp (a_typ, lifted_args))
    | Optimization (SmartLiftConstr (lifted_constr, args)) ->
       let sigma, lifted = lift_smart_lift_constr c en lifted_constr args lift_rec sigma in
       sigma, lifted
    | LiftConstr (lifted_constr, args) ->
       let sigma, constr_app = reduce_term en sigma (mkAppl (lifted_constr, args)) in
       if List.length args > 0 then
         let (f', args') = destApp constr_app in
         let sigma, args'' = map_rec_args lift_rec en sigma c args' in
         sigma, mkApp (f', args'')
       else
         sigma, constr_app
    | LiftPack ->
       if l.is_fwd then
         (* pack *)
         maybe_repack lift_rec c en tr tr (fun _ _ _ -> ret true) true sigma
       else
         (* unpack (when not covered by constructor rule) *)
         lift_rec en sigma c (dest_existT tr).unpacked
    | Optimization (SimplifyProjectPacked (reduce, (f, args))) ->
       lift_simplify_project_packed c en reduce f args lift_rec sigma
    | LiftElim (tr_elim, lifted_pms) ->
       let nargs =
         match l.orn.kind with
         | Algebraic (_, _) ->
            a_arity - (List.length tr_elim.pms) + 1
         | CurryRecord ->
            1
       in
       let (final_args, post_args) = take_split nargs tr_elim.final_args in
       let sigma, tr' = lift_elim en sigma c { tr_elim with final_args } lifted_pms in
       let sigma, tr'' = lift_rec en sigma c tr' in
       let sigma, post_args' = map_rec_args lift_rec en sigma c (Array.of_list post_args) in
       maybe_repack lift_rec c en tr (mkApp (tr'', post_args')) (fun c env typ sigma -> Util.on_snd Option.has_some (is_from c env typ sigma)) l.is_fwd sigma
    | Optimization (AppLazyDelta (f, args)) ->
       lift_app_lazy_delta c en f args lift_rec sigma
    | Optimization (ConstLazyDelta (co, u)) ->
       lift_const_lazy_delta c en (co, u) lift_rec sigma
    | CIC k ->
       (match k with
        | Cast (ca, k, t) ->
           (* CAST *)
           let sigma, ca' = lift_rec en sigma c ca in
           let sigma, t' = lift_rec en sigma c t in
           (sigma, mkCast (ca', k, t'))
        | Prod (n, t, b) ->
           (* PROD *)
           let sigma, t' = lift_rec en sigma c t in
           let en_b = push_local (n, t) en in
           let sigma, b' = lift_rec en_b sigma (zoom c) b in
           (sigma, mkProd (n, t', b'))
        | Lambda (n, t, b) ->
           (* LAMBDA *)
           let sigma, t' = lift_rec en sigma c t in
           let en_b = push_local (n, t) en in
           let sigma, b' = lift_rec en_b sigma (zoom c) b in
           (sigma, mkLambda (n, t', b'))
        | LetIn (n, trm, typ, e) ->
           (* LETIN *)
           if l.is_fwd then
             let sigma, trm' = lift_rec en sigma c trm in
             let sigma, typ' = lift_rec en sigma c typ in
             let en_e = push_let_in (n, trm, typ) en in
             let sigma, e' = lift_rec en_e sigma (zoom c) e in
             (sigma, mkLetIn (n, trm', typ', e'))
           else
             (* Needed for #58 until we implement #42 *)
             lift_rec en sigma c (reduce_stateless whd en sigma tr)
        | Case (ci, ct, m, bs) ->
           (* CASE (will not work if this destructs over A; preprocess first) *)
           let sigma, ct' = lift_rec en sigma c ct in
           let sigma, m' = lift_rec en sigma c m in
           let sigma, bs' = map_rec_args lift_rec en sigma c bs in
           (sigma, mkCase (ci, ct', m', bs'))
        | Fix ((is, i), (ns, ts, ds)) ->
           (* FIX (will not work if this destructs over A; preprocess first) *)
           let sigma, ts' = map_rec_args lift_rec en sigma c ts in
           let sigma, ds' = map_rec_args (fun en sigma a trm -> map_rec_env_fix lift_rec zoom en sigma a ns ts trm) en sigma c ds in
           (sigma, mkFix ((is, i), (ns, ts', ds')))
        | CoFix (i, (ns, ts, ds)) ->
           (* COFIX (will not work if this destructs over A; preprocess first) *)
           let sigma, ts' = map_rec_args lift_rec en sigma c ts in
           let sigma, ds' = map_rec_args (fun en sigma a trm -> map_rec_env_fix lift_rec zoom en sigma a ns ts trm) en sigma c ds in
           (sigma, mkCoFix (i, (ns, ts', ds')))
        | Proj (pr, co) ->
           (* PROJ *)
           let sigma, co' = lift_rec en sigma c co in
           (sigma, mkProj (pr, co'))
        | Construct _ ->
           smart_cache c tr tr; (sigma, tr)
        | _ ->
           (sigma, tr))
  in lift_rec env sigma c trm
              
(*
 * Run the core lifting algorithm on a term
 *)
let do_lift_term env sigma (l : lifting) trm opaques =
  let sigma, c = initialize_lift_config env l opaques sigma in
  lift_core env c trm sigma

(*
 * Run the core lifting algorithm on a definition
 *)
let do_lift_defn env sigma (l : lifting) def =
  do_lift_term env sigma l def

(************************************************************************)
(*                           Inductive types                            *)
(************************************************************************)

let define_lifted_eliminator ?(suffix="_sigT") l ind0 ind sort =
  (* Do not lift eliminator into sort `Set` -- unnecessary and error-prone *)
  if not (Sorts.family_equal Sorts.InSet sort) then
    let env = Global.env () in
    let (_, ind_body) as mind_specif = Inductive.lookup_mind_specif env ind in
    let ident =
      let ind_name = ind_body.mind_typename in
      let raw_ident = Indrec.make_elimination_ident ind_name sort in
      Nameops.add_suffix raw_ident suffix
    in
    let elim0 = Indrec.lookup_eliminator ind0 sort in
    let elim = Indrec.lookup_eliminator ind sort in
    let sigma, (eta_term, eta_type) =
      let sigma, term = Evarutil.new_global (Evd.from_env env) elim in
      let sigma, typ = Typing.type_of env sigma term in
      let typ = Reductionops.nf_betaiotazeta env sigma typ in
      let term, typ = EConstr.(to_constr sigma term, to_constr sigma typ) in
      sigma, Depelim.eta_guard_eliminator mind_specif term typ
    in
    let elim' = Universes.constr_of_global (Defutils.define_term ~typ:eta_type ident sigma eta_term true) in
    let elim0 = Universes.constr_of_global elim0 in
    save_lifting (lift_to l, lift_back l, elim0) elim';
    save_lifting (lift_back l, lift_to l, elim') elim0

let declare_inductive_liftings l ind ind' ncons =
  save_lifting (lift_to l, lift_back l, mkInd ind) (mkInd ind');
  save_lifting (lift_back l, lift_to l, mkInd ind') (mkInd ind);
  List.iter2
    (fun o n ->
      save_lifting (lift_to l, lift_back l, o) n;
      save_lifting (lift_back l, lift_to l, n) o)
    (List.init ncons (fun i -> mkConstruct (ind, i + 1)))
    (List.init ncons (fun i -> mkConstruct (ind', i + 1)))

(*
 * Lift the inductive type using sigma-packing.
 *
 * This algorithm assumes that type parameters are left constant and will lift
 * every binding and every term of the base type to the sigma-packed ornamented
 * type. (IND and CONSTR via caching)
 *)
let do_lift_ind env sigma l typename suffix ind ignores =
  let sigma, c = initialize_lift_config env l ignores sigma in
  let (mind_body, ind_body) as mind_specif = Inductive.lookup_mind_specif env ind in
  if is_opaque c (mkInd ind) then
    let _ = Feedback.msg_warning (Pp.str "Ignoring inductive type") in
    ind
  else
    let _ = check_inductive_supported mind_body in
    let env, univs, arity, constypes = open_inductive ~global:true env mind_specif in
    let sigma = Evd.update_sigma_env sigma env in
    let nparam = mind_body.mind_nparams_rec in
    let sigma, arity' = do_lift_term env sigma l arity ignores in
    let sigma, constypes' = map_state (fun trm sigma -> do_lift_term env sigma l trm ignores) constypes sigma in
    let consnames =
      Array.map_to_list (fun id -> Nameops.add_suffix id suffix) ind_body.mind_consnames
    in
    let is_template = is_ind_body_template ind_body in
    let ind' =
      declare_inductive typename consnames is_template univs nparam arity' constypes'
    in
    List.iter (define_lifted_eliminator l ind ind') ind_body.mind_kelim;
    declare_inductive_liftings l ind ind' (List.length constypes);
    ind'