Add LoadPath "coq/playground".
Require Import Vector.
Require Import List.
Require Import Ornamental.Ornaments.

Notation vector := Vector.t.
Notation nilV := Vector.nil.
Notation consV := Vector.cons.

Set DEVOID search prove coherence.
Set DEVOID search prove equivalence.
Set DEVOID lift type.

(*
 * Attempt at understanding why lifting eliminators is OK, formally.
 *)

(* --- Algebraic ornaments --- *)

Definition sigT_vect_rect (A : Type) (P : {H : nat & vector A H} -> Type)
  (pnil : P (existT (vector A) 0 (nilV A)))
  (pcons : forall (a : A) (l : {H : nat & vector A H}),
        P (existT (vector A) (projT1 l) (projT2 l)) ->
        P (existT (vector A) (S (projT1 l)) (consV A a (projT1 l) (projT2 l)))) 
  (l : {H : nat & vector A H}) :=
VectorDef.t_rect 
  A
  (fun (n : nat) (t : vector A n) => P (existT (vector A) n t))
  pnil
  (fun (h : A) (n : nat) (t : vector A n) (H : P (existT (vector A) n t)) =>
    pcons h (existT (vector A) n t) H) 
  (projT1 l) 
  (projT2 l).

Lift list vector in list_rect as sigT_vect_rect_lifted.
Lift vector list in sigT_vect_rect_lifted as list_rect_lifted.

Lemma lift_list_rect_correct: sigT_vect_rect_lifted = sigT_vect_rect.
Proof.
  reflexivity.
Qed.

Lemma lift_sigT_vect_rect_correct: list_rect_lifted = list_rect.
Proof.
  reflexivity.
Qed.

Definition list_rect_eta (A : Type) (P : list A -> Type)
  (pnil : P nil)
  (pcons : forall (a : A) (l : list A),
        P l ->
        P (cons a l))
  (l : list A) :=
@list_rect
  A
  (fun (l : list A) => P l)
  pnil
  (fun (h : A) (l : list A) (H : P l) =>
    pcons h l H) 
  l.

Definition path_rect_ltv_inv (A : Type) (P : list A -> Type) (s : sigT (vector A)):=
  P (list_to_t_inv A s).

Definition path_rect_ltv (A : Type) (P : sigT (vector A) -> Type) (l : list A):=
  P (list_to_t A l).

Definition list_rect_eta_1 (A : Type) (P : list A -> Type)
  (pnil : P nil)
  (pcons : forall (a : A) (l : list A),
        P l ->
        P (cons a l))
  (s : sigT (vector A)) :=
@list_rect
  A
  P
  pnil
  (fun (h : A) (l : list A) (H : P l) =>
    pcons h l H) 
  (list_to_t_inv A s).

Definition list_rect_eta_2 (A : Type) (P : sigT (vector A) -> Type)
  (pnil : (path_rect_ltv A P) nil)
  (pcons : forall (a : A) (l : list A),
        (path_rect_ltv A P) l ->
        (path_rect_ltv A P) (cons a l))
  (s : sigT (vector A)) :=
@list_rect
  A
  (path_rect_ltv A P)
  pnil
  (fun (h : A) (l : list A) (H : (path_rect_ltv A P) l) =>
    pcons h l H) 
  (list_to_t_inv A s).

Lemma path_rect_coh:
  forall (A : Type) (P : sigT (vector A) -> Type) (l : list A),
    (path_rect_ltv A P) l = P (list_to_t A l).
Proof.
  reflexivity.
Qed.

Definition list_rect_eta_3 (A : Type) (P : sigT (vector A) -> Type)
  (pnil : P (list_to_t A nil))
  (pcons : forall (a : A) (l : list A),
        P (list_to_t A l) ->
        P (list_to_t A (cons a l)))
  (s : sigT (vector A)) :=
@list_rect
  A
  (path_rect_ltv A P)
  pnil
  (fun (h : A) (l : list A) (H : P (list_to_t A l)) =>
    pcons h l H) 
  (list_to_t_inv A s).

