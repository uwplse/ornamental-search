open Constr
open Environ
open Utilities
open Debruijn
open Indexing
open Hofs
open Substitution
open Factoring
open Zooming
open Lifting
open Hypotheses
open Specialization
open Inference
open Typehofs
open Indutils
open Envutils
open Reducers
open Apputils
open Equtils
open Contextutils
open Sigmautils
open Stateutils

(* --- Automatically generated equivalence proofs about search components --- *)

(*
 * The proofs of both section and retraction apply lemmas
 * that show that equalities are preserved in inductive cases.
 * These lemmas are folds over substitutions of recursive arguments, 
 * with refl as identity.
 *
 * To construct these proofs, we first construct the lemmas, then 
 * specialize them to the appropriate arguments.
 *)
              
(*
 * Form the environment with the appropriate hypotheses for the equality lemmas.
 * Take as arguments the original environment, an evar_map, the recursive
 * arguments for the particular case, and a lift config.
 *)
let eq_lemmas_env env sigma recs l =
  List.fold_left
    (fun (sigma, e) r ->
      let r1 = shift_by (new_rels2 e env) r in
      let sigma, r_t = reduce_type e sigma r1 in
      let push_ib =
        map_backward
          (fun (sigma, e) ->
            Util.on_snd
              (fun t -> push_local (Anonymous, t) e)
              (reduce_type e sigma (get_arg l.off r_t)))
          l
      in
      (* push index in backwards direction *)
      let sigma, e_ib = push_ib (sigma, e) in 
      let adj_back = map_backward (reindex_app (reindex l.off (mkRel 1))) l in
      let r_t = adj_back (shift_by (new_rels2 e_ib e) r_t) in
      (* push new rec arg *)
      let e_r = push_local (Anonymous, r_t) e_ib in
      let pack_back = map_backward (fun (sigma, t) -> pack e_r sigma l.off t) l in
      let sigma, r1 = pack_back (sigma, shift_by (new_rels2 e_r e) r1) in
      let sigma, r2 = pack_back (sigma, mkRel 1) in
      let sigma, r_t = reduce_type e_r sigma r1 in
      let r_eq = apply_eq {at_type = r_t; trm1 = r1; trm2 = r2} in
      (* push equality *)
      sigma, push_local (Anonymous, r_eq) e_r)
    (sigma, env)
    recs
  
(*
 * Determine the equality lemmas for each case of an inductive type
 * Take as arguments an environment, an evar_map, the inductive type,
 * and a lift config.
 *)
