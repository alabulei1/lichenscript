open Core_kernel
open Core_type
open Typedtree

let type_assinable left right =
  let open TypeValue in
  match (left, right) with
  | (Any, _)
  | (_, Any)
  | (Unknown, Unknown) -> true
  | (Ctor left_sym, Ctor right_sym) ->
    if phys_equal left_sym right_sym then
      true
    else
      false

  | _ ->
    false

let rec check_statement env statement =
  let { tstmt_desc; tstmt_loc; _; } = statement in
  match tstmt_desc with
  | Tstmt_class cls ->
    check_class env cls

  | Tstmt_expr expr
  | Tstmt_semi expr ->
    check_expression env expr

  | Tstmt_function _fun ->
    check_function env _fun

  | Tstmt_while _while ->
    begin
      let { twhile_test; twhile_block; _; } = _while in
      check_expression env twhile_test;
      check_block env twhile_block
    end

  | Tstmt_binding binding -> 
    check_binding env binding

  | Tstmt_block blk ->
    check_block env blk

  | Tstmt_break _
  | Tstmt_continue _
  | Tstmt_debugger -> ()
  | Tstmt_return expr_opt -> 
    let expected = Option.value ~default:TypeValue.Unit (Env.return_type env) in
    (match expr_opt with
    | Some expr ->
      check_expression env expr;
      check_returnable env tstmt_loc expected expr.texp_val

    | None -> 
      check_returnable env tstmt_loc expected TypeValue.Unit

    )

  | Tstmt_empty -> ()

and check_class env cls =
  let { tcls_body; _; } = cls in
  let { tcls_body_elements; _; } = tcls_body in
  List.iter
    ~f:(function
    | Tcls_method _ ->
      ()

    | Tcls_property prop ->
      let { tcls_property_init; _; } = prop in
      Option.iter
        ~f:(fun expr ->
          check_expression env expr;
        )
        tcls_property_init

    )
    tcls_body_elements

and check_function (env: Env.t) _fun =
  let { tfun_body;  _; } = _fun in
  match tfun_body with
  | Tfun_block_body blk -> 
    check_block env blk;

  | Tfun_expression_body expr ->
    check_expression env expr

and check_block env blk =
  let { tblk_body; _ } = blk in
  List.iter ~f:(check_statement env) tblk_body

and check_binding env binding =
  let { tbinding_pat; tbinding_init; tbinding_loc; _ } = binding in
  let { tpat_desc; _; } = tbinding_pat in
  let left_val =
    match tpat_desc with
    | Tpat_symbol _var_sym ->
      TypeValue.Any
  in
  check_expression env tbinding_init;
  check_assignable env tbinding_loc left_val tbinding_init.texp_val

and check_expression (env: Env.t) expr =
  let { texp_desc; _; } = expr in
  match texp_desc with
  | Texp_constant _
  | Texp_identifier _
  | Texp_lambda
    -> ()

  | Texp_throw expr ->
    check_expression env expr

  | Texp_if _if ->
    begin
      let { tif_test; tif_consequent; tif_alternative; _; } = _if in
      check_expression env tif_test;
      check_statement env tif_consequent;
      Option.iter ~f:(check_statement env) tif_alternative
    end

  | Texp_array arr ->
    List.iter
      ~f:(fun expr ->
        check_expression env expr;
      )
      arr
    ;

  | Texp_call call ->
    let { tcallee; tcall_params; tcall_loc; _; } = call in
    check_expression env tcallee;
    let callee_type = tcallee.texp_val in
    let _param_types =
      List.map
        ~f:(fun param ->
          check_expression env param;
          param.texp_val
        )
        tcall_params
    in
    TypeValue.(
    match callee_type with
    | Function _ ->
      ()

    | _ ->
      let err = Type_error.make_error tcall_loc (Type_error.NotCallable callee_type) in
      Env.add_error env err
    )

  | Texp_member (expr, _field) ->
    check_expression env expr

  | Texp_unary (_, expr) ->
    check_expression env expr

  | Texp_binary (_, left, right) ->
    check_expression env left;
    check_expression env right

  | Texp_update (_, exp, _) ->
    check_expression env exp

and check_assignable env loc left right =
  if type_assinable left right then
    ()
  else
    let spec = Type_error.NotAssignable(left, right) in
    let err = {Type_error. loc; spec } in
    Env.add_error env err

and check_returnable env loc expected actual =
  if type_assinable expected actual then
    ()
  else
    let spec = Type_error.CannotReturn(expected, actual) in
    let err = {Type_error. loc; spec } in
    Env.add_error env err

let type_check env program =
  let { tprogram_statements; _; } = program in
  List.iter ~f:(check_statement env) tprogram_statements
