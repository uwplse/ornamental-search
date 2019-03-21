(*
 * Searching for ornamental promotions between inductive types.
 * This implements the automation from 5.1.1.
 * Some of the useful dependencies can be found in the differencing component.
 *)

open Names
open Constr
open Environ
open Coqterms
open Utilities
open Debruijn
open Indexing
open Hofs
open Factoring
open Zooming
open Abstraction
open Lifting
open Declarations
open Util
open Differencing

(* --- Finding the new index --- *)

(* 
 * As described in "Finding the New Index" in Section 5.1.1,
 * search starts by identifying the new index and offset.
 * The bulk of this is in the differencing component.
 *
 * The offset oracle
 *)

(* Find the new index offset and type *)
let find_new_index env_pms a b =
  let (a_t, b_t) = map_tuple fst (map_tuple destInd (fst a, fst b)) in
  let idx_op = new_index_type_simple env_pms a_t b_t in
  if Option.has_some idx_op then
    Option.get idx_op
  else
    let (elim_t_a, elim_t_b) = map_tuple snd (a, b) in
    new_index_type env_pms elim_t_a elim_t_b

(* --- Finding the indexer --- *)

(*
 * As described in the paragraph "Searching for the Indexer" in Section
 * 5.1.1, once the algorithm has the index offset and type, it then
 * searches for the indexer function. It does this by
 * traversing the types of the eliminators in parallel and forming
 * the function as it goes, substituting in the appropriate motive.
 *)            

(*
 * The new oracle with an optimization.
 *
 * The gist is that any new hypothesis in a constructor that has a different
 * type from the corresponding hypothesis in the old constructor definitely
 * computes a new index, assuming an indexing ornamental relationship
 * and no other changes. So if we find one of those we just assume it's an
 * index. But this does not capture every kind of index, so if we can't
 * make that assumption, then we need to do an extra check.
 *
 * An example might be if an inductive type already has an index of type nat,
 * and then we add a new index of type nat next to it. We then need to figure
 * out which index is the new one, and a naive (but efficient) algorithm may
 * ignore the correct index. This lets us only check that condition
 * in those situations, and otherwise just look for obvious indices by
 * comparing hypotheses.
 *)
let optimized_is_new env off p a b =
  let (a_t, elim_a) = a in
  let (b_t, elim_b) = b in
  let (_, t_a, b_a) = destProd elim_a in
  let (_, t_b, b_b) = destProd elim_b in
  let optimize_types = not (same_mod_indexing env p (a_t, t_a) (b_t, t_b)) in
  let optimize_arity = (arity b_a = arity b_b) in
  if optimize_types then
    true
  else if optimize_arity then
    false
  else
    (* call is_new *)
    computes_ih_index off (shift p) (mkRel 1) b_b

(*
 * Get a single case for the indexer, given:
 * 1. index_i, the location of the new index in the motive
 * 2. index_t, the type of the new index in the motive
 * 3. o, the old environment, inductive type, and constructor
 * 4. n, the new environment, inductive type, and constructor
 *
 * Eventually, it would be good to make this logic less ad-hoc,
 * though the terms we are looking at here are type signatures of
 * induction principles, and so should be very predictable.
 *)
let index_case env off p a b : types =
  let rec diff_case p p_a_b subs e a b =
    let (a_t, c_a) = a in
    let (b_t, c_b) = b in
    match map_tuple kind (c_a, c_b) with
    | (App (_, _), App (_, _)) ->
       (* INDEX-CONCLUSION *)
       List.fold_right all_eq_substs subs (get_arg off c_b)
    | (Prod (n_a, t_a, b_a), Prod (n_b, t_b, b_b)) ->
       let diff_b = diff_case (shift p) (shift p_a_b) in
       if optimized_is_new e off p_a_b a b then
         (* INDEX-HYPOTHESIS *)
         let a = map_tuple shift a in
         let b = (shift b_t, b_b) in
         unshift (diff_b (shift_subs subs) (push_local (n_b, t_b) e) a b)
       else
         let e_b = push_local (n_a, t_a) e in
         let a = (shift a_t, b_a) in
         let b = (shift b_t, b_b) in
         if apply p_a_b t_a t_b then
           (* INDEX-IH *)
           let sub_index = (shift (get_arg off t_b), mkRel 1) in
           let subs_b = sub_index :: shift_subs subs in
           mkLambda (n_a, mkAppl (p, unfold_args t_a), diff_b subs_b e_b a b)
         else
           (* INDEX-PROD *)
           mkLambda (n_a, t_a, diff_b (shift_subs subs) e_b a b)
    | _ ->
       failwith "unexpected case"
  in diff_case p (mkRel 1) [] env a b