let eq_lemmas env sigma typ l =
  let ((i, i_index), u) = destInd typ in
  map_state_array
    (fun c_index sigma ->
      let c = mkConstructU (((i, i_index), c_index + 1), u) in
      let sigma, c_exp = expand_eta env sigma c in
      let (env_c_b, c_body) = zoom_lambda_term env c_exp in
      let c_body = reduce_stateless reduce_term env_c_b sigma c_body in
      let c_args = unfold_args c_body in
      let recs = List.filter (on_red_type_default (ignore_env (is_or_applies typ)) env_c_b sigma) c_args in
      let sigma, env_lemma = eq_lemmas_env env_c_b sigma recs l in
      let pack_back = map_backward (fun (sigma, t) -> pack env_lemma sigma l.off t) l in
      let sigma, c_body = pack_back (sigma, shift_by (new_rels2 env_lemma env_c_b) c_body) in
      let sigma, c_body_type = reduce_type env_lemma sigma c_body in
      (* reflexivity proof: the identity case *)
      let refl = apply_eq_refl { typ = c_body_type; trm = c_body } in
      (* fold to recursively substitute each recursive argument *)
      let (body, _, _) =
        List.fold_right
          (fun _ (b, h, c_app) ->
            let h_r = destRel h in
            let (_, _, h_t) = CRD.to_tuple @@ lookup_rel h_r env_lemma in
            let app = dest_eq (shift_by h_r h_t) in
            let at_type = app.at_type in
            let r1 = app.trm1 in
            let r2 = app.trm2 in
            let c_body_b = shift c_body in
            let c_app_b = shift c_app in
            let (abs_c_app, c_app_trans) =
              if l.is_fwd then
                let abs_c_app = all_eq_substs (shift r1, mkRel 1) c_app_b in
                let c_app_trans = all_eq_substs (r1, r2) c_app in
                (abs_c_app, c_app_trans)
              else
                let (r1_ex, r2_ex) = map_tuple dest_existT (r1, r2) in
                let r1_u = r1_ex.unpacked in
                let r2_u = r2_ex.unpacked in
                let r1_ib = r1_ex.index in
                let r2_ib = r2_ex.index in
                let b_sig_typ = dest_sigT (shift at_type) in
                let (ib, u) = projections b_sig_typ (mkRel 1) in
                let abs_c_app_u = all_eq_substs (shift r1_u, u) c_app_b in
                let abs_c_app = all_eq_substs (shift r1_ib, ib) abs_c_app_u in
                let c_app_trans_u = all_eq_substs (r1_u, r2_u) c_app in
                let c_app_trans = all_eq_substs (r1_ib, r2_ib) c_app_trans_u in
                (abs_c_app, c_app_trans)
            in
            let typ_b = shift c_body_type in
            let p_b = { at_type = typ_b; trm1 = c_body_b; trm2 = abs_c_app } in
            let p = mkLambda (Anonymous, at_type, apply_eq p_b) in
            let eq_proof_app = {at_type; p; trm1 = r1; trm2 = r2; h; b} in
            let eq_proof = apply_eq_ind eq_proof_app in
            (eq_proof, shift_by (directional l 2 3) h, c_app_trans))
          recs
          (refl, mkRel 1, c_body)
      in sigma, reconstruct_lambda env_lemma body)
    (Array.mapi
       (fun i _ -> i)
       ((lookup_mind i env).mind_packets.(i_index)).mind_consnames)
    sigma

(*
 * Construct the motive for section/retraction
 *)
let equiv_motive env sigma p_t l =
  let env_motive = zoom_env zoom_product_type env p_t in
  let sigma, trm1 = map_backward (fun (sigma, t) -> pack env_motive sigma l.off t) l (sigma, mkRel 1) in
  let sigma, at_type = reduce_type env_motive sigma trm1 in
  let typ_args = non_index_args l.off env_motive sigma at_type in
  let trm1_lifted = mkAppl (lift_to l, snoc trm1 typ_args) in
  let trm2 = mkAppl (lift_back l, snoc trm1_lifted typ_args) in
  let p_b = apply_eq { at_type; trm1; trm2 } in
  sigma, reconstruct_lambda_n env_motive p_b (nb_rel env)

(*
 * Get a case of the proof of section/retraction
 * Take as arguments an environment, an evar_map, the parameters,
 * the motive of the section/retraction proof, the equality lemma for the case,
 * the type of the eliminator corresponding to the case, and a lifting config.
 *
 * The inner function works by tracking a list of regular hypotheses
 * and new arguments for the equality lemma, then applying them in the body.
 *)
let equiv_case env sigma pms p eq_lemma l c =
  let eq_lemma = mkAppl (eq_lemma, pms) in (* curry eq_lemma with pms *)
  let rec case e depth hypos args c =
    match kind c with
      | App (_, _) ->
         (* conclusion: apply eq lemma and beta-reduce *)
         let all_args = List.rev_append hypos (List.rev args) in
         reduce_stateless reduce_term e sigma (mkAppl (shift_by depth eq_lemma, all_args))
      | Prod (n, t, b) ->
         let case_b = case (push_local (n, t) e) (shift_i depth) in
         let p_rel = shift_by depth (mkRel 1) in
         let h = mkRel 1 in
         if applies p_rel t then
           (* IH *)
           let t = reduce_stateless reduce_term e sigma (mkAppl (shift_by depth p, unfold_args t)) in
           let trm = (dest_eq t).trm2 in
           let args =
             map_directional
               (fun xs -> trm :: xs)
               (fun xs ->
                 let (ib, u) = projections (on_red_type_default (ignore_env dest_sigT) e sigma trm) trm in
                 u :: ib :: xs)
               l
               args
           in mkLambda (n, t, case_b (shift_all hypos) (h :: shift_all args) b)
         else
           (* Product *)
           mkLambda (n, t, case_b (h :: shift_all hypos) (shift_all args) b)
      | _ ->
         failwith "unexpected case"
  in case env 0 [] [] c

