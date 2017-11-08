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
Require Archi.

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

Definition destroyed_at_call :=
  List.filter (fun r => negb (is_callee_save r)) all_mregs.

(** The following definitions are used by the register allocator. *)

(** When a PPC64 processor is used with the PPC32 ABI, the high 32 bits
  of integer callee-save registers may not be preserved.  So,
  declare all integer registers as having size 32 bits for the purpose
  of determining which variables can go in callee-save registers. *)
  
Definition callee_save_type (r: mreg): typ :=
  match r with
  | R3  | R4  | R5  | R6  | R7  | R8  | R9  | R10  | R11 | R12
  | R14 | R15 | R16 | R17 | R18 | R19 | R20 | R21 | R22 | R23 | R24
  | R25 | R26 | R27 | R28 | R29 | R30 | R31 => Tany32
  | F0  | F1  | F2  | F3  | F4  | F5  | F6  | F7
  | F8  | F9  | F10 | F11 | F12 | F13 | F14 | F15
  | F16 | F17 | F18 | F19 | F20 | F21 | F22 | F23
  | F24 | F25 | F26 | F27 | F28 | F29 | F30 | F31 => Tany64
  end.

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

Definition dummy_int_reg := R3.     (**r Used in [Coloring]. *)
Definition dummy_float_reg := F0.   (**r Used in [Coloring]. *)

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

Definition loc_result_32 (s: signature) : rpair mreg :=
  match s.(sig_res) with
  | None => One R3
  | Some (Tint | Tany32) => One R3
  | Some (Tfloat | Tsingle | Tany64) => One F1
  | Some Tlong => Twolong R3 R4
  end.

Definition loc_result_64 (s: signature) : rpair mreg :=
  match s.(sig_res) with
  | None => One R3
  | Some (Tint | Tlong | Tany32 | Tany64) => One R3
  | Some (Tfloat | Tsingle) => One F1
  end.

Definition loc_result :=
  if Archi.ptr64 then loc_result_64 else loc_result_32.

(** The result registers have types compatible with that given in the signature. *)

Lemma loc_result_type:
  forall sig,
  subtype (proj_sig_res sig) (typ_rpair mreg_type (loc_result sig)) = true.
Proof.
  intros. unfold proj_sig_res, loc_result, loc_result_32, loc_result_64, mreg_type.
  destruct Archi.ptr64 eqn:?; destruct (sig_res sig) as [[]|]; destruct Archi.ppc64; simpl; auto.
Qed.

(** The result locations are caller-save registers *)

Lemma loc_result_caller_save:
  forall (s: signature),
  forall_rpair (fun r => is_callee_save r = false) (loc_result s).
Proof.
  intros. unfold loc_result, loc_result_32, loc_result_64, is_callee_save;
  destruct Archi.ptr64; destruct (sig_res s) as [[]|]; simpl; auto.
Qed.

(** If the result is in a pair of registers, those registers are distinct and have type [Tint] at least. *)

Lemma loc_result_pair:
  forall sg,
  match loc_result sg with
  | One _ => True
  | Twolong r1 r2 =>
        r1 <> r2 /\ sg.(sig_res) = Some Tlong
     /\ subtype Tint (mreg_type r1) = true /\ subtype Tint (mreg_type r2) = true
     /\ Archi.ptr64 = false
  end.
Proof.
  intros; unfold loc_result, loc_result_32, loc_result_64, mreg_type;
  destruct Archi.ptr64; destruct (sig_res sg) as [[]|]; destruct Archi.ppc64; simpl; auto.
  split; auto. congruence.
  split; auto. congruence.
Qed.

(** The location of the result depends only on the result part of the signature *)

Lemma loc_result_exten:
  forall s1 s2, s1.(sig_res) = s2.(sig_res) -> loc_result s1 = loc_result s2.
Proof.
  intros. unfold loc_result, loc_result_32, loc_result_64.
  destruct Archi.ptr64; rewrite H; auto.
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
          (if Archi.ptr64
           then One (S Outgoing ofs Tlong)
           else Twolong (S Outgoing ofs Tint) (S Outgoing (ofs + 1) Tint)) ::
          loc_arguments_rec tys ir fr (ofs + 2)
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
  subst. destruct Archi.ptr64; [split|split;split]; try omega.
  apply align_divides; omega. apply Z.divide_1_l. apply Z.divide_1_l.
  eapply Y; eauto. omega.
  destruct H.
  subst. destruct Archi.ptr64; [split|split;split]; try omega.
  apply align_divides; omega. apply Z.divide_1_l. apply Z.divide_1_l.
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
                             ((if Archi.ptr64
                               then One (S Outgoing (align ofs0 2) Tlong)
                               else Twolong (S Outgoing (align ofs0 2) Tint)
                                            (S Outgoing (align ofs0 2 + 1) Tint))
                          :: loc_arguments_rec tyl ir' fr (align ofs0 2 + 2))) ->
    ofs + typesize ty <= size_arguments_rec tyl ir' fr (align ofs0 2 + 2)).
  { destruct Archi.ptr64; intros IN.
  - destruct IN. inv H1. apply size_arguments_rec_above. auto.
  - destruct IN. inv H1. transitivity (align ofs0 2 + 2). simpl; omega. apply size_arguments_rec_above.
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
