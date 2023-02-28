(* This file is part of the Catala compiler, a specification language for tax
   and social benefits computation rules. Copyright (C) 2020-2022 Inria,
   contributor: Alain Delaët-Tixeuil <alain.delaet--tixeuil@inria.fr>

   Licensed under the Apache License, Version 2.0 (the "License"); you may not
   use this file except in compliance with the License. You may obtain a copy of
   the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
   WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
   License for the specific language governing permissions and limitations under
   the License. *)

open Catala_utils
module D = Dcalc.Ast
module A = Ast

(** The main idea around this pass is to compile Dcalc to Lcalc without using
    [raise EmptyError] nor [try _ with EmptyError -> _]. To do so, we use the
    same technique as in rust or erlang to handle this kind of exceptions. Each
    [raise EmptyError] will be translated as [None] and each
    [try e1 with EmtpyError -> e2] as
    [match e1 with | None -> e2 | Some x -> x].

    When doing this naively, this requires to add matches and Some constructor
    everywhere. We apply here an other technique where we generate what we call
    `hoists`. Hoists are expression whom could minimally [raise EmptyError]. For
    instance in [let x = <e1, e2, ..., en| e_just :- e_cons> * 3 in x + 1], the
    sub-expression [<e1, e2, ..., en| e_just :- e_cons>] can produce an empty
    error. So we make a hoist with a new variable [y] linked to the Dcalc
    expression [<e1, e2, ..., en| e_just :- e_cons>], and we return as the
    translated expression [let x = y * 3 in x + 1].

    The compilation of expressions is found in the functions
    [translate_and_hoist ctx e] and [translate_expr ctx e]. Every
    option-generating expression when calling [translate_and_hoist] will be
    hoisted and later handled by the [translate_expr] function. Every other
    cases is found in the translate_and_hoist function.

    Problem arise when there is a function application. *)

open Shared_ast

type analysis_mark = {
  pos : Pos.t;
  ty : typ;
  unpure : bool;
  unpure_return : bool option;
}

(* voir sur papier pour voir si ça marche *)

type analysis_info = { unpure_info : bool; unpure_return : bool option }
(* type analysis_ctx = (dcalc, analysis_info) Var.Map.t *)

let make_new_mark (m : typed mark) ?(unpure_return = None) (unpure : bool) :
    analysis_mark =
  match m with
  | Typed m ->
    begin
      match Marked.unmark m.ty, unpure_return with
      | TArrow _, None ->
        Errors.raise_error
          "Internal Error: no pure/unpure return type commentary on a function."
      | _ -> ()
    end;
    { pos = m.pos; ty = m.ty; unpure; unpure_return }

(** [{
      type struct_ctx_analysis = bool StructField.Map.t StructName.Map.t
    }]

    [{ let rec detect_unpure_expr = assert false }]
    [{ let detect_unpure_scope_let = assert false }]
    [{ let detect_unpure_scope_body = assert false }]
    [{ let detect_unpure_scopes = assert false }]
    [{ let detect_unpure_program = assert false }]
    [{ let detect_unpure_scope_let = assert false }] *)
