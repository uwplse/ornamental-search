(*
 * Coq term and environment management
 *)

open Environ
open Term
open Names
open Constrexpr
open Evd
open Utilities
open Declarations
open Univ
       
module CRD = Context.Rel.Declaration

(* --- Constants --- *)

let coq_init_specif =
  ModPath.MPfile
    (DirPath.make (List.map Id.of_string ["Specif"; "Init"; "Coq"]))
                                     
(* sigma types *)
let sigT : types =
  mkInd (MutInd.make1 (KerName.make2 coq_init_specif (Label.make "sigT")), 0)
    
(* Introduction for sigma types *)
let existT : types =
  mkConstruct (fst (destInd sigT), 1)

(* Elimination for sigma types *)
let sigT_rect : types =
  mkConst (Constant.make2 coq_init_specif (Label.make "sigT_rect"))

(* Left projection *)
let projT1 : types =
  mkConst (Constant.make2 coq_init_specif (Label.make "projT1"))

(* Right projection *)
let projT2 : types =
  mkConst (Constant.make2 coq_init_specif (Label.make "projT2"))

(* --- Representations --- *)

(* Intern a term (for now, ignore the resulting evar_map) *)
let intern env evd t : types =
  let (trm, _) = Constrintern.interp_constr env evd t in
  trm

(* Extern a term *)
let extern env evd t : constr_expr =
  Constrextern.extern_constr true env evd t
                             
(* --- Constructing terms --- *)

(* mkApp with a list *)
let mkAppl (f, args) = mkApp (f, Array.of_list args)

(* Recursively turn a product into a function *)
let rec prod_to_lambda trm =
  match kind_of_term trm with
  | Prod (n, t, b) ->
     mkLambda (n, t, prod_to_lambda b)
  | _ ->
     trm

(* Recursively turn a function into a product *)
let rec lambda_to_prod trm =
  match kind_of_term trm with
  | Lambda (n, t, b) ->
     mkProd (n, t, lambda_to_prod b)
  | _ ->
     trm

(* --- Inductive types and their eliminators --- *)

