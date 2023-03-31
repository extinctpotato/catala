(* This file is part of the Catala compiler, a specification language for tax
   and social benefits computation rules. Copyright (C) 2023 Inria, contributor:
   Denis Merigoux <denis.merigoux@inria.fr>

   Licensed under the Apache License, Version 2.0 (the "License"); you may not
   use this file except in compliance with the License. You may obtain a copy of
   the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
   WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
   License for the specific language governing permissions and limitations under
   the License. *)

open Shared_ast
open Ast
open Catala_utils

(** If the variable is not an input, then it should be defined somewhere. *)
let detect_empty_definitions (p : program) : unit =
  ScopeName.Map.iter
    (fun (scope_name : ScopeName.t) scope ->
      ScopeDefMap.iter
        (fun scope_def_key scope_def ->
          if
            (match scope_def_key with ScopeDef.Var _ -> true | _ -> false)
            && RuleName.Map.is_empty scope_def.scope_def_rules
            && (not scope_def.scope_def_is_condition)
            &&
            match Marked.unmark scope_def.scope_def_io.io_input with
            | Ast.NoInput -> true
            | _ -> false
          then
            Errors.format_spanned_warning
              (ScopeDef.get_position scope_def_key)
              "The variable %a is declared but never defined in scope %a; did \
               you forget something?"
              (Cli.format_with_style [ANSITerminal.yellow])
              (Format.asprintf "\"%a\"" Ast.ScopeDef.format_t scope_def_key)
              (Cli.format_with_style [ANSITerminal.yellow])
              (Format.asprintf "\"%a\"" ScopeName.format_t scope_name))
        scope.scope_defs)
    p.program_scopes

let detect_unused_struct_fields (p : program) : unit =
  let struct_fields_used =
    Ast.fold_exprs
      ~f:(fun struct_fields_used e ->
        let rec structs_fields_used_expr e struct_fields_used =
          match Marked.unmark e with
          | EDStructAccess { name_opt = Some name; e = e_struct; field } ->
            let field =
              StructName.Map.find name
                (IdentName.Map.find field p.program_ctx.ctx_struct_fields)
            in
            StructField.Set.add field
              (structs_fields_used_expr e_struct struct_fields_used)
          | EStruct { name = _; fields } ->
            StructField.Map.fold
              (fun field e_field struct_fields_used ->
                StructField.Set.add field
                  (structs_fields_used_expr e_field struct_fields_used))
              fields struct_fields_used
          | _ -> Expr.deep_fold structs_fields_used_expr e struct_fields_used
        in
        structs_fields_used_expr e struct_fields_used)
      ~init:StructField.Set.empty p
  in
  let scope_out_structs_fields =
    ScopeName.Map.fold
      (fun _ out_struct acc ->
        ScopeVar.Map.fold
          (fun _ field acc -> StructField.Set.add field acc)
          out_struct.out_struct_fields acc)
      p.program_ctx.ctx_scopes StructField.Set.empty
  in
  StructName.Map.iter
    (fun s_name fields ->
      StructField.Map.iter
        (fun field _ ->
          if
            (not (StructField.Set.mem field struct_fields_used))
            && not (StructField.Set.mem field scope_out_structs_fields)
          then
            Errors.format_spanned_warning
              (snd (StructField.get_info field))
              "The field %a of struct %a is never used; maybe it's unnecessary?"
              (Cli.format_with_style [ANSITerminal.yellow])
              (Format.asprintf "\"%a\"" StructField.format_t field)
              (Cli.format_with_style [ANSITerminal.yellow])
              (Format.asprintf "\"%a\"" StructName.format_t s_name))
        fields)
    p.program_ctx.ctx_structs

let detect_unused_enum_constructors (p : program) : unit =
  let enum_constructors_used =
    Ast.fold_exprs
      ~f:(fun enum_constructors_used e ->
        let rec enum_constructors_used_expr e enum_constructors_used =
          match Marked.unmark e with
          | EInj { name = _; e = e_enum; cons } ->
            EnumConstructor.Set.add cons
              (enum_constructors_used_expr e_enum enum_constructors_used)
          | EMatch { e = e_match; name = _; cases } ->
            let enum_constructors_used =
              enum_constructors_used_expr e_match enum_constructors_used
            in
            EnumConstructor.Map.fold
              (fun cons e_cons enum_constructors_used ->
                EnumConstructor.Set.add cons
                  (enum_constructors_used_expr e_cons enum_constructors_used))
              cases enum_constructors_used
          | _ ->
            Expr.deep_fold enum_constructors_used_expr e enum_constructors_used
        in
        enum_constructors_used_expr e enum_constructors_used)
      ~init:EnumConstructor.Set.empty p
  in
  EnumName.Map.iter
    (fun e_name constructors ->
      EnumConstructor.Map.iter
        (fun constructor _ ->
          if not (EnumConstructor.Set.mem constructor enum_constructors_used)
          then
            Errors.format_spanned_warning
              (snd (EnumConstructor.get_info constructor))
              "The constructor %a of enumeration %a is never used; maybe it's \
               unnecessary?"
              (Cli.format_with_style [ANSITerminal.yellow])
              (Format.asprintf "\"%a\"" EnumConstructor.format_t constructor)
              (Cli.format_with_style [ANSITerminal.yellow])
              (Format.asprintf "\"%a\"" EnumName.format_t e_name))
        constructors)
    p.program_ctx.ctx_enums

let lint_program (p : program) : unit =
  detect_empty_definitions p;
  detect_unused_struct_fields p;
  detect_unused_enum_constructors p
