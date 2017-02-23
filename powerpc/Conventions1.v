(* *********************************************************************)
(*                                                                     *)
(*              The Compcert verified compiler                         *)
(*                                                                     *)
(*          Xavier Leroy, INRIA Paris-Rocquencourt                     *)
(*                                                                     *)
(*  Copyright Institut National de Recherche en Informatique et en     *)
(*  Automatique.  All rights reserved.  This file is distributed       *)
(*  under the terms of the INRIA Non-Commercial License Agreement.     *)
(*                                                                     *)
(* *********************************************************************)

(** Function calling conventions and other conventions regarding the use of
    machine registers and stack slots. *)

Require Import Coqlib.
Require Import Decidableplus.
Require Import AST.
Require Import Events.
Require Import Locations.

(** * Classification of machine registers *)

(** Machine registers (type [mreg] in module [Locations]) are divided in
  the following groups:
- Callee-save registers, whose value is preserved across a function call.
- Caller-save registers that can be modified during a function call.

  We follow the PowerPC/EABI application binary interface (ABI) in our choice
  of callee- and caller-save registers.
*)

Definition is_callee_save (r: mreg): bool :=
  match r with
  | R3  | R4  | R5  | R6  | R7  | R8  | R9  | R10  | R11 | R12 => false
  | R14 | R15 | R16 | R17 | R18 | R19 | R20 | R21 | R22 | R23 | R24
  | R25 | R26 | R27 | R28 | R29 | R30 | R31 => true
  | F0  | F1  | F2  | F3  | F4  | F5  | F6  | F7
  | F8  | F9  | F10 | F11 | F12 | F13 => false
  | F14 | F15 | F16 | F17 | F18 | F19 | F20 | F21 | F22 | F23
  | F24 | F25 | F26 | F27 | F28 | F29 | F30 | F31 => true
  end.

Definition int_caller_save_regs :=
  R3 :: R4 :: R5 :: R6 :: R7 :: R8 :: R9 :: R10 :: R11 :: R12 :: nil.

Definition float_caller_save_regs :=
  F0 :: F1 :: F2 :: F3 :: F4 :: F5 :: F6 :: F7 :: F8 :: F9 :: F10 :: F11 :: F12 :: F13 :: nil.

Definition int_callee_save_regs :=
  R31 :: R30 :: R29 :: R28 :: R27 :: R26 :: R25 :: R24 :: R23 ::
  R22 :: R21 :: R20 :: R19 :: R18 :: R17 :: R16 :: R15 :: R14 :: nil.

Definition float_callee_save_regs :=
  F31 :: F30 :: F29 :: F28 :: F27 :: F26 :: F25 :: F24 :: F23 ::
  F22 :: F21 :: F20 :: F19 :: F18 :: F17 :: F16 :: F15 :: F14 :: nil.

Definition destroyed_at_call :=
  List.filter (fun r => negb (is_callee_save r)) all_mregs.

Definition dummy_int_reg := R3.     (**r Used in [Coloring]. *)
Definition dummy_float_reg := F0.   (**r Used in [Coloring]. *)

Definition is_float_reg (r: mreg): bool :=
  match r with
  | R3  | R4  | R5  | R6  | R7  | R8  | R9  | R10  | R11 | R12
  | R14 | R15 | R16 | R17 | R18 | R19 | R20 | R21 | R22 | R23 | R24
  | R25 | R26 | R27 | R28 | R29 | R30 | R31 => false
  | F0  | F1  | F2  | F3  | F4  | F5  | F6  | F7
  | F8  | F9  | F10 | F11 | F12 | F13
  | F14 | F15 | F16 | F17 | F18 | F19 | F20 | F21 | F22 | F23
  | F24 | F25 | F26 | F27 | F28 | F29 | F30 | F31 => true
  end.

(** * Function calling conventions *)

(** The functions in this section determine the locations (machine registers
  and stack slots) used to communicate arguments and results between the
  caller and the callee during function calls.  These locations are functions
  of the signature of the function and of the call instruction.
  Agreement between the caller and the callee on the locations to use
  is guaranteed by our dynamic semantics for Cminor and RTL, which demand
  that the signature of the call instruction is identical to that of the
  called function.

  Calling conventions are largely arbitrary: they must respect the properties
  proved in this section (such as no overlapping between the locations
  of function arguments), but this leaves much liberty in choosing actual
  locations.  To ensure binary interoperability of code generated by our
  compiler with libraries compiled by another PowerPC compiler, we
  implement the standard conventions defined in the PowerPC/EABI
  application binary interface. *)