Lemma refold_cons:
  forall (A : Type) (P : sigT (vector A) -> Type) (l : list A) (a : A),
    (list_to_t A (cons a l)) = existT (vector A) (S (list_to_t_index A l)) (consV A a (list_to_t_index A l) (projT2 (list_to_t A l))).
Proof.
  reflexivity.
Qed.

Definition list_rect_eta_4 (A : Type) (P : sigT (vector A) -> Type)
  (pnil : P (list_to_t A nil))
  (pcons : forall (a : A) (l : list A),
        P (list_to_t A l) ->
        P (existT (vector A) (S (list_to_t_index A l)) (consV A a (list_to_t_index A l) (projT2 (list_to_t A l)))))
  (s : sigT (vector A)) :=
@list_rect
  A
  (path_rect_ltv A P)
  pnil
  (fun (h : A) (l : list A) (H : P (list_to_t A l)) =>
    pcons h l H) 
  (list_to_t_inv A s).

Definition list_rect_eta_5 (A : Type) (P : sigT (vector A) -> Type)
  (pnil : P (existT (vector A) 0 (nilV A)))
  (pcons : forall (a : A) (s : sigT (vector A)),
        P s->
        P (existT (vector A) (S (projT1 s)) (consV A a (projT1 s) (projT2 s))))
  (s : sigT (vector A)) :=
@list_rect
  A
  (path_rect_ltv A P)
  pnil
  (fun (h : A) (l : list A) (H : P (list_to_t A l)) =>
    pcons h (list_to_t A l) H) 
  (list_to_t_inv A s).

Check eq_rect.

Lemma path_ind_retract:
  forall A P (s : sigT (vector A)),
    path_rect_ltv A P (list_to_t_inv A s) ->
    P s.
Proof.
  intros. apply (@eq_rect (sigT (vector A)) (list_to_t A (list_to_t_inv A s)) _ X s (list_to_t_retraction A s)). 
Defined.

Definition list_rect_eta_6 (A : Type) (P : sigT (vector A) -> Type)
  (pnil : P (existT (vector A) 0 (nilV A)))
  (pcons : forall (a : A) (s : sigT (vector A)),
        P s->
        P (existT (vector A) (S (projT1 s)) (consV A a (projT1 s) (projT2 s))))
  (s : sigT (vector A)) :=
path_ind_retract
  A
  P
  s
  (@list_rect
    A
    (path_rect_ltv A P)
    pnil
    (fun (h : A) (l : list A) (H : P (list_to_t A l)) =>
      pcons h (list_to_t A l) H) 
    (list_to_t_inv A s)).

Lemma path_ind_eta:
  forall A P (s : sigT (vector A)),
    P s ->
    P (existT (vector A) (projT1 s) (projT2 s)).
Proof.
  intros. induction s. auto.
Defined.

Definition list_rect_eta_7 (A : Type) (P : sigT (vector A) -> Type)
  (pnil : P (existT (vector A) 0 (nilV A)))
  (pcons : forall (a : A) (s : sigT (vector A)),
        P s ->
        P (existT (vector A) (S (projT1 s)) (consV A a (projT1 s) (projT2 s))))
  (s : sigT (vector A)) :=
path_ind_eta
  A
  P
  s
  (path_ind_retract
    A
    P
    s
    (@list_rect
      A
      (path_rect_ltv A P)
      pnil
      (fun (h : A) (l : list A) (H : P (list_to_t A l)) =>
        pcons h (list_to_t A l) H) 
      (list_to_t_inv A s))).

Definition list_rect_eta_8 (A : Type) (P : sigT (vector A) -> Type)
  (pnil : P (existT (vector A) 0 (nilV A)))
  (pcons : forall (a : A) (s : sigT (vector A)),
        P (existT (vector A) (projT1 s) (projT2 s)) ->
        P (existT (vector A) (S (projT1 s)) (consV A a (projT1 s) (projT2 s))))
  (s : sigT (vector A)) :=