(* Get the cases for the indexer *)
let indexer_cases env off p nargs a b : types list =
  let (a_t, elim_t_a) = a in
  let (b_t, elim_t_b) = b in
  match map_tuple kind (elim_t_a, elim_t_b) with
  | (Prod (n_a, p_a_t, b_a), Prod (_, _, b_b)) ->
     let env_p_a = push_local (n_a, p_a_t) env in
     List.map2
       (fun c_a c_b ->
         shift_by
           (nargs - 1)
           (index_case env_p_a off p (a_t, c_a) (b_t, c_b)))
       (take_except nargs (factor_product b_a))
       (take_except (nargs + 1) (factor_product b_b))
  | _ ->
     failwith "not eliminators"

(* Find the motive for the indexer (INDEX-MOTIVE) *)
let index_motive idx npm env_a =
  let (off, ib_t) = idx in
  let ib_t = shift_by (npm + off) ib_t in
  reconstruct_lambda_n env_a ib_t npm

(* Search for an indexing function *)
let find_indexer env_pms idx elim_a a b : types =
  let (a_t, elim_t_a) = a in
  let (b_t, elim_t_b) = b in
  let npm = nb_rel env_pms in
  let (off, _) = idx in
  match kind elim_t_a with
  | Prod (_, p_a_t, _) ->
     let env_a = zoom_env zoom_product_type env_pms p_a_t in
     let nargs = offset env_a npm in
     let p = index_motive idx npm env_a in
     let app =
       apply_eliminator
         {
           elim = elim_a;
           pms = shift_all_by nargs (mk_n_rels npm);
           p = shift_by nargs p;
           cs = indexer_cases env_pms off (shift p) nargs a b;
           final_args = mk_n_rels nargs;
         }
     in reconstruct_lambda env_a app
  | _ ->
     failwith "not an eliminator"

(* --- Finding promote and forget --- *)

(*
 * This implements the "Searching for Promote and Forget" paragraph of
 * Section 5.1.1. It works a lot like searching for the indexer, but
 * it uses a different motive.
 *)

(*
 * Stretch the old motive type to match the new one
 * That is, add indices where they are missing in the old motive
 * For now just supports one index
 *)
let rec stretch_motive_type index_i env o n =
  let (ind_o, p_o) = o in
  let (ind_n, p_n) = n in
  match map_tuple kind (p_o, p_n) with
  | (Prod (n_o, t_o, b_o), Prod (n_n, t_n, b_n)) ->
     let n_b = (shift ind_n, b_n) in
     if index_i = 0 then
       mkProd (n_n, t_n, shift p_o)
     else
       let env_b = push_local (n_o, t_o) env in
       let o_b = (shift ind_o, b_o) in
       mkProd (n_o, t_o, stretch_motive_type (index_i - 1) env_b o_b n_b)
  | _ ->
     p_o

(*
 * Stretch the old motive to match the new one at the term level
 *
 * Hilariously, this function is defined as an ornamented
 * version of stretch_motive_type.
 *)
let stretch_motive index_i env o n =
  let (ind_o, p_o) = o in
  let o = (ind_o, lambda_to_prod p_o) in
  prod_to_lambda (stretch_motive_type index_i env o n)

(*
 * Stretch out the old eliminator type to match the new one
 * That is, add indexes to the old one to match new
 *)
let stretch index_i env indexer npm o n is_fwd =
  let (a, b) = map_if reverse (not is_fwd) (o, n) in
  let (a_typ, elim_a_typ) = a in
  let (b_typ, elim_b_typ) = b in
  let (n_exp, p_a_typ, b_a) = destProd elim_a_typ in
  let (_, p_b_typ, _) = destProd elim_b_typ in
  let p_exp = stretch_motive_type index_i env (a_typ, p_a_typ) (b_typ, p_b_typ) in
  let b_exp =
    map_term_if
      (fun (p, _) t -> applies p t)
      (fun (p, pms) t ->
        let non_pms = unfold_args t in
        let index = mkAppl (indexer, List.append pms non_pms) in
        mkAppl (p, insert_index index_i index non_pms))
      (fun (p, pms) -> (shift p, shift_all pms))
      (mkRel 1, shift_all (mk_n_rels npm))
      b_a
  in mkProd (n_exp, p_exp, b_exp)

