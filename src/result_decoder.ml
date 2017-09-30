open Ast
open Source_pos
open Schema

open Ast_402
open Parsetree
open Asttypes

open Type_utils
open Generator_utils

exception Unimplemented of string

let rec unify_type map_loc span ty schema (selection_set: selection list spanning option) =
  let loc = map_loc span in
  match ty with
  | Ntr_nullable t ->
    [%expr match Js.Json.decodeNull value with
      | None -> Some [%e unify_type map_loc span t schema selection_set]
      | Some _ -> None
    ] [@metaloc loc]
  | Ntr_list t ->
    [%expr match Js.Json.decodeArray value with
      | None -> raise Graphql_error
      | Some value -> Array.map (fun value -> [%e unify_type map_loc span t schema selection_set]) value
    ] [@metaloc loc]
  | Ntr_named n -> match lookup_type schema n with
    | None -> raise_error map_loc span ("Could not find type " ^ n)
    | Some Scalar { sm_name = "ID" } 
    | Some Scalar { sm_name = "String" } ->
      [%expr match Js.Json.decodeString value with
        | None -> raise Graphql_error
        | Some value -> (value : string)
      ] [@metaloc loc]
    | Some Scalar { sm_name = "Int" } ->
      [%expr match Js.Json.decodeNumber value with
        | None -> raise Graphql_error
        | Some value -> int_of_float value
      ] [@metaloc loc]
    | Some Scalar { sm_name = "Float" } ->
      [%expr match Js.Json.decodeNumber value with
        | None -> raise Graphql_error
        | Some value -> value
      ] [@metaloc loc]
    | Some Scalar { sm_name = "Boolean" } ->
      [%expr match Js.Json.decodeBoolean value with
        | None -> raise Graphql_error
        | Some value -> value
      ] [@metaloc loc]
    | Some Scalar _ -> 
      Ast_helper.(Exp.ident ~loc:loc {txt=Longident.Lident "value"; loc = loc})
    | Some ((Object o) as ty) ->
      unify_selection_set map_loc span schema ty selection_set
    | Some Enum { em_name; em_values } ->
      let enum_ty = Ast_helper.(
          Typ.variant ~loc:loc
            (List.map (fun { evm_name } -> Rtag (evm_name, [], true, [])) em_values)
            Closed None)
      in
      let enum_vals = Ast_helper.(
          Exp.match_ ~loc:loc [%expr value]
            (List.concat [
                List.map (fun { evm_name } ->
                    Exp.case
                      (Pat.constant ~loc:loc (Const_string (evm_name, None)))
                      (Exp.variant ~loc:loc evm_name None)) em_values;
                [Exp.case (Pat.any ()) [%expr raise Graphql_error]]]))
      in
      [%expr match Js.Json.decodeString value with
        | None -> raise Graphql_error
        | Some value -> ([%e enum_vals] : [%t enum_ty])
      ] [@metaloc loc]
    | Some ((Interface o) as ty) ->
      unify_selection_set map_loc span schema ty selection_set
    | Some InputObject obj -> raise_error map_loc span "Can't have fields on input objects"
    | Some Union _ -> raise_error map_loc span "Unions are not supported yet"