path_ind_eta
  A
  P
  s
  (path_ind_retract
    A
    P
    s
    (@list_rect
      A
      (path_rect_ltv A P)
      pnil
      (fun (h : A) (l : list A) (H : P (list_to_t A l)) =>
        pcons h (list_to_t A l) H) 
      (list_to_t_inv A s))).

(* ^ This general form is what works. What we get is because of some equality: *)

Lemma sigT_vect_rect_correct:
  forall A P pnil pcons s,
    sigT_vect_rect A P pnil pcons s =
    list_rect_eta_8 A P pnil pcons s.
Proof.
  (* ??? *)
Abort.

(* ^ May not need propositional equality here; try in HoTT *)

(* --- Unpacked equiv --- *)

Definition pltv (T : Type) (n : nat) (pl : { l : list T & list_to_t_index T l = n }) : vector T n :=
  list_rect
    (fun l0 : list T => forall n0 : nat, list_to_t_index T l0 = n0 -> vector T n0)
    (fun (n0 : nat) (H : list_to_t_index T Datatypes.nil = n0) =>
     eq_rect (list_to_t_index T Datatypes.nil) (fun n1 : nat => vector T n1) 
       (nilV T) n0 H)
    (fun (a : T) (l0 : list T)
       (IHl : forall n0 : nat, list_to_t_index T l0 = n0 -> vector T n0) 
       (n0 : nat) (H : list_to_t_index T (a :: l0) = n0) =>
     eq_rect (list_to_t_index T (a :: l0)) (fun n1 : nat => vector T n1)
       (consV T a
          (list_to_t_index T l0)
          (IHl (list_to_t_index T l0) eq_refl)) n0 H)
  (projT1 pl) 
  n 
  (projT2 pl).

Program Definition vtl (T : Type) (n : nat) (v : vector T n) : { l : list T & list_to_t_index T l = n }.
Proof.
  induction v.
  - exists nil. reflexivity.
  - exists (cons h (projT1 IHv)). simpl. rewrite (projT2 IHv). reflexivity.
Defined. 

Lemma pltv_section:
  forall T n pl, vtl T n (pltv T n pl) = pl.
Proof.
  induction pl. revert p. revert n. induction x.
  - intros. rewrite <- p. reflexivity.
  - intros. simpl. specialize (IHx (list_to_t_index T x) eq_refl).
    simpl in IHx. rewrite <- p. simpl. unfold pltv in IHx. simpl in IHx. rewrite IHx.
    simpl. reflexivity.
Defined.

Lemma coherence:
  forall T n v, list_to_t_index T (projT1 (vtl T n v)) = n.
Proof.
  intros. induction v.
  - reflexivity.
  - simpl. rewrite IHv. reflexivity.
Defined.

Lemma pltv_retraction:
  forall T n v, pltv T n (vtl T n v) = v.
Proof.
  intros T n v. induction v.
  - reflexivity.
  - pose proof (coherence T n v). admit.
Abort.

(* --- What about splitting constructors? --- *)

Inductive list2 (T : Type) :=
| nil2 : list2 T
| cons2 : T -> list2 T -> list2 T
| never : False -> list2 T.

Program Definition list_to_list2 : forall (T : Type) (l : list T), list2 T.
Proof.
  intros. induction l.
  - apply nil2.
  - apply cons2.
    + apply a.
    + apply IHl.
Defined.

Program Definition list2_to_list : forall (T : Type) (l : list2 T), list T.
Proof.
  intros. induction l.
  - apply nil.
  - apply cons.
    + apply t.
    + apply IHl.
  - inversion f.
Defined.

Theorem list_to_list2_section:
  forall (T : Type) (l : list T), list2_to_list T (list_to_list2 T l) = l.
Proof.
  intros. induction l.
  - auto.
  - simpl. rewrite IHl. auto.
Defined.

Theorem list_to_list2_retraction:
  forall (T : Type) (l : list2 T), list_to_list2 T (list2_to_list T l) = l.
Proof.
  intros. induction l.
  - auto.
  - simpl. rewrite IHl. auto.
  - inversion f.
Defined.

