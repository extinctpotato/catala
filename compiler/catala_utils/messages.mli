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

(** Interface for emitting compiler messages *)

val debug_marker : Format.formatter -> unit -> unit
val error_marker : Format.formatter -> unit -> unit
val warning_marker : Format.formatter -> unit -> unit
val result_marker : Format.formatter -> unit -> unit
val log_marker : Format.formatter -> unit -> unit

(**{2 Printers}*)

(** All the printers below print their argument after the correct marker *)

val debug_print : ('a, Format.formatter, unit) format -> 'a
val debug_format : ('a, Format.formatter, unit) format -> 'a
val error_print : ('a, Format.formatter, unit) format -> 'a
val error_format : ('a, Format.formatter, unit) format -> 'a
val warning_print : ('a, Format.formatter, unit) format -> 'a
val warning_format : ('a, Format.formatter, unit) format -> 'a
val result_print : ('a, Format.formatter, unit) format -> 'a
val result_format : ('a, Format.formatter, unit) format -> 'a
val log_print : ('a, Format.formatter, unit) format -> 'a
val log_format : ('a, Format.formatter, unit) format -> 'a

(** {1 Message content} *)

type message_content
type content_type = Error | Warning | Debug | Log

val to_internal_error : message_content -> message_content

val emit_content : message_content -> content_type -> unit
(** This functions emits the message according to the emission type defined by
    [Cli.message_format_flag]. *)

(** {1 Error exception} *)

exception CompilerError of message_content

(** {1 Common error raising} *)

val raise_spanned_error :
  ?span_msg:string -> Pos.t -> ('a, Format.formatter, unit, 'b) format4 -> 'a

val raise_multispanned_error :
  (string option * Pos.t) list -> ('a, Format.formatter, unit, 'b) format4 -> 'a

val raise_error : ('a, Format.formatter, unit, 'b) format4 -> 'a
val raise_internal_error : ('a, Format.formatter, unit, 'b) format4 -> 'a

val assert_internal_error :
  bool -> ('a, Format.formatter, unit, unit, unit, unit) format6 -> 'a

(** {1 Common warning raising}*)

val emit_multispanned_warning :
  (string option * Pos.t) list -> ('a, Format.formatter, unit) format -> 'a

val emit_spanned_warning :
  ?span_msg:string -> Pos.t -> ('a, Format.formatter, unit) format -> 'a

val emit_warning : ('a, Format.formatter, unit) format -> 'a