(*
 * Get the cases of the proof of section/retraction
 * Take as arguments the environment with the motive type pushed,
 * an evar_map, the parameters, the motive, the equality lemmas,
 * the lifting, and the type of the eliminator body after the motive
 *)
let equiv_cases env sigma pms p lemmas l elim_typ =
  List.mapi
    (fun j -> equiv_case env sigma pms p lemmas.(j) l)
    (take (Array.length lemmas) (factor_product elim_typ))
(*
 * Prove section/retraction
 *)
let equiv_proof env sigma l =
  let to_body = lookup_definition env (lift_to l) in
  let env_to = zoom_env zoom_lambda_term env to_body in
  let sigma, typ_app = reduce_type env_to sigma (mkRel 1) in
  let typ = first_fun (zoom_if_sig_app typ_app) in
  let ((i, i_index), _) = destInd typ in
  let npm = (lookup_mind i env).mind_nparams in
  let nargs = new_rels env_to npm in
  let sigma, lemmas = eq_lemmas env sigma typ l in (* equality lemmas *)
  let env_eq_proof = (* unpack env_to for retraction *)
    map_backward
      (fun env ->
        let b_sig_typ = dest_sigT typ_app in
        let ib_typ = b_sig_typ.index_type in
        let env_ib = push_local (Anonymous, ib_typ) env_to in
        let b_typ = mkAppl (shift b_sig_typ.packer, [mkRel 1]) in
        push_local (Anonymous, b_typ) env_ib)
      l
      env_to
  in
  let elim = type_eliminator env_to (i, i_index) in
  let sigma, elim_typ = infer_type env sigma elim in
  let (env_pms, elim_typ_p) = zoom_n_prod env npm elim_typ in
  let (n, p_t, elim_typ) = destProd elim_typ_p in
  let env_p = push_local (n, p_t) env_pms in
  let sigma, p = Util.on_snd shift (equiv_motive env_pms sigma p_t l) in
  let pms = shift_all (mk_n_rels npm) in
  let cs = equiv_cases env_p sigma pms p lemmas l elim_typ in
  let args = shift_all_by (new_rels2 env_eq_proof env_to) (mk_n_rels nargs) in
  let index_back = map_backward (insert_index (l.off - npm) (mkRel 2)) l in
  let reindex_back = map_backward (reindex nargs (mkRel 1)) l in
  let depth = new_rels2 env_eq_proof env_p in
  let eq_proof =
    apply_eliminator
      {
        elim;
        pms = shift_all_by depth pms;
        p = shift_by depth p;
        cs = shift_all_by depth cs;
        final_args = reindex_back (index_back args);
      }
  in 
  let eq_typ = on_red_type_default (ignore_env dest_eq) env_eq_proof sigma eq_proof in
  let sym_app = apply_eq_sym { eq_typ; eq_proof } in
  let equiv_b =
    map_backward
      (fun unpacked -> (* eliminate sigT for retraction *)
        let env_p = push_local (Anonymous, typ_app) env_to in
        let trm1 = unshift (all_eq_substs (eq_typ.trm1, mkRel 2) eq_typ.trm2) in
        let at_type = shift typ_app in
        let p_b = apply_eq { at_type; trm1; trm2 = mkRel 1 } in
        let p = reconstruct_lambda_n env_p p_b (nb_rel env_to) in
        let to_elim = dest_sigT typ_app in
        elim_sigT { to_elim; packed_type = p; unpacked; arg = mkRel 1 })
      l
      (reconstruct_lambda_n env_eq_proof sym_app (nb_rel env_to))
  in reconstruct_lambda env_to equiv_b (* TODO OK to ignore sigma? *)

(*
 * Prove section and retraction
 *)
let prove_equivalence env sigma = twice_directional (equiv_proof env sigma)