(*
 * Utility function
 * Remove the binding at index i from the environment
 *)
let remove_rel (i : int) (env : env) : env =
  let (env_pop, popped) = lookup_pop i env in
  let push =
    List.mapi
      (fun j rel ->
        let (n, _, t) = CRD.to_tuple rel in
        (n, unshift_local (i - j - 1) 1 t))
      (List.rev (List.tl (List.rev popped)))
  in List.fold_right push_local push env_pop

(*
 * Find the motive that the ornamental promotion or forgetful function proves
 * for an indexing function (PROMOTE-MOTIVE and FORGET-MOTIVE)
 *)
let promote_forget_motive off env t arity npm indexer_opt =
  let args = shift_all (mk_n_rels arity) in
  let concl =
    match indexer_opt with
    | Some indexer ->
       (* PROMOTE-MOTIVE *)
       let indexer = Option.get indexer_opt in
       let index = mkAppl (indexer, snoc (mkRel 1) args) in
       mkAppl (t, insert_index (npm + off) index args)
    | None ->
       (* FORGET-MOTIVE *)
       mkAppl (t, adjust_no_index (npm + off) (shift_all args))
  in reconstruct_lambda_n env concl npm

(*
 * Substitute indexes and IHs in a case of promote or forget 
 *)
let promote_forget_case env off is_fwd p o n : types =
  let directional a b = if is_fwd then a else b in
  let rec sub p p_a_b subs e o n =
    let (ind_o, c_o) = o in
    let (ind_n, c_n) = n in
    match map_tuple kind (c_o, c_n) with
    | (App (f_o, args_o), App (f_n, args_n)) ->
       (* PROMOTE-CONCLUSION / FORGET-CONCLUSION *)
       List.fold_right all_eq_substs subs (last_arg c_n)
    | (Prod (n_o, t_o, b_o), Prod (n_n, t_n, b_n)) ->
       let sub_b = sub (shift p) (shift p_a_b) in
       if optimized_is_new e off p_a_b (directional o n) (directional n o) then
         (* PROMOTE-HYPOTHESIS and FORGET-HYPOTHESIS *)
         let o = (shift ind_o, directional (shift c_o) b_o) in
         let n = (shift ind_n, directional b_n (shift c_n)) in
         directional
           unshift
           (fun b -> mkLambda (n_o, t_o, b))
           (sub_b (shift_subs subs) (push_local (n_n, t_n) e) o n)
       else
         let e_b = push_local (n_o, t_o) e in
         let o = (shift ind_o, b_o) in
         let n = (shift ind_n, b_n) in
         if apply p_a_b t_o t_n then
           (* PROMOTE-IH / FORGET-IH *)
           let ib_sub = map_tuple shift (map_tuple (get_arg off) (t_n, t_o)) in
           let ih_sub = (shift (last_arg t_n), mkRel 1) in
           let subs_b = List.append [ib_sub; ih_sub] (shift_subs subs) in
           mkLambda (n_o, mkAppl (p, unfold_args t_o), sub_b subs_b e_b o n)
         else
           (* PROMOTE-PROD / FORGET-PROD *)
           mkLambda (n_o, t_o, sub_b (shift_subs subs) e_b o n)
    | _ ->
       failwith "unexpected case substituting index"
  in sub p (mkRel 1) [] env o n

(*
 * Get the cases for the ornamental promotion/forgetful function. 
 *
 * For each case, this currently works in the following way:
 * 1. If it's forwards, then adjust the motive to have the index
 * 2. Substitute in the motive, ih, & indices (or lack thereof, if backwards)
 *
 * Eventually, we might want to think of this as (or rewrite this to)
 * abstracting the indexed type to take an indexing function, then
 * deriving the result through specialization.
 *)
let promote_forget_cases env off is_fwd orn_p nargs o n : types list =
  let directional a b = if is_fwd then a else b in
  let (o_t, elim_t_o) = o in
  let (n_t, elim_t_n) = n in
  match map_tuple kind (elim_t_o, elim_t_n) with
  | (Prod (n_o, p_o_t, b_o), Prod (_, p_n_t, b_n)) ->
     let env_p_o = push_local (n_o, p_o_t) env in
     let adjust p = shift (stretch_motive off env (o_t, p) (n_t, p_n_t)) in
     let p = map_if adjust is_fwd (unshift orn_p) in
     List.map2
       (fun c_o c_n ->
         shift_by
           (directional (nargs - 1) (nargs - 2))
           (promote_forget_case env off is_fwd p (o_t, c_o) (n_t, c_n)))
       (take_except nargs (factor_product b_o))
       (take_except (directional (nargs + 1) (nargs - 1)) (factor_product b_n))
  | _ ->
     failwith "not an eliminator"