Lemma list2_list_rect :
  forall (A : Type) (P : list2 A -> Type),
    P (nil2 A) ->
    (forall (a : A) (l : list2 A) (IH : P l),
      P (cons2 A a l)) ->
    forall (l : list2 A), P l.
Proof.
  intros A P pnil2 pcons2 l. induction l.
  - apply pnil2.
  - apply pcons2. apply IHl.
  - inversion f.
Defined.

Definition transport_nil:
  forall (A : Type) (P : list2 A -> Type),
    P (list_to_list2 A nil) ->
    P (nil2 A).
Proof.
  intros. apply X.
Defined.

Definition transport_nil_inv:
  forall (A : Type) (P : list2 A -> Type),
    P (nil2 A) ->
    P (list_to_list2 A nil).
Proof.
  intros. apply X.
Defined.

Definition transport_cons:
  forall (A : Type) (P : list2 A -> Type) (l : list2 A) (a : A),
    P (list_to_list2 A (cons a (list2_to_list A l))) ->
    P (cons2 A a l).
Proof.
  intros. simpl in X. rewrite list_to_list2_retraction in X. apply X.
Defined.

Definition transport_cons_inv:
  forall (A : Type) (P : list2 A -> Type) (l : list2 A) (a : A),
    P (cons2 A a l) ->
    P (list_to_list2 A (cons a (list2_to_list A l))).
Proof.
  intros. simpl. rewrite list_to_list2_retraction. apply X.
Defined.

(*
 * Definitely follows patterns from the equivalences, but still not sure
 * exactly what is happening here.
 *)

(* --- Let's see --- *)

Inductive Foo : nat -> Type :=
| f : forall (n : nat), Foo n.

Inductive Bar : nat -> Type :=
| f1 : Bar 0
| f2 : forall (n : nat), Bar n -> Bar (S n).

Program Definition Foo_to_Bar : forall (n : nat), Foo n -> Bar n.
Proof.
  intros. induction H.
  - induction n.
    + apply f1.
    + apply f2. apply IHn.
Defined.

Program Definition Bar_to_Foo : forall (n : nat), Bar n -> Foo n.
Proof.
  intros. apply f.
Defined.

Theorem Foo_to_Bar_section:
  forall (n : nat) (f : Foo n), Bar_to_Foo n (Foo_to_Bar n f) = f.
Proof.
  intros. induction f0.
  - induction n.
    + auto.
    + auto.
Defined.

Theorem Foo_to_Bar_retraction:
  forall (n : nat) (b : Bar n), Foo_to_Bar n (Bar_to_Foo n b) = b.
Proof.
  intros. induction b.
  - auto.
  - simpl. simpl in IHb. rewrite IHb. auto.
Defined.

Check Foo_rect.

Lemma Bar_nat_rect:
  forall (n : nat) (b : Bar n),
    nat_rect Bar f1 (fun (n : nat) (IHn : Bar n) => f2 n IHn) n = b.
Proof.
  intros. induction b.
  - reflexivity.
  - simpl. rewrite IHb. reflexivity.
Defined.

Lemma Bar_Foo_rect:
  forall (P : forall (n : nat), Bar n -> Type),
    (forall (n : nat), P n (nat_rect Bar f1 (fun _ IHn => f2 _ IHn) n)) -> (* <-- looks like repacking *)
    (forall (n : nat) (b : Bar n), P n b).
Proof.
  intros P pf0 n b. rewrite <- Bar_nat_rect. apply pf0. 
Defined.

(* So repacking really is dependent elimination! *)

Lemma Foo_Bar_rect:
  forall P : forall n : nat, Foo n -> Type,
    P 0 (f 0) ->
    (forall (n : nat) (f0 : Foo n), P n (f n) -> P (S n) (f (S n))) ->
    forall (n : nat) (b : Foo n), P n (f n).
Proof.
  intros P pf1 pf2 n f. induction f.
  - induction n.
    + apply pf1.
    + apply (pf2 n (f n)). apply IHn.
Defined.

(* Also note how each of these corresponds to Foo_to_Bar and Bar_to_Foo, respectively. *)