(** ** Location of function result *)

(** The result value of a function is passed back to the caller in
  registers [R3] or [F1] or [R3, R4], depending on the type of the returned value.
  We treat a function without result as a function with one integer result. *)

Definition loc_result (s: signature) : rpair mreg :=
  match s.(sig_res) with
  | None => One R3
  | Some (Tint | Tany32) => One R3
  | Some (Tfloat | Tsingle | Tany64) => One F1
  | Some Tlong => Twolong R3 R4
  end.

Lemma loc_result_type:
  forall sig,
  subtype (proj_sig_res sig) (typ_rpair mreg_type (loc_result sig)) = true.
Proof.
  intros. unfold proj_sig_res, loc_result.
  destruct (sig_res sig) as [[]|]; simpl; destruct Archi.ppc64; auto.
Qed.

(** The result locations are caller-save registers *)

Lemma loc_result_caller_save:
  forall (s: signature),
  forall_rpair (fun r => is_callee_save r = false) (loc_result s).
Proof.
  intros.
  unfold loc_result. destruct (sig_res s) as [[]|]; simpl; auto.
Qed.

(** If the result is in a pair of registers, those registers are distinct and have type [Tint] at least. *)

Lemma loc_result_pair:
  forall sg,
  match loc_result sg with
  | One _ => True
  | Twolong r1 r2 =>
        r1 <> r2 /\ sg.(sig_res) = Some Tlong
     /\ subtype Tint (mreg_type r1) = true /\ subtype Tint (mreg_type r2) = true
     /\ Archi.splitlong = true 
  end.
Proof.
  intros; unfold loc_result; destruct (sig_res sg) as [[]|]; auto.
  simpl; intuition congruence. 
Qed.

(** The location of the result depends only on the result part of the signature *)

Lemma loc_result_exten:
  forall s1 s2, s1.(sig_res) = s2.(sig_res) -> loc_result s1 = loc_result s2.
Proof.
  intros. unfold loc_result. rewrite H; auto.
Qed.

(** ** Location of function arguments *)

(** The PowerPC EABI states the following convention for passing arguments
  to a function:
- The first 8 integer arguments are passed in registers [R3] to [R10].
- The first 8 float arguments are passed in registers [F1] to [F8].
- The first 4 long integer arguments are passed in register pairs [R3,R4] ... [R9,R10].
- Extra arguments are passed on the stack, in [Outgoing] slots, consecutively
  assigned (1 word for an integer argument, 2 words for a float),
  starting at word offset 0.
- No stack space is reserved for the arguments that are passed in registers.
*)

Definition int_param_regs :=
  R3 :: R4 :: R5 :: R6 :: R7 :: R8 :: R9 :: R10 :: nil.
Definition float_param_regs :=
  F1 :: F2 :: F3 :: F4 :: F5 :: F6 :: F7 :: F8 :: nil.

Fixpoint loc_arguments_rec
    (tyl: list typ) (ir fr ofs: Z) {struct tyl} : list (rpair loc) :=
  match tyl with
  | nil => nil
  | (Tint | Tany32) as ty :: tys =>
      match list_nth_z int_param_regs ir with
      | None =>
          One (S Outgoing ofs ty) :: loc_arguments_rec tys ir fr (ofs + 1)
      | Some ireg =>
          One (R ireg) :: loc_arguments_rec tys (ir + 1) fr ofs
      end
  | (Tfloat | Tsingle | Tany64) as ty :: tys =>
      match list_nth_z float_param_regs fr with
      | None =>
          let ofs := align ofs 2 in
          One (S Outgoing ofs ty) :: loc_arguments_rec tys ir fr (ofs + 2)
      | Some freg =>
          One (R freg) :: loc_arguments_rec tys ir (fr + 1) ofs
      end
  | Tlong :: tys =>
      let ir := align ir 2 in
      match list_nth_z int_param_regs ir, list_nth_z int_param_regs (ir + 1) with
      | Some r1, Some r2 =>
          Twolong (R r1) (R r2) :: loc_arguments_rec tys (ir + 2) fr ofs
      | _, _ =>
          let ofs := align ofs 2 in
          Twolong (S Outgoing ofs Tint) (S Outgoing (ofs + 1) Tint) :: loc_arguments_rec tys ir fr (ofs + 2)
      end
  end.

