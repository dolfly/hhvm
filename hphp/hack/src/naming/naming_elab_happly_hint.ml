(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)
open Hh_prelude
open Common
module Err = Naming_phase_error
module SN = Naming_special_names

module Env = struct
  let tparams
      Naming_phase_env.{ elab_happly_hint = Elab_happly_hint.{ tparams; _ }; _ }
      =
    tparams

  let extend_tparams_with t ~add ps =
    let elab_happly_hint = t.Naming_phase_env.elab_happly_hint in
    let tparams =
      add ps elab_happly_hint.Naming_phase_env.Elab_happly_hint.tparams
    in
    let elab_happly_hint = Naming_phase_env.Elab_happly_hint.{ tparams } in
    Naming_phase_env.{ t with elab_happly_hint }

  let add_tparams ps init =
    List.fold
      ps
      ~f:(fun acc Aast.{ tp_name = (pos, nm); _ } -> SMap.add nm pos acc)
      ~init

  let extend_tparams t ps = extend_tparams_with t ~add:add_tparams ps

  let add_hint_tparams ps init =
    List.fold
      ps
      ~f:(fun acc Aast.{ htp_name = (pos, nm); _ } -> SMap.add nm pos acc)
      ~init

  let extend_hint_tparams t ps = extend_tparams_with t ~add:add_hint_tparams ps

  let in_class t Aast.{ c_tparams; _ } =
    let elab_happly_hint =
      Naming_phase_env.Elab_happly_hint.
        { tparams = add_tparams c_tparams SMap.empty }
    in
    Naming_phase_env.{ t with elab_happly_hint }

  let in_fun_def t Aast.{ fd_tparams; _ } =
    let elab_happly_hint =
      Naming_phase_env.Elab_happly_hint.
        { tparams = add_tparams fd_tparams SMap.empty }
    in
    Naming_phase_env.{ t with elab_happly_hint }

  let in_typedef t Aast.{ t_tparams; _ } =
    let elab_happly_hint =
      Naming_phase_env.Elab_happly_hint.
        { tparams = add_tparams t_tparams SMap.empty }
    in
    Naming_phase_env.{ t with elab_happly_hint }

  let in_gconst t =
    let elab_happly_hint =
      Naming_phase_env.Elab_happly_hint.{ tparams = SMap.empty }
    in
    Naming_phase_env.{ t with elab_happly_hint }

  let in_module_def t =
    let elab_happly_hint =
      Naming_phase_env.Elab_happly_hint.{ tparams = SMap.empty }
    in
    Naming_phase_env.{ t with elab_happly_hint }
end

type canon_result =
  | Concrete of Aast.hint
  | This of Pos.t
  | Classname of Pos.t
  | Tycon of Pos.t * string
  | Typaram of string
  | Varray of Pos.t
  | Darray of Pos.t
  | Vec_or_dict of Pos.t * string
  | CanonErr of Naming_error.t

(* A number of hints are represented by `Happly` after lowering; we elaborate
   to the canonical representation here taking care to separate the result
   so we can apply subsequent validation of the hint based on where it appeared *)