(*
 * Make a packer function for existT/sigT
 *)
let make_packer env evd typ args (index_i, index_typ) is_fwd =
  let sub_index = if is_fwd then insert_index else reindex in
  let packed_args = sub_index index_i (mkRel 1) (shift_all args) in
  let env_abs = push_local (Anonymous, index_typ) env in
  abstract_arg env_abs evd index_i (mkAppl (typ, packed_args))

(*
 * Pack the conclusion of an ornamental promotion
 *)
let pack_conclusion env evd idx f_indexer n unpacked =
  let (ind, arity) = n in
  let off = arity - 1 in
  let index_type = shift_by off (snd idx) in
  let packer = make_packer env evd ind (mk_n_rels off) idx true in
  let index = mkAppl (f_indexer, mk_n_rels arity) in
  (env, pack_existT {index_type; packer; index; unpacked})

(*
 * Pack the hypothesis type into a sigT, and update the environment
 *)
let pack_hypothesis_type env index_type packer (id, unpacked_typ) : env =
  let packer = unshift packer in
  let packed_typ = pack_sigT { index_type ; packer } in
  push_local (id, packed_typ) (pop_rel_context 1 env)

(*
 * Apply the packer to the index
 *)
let apply_packer env packer arg =
  reduce_term env (mkAppl (packer, [arg]))

(*
 * Remove the index from the environment, and adjust terms appropriately
 *)
let adjust_to_elim env index_rel packer packed =
  let env_packed = remove_rel (index_rel + 1) env in
  let adjust = unshift_local index_rel 1 in
  (env_packed, adjust packer, adjust packed)

(*
 * Pack the unpacked term to eliminate using the new hypothesis
 *)
let pack_unpacked env packer index_typ index_rel unpacked =
  let sub_typ = all_eq_substs (mkRel (4 - index_rel), mkRel 1) in
  let sub_index = all_eq_substs (mkRel (index_rel + 3), mkRel 2) in
  let adjust trm = shift_local index_rel 1 (shift trm) in
  let typ_body = sub_index (sub_typ (adjust unpacked)) in
  let packer_indexed = apply_packer env (shift packer) (mkRel 1) in
  let index_body = mkLambda (Anonymous, packer_indexed, typ_body) in
  mkLambda (Anonymous, shift index_typ, index_body)

(*
 * Pack the hypothesis of an ornamental forgetful function
 *)
let pack_hypothesis env evd idx o unpacked =
  let (index_i, index_type) = idx in
  let (ind, arity) = o in
  let index_type = shift index_type in
  let (id, _, unpacked_typ) = CRD.to_tuple @@ lookup_rel 1 env in
  let packer = make_packer env evd ind (unfold_args unpacked_typ) idx false in
  let env_push = pack_hypothesis_type env index_type packer (id, unpacked_typ) in
  let index_rel = offset (pop_rel_context 1 env) index_i in
  let unpacked = pack_unpacked env_push packer index_type index_rel unpacked in
  let adjusted = adjust_to_elim env_push index_rel packer unpacked in
  let (env_packed, packer, unpacked) = adjusted in
  let arg = mkRel 1 in
  let arg_typ = on_type dest_sigT env_packed evd arg in
  let index = project_index arg_typ arg in
  let value = project_value arg_typ arg in
  (env_packed, reduce_term env_packed (mkAppl (unpacked, [index; value])))

(*
 * This packs an ornamental promotion to/from an indexed type like Vector A n,
 * with n at index_i, into a sigma type. The theory of this is more elegant,
 * and the types are easier to reason about automatically. However,
 * the other version may be more desirable for users.
 *
 * It is simple to extract the unpacked version from this form;
 * later it might be useful to define both separately.
 * For now we have a metatheoretic guarantee about the indexer we return
 * corresponding to the projection of the sigma type.
 *)
let pack_orn env evd idx f_indexer o n is_fwd unpacked =
  if is_fwd then
    pack_conclusion env evd idx f_indexer n unpacked
  else
    pack_hypothesis env evd idx o unpacked