(* Don't support mutually inductive or coinductive types yet *)
let check_inductive_supported mutind_body : unit =
  let ind_bodies = mutind_body.mind_packets in
  if not (Array.length ind_bodies = 1) then
    failwith "mutually inductive types not yet supported"
  else
    if (mutind_body.mind_finite = Decl_kinds.CoFinite) then
      failwith "coinductive types not yet supported"
    else
      ()

(*
 * Check if a constant is an inductive elminator
 * If so, return the inductive type
 *)
let inductive_of_elim (env : env) (pc : pconstant) : mutual_inductive option =
  let (c, u) = pc in
  let kn = Constant.canonical c in
  let (modpath, dirpath, label) = KerName.repr kn in
  let rec try_find_ind is_rev =
    try
      let label_string = Label.to_string label in
      let label_length = String.length label_string in
      let split_index = String.rindex_from label_string (if is_rev then (label_length - 3) else label_length) '_'  in
      let suffix_length = label_length - split_index in
      let suffix = String.sub label_string split_index suffix_length in
      if (suffix = "_ind" || suffix = "_rect" || suffix = "_rec" || suffix = "_ind_r") then
        let ind_label_string = String.sub label_string 0 split_index in
        let ind_label = Label.of_id (Id.of_string_soft ind_label_string) in
        let ind_name = MutInd.make1 (KerName.make modpath dirpath ind_label) in
        lookup_mind ind_name env;
        Some ind_name
      else
        if not is_rev then
          try_find_ind true
        else
          None
    with _ ->
      if not is_rev then
        try_find_ind true
      else
        None
  in try_find_ind false

(*
 * Boolean version of above that doesn't care about the term type
 *)
let is_elim (env : env) (trm : types) =
  isConst trm && Option.has_some (inductive_of_elim env (destConst trm))

(* Get the type of an inductive type *)
let type_of_inductive env index mutind_body : types =
  let ind_bodies = mutind_body.mind_packets in
  let ind_body = Array.get ind_bodies index in
  let univ_context = mutind_body.mind_universes in
  let univ_instance = UContext.instance univ_context in
  let mutind_spec = (mutind_body, ind_body) in
  Inductive.type_of_inductive env (mutind_spec, univ_instance)

(* Lookup the eliminator over the type sort *)
let type_eliminator (env : env) (ind : inductive) =
  Universes.constr_of_global (Indrec.lookup_eliminator ind InType)
                             
(* --- Environments --- *)

(* Return a list of all indexes in env, starting with 1 *)
let all_rel_indexes (env : env) : int list =
  from_one_to (nb_rel env)

(* Push a local binding to an environment *)
let push_local (n, t) = push_rel CRD.(LocalAssum (n, t))

(* Push a let-in definition to an environment *)
let push_let_in (n, e, t) = push_rel CRD.(LocalDef(n, e, t))

(* Lookup a definition *)
let lookup_definition (env : env) (def : types) : types =
  match kind_of_term def with
  | Const (c, u) ->
     let c_body = (lookup_constant c env).const_body in
     (match c_body with
      | Def cs -> Mod_subst.force_constr cs
      | OpaqueDef o -> Opaqueproof.force_proof (Global.opaque_tables ()) o
      | _ -> failwith "an axiom has no definition")
  | Ind _ -> def
  | _ -> failwith "not a definition"

(* Fully lookup a def in env, but return the term if it is not a definition *)
let rec unwrap_definition (env : env) (trm : types) : types =
  try
    unwrap_definition env (lookup_definition env trm)
  with _ ->
    trm

(*
 * Inductive types create bindings that we need to push to the environment
 * This function gets those bindings
 *)
let bindings_for_inductive env mutind_body ind_bodies : CRD.t list =
  Array.to_list
    (Array.mapi
       (fun i ind_body ->
         let name_id = ind_body.mind_typename in
         let typ = type_of_inductive env i mutind_body in
         CRD.LocalAssum (Names.Name name_id, typ))
       ind_bodies)

(*
 * Similarly but for fixpoints
 *)
let bindings_for_fix (names : name array) (typs : types array) : CRD.t list =
  Array.to_list
    (CArray.map2_i
       (fun i name typ -> CRD.LocalAssum (name, Vars.lift i typ))
       names typs)

(* --- Basic questions about terms --- *)

(*
 * Get the arity of a function or function type
 *)
let rec arity p =
  match kind_of_term p with
  | Lambda (_, _, b) ->
     1 + arity b
  | Prod (_, _, b) ->
     1 + arity b
  | _ ->
     0

(* Check whether trm applies f (using eq_constr for equality) *)
let applies (f : types) (trm : types) =
  match kind_of_term trm with
  | App (g, _) ->
     eq_constr f g
  | _ ->
     false

(* Check whether trm is trm' or applies trm', using eq_constr *)
let is_or_applies (trm' : types) (trm : types) : bool =
  applies trm' trm || eq_constr trm' trm

(* --- Convertibility and types --- *)
                                
(* Infer the type of trm in env *)
let infer_type (env : env) (evd : evar_map) (trm : types) : types =
  Typing.unsafe_type_of env evd trm

(* Check whether two terms are convertible, ignoring universe inconsistency *)
let conv_ignoring_univ_inconsistency env evm trm1 trm2 : bool =
  try
    Reductionops.is_conv env evm trm1 trm2
  with _ ->
    match map_tuple kind_of_term (trm1, trm2) with
    | (Sort (Type u1), Sort (Type u2)) -> true
    | _ -> false

(* Checks whether two terms are convertible in env with no evars *)
let convertible (env : env) (trm1 : types) (trm2 : types) : bool =
  conv_ignoring_univ_inconsistency env Evd.empty trm1 trm2

(* --- Zooming and reconstructing --- *)

(* Zoom into a term *)
let rec zoom_n_prod env npm typ : env * types =
  if npm = 0 then
    (env, typ)
  else
    match kind_of_term typ with
    | Prod (n1, t1, b1) ->
       zoom_n_prod (push_local (n1, t1) env) (npm - 1) b1
    | _ ->
       failwith "more parameters expected"

(* Lambda version *)
let zoom_n_lambda env npm trm : env * types =
  let (env, typ) = zoom_n_prod env npm (lambda_to_prod trm) in
  (env, prod_to_lambda typ)

(* Zoom all the way into a lambda term *)
let rec zoom_lambda_term (env : env) (trm : types) : env * types =
  match kind_of_term trm with
  | Lambda (n, t, b) ->
     zoom_lambda_term (push_local (n, t) env) b
  | _ ->
     (env, trm)

(* Zoom all the way into a product type *)
let rec zoom_product_type (env : env) (typ : types) : env * types =
  match kind_of_term typ with
  | Prod (n, t, b) ->
     zoom_product_type (push_local (n, t) env) b
  | _ ->
     (env, typ)

(* Zoom into the environment *)
let zoom_env zoom (env : env) (trm : types) : env =
  fst (zoom env trm)

(* Zoom into the term *)
let zoom_term zoom (env : env) (trm : types) : types =
  snd (zoom env trm)

(* Reconstruct a lambda from an environment, but stop when i are left *)
let rec reconstruct_lambda_n (env : env) (b : types) (i : int) : types =
  if nb_rel env = i then
    b
  else
    let (n, _, t) = CRD.to_tuple @@ lookup_rel 1 env in
    let env' = pop_rel_context 1 env in
    reconstruct_lambda_n env' (mkLambda (n, t, b)) i

(* Reconstruct a lambda from an environment *)
let reconstruct_lambda (env : env) (b : types) : types =
  reconstruct_lambda_n env b 0

(* Reconstruct a product from an environment, but stop when i are left *)
let rec reconstruct_product_n (env : env) (b : types) (i : int) : types =
  if nb_rel env = i then
    b
  else
    let (n, _, t) = CRD.to_tuple @@ lookup_rel 1 env in
    let env' = pop_rel_context 1 env in
    reconstruct_product_n env' (mkProd (n, t, b)) i

(* Reconstruct a product from an environment *)
let reconstruct_product (env : env) (b : types) : types =
  reconstruct_product_n env b 0

(* --- Basic mapping --- *)

(*
 * Recurse on a mapping function with an environment for a fixpoint
 *)
let map_rec_env_fix map_rec d env a (ns : name array) (ts : types array) =
  let fix_bindings = bindings_for_fix ns ts in
  let env_fix = push_rel_context fix_bindings env in
  let n = List.length fix_bindings in
  let d_n = List.fold_left (fun a' _ -> d a') a (range 0 n) in
  map_rec env_fix d_n

(*
 * Map a function over a term in an environment
 * Update the environment as you go
 * Update the argument of type 'a using the a supplied update function
 * Return a new term
 *)
let rec map_term_env f d (env : env) (a : 'a) (trm : types) : types =
  let map_rec = map_term_env f d in
  match kind_of_term trm with
  | Cast (c, k, t) ->
     let c' = map_rec env a c in
     let t' = map_rec env a t in
     mkCast (c', k, t')
  | Prod (n, t, b) ->
     let t' = map_rec env a t in
     let b' = map_rec (push_local (n, t) env) (d a) b in
     mkProd (n, t', b')
  | Lambda (n, t, b) ->
     let t' = map_rec env a t in
     let b' = map_rec (push_local (n, t) env) (d a) b in
     mkLambda (n, t', b')
  | LetIn (n, trm, typ, e) ->
     let trm' = map_rec env a trm in
     let typ' = map_rec env a typ in
     let e' = map_rec (push_let_in (n, e, typ) env) (d a) e in
     mkLetIn (n, trm', typ', e')
  | App (fu, args) ->
     let fu' = map_rec env a fu in
     let args' = Array.map (map_rec env a) args in
     mkApp (fu', args')
  | Case (ci, ct, m, bs) ->
     let ct' = map_rec env a ct in
     let m' = map_rec env a m in
     let bs' = Array.map (map_rec env a) bs in
     mkCase (ci, ct', m', bs')
  | Fix ((is, i), (ns, ts, ds)) ->
     let ts' = Array.map (map_rec env a) ts in
     let ds' = Array.map (map_rec_env_fix map_rec d env a ns ts) ds in
     mkFix ((is, i), (ns, ts', ds'))
  | CoFix (i, (ns, ts, ds)) ->
     let ts' = Array.map (map_rec env a) ts in
     let ds' = Array.map (map_rec_env_fix map_rec d env a ns ts) ds in
     mkCoFix (i, (ns, ts', ds'))
  | Proj (p, c) ->
     let c' = map_rec env a c in
     mkProj (p, c')
  | _ ->
     f env a trm

(*
 * Map a function over a term, when the environment doesn't matter
 * Update the argument of type 'a using the a supplied update function
 * Return a new term
 *)
let map_term f d (a : 'a) (trm : types) : types =
  map_term_env (fun _ a t -> f a t) d empty_env a trm