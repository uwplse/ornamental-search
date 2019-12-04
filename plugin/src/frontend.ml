open Constr
open Names
open Globnames
open Lifting
open Caching
open Search
open Lift
open Unpack
open Utilities
open Pp
open Printer
open Coherence
open Equivalence
open Options
open Typehofs
open Constutils
open Nameutils
open Defutils
open Envutils
open Stateutils
open Environ
open Inference

(* --- Commands --- *)

(*
 * Refresh an environment and get the corresponding state after defining
 * a term
 *)
let refresh_env () : env state =
  let env = Global.env () in
  Evd.from_env env, env
       
(*
 * If the option is enabled, then prove coherence after find_ornament is called.
 * Otherwise, do nothing.
 *)
let maybe_prove_coherence n inv_n idx_n kind : unit =
  if is_search_coh () && Option.has_some idx_n then
    let sigma, env = refresh_env () in
    let (promote, forget) = map_tuple make_constant (n, inv_n) in
    let indexer = Some (make_constant (Option.get idx_n)) in
    let orn = { indexer; promote; forget; kind } in
    let coh, coh_typ = prove_coherence env sigma orn in
    let coh_n = with_suffix n "coh" in
    let _ = define_term ~typ:coh_typ coh_n sigma coh true in
    Feedback.msg_notice (Pp.str (Printf.sprintf "Defined coherence proof %s" (Id.to_string coh_n)))
  else
    ()

(*
 * If the option is enabled, then prove section, retraction, and adjunction after
 * find_ornament is called. Otherwise, do nothing.
 *)
let maybe_prove_equivalence n inv_n : unit =
  let define_proof suffix ?(adjective=suffix) evd term =
    let ident = with_suffix n suffix in
    let const = define_term ident evd term true |> destConstRef in
    Feedback.msg_notice (Pp.str (Printf.sprintf "Defined %s proof %s" adjective (Id.to_string ident)));
    const
  in
  if is_search_equiv () then
    let sigma, env = refresh_env () in
    let (promote, forget) = map_tuple make_constant (n, inv_n) in
    let l = initialize_lifting env sigma promote forget in
    let (section, retraction) = prove_equivalence env sigma l in
    let sect = define_proof "section" sigma section in
    let retr0 = define_proof "retraction" sigma retraction in
    let pre_adj = { orn = l; sect; retr0 } in
    let _ =
      let sigma, env = refresh_env () in
      let (sigma, retraction_adj) = adjointify_retraction env pre_adj sigma in
      define_proof "retraction_adjoint" sigma retraction_adj ~adjective:"adjoint retraction"
    in
    let _ =
      let sigma, env = refresh_env () in
      let (sigma, adjunction) = prove_adjunction env pre_adj sigma in
      define_proof "adjunction" sigma adjunction
    in ()
  else
    ()