(* Search for the promotion or forgetful function *)
let find_promote_or_forget env_pms evd idx indexer_n o n is_fwd =
  let directional x y = if is_fwd then x else y in
  let (o_typ, arity_o, elim, elim_o_typ) = o in
  let (n_typ, arity_n, _, elim_n_typ) = n in
  let npm = nb_rel env_pms in
  let (off, idx_t) = idx in
  let f_indexer = make_constant indexer_n in
  let f_indexer_opt = directional (Some f_indexer) None in
  let (_, p_o, _) = destProd elim_o_typ in
  let env_p_o = zoom_env zoom_product_type env_pms p_o in
  let nargs = offset env_p_o npm in
  let (typ, arity) = (n_typ, directional arity_o arity_n) in
  let o = (o_typ, elim_o_typ) in
  let n = (n_typ, elim_n_typ) in
  let elim_a_typ_exp = stretch off env_pms f_indexer npm o n is_fwd in
  let o = (o_typ, directional elim_a_typ_exp elim_o_typ) in
  let n = (n_typ, directional elim_n_typ elim_a_typ_exp) in
  let p = promote_forget_motive off env_p_o typ arity npm f_indexer_opt in
  let adj = directional identity shift in
  let unpacked =
    apply_eliminator
      {
        elim = elim;
        pms = shift_all_by nargs (mk_n_rels npm);
        p = shift_by nargs p;
        cs =
          List.map
            adj
            (promote_forget_cases env_pms off is_fwd (adj (shift p)) nargs o n);
        final_args = mk_n_rels nargs;
      }
  in
  let o = (o_typ, arity_o) in
  let n = (n_typ, arity_n) in
  let idx = (npm + off, idx_t) in
  let packed = pack_orn env_p_o evd idx f_indexer o n is_fwd unpacked in
  reconstruct_lambda (fst packed) (snd packed)

(* Find promote and forget, using a directional flag for abstraction *)
let find_promote_forget env_pms evd idx indexer_n a b =
  twice (find_promote_or_forget env_pms evd idx indexer_n) a b

(* --- Algebraic ornaments --- *)
              
(*
 * Search two inductive types for an algebraic ornament between them
 *)
let search_algebraic env evd npm indexer_n a b =
  let (a_typ, arity_a) = a in
  let (b_typ, arity_b) = b in
  let lookup_elim typ = type_eliminator env (fst (destInd typ)) in
  let elims = map_tuple lookup_elim (a_typ, b_typ) in
  let zoom_elim_typ el = zoom_n_prod env npm (infer_type env evd el) in
  let ((env_pms, el_a_typ), (_, el_b_typ)) = map_tuple zoom_elim_typ elims in
  let a = (a_typ, el_a_typ) in
  let b = (b_typ, el_b_typ) in
  let idx = find_new_index env_pms a b in (* idx = (off, I_B) *)
  let indexer = find_indexer env_pms idx (fst elims) a b in
  let a = (a_typ, arity_a, fst elims, el_a_typ) in
  let b = (b_typ, arity_b, snd elims, el_b_typ) in
  let (promote, forget) = find_promote_forget env_pms evd idx indexer_n a b in
  { indexer; promote; forget }

(* --- Top-level search --- *)

(*
 * Search two inductive types for an ornament between them.
 * This is more general to handle eventual extension with other 
 * kinds of ornaments.
 *)
let search_orn_inductive env evd indexer_id trm_o trm_n : promotion =
  match map_tuple kind (trm_o, trm_n) with
  | (Ind ((i_o, ii_o), u_o), Ind ((i_n, ii_n), u_n)) ->
     let (m_o, m_n) = map_tuple (fun i -> lookup_mind i env) (i_o, i_n) in
     check_inductive_supported m_o;
     check_inductive_supported m_n;
     let (npm_o, npm_n) = map_tuple (fun m -> m.mind_nparams) (m_o, m_n) in
     if not (npm_o = npm_n) then
       (* new parameter *)
       failwith "new parameters are not yet supported"
     else
       let npm = npm_o in
       let (typ_o, typ_n) = map_tuple (type_of_inductive env 0) (m_o, m_n) in
       let (arity_o, arity_n) = map_tuple arity (typ_o, typ_n) in
       if not (arity_o = arity_n) then
         (* new index *)
         let o = (trm_o, arity_o) in
         let n = (trm_n, arity_n) in
         let (a, b) = map_if reverse (arity_n <= arity_o) (o, n) in
         search_algebraic env evd npm indexer_id a b
       else
         failwith "this kind of change is not yet supported"
  | _ ->
     failwith "this kind of change is not yet supported"