(** [loc_arguments s] returns the list of locations where to store arguments
  when calling a function with signature [s].  *)

Definition loc_arguments (s: signature) : list (rpair loc) :=
  loc_arguments_rec s.(sig_args) 0 0 0.

(** [size_arguments s] returns the number of [Outgoing] slots used
  to call a function with signature [s]. *)

Fixpoint size_arguments_rec (tyl: list typ) (ir fr ofs: Z) {struct tyl} : Z :=
  match tyl with
  | nil => ofs
  | (Tint | Tany32) :: tys =>
      match list_nth_z int_param_regs ir with
      | None => size_arguments_rec tys ir fr (ofs + 1)
      | Some ireg => size_arguments_rec tys (ir + 1) fr ofs
      end
  | (Tfloat | Tsingle | Tany64) :: tys =>
      match list_nth_z float_param_regs fr with
      | None => size_arguments_rec tys ir fr (align ofs 2 + 2)
      | Some freg => size_arguments_rec tys ir (fr + 1) ofs
      end
  | Tlong :: tys =>
      let ir := align ir 2 in
      match list_nth_z int_param_regs ir, list_nth_z int_param_regs (ir + 1) with
      | Some r1, Some r2 => size_arguments_rec tys (ir + 2) fr ofs
      | _, _ => size_arguments_rec tys ir fr (align ofs 2 + 2)
      end
  end.

Definition size_arguments (s: signature) : Z :=
  size_arguments_rec s.(sig_args) 0 0 0.

(** Argument locations are either caller-save registers or [Outgoing]
  stack slots at nonnegative offsets. *)

Definition loc_argument_acceptable (l: loc) : Prop :=
  match l with
  | R r => is_callee_save r = false
  | S Outgoing ofs ty => ofs >= 0 /\ (typealign ty | ofs)
  | _ => False
  end.

