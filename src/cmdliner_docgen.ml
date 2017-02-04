(*---------------------------------------------------------------------------
   Copyright (c) 2011 Daniel C. Bünzli. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
   %%NAME%% %%VERSION%%
  ---------------------------------------------------------------------------*)

let rev_compare n0 n1 = compare n1 n0

let strf = Printf.sprintf

let esc = Cmdliner_manpage.markup_text_escape
let term_name t = esc @@ Cmdliner_info.term_name t

let sorted_items_to_blocks ~boilerplate:b items =
  (* Items are sorted by section and then rev. sorted by appearance.
     We gather them by section in correct order in a `Block and prefix
     them with optional boilerplate *)
  let boilerplate = match b with None -> (fun _ -> None) | Some b -> b in
  let mk_block sec acc = match boilerplate sec with
  | None -> (sec, `Blocks acc)
  | Some b -> (sec, `Blocks (b :: acc))
  in
  let rec loop secs sec acc = function
  | (sec', it) :: its when sec' = sec -> loop secs sec (it :: acc) its
  | (sec', it) :: its -> loop (mk_block sec acc :: secs) sec' [it] its
  | [] -> (mk_block sec acc) :: secs
  in
  match items with
  | [] -> []
  | (sec, it) :: its -> loop [] sec [it] its

(* Doc string variables substitutions. *)

let term_info_subst ei = function
| "tname" -> Some (strf "$(b,%s)" @@ term_name (Cmdliner_info.eval_term ei))
| "mname" -> Some (strf "$(b,%s)" @@ term_name (Cmdliner_info.eval_main ei))
| _ -> None

let arg_info_subst ~subst a = function
| "docv" ->
    Some (strf "$(i,%s)" @@ esc (Cmdliner_info.arg_docv a))
| "opt" when Cmdliner_info.arg_is_opt a ->
    Some (strf "$(b,%s)" @@ esc (Cmdliner_info.arg_opt_name_sample a))
| "env" as id ->
    begin match Cmdliner_info.arg_env a with
    | Some e -> Some (strf "$(b,%s)" @@ esc (Cmdliner_info.env_var e))
    | None -> subst id
    end
| id -> subst id

(* Command docs *)

let invocation ?(sep = ' ') ei = match Cmdliner_info.eval_kind ei with
| `Simple | `Multiple_main -> term_name (Cmdliner_info.eval_main ei)
| `Multiple_sub ->
    strf "%s%c%s"
      Cmdliner_info.(term_name @@ eval_main ei) sep
      Cmdliner_info.(term_name @@ eval_term ei)

let plain_invocation ei = invocation ei
let invocation ?sep ei = esc @@ invocation ?sep ei

let synopsis_pos_arg a =
  let v = match Cmdliner_info.arg_docv a with "" -> "ARG" | v -> v in
  let v = strf "$(i,%s)" (esc v) in
  let v = (if Cmdliner_info.arg_is_req a then strf "%s" else strf "[%s]") v in
  match Cmdliner_info.(pos_len @@ arg_pos a) with
  | None -> v ^ "..."
  | Some 1 -> v
  | Some n ->
      let rec loop n acc = if n <= 0 then acc else loop (n - 1) (v :: acc) in
      String.concat " " (loop n [])

let synopsis ei = match Cmdliner_info.eval_kind ei with
| `Multiple_main -> strf "$(b,%s) $(i,COMMAND) ..." @@ invocation ei
| `Simple | `Multiple_sub ->
    let rev_cli_order (a0, _) (a1, _) =
      Cmdliner_info.rev_arg_pos_cli_order a0 a1
    in
    let add_pos acc a = match Cmdliner_info.arg_is_opt a with
    | true -> acc
    | false -> (a, synopsis_pos_arg a) :: acc
    in
    let pargs = List.fold_left add_pos [] (Cmdliner_info.eval_term_args ei) in
    let pargs = List.sort rev_cli_order pargs in
    let pargs = String.concat " " (List.rev_map snd pargs) in
    strf "$(b,%s) [$(i,OPTION)]... %s" (invocation ei) pargs

let cmd_man_docs ei = match Cmdliner_info.eval_kind ei with
| `Simple | `Multiple_sub -> []
| `Multiple_main ->
    let add_cmd acc (ti, _) =
      let cmd = strf "$(b,%s)" @@ term_name ti in
      (Cmdliner_info.term_docs ti, `I (cmd, Cmdliner_info.term_doc ti)) :: acc
    in
    let by_sec_by_rev_name (s0, `I (c0, _)) (s1, `I (c1, _)) =
      let c = compare s0 s1 in
      if c <> 0 then c else compare c1 c0 (* N.B. reverse *)
    in
    let cmds = List.fold_left add_cmd [] (Cmdliner_info.eval_choices ei) in
    let cmds = List.sort by_sec_by_rev_name cmds in
    let cmds = (cmds :> (string * Cmdliner_manpage.block) list) in
    sorted_items_to_blocks ~boilerplate:None cmds

(* Argument docs *)

let arg_man_item_label a =
  if Cmdliner_info.arg_is_pos a
  then strf "$(i,%s)" (esc @@ Cmdliner_info.arg_docv a) else
  let fmt_name var = match Cmdliner_info.arg_opt_kind a with
  | Cmdliner_info.Flag -> fun n -> strf "$(b,%s)" (esc n)
  | Cmdliner_info.Opt ->
      fun n ->
        if String.length n > 2
        then strf "$(b,%s)=$(i,%s)" (esc n) (esc var)
        else strf "$(b,%s) $(i,%s)" (esc n) (esc var)
  | Cmdliner_info.Opt_vopt _ ->
      fun n ->
        if String.length n > 2
        then strf "$(b,%s)[=$(i,%s)]" (esc n) (esc var)
        else strf "$(b,%s) [$(i,%s)]" (esc n) (esc var)
  in
  let var = match Cmdliner_info.arg_docv a with "" -> "VAL" | v -> v in
  let names = List.sort compare (Cmdliner_info.arg_opt_names a) in
  let s = String.concat ", " (List.rev_map (fmt_name var) names) in
  s

let arg_to_man_item ~buf ~subst a =
  let or_env ~value a = match Cmdliner_info.arg_env a with
  | None -> ""
  | Some e ->
      let value = if value then " or" else "absent " in
      strf "%s $(b,%s) env" value (esc @@ Cmdliner_info.env_var e)
  in
  let absent = match Cmdliner_info.arg_absent a with
  | Cmdliner_info.Err -> ""
  | Cmdliner_info.Val v ->
      match Lazy.force v with
      | "" -> strf "%s" (or_env ~value:false a)
      | v -> strf "absent=%s%s" v (or_env ~value:true a)
  in
  let optvopt = match Cmdliner_info.arg_opt_kind a with
  | Cmdliner_info.Opt_vopt v -> strf "default=%s" v
  | _ -> ""
  in
  let argvdoc = match optvopt, absent with
  | "", "" -> ""
  | s, "" | "", s -> strf " (%s)" s
  | s, s' -> strf " (%s) (%s)" s s'
  in
  let subst = arg_info_subst ~subst a in
  let doc = Cmdliner_manpage.subst_vars buf ~subst (Cmdliner_info.arg_doc a) in
  (Cmdliner_info.arg_docs a, `I (arg_man_item_label a ^ argvdoc, doc))

let arg_man_docs ~buf ~subst ei =
  let by_sec_by_arg a0 a1 =
    let c = compare (Cmdliner_info.arg_docs a0) (Cmdliner_info.arg_docs a1) in
    if c <> 0 then c else
    match Cmdliner_info.arg_is_opt a0, Cmdliner_info.arg_is_opt a1 with
    | true, true -> (* optional by name *)
        let key names =
          let k = List.hd (List.sort rev_compare names) in
          let k = Cmdliner_base.lowercase k in
          if k.[1] = '-' then String.sub k 1 (String.length k - 1) else k
        in
        compare
          (key @@ Cmdliner_info.arg_opt_names a0)
          (key @@ Cmdliner_info.arg_opt_names a1)
    | false, false -> (* positional by variable *)
        compare
          (Cmdliner_base.lowercase @@ Cmdliner_info.arg_docv a0)
          (Cmdliner_base.lowercase @@ Cmdliner_info.arg_docv a1)
    | true, false -> -1 (* positional first *)
    | false, true -> 1  (* optional after *)
  in
  let keep_arg a =
    not Cmdliner_info.(arg_is_pos a && (arg_docv a = "" || arg_doc a = ""))
  in
  let args = List.filter keep_arg (Cmdliner_info.eval_term_args ei) in
  let args = List.sort by_sec_by_arg args in
  let args = List.rev_map (arg_to_man_item ~buf ~subst) args in
  sorted_items_to_blocks ~boilerplate:None args

(* Environment doc *)

let env_boilerplate sec = match sec = Cmdliner_manpage.s_environment with
| false -> None
| true -> Some (Cmdliner_manpage.s_environment_intro)

let env_man_docs ~buf ~subst ~has_senv ei =
  let add_env_man_item ~subst acc e =
    let var = strf "$(b,%s)" @@ esc (Cmdliner_info.env_var e) in
    let doc = Cmdliner_info.env_doc e in
    let doc = Cmdliner_manpage.subst_vars buf ~subst doc in
    (Cmdliner_info.env_docs e, `I (var, doc)) :: acc
  in
  let add_arg_env acc a = match Cmdliner_info.arg_env a with
  | None -> acc
  | Some e -> add_env_man_item ~subst:(arg_info_subst ~subst a) acc e
  in
  let by_sec_by_rev_name (s0, `I (v0, _)) (s1, `I (v1, _)) =
    let c = compare s0 s1 in
    if c <> 0 then c else compare v1 v0 (* N.B. reverse *)
  in
  let envs = List.fold_left add_arg_env [] (Cmdliner_info.eval_term_args ei)in
  let envs = List.sort by_sec_by_rev_name envs in
  let envs = (envs :> (string * Cmdliner_manpage.block) list) in
  let boilerplate = if has_senv then None else Some env_boilerplate in
  sorted_items_to_blocks ~boilerplate envs

(* Man page construction *)

let ensure_s_name ei sm =
  if Cmdliner_manpage.(smap_has_section sm s_name) then sm else
  let tname = invocation ~sep:'-' ei in
  let tdoc = Cmdliner_info.(term_doc @@ eval_term ei) in
  let tagline = if tdoc = "" then "" else strf " - %s" tdoc in
  let tagline = `P (strf "%s%s" tname tagline) in
  Cmdliner_manpage.(smap_append_block sm ~sec:s_name tagline)

let ensure_s_synopsis ei sm =
  if Cmdliner_manpage.(smap_has_section sm ~sec:s_synopsis) then sm else
  let synopsis = `P (synopsis ei) in
  Cmdliner_manpage.(smap_append_block sm ~sec:s_synopsis synopsis)

let insert_term_man_docs ei sm =
  let buf = Buffer.create 200 in
  let subst = term_info_subst ei in
  let insert sm (s, b) = Cmdliner_manpage.smap_append_block sm s b in
  let has_senv = Cmdliner_manpage.(smap_has_section sm s_environment) in
  let sm = List.fold_left insert sm (cmd_man_docs ei) in
  let sm = List.fold_left insert sm (arg_man_docs ~buf ~subst ei) in
  let sm = List.fold_left insert sm (env_man_docs ~buf ~subst ~has_senv ei) in
  sm

let text ei =
  let man = Cmdliner_info.(term_man @@ eval_term ei) in
  let sm = Cmdliner_manpage.smap_of_blocks man in
  let sm = ensure_s_name ei sm in
  let sm = ensure_s_synopsis ei sm in
  let sm = insert_term_man_docs ei sm in
  Cmdliner_manpage.smap_to_blocks sm

let title ei =
  let main = Cmdliner_info.eval_main ei in
  let exec = Cmdliner_base.capitalize (Cmdliner_info.term_name main) in
  let name = Cmdliner_base.uppercase (invocation ~sep:'-' ei) in
  let center_header = esc @@ strf "%s Manual" exec in
  let left_footer =
    let version = match Cmdliner_info.term_version main with
    | None -> "" | Some v -> " " ^ v
    in
    esc @@ strf "%s%s" exec version
  in
  name, 1, "", left_footer, center_header

let man ei = title ei, text ei

let pp_man fmt ppf ei =
  Cmdliner_manpage.print ~subst:(term_info_subst ei) fmt ppf (man ei)

let pp_plain_synopsis ppf ei =
  let buf = Buffer.create 100 in
  let subst = term_info_subst ei in
  let syn = Cmdliner_manpage.doc_to_plain ~subst buf (synopsis ei) in
  Format.fprintf ppf "@[%s@]" syn

(*---------------------------------------------------------------------------
   Copyright (c) 2011 Daniel C. Bünzli

   Permission to use, copy, modify, and/or distribute this software for any
   purpose with or without fee is hereby granted, provided that the above
   copyright notice and this permission notice appear in all copies.

   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
   WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
   MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
   ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
   WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
   ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
   OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
  ---------------------------------------------------------------------------*)