let canonical_tycon typarams (pos, name) =
  if String.equal name SN.Typehints.int then
    Concrete (pos, Aast.(Hprim Tint))
  else if String.equal name SN.Typehints.bool then
    Concrete (pos, Aast.(Hprim Tbool))
  else if String.equal name SN.Typehints.float then
    Concrete (pos, Aast.(Hprim Tfloat))
  else if String.equal name SN.Typehints.string then
    Concrete (pos, Aast.(Hprim Tstring))
  else if String.equal name SN.Typehints.darray then
    Darray pos
  else if String.equal name SN.Typehints.varray then
    Varray pos
  (* TODO[mjt] `vec_or_dict` is currently special cased since the canonical representation
     requires us to have no arity mismatches or throw away info. We do not use that repr here
     to avoid having to do so. Ultimately, we should remove that special case *)
  else if
    String.(
      equal name SN.Typehints.varray_or_darray
      || equal name SN.Typehints.vec_or_dict)
  then
    Vec_or_dict (pos, name)
  else if String.equal name SN.Typehints.void then
    Concrete (pos, Aast.(Hprim Tvoid))
  else if String.equal name SN.Typehints.noreturn then
    Concrete (pos, Aast.(Hprim Tnoreturn))
  else if String.equal name SN.Typehints.null then
    Concrete (pos, Aast.(Hprim Tnull))
  else if String.equal name SN.Typehints.num then
    Concrete (pos, Aast.(Hprim Tnum))
  else if String.equal name SN.Typehints.resource then
    Concrete (pos, Aast.(Hprim Tresource))
  else if String.equal name SN.Typehints.arraykey then
    Concrete (pos, Aast.(Hprim Tarraykey))
  else if String.equal name SN.Typehints.mixed then
    Concrete (pos, Aast.Hmixed)
  else if String.equal name SN.Typehints.nonnull then
    Concrete (pos, Aast.Hnonnull)
  else if String.equal name SN.Typehints.nothing then
    Concrete (pos, Aast.Hnothing)
  else if String.equal name SN.Typehints.dynamic then
    Concrete (pos, Aast.Hdynamic)
  else if String.equal name SN.Typehints.this then
    This pos
  else if
    String.(
      equal name ("\\" ^ SN.Typehints.void)
      || equal name ("\\" ^ SN.Typehints.null)
      || equal name ("\\" ^ SN.Typehints.noreturn)
      || equal name ("\\" ^ SN.Typehints.int)
      || equal name ("\\" ^ SN.Typehints.bool)
      || equal name ("\\" ^ SN.Typehints.float)
      || equal name ("\\" ^ SN.Typehints.num)
      || equal name ("\\" ^ SN.Typehints.string)
      || equal name ("\\" ^ SN.Typehints.resource)
      || equal name ("\\" ^ SN.Typehints.mixed)
      || equal name ("\\" ^ SN.Typehints.nonnull)
      || equal name ("\\" ^ SN.Typehints.arraykey)
      || equal name ("\\" ^ SN.Typehints.nothing))
  then
    CanonErr (Naming_error.Primitive_top_level pos)
  (* TODO[mjt] why wouldn't be have a fully qualified name here? *)
  else if String.(equal name SN.Classes.cClassname || equal name "classname")
  then
    Classname pos
  else if SMap.mem name typarams then
    Typaram name
  else
    Tycon (pos, name)

(* TODO[mjt] should we really be special casing `vec_or_dict` both in
   its representation and error handling? *)
let canonicalise_vec_or_dict tycon hint_pos pos hints =
  match hints with
  | [] ->
    let err = Some (Err.naming @@ Naming_error.Too_few_type_arguments hint_pos)
    and hint_ = Aast.Happly ((pos, tycon), hints) in
    Ok ((hint_pos, hint_), err)
  | [val_hint] -> Ok ((hint_pos, Aast.Hvec_or_dict (None, val_hint)), None)
  | [key_hint; val_hint] ->
    Ok ((hint_pos, Aast.Hvec_or_dict (Some key_hint, val_hint)), None)
  | _ ->
    let err = Some (Err.naming @@ Naming_error.Too_many_type_arguments hint_pos)
    and hint_ = Aast.Happly ((pos, tycon), hints) in
    Ok ((hint_pos, hint_), err)

(* After lowering many hints are represented as `Happly(...,...)`. Here
   we canonicalise the representation of type constructor then handle
   errors and further elaboration *)
let canonicalize_happly tparams hint_pos tycon hints =
  match canonical_tycon tparams tycon with
  (* The hint was malformed *)
  | CanonErr err ->
    let hint_ = Aast.Happly (tycon, hints) in
    Error ((hint_pos, hint_), Err.naming err)
  (* The type constructors canonical representation is a concrete type *)
  | Concrete (pos, hint_) ->
    (* We can't represent a concrete type applied to other types
       so we raise an error here *)
    let err_opt =
      if not @@ List.is_empty hints then
        Some (Err.naming @@ Naming_error.Unexpected_type_arguments pos)
      else
        None
    in
    Ok ((hint_pos, hint_), err_opt)
  (* The type constructors corresponds to an in-scope type parameter *)
  | Typaram name ->
    let err =
      if List.is_empty hints then
        None
      else
        Some
          (Err.naming
          @@ Naming_error.Tparam_applied_to_type
               { pos = hint_pos; tparam_name = name })
    in

    let hint_ = Aast.Habstr name in
    Ok ((hint_pos, hint_), err)
  (* The type constructors canonical representation is `Happly` but
     additional elaboration / validation is required *)
  | This pos ->
    let err_opt =
      if not @@ List.is_empty hints then
        Some (Err.naming @@ Naming_error.This_no_argument hint_pos)
      else
        None
    in
    Ok ((pos, Aast.Hthis), err_opt)
  | Classname pos ->
    (* TODO[mjt] currently if `classname` is not applied to exactly
       one type parameter, it canonicalizes to `Hprim Tstring`.
       Investigate why this happens and if we can delay treatment to
       typing *)
    (match hints with
    | [_] ->
      let hint_ = Aast.Happly ((pos, SN.Classes.cClassname), hints) in
      Ok ((hint_pos, hint_), None)
    | _ ->
      Ok
        ( (hint_pos, Aast.(Hprim Tstring)),
          Some (Err.naming @@ Naming_error.Classname_param pos) ))
  | Darray pos ->
    Ok ((hint_pos, Aast.Happly ((pos, SN.Collections.cDict), hints)), None)
  | Varray pos ->
    Ok ((hint_pos, Aast.Happly ((pos, SN.Collections.cVec), hints)), None)
  | Vec_or_dict (pos, tycon) ->
    canonicalise_vec_or_dict tycon hint_pos pos hints
  (* The type constructors canonical representation is `Happly` *)
  | Tycon (pos, tycon) ->
    let hint_ = Aast.Happly ((pos, tycon), hints) in
    Ok ((hint_pos, hint_), None)

let on_typedef t ~ctx = (Env.in_typedef ctx t, Ok t)

let on_gconst cst ~ctx = (Env.in_gconst ctx, Ok cst)

let on_fun_def fd ~ctx = (Env.in_fun_def ctx fd, Ok fd)

let on_module_def md ~ctx = (Env.in_module_def ctx, Ok md)

let on_class_ c ~ctx = (Env.in_class ctx c, Ok c)

let on_method_ m ~ctx =
  let ctx = Env.extend_tparams ctx m.Aast.m_tparams in
  (ctx, Ok m)

let on_hint on_error hint ~ctx =
  match hint with
  | (hint_pos, Aast.Happly (tycon, hints)) ->
    (match canonicalize_happly (Env.tparams ctx) hint_pos tycon hints with
    | Ok (hint, err_opt) ->
      Option.iter ~f:on_error err_opt;
      (ctx, Ok hint)
    | Error (hint, err) ->
      on_error err;
      (ctx, Error hint))
  | _ -> (ctx, Ok hint)

(* Disallow rebinding type parameters that occur in class or method position
   but allow names to be reused across different first-class polymorphic function
   hints *)
let validate_hint_tparams tparams on_error ~ctx =
  let bound = Env.tparams ctx in
  let _bound =
    List.fold_left
      tparams
      ~init:bound
      ~f:(fun bound Aast_defs.{ htp_name = (pos, tparam_name); _ } ->
        match SMap.find_opt tparam_name bound with
        | Some prev_pos ->
          let err =
            Naming_phase_error.naming
              (Naming_error.Shadowed_tparam { pos; prev_pos; tparam_name })
          in
          let () = on_error err in
          bound
        | None -> SMap.add tparam_name pos bound)
  in
  ()

let on_expr_ on_error expr_ ~ctx =
  let ctx =
    match expr_ with
    | Aast_defs.Lfun (fun_, _)
    | Aast_defs.(Efun { ef_fun = fun_; _ }) ->
      let Aast.{ f_tparams; _ } = fun_ in
      let (_ : unit) = validate_hint_tparams f_tparams on_error ~ctx in
      Env.extend_hint_tparams ctx f_tparams
    | _ -> ctx
  in
  (ctx, Ok expr_)

let on_hint_fun on_error hint_fun ~ctx =
  let Aast.{ hf_tparams; _ } = hint_fun in
  let (_ : unit) = validate_hint_tparams hf_tparams on_error ~ctx in
  let ctx = Env.extend_hint_tparams ctx hf_tparams in
  (ctx, Ok hint_fun)

let pass on_error =
  let id = Aast.Pass.identity () in
  let on_ty_expr_ expr_ ~ctx = on_expr_ on_error expr_ ~ctx in
  Naming_phase_pass.top_down
    Aast.Pass.
      {
        id with
        on_ty_typedef = Some on_typedef;
        on_ty_gconst = Some on_gconst;
        on_ty_fun_def = Some on_fun_def;
        on_ty_module_def = Some on_module_def;
        on_ty_class_ = Some on_class_;
        on_ty_method_ = Some on_method_;
        on_ty_hint = Some (on_hint on_error);
        on_ty_hint_fun = Some (on_hint_fun on_error);
        on_ty_expr_ = Some on_ty_expr_;
      }