Definition loc_argument_charact (ofs: Z) (l: loc) : Prop :=
  match l with
  | R r => In r int_param_regs \/ In r float_param_regs
  | S Outgoing ofs' ty => ofs' >= ofs /\ (typealign ty | ofs')
  | _ => False
  end.

Remark loc_arguments_rec_charact:
  forall tyl ir fr ofs p,
  In p (loc_arguments_rec tyl ir fr ofs) ->
  forall_rpair (loc_argument_charact ofs) p.
Proof.
  assert (X: forall ofs1 ofs2 l, loc_argument_charact ofs2 l -> ofs1 <= ofs2 -> loc_argument_charact ofs1 l).
  { destruct l; simpl; intros; auto. destruct sl; auto. intuition omega. }
  assert (Y: forall ofs1 ofs2 p, forall_rpair (loc_argument_charact ofs2) p -> ofs1 <= ofs2 -> forall_rpair (loc_argument_charact ofs1) p).
  { destruct p; simpl; intuition eauto. }
Opaque list_nth_z.
  induction tyl; simpl loc_arguments_rec; intros.
  elim H.
  destruct a.
- (* int *)
  destruct (list_nth_z int_param_regs ir) as [r|] eqn:E; destruct H.
  subst. left. eapply list_nth_z_in; eauto.
  eapply IHtyl; eauto.
  subst. split. omega. apply Z.divide_1_l.
  eapply Y; eauto. omega.
- (* float *)
  assert (ofs <= align ofs 2) by (apply align_le; omega).
  destruct (list_nth_z float_param_regs fr) as [r|] eqn:E; destruct H.
  subst. right. eapply list_nth_z_in; eauto.
  eapply IHtyl; eauto.
  subst. split. omega. apply Z.divide_1_l.
  eapply Y; eauto. omega.
- (* long *)
  assert (ofs <= align ofs 2) by (apply align_le; omega).
  set (ir' := align ir 2) in *.
  destruct (list_nth_z int_param_regs ir') as [r1|] eqn:E1.
  destruct (list_nth_z int_param_regs (ir' + 1)) as [r2|] eqn:E2.
  destruct H. subst; split; left; eapply list_nth_z_in; eauto.
  eapply IHtyl; eauto.
  destruct H.
  subst. split; (split; [omega|apply Z.divide_1_l]).
  eapply Y; eauto. omega.
  destruct H.
  subst. split; (split; [omega|apply Z.divide_1_l]).
  eapply Y; eauto. omega.
- (* single *)
  assert (ofs <= align ofs 2) by (apply align_le; omega).
  destruct (list_nth_z float_param_regs fr) as [r|] eqn:E; destruct H.
  subst. right. eapply list_nth_z_in; eauto.
  eapply IHtyl; eauto.
  subst. split. omega. apply Z.divide_1_l.
  eapply Y; eauto. omega.
- (* any32 *)
  destruct (list_nth_z int_param_regs ir) as [r|] eqn:E; destruct H.
  subst. left. eapply list_nth_z_in; eauto.
  eapply IHtyl; eauto.
  subst. split. omega. apply Z.divide_1_l.
  eapply Y; eauto. omega.
- (* float *)
  assert (ofs <= align ofs 2) by (apply align_le; omega).
  destruct (list_nth_z float_param_regs fr) as [r|] eqn:E; destruct H.
  subst. right. eapply list_nth_z_in; eauto.
  eapply IHtyl; eauto.
  subst. split. omega. apply Z.divide_1_l.
  eapply Y; eauto. omega.
Qed.

Lemma loc_arguments_acceptable:
  forall (s: signature) (p: rpair loc),
  In p (loc_arguments s) -> forall_rpair loc_argument_acceptable p.
Proof.
  unfold loc_arguments; intros.
  exploit loc_arguments_rec_charact; eauto.
  assert (A: forall r, In r int_param_regs -> is_callee_save r = false) by decide_goal.
  assert (B: forall r, In r float_param_regs -> is_callee_save r = false) by decide_goal.
  assert (X: forall l, loc_argument_charact 0 l -> loc_argument_acceptable l).
  { unfold loc_argument_charact, loc_argument_acceptable.
    destruct l as [r | [] ofs ty]; auto.  intros [C|C]; auto. }
  unfold forall_rpair; destruct p; intuition auto.
Qed.

Hint Resolve loc_arguments_acceptable: locs.

(** The offsets of [Outgoing] arguments are below [size_arguments s]. *)

Remark size_arguments_rec_above:
  forall tyl ir fr ofs0,
  ofs0 <= size_arguments_rec tyl ir fr ofs0.
Proof.
  induction tyl; simpl; intros.
  omega.
  destruct a.
  destruct (list_nth_z int_param_regs ir); eauto. apply Zle_trans with (ofs0 + 1); auto; omega.
  destruct (list_nth_z float_param_regs fr); eauto.
  apply Zle_trans with (align ofs0 2). apply align_le; omega.
  apply Zle_trans with (align ofs0 2 + 2); auto; omega.
  set (ir' := align ir 2).
  destruct (list_nth_z int_param_regs ir'); eauto.
  destruct (list_nth_z int_param_regs (ir' + 1)); eauto.
  apply Zle_trans with (align ofs0 2). apply align_le; omega.
  apply Zle_trans with (align ofs0 2 + 2); auto; omega.
  apply Zle_trans with (align ofs0 2). apply align_le; omega.
  apply Zle_trans with (align ofs0 2 + 2); auto; omega.
  destruct (list_nth_z float_param_regs fr); eauto.
  apply Zle_trans with (align ofs0 2). apply align_le; omega.
  apply Zle_trans with (align ofs0 2 + 2); auto; omega.
  destruct (list_nth_z int_param_regs ir); eauto. apply Zle_trans with (ofs0 + 1); auto; omega.
  destruct (list_nth_z float_param_regs fr); eauto.
  apply Zle_trans with (align ofs0 2). apply align_le; omega.
  apply Zle_trans with (align ofs0 2 + 2); auto; omega.
Qed.

Lemma size_arguments_above:
  forall s, size_arguments s >= 0.
Proof.
  intros; unfold size_arguments. apply Zle_ge.
  apply size_arguments_rec_above.
Qed.

Lemma loc_arguments_bounded:
  forall (s: signature) (ofs: Z) (ty: typ),
  In (S Outgoing ofs ty) (regs_of_rpairs (loc_arguments s)) ->
  ofs + typesize ty <= size_arguments s.
Proof.
  intros.
  assert (forall tyl ir fr ofs0,
    In (S Outgoing ofs ty) (regs_of_rpairs (loc_arguments_rec tyl ir fr ofs0)) ->
    ofs + typesize ty <= size_arguments_rec tyl ir fr ofs0).
{
  induction tyl; simpl; intros.
  elim H0.
  destruct a.
- (* int *)
  destruct (list_nth_z int_param_regs ir); destruct H0.
  congruence.
  eauto.
  inv H0. apply size_arguments_rec_above.
  eauto.
- (* float *)
  destruct (list_nth_z float_param_regs fr); destruct H0.
  congruence.
  eauto.
  inv H0. apply size_arguments_rec_above. eauto.
- (* long *)
  set (ir' := align ir 2) in *.
  assert (DFL:
    In (S Outgoing ofs ty) (regs_of_rpairs
                             (Twolong (S Outgoing (align ofs0 2) Tint)
                                      (S Outgoing (align ofs0 2 + 1) Tint)
                          :: loc_arguments_rec tyl ir' fr (align ofs0 2 + 2))) ->
    ofs + typesize ty <= size_arguments_rec tyl ir' fr (align ofs0 2 + 2)).
  { intros IN. destruct IN. inv H1.
    transitivity (align ofs0 2 + 2). simpl; omega. apply size_arguments_rec_above. 
    destruct H1. inv H1. transitivity (align ofs0 2 + 2). simpl; omega. apply size_arguments_rec_above.
    auto. }
  destruct (list_nth_z int_param_regs ir'); auto.
  destruct (list_nth_z int_param_regs (ir' + 1)); auto.
  destruct H0. congruence. destruct H0. congruence. eauto.
- (* single *)
  destruct (list_nth_z float_param_regs fr); destruct H0.
  congruence.
  eauto.
  inv H0. transitivity (align ofs0 2 + 2). simpl; omega. apply size_arguments_rec_above.
  eauto.
- (* any32 *)
  destruct (list_nth_z int_param_regs ir); destruct H0.
  congruence.
  eauto.
  inv H0. apply size_arguments_rec_above.
  eauto.
- (* any64 *)
  destruct (list_nth_z float_param_regs fr); destruct H0.
  congruence.
  eauto.
  inv H0. apply size_arguments_rec_above. eauto.
  }
  eauto.
Qed.

Lemma loc_arguments_main:
  loc_arguments signature_main = nil.
Proof.
  reflexivity.
Qed.

Lemma loc_arguments_charact':
  forall tyl p,
    In p (regs_of_rpairs (loc_arguments tyl)) ->
    loc_argument_charact 0 p.
Proof.
  unfold loc_arguments.
  intros tyl p IN.
  apply in_regs_of_rpairs_inv in IN. destruct IN as (P & IN & IN').
  apply loc_arguments_rec_charact in IN.
  destruct P; simpl in *; auto.
  destruct IN'; subst; auto. easy.
  destruct IN' as [A|[A|A]]; inv A; intuition.
Qed.

Definition loc_argument_charact' ofs ir fr l :=
  match l with
  | R r => (In r int_param_regs /\ exists i, i >= ir /\ list_nth_z int_param_regs i = Some r)
          \/ (In r float_param_regs /\ exists i, i >= fr /\ list_nth_z float_param_regs i = Some r)
  | S Local _ _ => False
  | S Incoming _ _ => False
  | S Outgoing ofs' ty => ofs' >= ofs /\ (typealign ty | ofs')
  end.

Remark loc_arguments_rec_charact':
  forall tyl ir fr ofs p,
  In p (loc_arguments_rec tyl ir fr ofs) ->
  forall_rpair (loc_argument_charact' ofs ir fr) p.
Proof.
  assert (X: forall ofs1 ofs2 ir fr l, loc_argument_charact' ofs2 ir fr l -> ofs1 <= ofs2 ->
                                  loc_argument_charact' ofs1 ir fr l).
  { destruct l; simpl; intros; auto.
    destruct sl; auto. intuition omega. }
  assert (Y: forall ofs1 ofs2 ir fr p, forall_rpair (loc_argument_charact' ofs2 ir fr) p -> ofs1 <= ofs2 ->
                                  forall_rpair (loc_argument_charact' ofs1 ir fr) p).
  { destruct p; simpl; intuition eauto. }
   assert (C: forall ofs ir1 ir2 fr l, loc_argument_charact' ofs ir2 fr l -> ir1 <= ir2 -> loc_argument_charact' ofs ir1 fr l).
  {
    Opaque int_param_regs float_param_regs.
    destruct l; simpl; intros; auto. destruct H.
    - destruct H.
      left; split; auto. destruct H1 as (i & LE & NTH); exists i; split; eauto. omega.
    - destruct H.
      right; split; auto.
  } 
  assert (D: forall ofs ir1 ir2 fr p, forall_rpair (loc_argument_charact' ofs ir2 fr) p -> ir1 <= ir2 -> forall_rpair (loc_argument_charact' ofs ir1 fr) p).
  { destruct p; simpl; intuition eauto.
  }
  assert (E0: forall ofs ir fr1 fr2 l, loc_argument_charact' ofs ir fr2 l -> fr1 <= fr2 -> loc_argument_charact' ofs ir fr1 l).
  {
    Opaque int_param_regs float_param_regs.
    destruct l; simpl; intros; auto. destruct H.
    - destruct H.
      left; split; auto. 
    - destruct H.
      right; split; auto.
      destruct H1 as (i & LE & NTH). exists i; split; eauto. omega.
  } 
  assert (F: forall ofs ir fr1 fr2 p, forall_rpair (loc_argument_charact' ofs ir fr2) p -> fr1 <= fr2 -> forall_rpair (loc_argument_charact' ofs ir fr1) p).
  { destruct p; simpl; intuition eauto.
  }
Opaque list_nth_z.
  induction tyl; simpl loc_arguments_rec; intros.
  elim H.
  destruct a.
- (* int *)
  destruct (list_nth_z int_param_regs ir) as [r|] eqn:E; destruct H. 
  + subst. left. split. eapply list_nth_z_in; eauto. eexists; split; eauto. omega.
  + eapply D. eapply IHtyl; eauto. omega.
  + subst. split. omega. apply Z.divide_1_l.
  + eapply Y. eapply IHtyl. eauto. omega.
- (* float *)
  assert (ofs <= align ofs 2) by (apply align_le; omega).
  destruct (list_nth_z float_param_regs fr) as [r|] eqn:E; destruct H.
  + subst. right. split. eapply list_nth_z_in; eauto. eexists; split; eauto. omega.
  + eapply F. eapply IHtyl; eauto. omega.
  + subst. split. omega. apply Z.divide_1_l.
  + eapply Y; eauto. omega.
- (* long *)
  assert (ofs <= align ofs 2) by (apply align_le; omega).
  set (ir' := align ir 2) in *.
  destruct (list_nth_z int_param_regs ir') as [r1|] eqn:E1.
  destruct (list_nth_z int_param_regs (ir' + 1)) as [r2|] eqn:E2.
  destruct H.
  + subst; split; left; split; try eapply list_nth_z_in; eauto.
    eexists; split; eauto. unfold ir'. apply Zle_ge. apply align_le; omega.
    eexists; split; eauto. unfold ir'. apply Zle_ge.
    transitivity (align ir 2). apply align_le; omega. omega.
  + eapply D. eapply IHtyl; eauto. unfold ir'.
    transitivity (align ir 2). apply align_le; omega. omega.
  + destruct H.
    * subst. split; (split; [omega|apply Z.divide_1_l]).
    * eapply D. eapply Y; eauto. transitivity (align ofs 2). apply align_le; omega.
      omega. unfold ir'. apply align_le; omega.
  + destruct H.
    * subst. split; (split; [omega|apply Z.divide_1_l]).
    * eapply D. eapply Y; eauto. transitivity (align ofs 2). apply align_le; omega.
      omega. unfold ir'. apply align_le; omega. 
- (* single *)
  assert (ofs <= align ofs 2) by (apply align_le; omega).
  destruct (list_nth_z float_param_regs fr) as [r|] eqn:E; destruct H.
  + subst. right. split. eapply list_nth_z_in; eauto. eexists; split; eauto. omega.
  + eapply F. eapply IHtyl; eauto. omega.
  + subst. split. omega. apply Z.divide_1_l.
  + eapply Y; eauto. omega.
- (* any32 *)
  destruct (list_nth_z int_param_regs ir) as [r|] eqn:E; destruct H.
  + subst. left. split. eapply list_nth_z_in; eauto. eexists; split; eauto. omega.
  + eapply D. eapply IHtyl; eauto. omega.
  + subst. split. omega. apply Z.divide_1_l.
  + eapply Y; eauto. omega.
- (* float *)
  assert (ofs <= align ofs 2) by (apply align_le; omega).
  destruct (list_nth_z float_param_regs fr) as [r|] eqn:E; destruct H.
  + subst. right. split. eapply list_nth_z_in; eauto. eexists; split; eauto. omega.
  + eapply F. eapply IHtyl; eauto. omega.
  + subst. split. omega. apply Z.divide_1_l.
  + eapply Y; eauto. omega.
Qed.

Remark loc_arguments_rec_charact'':
  forall tyl ir fr ofs p,
    In p (regs_of_rpairs (loc_arguments_rec tyl ir fr ofs)) ->
    loc_argument_charact' ofs ir fr p.
Proof.
  intros.
  apply in_regs_of_rpairs_inv in H.
  destruct H as (p0 & IN & ROR).
  exploit loc_arguments_rec_charact'; eauto.
  intros.
  destruct p0; simpl in *.
  destruct ROR; subst; auto.  easy.
  intuition subst; auto.
Qed.

Lemma list_nth_z_rew:
  forall {A} (l: list A) a n,
    list_nth_z (a::l) n =
    if zeq n 0
    then Some a
    else list_nth_z l (Z.pred n).
Proof. simpl; intros. reflexivity. Qed.

Lemma list_nth_z_norepet_same:
  forall {A} (l: list A) (lnr: list_norepet l) r i1 i2,
    list_nth_z l i1 = Some r ->
    list_nth_z l i2 = Some r ->
    i1 = i2.
Proof.
  induction 1; simpl; intros; eauto.
  discriminate.
  rewrite list_nth_z_rew in H0, H1.
  destruct (zeq i1 0). inv H0.
  destruct (zeq i2 0). auto. apply list_nth_z_in in H1. congruence.
  destruct (zeq i2 0). inv H1. apply list_nth_z_in in H0. congruence.
  eapply IHlnr in H0. 2: exact H1. apply f_equal with (f:=Z.succ) in H0.
  rewrite <- ! Zsucc_pred in H0.
  eauto.
Qed.

Lemma loc_arguments_rec_norepet sg:
  forall ir fr ofs,
    Loc.norepet (regs_of_rpairs (loc_arguments_rec sg ir fr ofs)).
Proof.
  Opaque int_param_regs float_param_regs.
  induction sg; simpl; auto using Loc.norepet_nil.
  assert (H64: forall ty ofs ir fr,
             Loc.norepet
               (regs_of_rpair (One (S Outgoing ofs ty)) ++
                              regs_of_rpairs (loc_arguments_rec sg ir fr (ofs + typesize ty)))).
  {
    simpl. intros ty ofs ir fr.
    apply Loc.norepet_cons; auto.
    rewrite Loc.notin_iff.
    intros l' H.
    apply loc_arguments_rec_charact'' in H; auto.
    destruct l' ; try contradiction. simpl. auto.
    destruct sl; try contradiction. simpl.
    simpl in H.
    right. simpl. omega.
  }
  generalize (loc_arguments_rec_charact'' sg).
  unfold loc_argument_charact'.
  assert ( forall r, In r int_param_regs -> In r float_param_regs -> False).
  {
    Transparent int_param_regs float_param_regs.
    simpl. intuition congruence.
  }
  assert( list_norepet int_param_regs).
  repeat (constructor; [ simpl; intuition congruence | ]); constructor.
  assert( list_norepet float_param_regs).
  repeat (constructor; [ simpl; intuition congruence | ]); constructor.
  revert H H0 H1.
  generalize int_param_regs as IPR, float_param_regs as FPR.
  intros IPR FPR DISJ LNR1 LNR2 CHARACT.
  assert (H64_reg: forall ir fr ofs ireg,
             list_nth_z IPR ir = Some ireg ->
             Loc.norepet
               (regs_of_rpair (One (R ireg)) ++
                              regs_of_rpairs (loc_arguments_rec sg (ir + 1) fr ofs))).
  {
    simpl. intros ir fr ofs ireg NTH.
    apply Loc.norepet_cons; auto.
    rewrite Loc.notin_iff.
    intros l' H.
    apply CHARACT in H; auto. simpl.
    destruct l'; auto.
    destruct H as [(IN & (i & SUP & EQ)) | (IN & (i & SUP & EQ))].
    intro; subst.
    exploit (list_nth_z_norepet_same (A:=mreg)). 2: apply NTH. 2: apply EQ. auto. intro; subst. omega.
    apply list_nth_z_in in NTH. intro; subst. eauto.
  }
  assert (H64_freg: forall ir fr ofs ireg,
             list_nth_z FPR fr = Some ireg ->
             Loc.norepet
               (regs_of_rpair (One (R ireg)) ++
                              regs_of_rpairs (loc_arguments_rec sg ir (fr + 1) ofs))).
  {
    simpl. intros ir fr ofs ireg NTH.
    apply Loc.norepet_cons; auto.
    rewrite Loc.notin_iff.
    intros l' H.
    apply CHARACT in H; auto. simpl.
    destruct l'; auto.
    destruct H as [(IN & (i & SUP & EQ)) | (IN & (i & SUP & EQ))].
    intro; subst. apply list_nth_z_in in NTH. eauto. 
    intro; subst.
    exploit (list_nth_z_norepet_same (A:=mreg)). 2: apply NTH. 2: apply EQ. auto. intro; subst. omega.
  }
  intros.
  destruct a; auto.
  - destruct (list_nth_z IPR ir) eqn:EQ.
    + simpl in *. apply H64_reg. auto. 
    + simpl in *. apply H64. 
  - destruct (list_nth_z FPR fr) eqn:EQ.
    + simpl in *. apply H64_freg. auto. 
    + simpl in *. apply H64. 
  - destruct (list_nth_z IPR (align ir 2)) eqn:EQ.
    destruct (list_nth_z IPR (align ir 2 + 1)) eqn:EQ1.
    + simpl in *.
      constructor. simpl. split.
      * intro; subst. exploit (list_nth_z_norepet_same (A:=mreg)). apply LNR1. apply EQ. apply EQ1.
        omega.
      * rewrite Loc.notin_iff.
        intros.
        apply CHARACT in H. destruct l'; simpl;  auto.
        destruct H as [(IN & (i & SUP & EQ')) | (IN & (i & SUP & EQ'))].
        intro; subst.
        exploit (list_nth_z_norepet_same (A:=mreg)). 2: apply EQ'. 2: apply EQ. auto. intro; subst. omega.
        intro; subst. apply list_nth_z_in in EQ. eauto. 
      * 
        generalize (H64_reg _ fr ofs _ EQ1).
        replace (align ir 2 + 1 + 1) with (align ir 2 + 2). auto. omega.
    + simpl in *.
      constructor. simpl. split.
      * right. left. omega. 
      * rewrite Loc.notin_iff. intros.
        apply CHARACT in H. destruct l'; simpl;  auto.
        destruct sl; auto. right. left. omega.
      * generalize (H64 Tint (align ofs 2 + 1) (align ir 2) fr). simpl.
        replace (align ofs 2 + 1 + 1) with (align ofs 2 + 2). auto. omega.
    + simpl in *.
      constructor. simpl. split.
      * right. left. omega. 
      * rewrite Loc.notin_iff. intros.
        apply CHARACT in H. destruct l'; simpl;  auto.
        destruct sl; auto. right. left. omega.
      * generalize (H64 Tint (align ofs 2 + 1) (align ir 2) fr). simpl.
        replace (align ofs 2 + 1 + 1) with (align ofs 2 + 2). auto. omega.
  - destruct (list_nth_z FPR fr) eqn:EQ.
    + simpl in *. apply H64_freg. auto.
    + simpl in *. constructor.
      * rewrite Loc.notin_iff. intros.
        apply CHARACT in H. destruct l'; simpl;  auto.
        destruct sl; auto. right. left. omega.
      * auto. 
  - destruct (list_nth_z IPR ir) eqn:EQ.
    + simpl in *. apply H64_reg. auto. 
    + simpl in *. apply H64. 
  - destruct (list_nth_z FPR fr) eqn:EQ.
    + simpl in *. apply H64_freg. auto. 
    + simpl in *. apply H64. 
Qed.

Lemma loc_arguments_norepet:
  forall sg,
    Loc.norepet (regs_of_rpairs (loc_arguments sg)).
Proof.
  unfold loc_arguments; intros.
  apply loc_arguments_rec_norepet.
Qed.