and unify_variant map_loc span ty schema selection_set =
  let loc = map_loc span in
  let rec match_loop ty selection_set = match selection_set with
    | [] -> [%expr raise Graphql_error] [@metaloc loc]
    | Field { item; span } :: tl -> begin
        match lookup_field ty item.fd_name.item with
        | None -> raise_error map_loc span ("Unknown field on type " ^ type_name ty)
        | Some field_meta ->
          let key = (some_or item.fd_alias item.fd_name).item in
          let inner_type = match (to_native_type_ref field_meta.fm_field_type) with
            | Ntr_list _ | Ntr_named _ -> raise_error map_loc span "Variant field must only contain nullable fields"
            | Ntr_nullable i -> i in
          [%expr
            let temp = Js.Dict.unsafeGet value [%e Ast_helper.(Exp.constant ~loc:loc (Const_string (key, None)))] in
            match Js.Json.decodeNull temp with
            | None -> let value = temp in 
              [%e Ast_helper.(Exp.variant ~loc:loc 
                                (String.capitalize key)
                                (Some (unify_type map_loc span inner_type schema item.fd_selection_set)))]
            | Some _ -> [%e match_loop ty tl]] [@metaloc loc]
      end
    | FragmentSpread { span } :: _ -> raise_error map_loc span "Variant selections can only contain fields"
    | InlineFragment { span } :: _ -> raise_error map_loc span "Variant selections can only contain fields"
  in
  match ty with
  | Ntr_nullable t -> 
    [%expr match Js.Json.decodeNull value with
      | None -> None
      | Some value -> Some [%e unify_variant map_loc span t schema selection_set]
    ] [@metaloc loc]
  | Ntr_list t ->
    [%expr match Js.Json.decodeArray value with
      | None -> raise Graphql_error
      | Some value -> Array.map (fun value -> [%e unify_variant map_loc span t schema selection_set]) value
    ] [@metaloc loc]
  | Ntr_named n -> match lookup_type schema n with
    | None -> raise_error map_loc span ("Could not find type " ^ n)
    | Some Scalar _ -> raise_error map_loc span "Variant fields can only be applied to object types"
    | Some Enum _ -> raise_error map_loc span "Variant fields can only be applied to object types"
    | Some Interface _ -> raise_error map_loc span "Variant fields can only be applied to object types"
    | Some Union _ -> raise_error map_loc span "Variant fields can only be applied to object types"
    | Some InputObject _ -> raise_error map_loc span "Variant fields can only be applied to object types"
    | Some ((Object _) as ty) ->
      match selection_set with
      | Some { item } ->
        [%expr match Js.Json.decodeObject value with
          | None -> raise Graphql_error
          | Some value -> [%e match_loop ty item]] [@metaloc loc]
      | None -> raise_error map_loc span "Variant fields need a selection set"

and unify_field map_loc field_span ty schema =
  let ast_field = field_span.item in
  let field_meta = lookup_field ty ast_field.fd_name.item in
  let key = (some_or ast_field.fd_alias ast_field.fd_name).item in
  let loc = map_loc field_span.span in
  let is_variant = List.exists (fun { item = { d_name = { item } } } -> item = "bsVariant") ast_field.fd_directives in
  let sub_unifier = if is_variant then unify_variant else unify_type in
  match field_meta with
  | None -> raise_error map_loc field_span.span ("Unknown field on type " ^ type_name ty)
  | Some field_meta ->
    (
      { txt = Longident.Lident key; loc = loc },
      [%expr
        let value = Js.Dict.unsafeGet value [%e Ast_helper.Exp.constant ~loc:loc (Const_string (key, None))]
        in [%e sub_unifier 
            map_loc
            field_span.span
            (to_native_type_ref field_meta.fm_field_type)
            schema 
            ast_field.fd_selection_set]]
    )

and unify_selection map_loc schema ty selection = match selection with
  | Field field_span -> unify_field map_loc field_span ty schema
  | FragmentSpread _ -> raise @@ Unimplemented "fragment spreads"
  | InlineFragment _ -> raise @@ Unimplemented "inline fragments"

and unify_selection_set map_loc span schema ty selection_set = match selection_set with
  | None -> raise_error map_loc span "Must select subfields on objects"
  | Some { item } -> let loc = map_loc span in
    [%expr match Js.Json.decodeObject value with
      | None -> raise Graphql_error
      | Some value -> [%e {pexp_loc = loc; pexp_attributes = []; pexp_desc = (Pexp_extension (
          {txt = "bs.obj"; loc = loc},
          PStr [{
              pstr_desc = Pstr_eval (
                  {pexp_desc = Pexp_record (
                       (List.map (unify_selection map_loc schema ty) item),
                       None);
                   pexp_loc = loc;
                   pexp_attributes = []},
                  []);
              pstr_loc = loc;
            }]
        ))}]
    ] [@metaloc loc]


let unify_document_schema map_loc schema document =
  match document with
  | [Operation { item = { o_type = Query; o_selection_set }; span } ] ->
    unify_selection_set map_loc span schema (query_type schema) (Some o_selection_set)
  | [Operation { item = { o_type = Mutation; o_selection_set }; span } ] -> begin match mutation_type schema with
      | Some mutation_type -> 
        unify_selection_set map_loc span schema mutation_type (Some o_selection_set)
      | None ->
        raise_error map_loc span "This schema does not contain any mutations"
    end
  | _ -> raise @@ Unimplemented "unification with other than singular queries"