(*
 * Identify an algebraic ornament between two types
 * Define the components of the corresponding equivalence
 * (Don't prove section and retraction)
 *)
let find_ornament n_o d_old d_new =
  let (sigma, env) = Pfedit.get_current_context () in
  let sigma, def_o = intern env sigma d_old in
  let sigma, def_n = intern env sigma d_new in
  let trm_o = unwrap_definition env def_o in
  let trm_n = unwrap_definition env def_n in
  let trm_o = if isInd trm_o then trm_o else def_o in (* TODO explain *)
  let trm_n = if isInd trm_n then trm_n else def_n in (* TODO explain *)
  let n, inv_n, idx_n =
    match map_tuple kind (trm_o, trm_n) with
    | Ind ((m_o, _), _), Ind ((m_n, _), _) ->
       let (_, _, lab_o) = KerName.repr (MutInd.canonical m_o) in
       let (_, _, lab_n) = KerName.repr (MutInd.canonical m_n) in
       let name_o = Label.to_id lab_o in
       let name_n = Label.to_string lab_n in
       let auto_n = with_suffix (with_suffix name_o "to") name_n in
       let n = Option.default auto_n n_o in
       let idx_n = with_suffix n "index" in
       let inv_n = with_suffix n "inv" in
       n, inv_n, Some idx_n
    |_ ->
      if isInd trm_o || isInd trm_n then
        (* TODO imperfect logic on delta *)
        let ind, non_ind = if isInd trm_o then (trm_o, trm_n) else (trm_n, trm_o) in
        let ((m, _), _) = destInd ind in
        let (_, _, lab) = KerName.repr (MutInd.canonical m) in
        let name = Label.to_id lab in
        let auto_n = with_suffix name "curry" in
        let n = Option.default auto_n n_o in
        let inv_n = with_suffix n "inv" in
        n, inv_n, None
      else      
        CErrors.user_err (str "Change not yet supported")
  in
  let sigma, orn = search_orn env sigma idx_n trm_o trm_n in
  (match orn.kind with
   | Algebraic ->
      let idx_n = Option.get idx_n in
      let indexer = Option.get orn.indexer in
      let _ = define_term idx_n sigma indexer true in
      Feedback.msg_notice (str (Printf.sprintf "Defined indexing function %s." (Id.to_string idx_n)))
   | _ ->
      ());
  let promote = define_term n sigma orn.promote true in
  Feedback.msg_notice (str (Printf.sprintf "Defined promotion %s." (Id.to_string n)));
  let inv_n = with_suffix n "inv" in
  let forget = define_term inv_n sigma orn.forget true in
  Feedback.msg_notice (str (Printf.sprintf "Defined forgetful function %s." (Id.to_string inv_n)));
  maybe_prove_coherence n inv_n idx_n orn.kind;
  maybe_prove_equivalence n inv_n;
  (try
     let trm_o = if isInd trm_o then trm_o else def_o in
     let trm_n = if isInd trm_n then trm_n else def_n in
     let promote, forget = map_tuple Universes.constr_of_global (promote, forget) in
     save_ornament (trm_o, trm_n) (promote, forget, orn.kind)
   with _ ->
     Feedback.msg_warning (str "Failed to cache ornamental promotion."))  

(*
 * Lift a definition according to a lifting configuration, defining the lifted
 * definition and declaring it as a lifting of the original definition.
 *)
let lift_definition_by_ornament env sigma n l c_old ignores =
  let sigma, lifted = do_lift_defn env sigma l c_old ignores in
  ignore
    (if is_lift_type () then
       (* Lift the type as well *)
       let sigma, typ = infer_type env sigma c_old in
       let sigma, lifted_typ = do_lift_defn env sigma l typ ignores in
       define_term n sigma lifted true ~typ:lifted_typ
     else
       (* Let Coq infer the type *)
       define_term n sigma lifted true);
  try
    let c_new = mkConst (Constant.make1 (Lib.make_kn n)) in
    save_lifting (l.orn.promote, l.orn.forget, c_old) c_new;
    save_lifting (l.orn.promote, l.orn.forget, c_new) c_old
  with _ ->
    Feedback.msg_warning (Pp.str "Failed to cache lifting.")

(*
 * Lift an inductive type according to a lifting configuration, defining the
 * new lifted version and declaring type-to-type, constructor-to-constructor,
 * and eliminator-to-eliminator liftings.
 *)
let lift_inductive_by_ornament env sigma n s l c_old ignores =
  let ind, _ = destInd c_old in
  let ind' = do_lift_ind env sigma l n s ind ignores in
  let env' = Global.env () in
  Feedback.msg_notice (str "Defined lifted inductive type " ++ pr_inductive env' ind')
                      
(*
 * Lift the supplied definition or inductive type along the supplied ornament
 * Define the lifted version
 *)
let lift_by_ornament ?(suffix=false) ?(ignores=[]) n d_orn d_orn_inv d_old =
  let (sigma, env) = Pfedit.get_current_context () in
  let sigma, ignores = map_state (fun t sigma -> intern env sigma t) ignores sigma in
  let sigma, c_orn = intern env sigma d_orn in
  let sigma, c_orn_inv = intern env sigma d_orn_inv in
  let sigma, c_old = intern env sigma d_old in
  let n_new = if suffix then suffix_term_name c_old n else n in
  let s = if suffix then Id.to_string n else "_" ^ Id.to_string n in
  let u_o, u_n = map_tuple (unwrap_definition env) (c_orn, c_orn_inv) in
  let orn_not_supplied = isInd u_o || isInd u_n in
  let (o, n) = (* TODO explain/move... deals with different args & curry vs. normal & caching *)
    (* TODO def logic won't always be good here, really want to delta until _almost_ the end but then stop, for curry thtat is *)
    if orn_not_supplied then
      let u_o = if isInd u_o then u_o else c_orn in
      let u_n = if isInd u_n then u_n else c_orn_inv in
      u_o, u_n
    else
      c_orn, c_orn_inv
  in
  let sigma, env =
    if orn_not_supplied then
      let orn_opt = lookup_ornament (o, n) in
      if not (Option.has_some orn_opt) then
        (* The user never ran Find ornament *)
        let _ = Feedback.msg_notice (str "Searching for ornament first") in
        let _ = find_ornament None d_orn d_orn_inv in
        refresh_env ()
      else
        (* The ornament is cached *)
        sigma, env
    else
      (* The ornament is provided *)
      sigma, env
  in
  let l = initialize_lifting env sigma o n in
  let u_old = unwrap_definition env c_old in
  if isInd u_old then
    let from_typ = fst (on_red_type_default (fun _ _ -> ind_of_promotion_type) env sigma l.orn.promote) in
    if not (equal u_old from_typ) then
      lift_inductive_by_ornament env sigma n_new s l c_old ignores
    else
      lift_definition_by_ornament env sigma n_new l c_old ignores
  else
    lift_definition_by_ornament env sigma n_new l c_old ignores

(*
 * Unpack sigma types in the functional signature of a constant.
 *
 * This transformation assumes that the input constant was generated by
 * ornamental lifting.
 *)
let do_unpack_constant ident const_ref =
  let env = Global.env () in
  let sigma = ref (Evd.from_env env) in
  let term =
    qualid_of_reference const_ref |> Nametab.locate_constant |>
    unpack_constant env sigma
  in
  ignore (define_term ident !sigma term true)
