(*
 * Functions to manage the hypotheses of a term
 *)

open Term
open Environ
open Evd  

(*
 * Eta expansion of an application or function
 *)
val expand_eta : env -> evar_map -> types -> types