let rec detect_unpure_expr ctx (e : (dcalc, typed mark) gexpr) :
    (dcalc, analysis_mark) boxed_gexpr =
  let m = Marked.get_mark e in
  match Marked.unmark e with
  | EVar x ->
    (* we suppose we don't need any information on a variable containing a
       function, because the only place such variable [f] can appear is in a
       EApp {f; ...} position. Hence it will be matched elsewhere. This is kept
       by the following invariant: *)
    Errors.assert_internal_error
      (match Marked.unmark (Expr.ty e) with TArrow _ -> false | _ -> true)
      "The variable %a should not be a function in this context." Print.var x;
    Expr.make_var (Var.translate x)
      (make_new_mark m (Var.Map.find x ctx).unpure_info)
  | EAbs { binder; tys } ->
    let vars, body = Bindlib.unmbind binder in
    let body' = detect_unpure_expr ctx body in
    let binder' = Expr.bind (Array.map Var.translate vars) body' in
    (* eabs is a value, hence is always pure. However, it is possible the
       function returns something that is pure. In this case the information
       needs to be backpropagated somewhere. *)
    Expr.eabs binder' tys
      (make_new_mark m false
         ~unpure_return:(Some (Marked.get_mark body').unpure))
  | EDefault { excepts; just; cons } ->
    let excepts' = List.map (detect_unpure_expr ctx) excepts in
    let just' = detect_unpure_expr ctx just in
    let cons' = detect_unpure_expr ctx cons in
    (* because of the structural invariant, there is no functions inside an
       default. Hence, there is no need for any verification here. *)
    Expr.edefault excepts' just' cons' (make_new_mark m true)
  | ELit l ->
    Expr.elit l
      (make_new_mark m (match l with LEmptyError -> true | _ -> false))
  | EErrorOnEmpty arg ->
    let arg' = detect_unpure_expr ctx arg in
    (* the result is always pure *)
    Expr.eerroronempty arg' (make_new_mark m false)
  | EApp { f = (EVar x, _) as f; args } ->
    let args' = List.map (detect_unpure_expr ctx) args in
    let unpure =
      args'
      |> List.map (fun arg -> (Marked.get_mark arg).unpure)
      |> List.fold_left ( || ) false
      |> ( || ) (Var.Map.find x ctx).unpure_info
    in
    let f' = detect_unpure_expr ctx f in
    if Option.get (Var.Map.find x ctx).unpure_return then
      Expr.eapp f' args' (make_new_mark m (true || unpure))
    else Expr.eapp f' args' (make_new_mark m unpure)
  | EApp { f = (EAbs _, _) as f; args } ->
    let f' = detect_unpure_expr ctx f in
    let args' = List.map (detect_unpure_expr ctx) args in
    let unpure =
      args'
      |> List.map (fun arg -> (Marked.get_mark arg).unpure)
      |> List.fold_left ( || ) false
      |> ( || ) (Marked.get_mark f').unpure
      ||
      match (Marked.get_mark f').unpure_return with
      | None ->
        Errors.raise_internal_error
          "A function has no information on whenever it is empty or not"
      | Some unpure_return -> unpure_return
    in
    Expr.eapp f' args' (make_new_mark m unpure)
  | EApp { f = EApp { f = EOp { op = Op.Log _; _ }, _; args = _ }, _; _ } ->
    assert false
  | EApp { f = EStructAccess _, _; _ } -> assert false
  (* Now operator application. Those come in multiple shape and forms: either
     the operator is an EOp, or it is an array, ifthenelse, struct, inj, match,
     structAccess, tuple, tupleAccess, Assert.

     Note that for the moment, we consider the ifthenelse an normal if then
     else, and not the selective applicative functor corresponding. *)
  | EApp { f = EOp { op; tys }, opmark; args } ->
    let args' = List.map (detect_unpure_expr ctx) args in
    let unpure =
      args'
      |> List.map (fun arg -> (Marked.get_mark arg).unpure)
      |> List.fold_left ( || ) false
    in
    Expr.eapp
      (Expr.eop op tys (make_new_mark opmark true))
      args' (make_new_mark m unpure)
  | EArray args ->
    let args = List.map (detect_unpure_expr ctx) args in
    let unpure =
      args
      |> List.map (fun arg -> (Marked.get_mark arg).unpure)
      |> List.fold_left ( || ) false
    in
    Expr.earray args (make_new_mark m unpure)
  | EStruct { name; fields } ->
    let fields = StructField.Map.map (detect_unpure_expr ctx) fields in
    let unpure =
      fields
      |> StructField.Map.map (fun field -> (Marked.get_mark field).unpure)
      |> fun ctx -> StructField.Map.fold (fun _ -> ( || )) ctx false
    in
    Expr.estruct name fields (make_new_mark m unpure)
  | EIfThenElse { cond; etrue; efalse } ->
    let cond = detect_unpure_expr ctx cond in
    let etrue = detect_unpure_expr ctx etrue in
    let efalse = detect_unpure_expr ctx efalse in
    let unpure =
      [cond; etrue; efalse]
      |> List.map (fun arg -> (Marked.get_mark arg).unpure)
      |> List.fold_left ( || ) false
    in
    Expr.eifthenelse cond etrue efalse (make_new_mark m unpure)
  | EInj { name; e; cons } ->
    let e = detect_unpure_expr ctx e in
    let unpure = (Marked.get_mark e).unpure in
    Expr.einj e cons name (make_new_mark m unpure)
  | EMatch { name; e; cases } ->
    let e = detect_unpure_expr ctx e in
    let cases = EnumConstructor.Map.map (detect_unpure_expr ctx) cases in
    let unpure =
      e :: List.map snd (EnumConstructor.Map.bindings cases)
      |> List.map (fun arg -> (Marked.get_mark arg).unpure)
      |> List.fold_left ( || ) false
    in
    Expr.ematch e name cases (make_new_mark m unpure)
  | EStructAccess { name; e; field } ->
    let e = detect_unpure_expr ctx e in
    let unpure = (Marked.get_mark e).unpure in
    Expr.estructaccess e field name (make_new_mark m unpure)
  | ETuple args ->
    let args = List.map (detect_unpure_expr ctx) args in
    let unpure =
      args
      |> List.map (fun arg -> (Marked.get_mark arg).unpure)
      |> List.fold_left ( || ) false
    in
    Expr.etuple args (make_new_mark m unpure)
  | ETupleAccess { e; index; size } ->
    let e = detect_unpure_expr ctx e in
    let unpure = (Marked.get_mark e).unpure in
    Expr.etupleaccess e index size (make_new_mark m unpure)
  | EAssert e ->
    let e = detect_unpure_expr ctx e in
    let unpure = (Marked.get_mark e).unpure in
    Expr.eassert e (make_new_mark m unpure)
  (* Those cases should not happend because of the structural invariant on the
     structure of the ast at this point. *)
  | EApp _ -> assert false (* invalid invariant *)
  | EOp _ -> assert false (* invalid invariant *)

let _ = detect_unpure_expr

type 'm hoists = ('m A.expr, 'm D.expr) Var.Map.t
(** Hoists definition. It represent bindings between [A.Var.t] and [D.expr]. *)

type 'm info = { expr : 'm A.expr boxed; var : 'm A.expr Var.t; is_pure : bool }
(** Information about each encontered Dcalc variable is stored inside a context
    : what is the corresponding LCalc variable; an expression corresponding to
    the variable build correctly using Bindlib, and a boolean `is_pure`
    indicating whenever the variable can be an EmptyError and hence should be
    matched (false) or if it never can be EmptyError (true). *)

let pp_info (fmt : Format.formatter) (info : 'm info) =
  Format.fprintf fmt "{var: %a; is_pure: %b}" Print.var info.var info.is_pure

type 'm ctx = {
  decl_ctx : decl_ctx;
  vars : ('m D.expr, 'm info) Var.Map.t;
      (** information context about variables in the current scope *)
}

let _pp_ctx (fmt : Format.formatter) (ctx : 'm ctx) =
  let pp_binding
      (fmt : Format.formatter)
      ((v, info) : 'm D.expr Var.t * 'm info) =
    Format.fprintf fmt "%a: %a" Print.var v pp_info info
  in

  let pp_bindings =
    Format.pp_print_list
      ~pp_sep:(fun fmt () -> Format.pp_print_string fmt "; ")
      pp_binding
  in

  Format.fprintf fmt "@[<2>[%a]@]" pp_bindings (Var.Map.bindings ctx.vars)

(** [find ~info n ctx] is a warpper to ocaml's Map.find that handle errors in a
    slightly better way. *)
let find ?(info : string = "none") (n : 'm D.expr Var.t) (ctx : 'm ctx) :
    'm info =
  try Var.Map.find n ctx.vars
  with Not_found ->
    Errors.raise_spanned_error Pos.no_pos
      "Internal Error: Variable %a was not found in the current environment. \
       Additional informations : %s."
      Print.var n info

(** [add_var pos var is_pure ctx] add to the context [ctx] the Dcalc variable
    var, creating a unique corresponding variable in Lcalc, with the
    corresponding expression, and the boolean is_pure. It is usefull for
    debuging purposes as it printing each of the Dcalc/Lcalc variable pairs. *)
let add_var
    (mark : 'm mark)
    (var : 'm D.expr Var.t)
    (is_pure : bool)
    (ctx : 'm ctx) : 'm ctx =
  let new_var = Var.make (Bindlib.name_of var) in
  let expr = Expr.make_var new_var mark in

  {
    ctx with
    vars =
      Var.Map.update var
        (fun _ -> Some { expr; var = new_var; is_pure })
        ctx.vars;
  }

(** [tau' = translate_typ tau] translate the a dcalc type into a lcalc type.

    Since positions where there is thunked expressions is exactly where we will
    put option expressions. Hence, the transformation simply reduce [unit -> 'a]
    into ['a option] recursivly. There is no polymorphism inside catala. *)
let rec translate_typ (tau : typ) : typ =
  (Fun.flip Marked.same_mark_as)
    tau
    begin
      match Marked.unmark tau with
      | TLit l -> TLit l
      | TTuple ts -> TTuple (List.map translate_typ ts)
      | TStruct s -> TStruct s
      | TEnum en -> TEnum en
      | TOption _ -> assert false
      | TAny -> TAny
      | TArray ts -> TArray (translate_typ ts)
      (* catala is not polymorphic *)
      | TArrow ([(TLit TUnit, _)], t2) -> TOption (translate_typ t2)
      | TArrow (t1, t2) -> TArrow (List.map translate_typ t1, translate_typ t2)
    end

(** [c = disjoint_union_maps cs] Compute the disjoint union of multiple maps.
    Raises an internal error if there is two identicals keys in differnts parts. *)
let disjoint_union_maps (pos : Pos.t) (cs : ('e, 'a) Var.Map.t list) :
    ('e, 'a) Var.Map.t =
  let disjoint_union =
    Var.Map.union (fun _ _ _ ->
        Errors.raise_spanned_error pos
          "Internal Error: Two supposed to be disjoints maps have one shared \
           key.")
  in

  List.fold_left disjoint_union Var.Map.empty cs

(** [e' = translate_and_hoist ctx e ] Translate the Dcalc expression e into an
    expression in Lcalc, given we translate each hoists correctly. It ensures
    the equivalence between the execution of e and the execution of e' are
    equivalent in an environement where each variable v, where (v, e_v) is in
    hoists, has the non-empty value in e_v. *)
let rec translate_and_hoist (ctx : 'm ctx) (e : 'm D.expr) :
    'm A.expr boxed * 'm hoists =
  Cli.debug_format "%a" (Print.expr_debug ~debug:false) e;
  let mark = Marked.get_mark e in
  let pos = Expr.mark_pos mark in
  match Marked.unmark e with
  (* empty-producing/using terms. We hoist those. (D.EVar in some cases,
     EApp(D.EVar _, [ELit LUnit]), EDefault _, ELit LEmptyDefault) I'm unsure
     about assert. *)
  | EVar v ->
    (* todo: for now, every unpure (such that [is_pure] is [false] in the
       current context) is thunked, hence matched in the next case. This
       assumption can change in the future, and this case is here for this
       reason. *)
    if not (find ~info:"search for a variable" v ctx).is_pure then
      let v' = Var.make (Bindlib.name_of v) in
      (* Cli.debug_print @@ Format.asprintf "Found an unpure variable %a,
         created a variable %a to replace it" Print.var v Print.var v'; *)
      Expr.make_var v' mark, Var.Map.singleton v' e
    else (find ~info:"should never happen" v ctx).expr, Var.Map.empty
  | EApp { f = EVar v, p; args = [(ELit LUnit, _)] } ->
    if not (find ~info:"search for a variable" v ctx).is_pure then
      let v' = Var.make (Bindlib.name_of v) in
      (* Cli.debug_print @@ Format.asprintf "Found an unpure variable %a,
         created a variable %a to replace it" Print.var v Print.var v'; *)
      Expr.make_var v' mark, Var.Map.singleton v' (EVar v, p)
    else
      Errors.raise_spanned_error (Expr.pos e)
        "Internal error: an pure variable was found in an unpure environment."
  | EDefault _ ->
    let v' = Var.make "default_term" in
    Expr.make_var v' mark, Var.Map.singleton v' e
  | ELit LEmptyError ->
    let v' = Var.make "empty_litteral" in
    Expr.make_var v' mark, Var.Map.singleton v' e
  (* This one is a very special case. It transform an unpure expression
     environement to a pure expression. *)
  | EErrorOnEmpty arg ->
    (* [ match arg with | None -> raise NoValueProvided | Some v -> {{ v }} ] *)
    let silent_var = Var.make "_" in
    let x = Var.make "non_empty_argument" in

    let arg' = translate_expr ctx arg in
    let rty = Expr.maybe_ty mark in

    ( A.make_matchopt_with_abs_arms arg'
        (Expr.make_abs [| silent_var |]
           (Expr.eraise NoValueProvided (Expr.with_ty mark rty))
           [rty] pos)
        (Expr.make_abs [| x |] (Expr.make_var x mark) [rty] pos),
      Var.Map.empty )
  (* pure terms *)
  | ELit
      ((LBool _ | LInt _ | LRat _ | LMoney _ | LUnit | LDate _ | LDuration _) as
      l) ->
    Expr.elit l mark, Var.Map.empty
  | EIfThenElse { cond; etrue; efalse } ->
    let cond', h1 = translate_and_hoist ctx cond in
    let etrue', h2 = translate_and_hoist ctx etrue in
    let efalse', h3 = translate_and_hoist ctx efalse in

    let e' = Expr.eifthenelse cond' etrue' efalse' mark in

    (*(* equivalent code : *) let e' = let+ cond' = cond' and+ etrue' = etrue'
      and+ efalse' = efalse' in (A.EIfThenElse (cond', etrue', efalse'), pos)
      in *)
    e', disjoint_union_maps (Expr.pos e) [h1; h2; h3]
  | EAssert e1 ->
    (* same behavior as in the ICFP paper: if e1 is empty, then no error is
       raised. *)
    let e1', h1 = translate_and_hoist ctx e1 in
    Expr.eassert e1' mark, h1
  | EAbs { binder; tys } ->
    let vars, body = Bindlib.unmbind binder in
    let ctx, lc_vars =
      ArrayLabels.fold_right vars ~init:(ctx, []) ~f:(fun var (ctx, lc_vars) ->
          (* We suppose the invariant that when applying a function, its
             arguments cannot be of the type "option".

             The code should behave correctly in the without this assumption if
             we put here an is_pure=false, but the types are more compilcated.
             (unimplemented for now) *)
          let ctx = add_var mark var true ctx in
          let lc_var = (find var ctx).var in
          ctx, lc_var :: lc_vars)
    in
    let lc_vars = Array.of_list lc_vars in

    (* Even if abstractions cannot have unpure arguments, it is possible its
       returns unpure values. For instance, the term $fun x -> <|x > 0 :- x>$ is
       valid and appear in the basecode. Hence, we need to translate it using
       the transalte_expr function. This is linked to a more complex handling of
       the EApp case. *)
    let new_body = translate_expr ctx body in
    let new_binder = Expr.bind lc_vars new_body in

    Expr.eabs new_binder (List.map translate_typ tys) mark, Var.Map.empty
  | EApp { f = EAbs { binder; tys }, varmark; args }
    when Bindlib.mbinder_arity binder = 1 && List.length args = 1 ->
    (* let bindings *)
    let vars, body = Bindlib.unmbind binder in
    let var =
      match vars with
      | [| var |] -> var
      | _ ->
        Errors.raise_error
          "Internal Error: found a let binding with variable arity different \
           than one."
    in

    let var' : (lcalc, 'm mark) naked_gexpr Bindlib.var =
      Var.make (Bindlib.name_of var)
    in
    let arg =
      match args with
      | [arg] -> arg
      | _ ->
        Errors.raise_error
          "Internal Error: found a let binding with argument arity different \
           to one."
    in
    let ty =
      match tys with
      | [ty] -> ty
      | _ ->
        Errors.raise_error
          "Internal Error: found a let binding with type arity different to \
           one."
    in

    (* [let var: ty = arg in body]*)

    (* translation depends on whenever arg can return empty. To not make things
       more complicated, we just translate it as an expression and match the
       result. *)
    let arg' = translate_expr ctx arg in
    let ctx' = add_var varmark var true ctx in
    let body' = translate_expr ctx' body in

    (* type is unchanged *)
    Expr.make_let_in var' ty arg' body' (Expr.mark_pos varmark), Var.Map.empty
  | EApp { f; args } -> begin
    match Marked.unmark f with
    | EOp _ ->
      let f', h1 = translate_and_hoist ctx f in
      let args', h_args =
        args |> List.map (translate_and_hoist ctx) |> List.split
      in
      let hoists = disjoint_union_maps (Expr.pos e) (h1 :: h_args) in
      Expr.eapp f' args' mark, hoists
    | _ ->
      let v' = Var.make "function_application" in
      Expr.make_var v' mark, Var.Map.singleton v' e
  end
  | EStruct { name; fields } ->
    let fields', h_fields =
      StructField.Map.fold
        (fun field e (fields, hoists) ->
          let e, h = translate_and_hoist ctx e in
          StructField.Map.add field e fields, h :: hoists)
        fields
        (StructField.Map.empty, [])
    in
    let hoists = disjoint_union_maps (Expr.pos e) h_fields in
    Expr.estruct name fields' mark, hoists
  | EStructAccess { name; e = e1; field } ->
    let e1', hoists = translate_and_hoist ctx e1 in
    let e1' = Expr.estructaccess e1' field name mark in
    e1', hoists
  | ETuple es ->
    let hoists, es' =
      List.fold_left_map
        (fun hoists e ->
          let e, h = translate_and_hoist ctx e in
          h :: hoists, e)
        [] es
    in
    Expr.etuple es' mark, disjoint_union_maps (Expr.pos e) hoists
  | ETupleAccess { e = e1; index; size } ->
    let e1', hoists = translate_and_hoist ctx e1 in
    let e1' = Expr.etupleaccess e1' index size mark in
    e1', hoists
  | EInj { name; e = e1; cons } ->
    let e1', hoists = translate_and_hoist ctx e1 in
    let e1' = Expr.einj e1' cons name mark in
    e1', hoists
  | EMatch { name; e = e1; cases } ->
    (* The current encoding of matches is e with an expression, that will be
       deconstructed and a series of cases. Each cases is an key constructor and
       a expression that contains a lambda expression. Hence the following
       encoding is correct: hoist each branches & the destructed expression. *)
    let e1', h1 = translate_and_hoist ctx e1 in
    let cases', h_cases =
      EnumConstructor.Map.fold
        (fun cons e (cases, hoists) ->
          let e', h = translate_and_hoist ctx e in
          EnumConstructor.Map.add cons e' cases, h :: hoists)
        cases
        (EnumConstructor.Map.empty, [])
    in
    let hoists = disjoint_union_maps (Expr.pos e) (h1 :: h_cases) in
    let e' = Expr.ematch e1' name cases' mark in
    e', hoists
  | EArray es ->
    let es', hoists = es |> List.map (translate_and_hoist ctx) |> List.split in

    Expr.earray es' mark, disjoint_union_maps (Expr.pos e) hoists
  | EOp { op; tys } -> Expr.eop (Operator.translate op) tys mark, Var.Map.empty

and translate_hoists ~append_esome ctx hoists kont =
  ListLabels.fold_left hoists
    ~init:(if append_esome then A.make_some kont else kont)
    ~f:(fun acc (v, (hoist, mark_hoist)) ->
      (* Cli.debug_print @@ Format.asprintf "hoist using A.%a" Print.var v; *)
      let pos = Expr.mark_pos mark_hoist in
      let c' : 'm A.expr boxed =
        match hoist with
        (* Here we have to handle only the cases appearing in hoists, as defined
           the [translate_and_hoist] function. *)
        | EVar v -> (find ~info:"should never happen" v ctx).expr
        | EDefault { excepts; just; cons } ->
          let excepts' = List.map (translate_expr ctx) excepts in
          let just' = translate_expr ctx just in
          let cons' = translate_expr ctx cons in
          (* calls handle_option. *)
          Cli.debug_format "building_default %a"
            (Print.expr_debug ~debug:false)
            (Marked.mark mark_hoist hoist);
          let new_mark : typed mark =
            match mark_hoist with Typed m -> Typed { m with ty = TAny, pos }
          in
          Expr.make_app ~decl_ctx:(Some ctx.decl_ctx)
            (Expr.make_var (Var.translate A.handle_default_opt) new_mark)
            [Expr.earray excepts' new_mark; just'; cons']
            pos
        | ELit LEmptyError -> A.make_none mark_hoist
        | EApp { f; args } ->
          let f = translate_expr ctx f in
          let args = List.map (translate_expr ctx) args in

          (* let*m args' = args' and* f' = f' in f' args' *)
          Cli.debug_format "building_app %a"
            (Print.expr_debug ~debug:false)
            (Marked.mark mark_hoist hoist);

          A.make_bind_cont mark_hoist f (fun f ->
              A.make_bindm_cont mark_hoist args (fun args ->
                  Expr.make_app ~decl_ctx:(Some ctx.decl_ctx) f args pos
                  (* A.make_bind_cont mark_hosit (Expr.make_app f args pos) *)))
          (* assert false *)
        | EAssert arg ->
          let arg' = translate_expr ctx arg in

          (* [ match arg with | None -> raise NoValueProvided | Some v -> assert
             {{ v }} ] *)
          let silent_var = Var.make "_" in
          let x = Var.make "assertion_argument" in

          A.make_matchopt_with_abs_arms arg'
            (Expr.make_abs [| silent_var |]
               (Expr.eraise NoValueProvided mark_hoist)
               [TAny, Expr.mark_pos mark_hoist]
               pos)
            (Expr.make_abs [| x |]
               (Expr.eassert (Expr.make_var x mark_hoist) mark_hoist)
               [TAny, Expr.mark_pos mark_hoist]
               pos)
        | _ ->
          Errors.raise_spanned_error (Expr.mark_pos mark_hoist)
            "Internal Error: An term was found in a position where it should \
             not be"
      in

      A.make_matchopt pos v
        (TAny, Expr.mark_pos mark_hoist)
        c' (A.make_none mark_hoist) acc)

and translate_expr ?(append_esome = true) (ctx : 'm ctx) (e : 'm D.expr) :
    'm A.expr boxed =
  let e', hoists = translate_and_hoist ctx e in
  let hoists = Var.Map.bindings hoists in

  let _pos = Marked.get_mark e in

  (* build the hoists *)
  (* Cli.debug_print @@ Format.asprintf "hoist for the expression: [%a]"
     (Format.pp_print_list Print.var) (List.map fst hoists); *)
  translate_hoists ~append_esome ctx hoists e'

let rec translate_scope_let (ctx : 'm ctx) (lets : 'm D.expr scope_body_expr) :
    'm A.expr scope_body_expr Bindlib.box =
  match lets with
  | Result e ->
    Bindlib.box_apply
      (fun e -> Result e)
      (Expr.Box.lift (translate_expr ~append_esome:false ctx e))
  | ScopeLet
      {
        scope_let_kind = SubScopeVarDefinition;
        scope_let_typ = typ;
        scope_let_expr = EAbs { binder; _ }, emark;
        scope_let_next = next;
        scope_let_pos = pos;
      } ->
    (* special case : the subscope variable is thunked (context i/o). We remove
       this thunking. *)
    let _, expr = Bindlib.unmbind binder in

    let var_is_pure = true in
    let var, next = Bindlib.unbind next in
    (* Cli.debug_print @@ Format.asprintf "unbinding %a" Print.var var; *)
    let vmark = Expr.with_ty emark ~pos typ in
    let ctx' = add_var vmark var var_is_pure ctx in
    let new_var = (find ~info:"variable that was just created" var ctx').var in
    let new_next = translate_scope_let ctx' next in
    Bindlib.box_apply2
      (fun new_expr new_next ->
        ScopeLet
          {
            scope_let_kind = SubScopeVarDefinition;
            scope_let_typ = translate_typ typ;
            scope_let_expr = new_expr;
            scope_let_next = new_next;
            scope_let_pos = pos;
          })
      (Expr.Box.lift (translate_expr ctx ~append_esome:false expr))
      (Bindlib.bind_var new_var new_next)
  | ScopeLet
      {
        scope_let_kind = SubScopeVarDefinition;
        scope_let_typ = typ;
        scope_let_expr = (EErrorOnEmpty _, emark) as expr;
        scope_let_next = next;
        scope_let_pos = pos;
      } ->
    (* special case: regular input to the subscope *)
    let var_is_pure = true in
    let var, next = Bindlib.unbind next in
    (* Cli.debug_print @@ Format.asprintf "unbinding %a" Print.var var; *)
    let vmark = Expr.with_ty emark ~pos typ in
    let ctx' = add_var vmark var var_is_pure ctx in
    let new_var = (find ~info:"variable that was just created" var ctx').var in
    Bindlib.box_apply2
      (fun new_expr new_next ->
        ScopeLet
          {
            scope_let_kind = SubScopeVarDefinition;
            scope_let_typ = translate_typ typ;
            scope_let_expr = new_expr;
            scope_let_next = new_next;
            scope_let_pos = pos;
          })
      (Expr.Box.lift (translate_expr ctx ~append_esome:false expr))
      (Bindlib.bind_var new_var (translate_scope_let ctx' next))
  | ScopeLet
      {
        scope_let_kind = SubScopeVarDefinition;
        scope_let_pos = pos;
        scope_let_expr = expr;
        _;
      } ->
    Errors.raise_spanned_error pos
      "Internal Error: found an SubScopeVarDefinition that does not satisfy \
       the invariants when translating Dcalc to Lcalc without exceptions: \
       @[<hov 2>%a@]"
      (Expr.format ctx.decl_ctx) expr
  | ScopeLet
      {
        scope_let_kind = kind;
        scope_let_typ = typ;
        scope_let_expr = expr;
        scope_let_next = next;
        scope_let_pos = pos;
      } ->
    let var_is_pure =
      match kind with
      | DestructuringInputStruct -> (
        (* Here, we have to distinguish between context and input variables. We
           can do so by looking at the typ of the destructuring: if it's
           thunked, then the variable is context. If it's not thunked, it's a
           regular input. *)
        match Marked.unmark typ with
        | TArrow ([(TLit TUnit, _)], _) -> false
        | _ -> true)
      | ScopeVarDefinition | SubScopeVarDefinition | CallingSubScope
      | DestructuringSubScopeResults | Assertion ->
        true
    in
    let var, next = Bindlib.unbind next in
    (* Cli.debug_print @@ Format.asprintf "unbinding %a" Print.var var; *)
    let vmark = Expr.with_ty (Marked.get_mark expr) ~pos typ in
    let ctx' = add_var vmark var var_is_pure ctx in
    let new_var = (find ~info:"variable that was just created" var ctx').var in
    Bindlib.box_apply2
      (fun new_expr new_next ->
        ScopeLet
          {
            scope_let_kind = kind;
            scope_let_typ = translate_typ typ;
            scope_let_expr = new_expr;
            scope_let_next = new_next;
            scope_let_pos = pos;
          })
      (Expr.Box.lift (translate_expr ctx ~append_esome:false expr))
      (Bindlib.bind_var new_var (translate_scope_let ctx' next))

let translate_scope_body
    (scope_pos : Pos.t)
    (ctx : 'm ctx)
    (body : typed D.expr scope_body) : 'm A.expr scope_body Bindlib.box =
  match body with
  | {
   scope_body_expr = result;
   scope_body_input_struct = input_struct;
   scope_body_output_struct = output_struct;
  } ->
    let v, lets = Bindlib.unbind result in
    let vmark =
      let m =
        match lets with
        | Result e | ScopeLet { scope_let_expr = e; _ } -> Marked.get_mark e
      in
      Expr.map_mark (fun _ -> scope_pos) (fun ty -> ty) m
    in
    let ctx' = add_var vmark v true ctx in
    let v' = (find ~info:"variable that was just created" v ctx').var in
    Bindlib.box_apply
      (fun new_expr ->
        {
          scope_body_expr = new_expr;
          scope_body_input_struct = input_struct;
          scope_body_output_struct = output_struct;
        })
      (Bindlib.bind_var v' (translate_scope_let ctx' lets))

let translate_code_items (ctx : 'm ctx) (scopes : 'm D.expr code_item_list) :
    'm A.expr code_item_list Bindlib.box =
  let _ctx, scopes =
    Scope.fold_map
      ~f:
        (fun ctx var -> function
          | Topdef (name, ty, e) ->
            ( add_var (Marked.get_mark e) var true ctx,
              Bindlib.box_apply
                (fun e -> Topdef (name, ty, e))
                (Expr.Box.lift (translate_expr ~append_esome:false ctx e)) )
          | ScopeDef (scope_name, scope_body) ->
            ( ctx,
              let scope_pos = Marked.get_mark (ScopeName.get_info scope_name) in
              Bindlib.box_apply
                (fun body -> ScopeDef (scope_name, body))
                (translate_scope_body scope_pos ctx scope_body) ))
      ~varf:Var.translate ctx scopes
  in
  scopes

let translate_program (prgm : typed D.program) : 'm A.program =
  let inputs_structs =
    Scope.fold_left prgm.code_items ~init:[] ~f:(fun acc def _ ->
        match def with
        | ScopeDef (_, body) -> body.scope_body_input_struct :: acc
        | Topdef _ -> acc)
  in
  (* Cli.debug_print @@ Format.asprintf "List of structs to modify: [%a]"
     (Format.pp_print_list D.StructName.format_t) inputs_structs; *)
  let decl_ctx =
    {
      prgm.decl_ctx with
      ctx_enums =
        prgm.decl_ctx.ctx_enums
        |> EnumName.Map.add A.option_enum A.option_enum_config;
    }
  in
  let decl_ctx =
    {
      decl_ctx with
      ctx_structs =
        prgm.decl_ctx.ctx_structs
        |> StructName.Map.mapi (fun n str ->
               if List.mem n inputs_structs then
                 StructField.Map.map translate_typ str
                 (* Cli.debug_print @@ Format.asprintf "Input type: %a"
                    (Print.typ decl_ctx) tau; Cli.debug_print @@ Format.asprintf
                    "Output type: %a" (Print.typ decl_ctx) (translate_typ
                    tau); *)
               else str);
    }
  in

  let _code_items =
    Bindlib.unbox
      (translate_code_items { decl_ctx; vars = Var.Map.empty } prgm.code_items)
  in
  assert false
