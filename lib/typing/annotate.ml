open Core_kernel
open Core_type
open Typedtree
open Waterlang_parsing

let rec annotate_statement (env: Env.t) stmt =
  let { Ast. pstmt_loc; pstmt_desc; _; } = stmt in
  let tstmt_desc =
    match pstmt_desc with
    | Pstmt_class cls ->
      let cls = annotate_class env cls in
      let ty_val = Infer.infer_class cls in
      cls.tcls_id.value <- ty_val;
      Tstmt_class cls

    | Pstmt_expr expr ->
      Tstmt_expr (annotate_expression env expr)

    | Pstmt_semi expr ->
      Tstmt_semi (annotate_expression env expr)

    | Pstmt_function _fun ->
      Tstmt_function (annotate_function env _fun)

    | Pstmt_while {Ast. pwhile_test; pwhile_block; pwhile_loc; } ->
      let twhile_test = annotate_expression env pwhile_test in
      let twhile_block = annotate_block env pwhile_block in
      Tstmt_while {
        twhile_test;
        twhile_block;
        twhile_loc = pwhile_loc;
      }

    | Pstmt_binding binding ->
      Tstmt_binding (annotate_binding env binding)

    | Pstmt_block block ->
      Tstmt_block (annotate_block env block)

    | Pstmt_break id -> Tstmt_break id
    | Pstmt_contintue id -> Tstmt_continue id
    | Pstmt_debugger -> Tstmt_debugger
    | Pstmt_return expr_opt ->
      Tstmt_return (Option.map ~f:(annotate_expression env) expr_opt)

    | Pstmt_empty -> Tstmt_empty

  in

  {
    tstmt_desc;
    tstmt_loc = pstmt_loc;
  }

and annotate_function env _function =
  let annotate_param env param =
    let {Ast. pparam_pat; pparam_init; pparam_loc; pparam_rest; _ } = param in
    let tparam_pat = annotate_pattern env pparam_pat in
    {
      tparam_pat;
      tparam_init = Option.map ~f:(annotate_expression env) pparam_init;
      tparam_loc = pparam_loc;
      tparam_rest = pparam_rest;
    }
  in
  let { Ast. pfun_id; pfun_params; pfun_body; pfun_loc; _; } = _function in
  let name = (Option.value_exn pfun_id).pident_name in
  let scope = Env.peek_scope env in
  let var_sym = Scope.find_var_symbol scope name in

  match var_sym with
  | Some tfun_id ->
    begin
      let tfun_params =
        {
          tparams_content = List.map ~f:(annotate_param env) pfun_params.pparams_content;
          tparams_loc = pfun_params.pparams_loc;
        }
      in
      let tfun_body = match pfun_body with
        | Ast.Pfun_block_body block ->
          Tfun_block_body (annotate_block env block)

        | Ast.Pfun_expression_body expr ->
          Tfun_expression_body (annotate_expression env expr)

      in
      {
        tfun_id;
        tfun_params;
        tfun_body;
        tfun_loc = pfun_loc;
      }
    end

  | None ->
    begin
      let err = Type_error.make_error pfun_loc (Type_error.CannotFindName name) in
      Env.add_error env err;
      raise (Type_error.Error err)
    end

and annotate_class env _class =
  let annotate_body env cls_body =
    let { Ast. pcls_body_elements; pcls_body_loc } = cls_body in
    let tcls_body_elements =
      List.map
        ~f:(function
        | Pcls_method _method ->
          begin
            let { Ast. pcls_method_visiblity; pcls_method_loc; _ } = _method in
            let tcls_method_visibility =
              Option.value ~default:Ast.Pvisibility_private pcls_method_visiblity
            in
            Tcls_method {
              tcls_method_visibility;
              tcls_method_loc = pcls_method_loc;
            }
          end

        | Pcls_property prop ->
          begin
            let { Ast.
              pcls_property_visiblity;
              pcls_property_loc;
              pcls_property_name;
              (* pcls_property_type; *)
              pcls_property_init;
              _;
            } = prop
            in
            let tcls_property_visibility =
              Option.value ~default:Ast.Pvisibility_private pcls_property_visiblity
            in
            let tcls_property_init = Option.map ~f:(annotate_expression env) pcls_property_init in
            Tcls_property {
              tcls_property_visibility;
              tcls_property_loc = pcls_property_loc;
              tcls_property_name = pcls_property_name;
              tcls_property_init;
            }
          end

        )
        pcls_body_elements
    in
    {
      tcls_body_elements;
      tcls_body_loc = pcls_body_loc;
    }
  in

  let { Ast. pcls_id; pcls_loc; pcls_body; _; } = _class in
  let id = Option.value_exn pcls_id in
  let scope = Env.peek_scope env in
  let type_sym_opt = Scope.find_type_symbol scope id.pident_name in
  match type_sym_opt with
  | Some tcls_id ->
    begin
      let tcls_body = annotate_body env pcls_body in
      {
        tcls_id;
        tcls_loc = pcls_loc;
        tcls_body;
      }
    end

  | None ->
    begin
      let err = Type_error.make_error pcls_loc (Type_error.CannotFindName id.pident_name) in
      Env.add_error env err;
      raise (Type_error.Error err)
    end

and annotate_block env block =
  let { Ast. pblk_body; pblk_loc } = block in
  let tblk_body = List.map ~f:(annotate_statement env) pblk_body in
  {
    tblk_body;
    tblk_loc = pblk_loc;
  }

and annotate_binding env binding =
  let { Ast. pbinding_kind; pbinding_loc; pbinding_ty; pbinding_pat; pbinding_init } = binding in
  let tbinding_init = annotate_expression env pbinding_init in
  let tbinding_ty = Option.map ~f:(annotate_type env) pbinding_ty in
  let tbinding_pat = annotate_pattern env pbinding_pat in
  {
    tbinding_kind = pbinding_kind;
    tbinding_loc = pbinding_loc;
    tbinding_ty;
    tbinding_pat;
    tbinding_init;
  }

and annotate_pattern env pat =
  let {Ast. ppat_desc; ppat_loc } = pat in
  let tpat_desc =
    match ppat_desc with
    | Ast.Ppat_identifier id ->
      begin
        let current_scope = Env.peek_scope env in
        let var_sym = VarSym.mk_local ~scope_id:current_scope.id id.pident_name in
        Scope.set_var_symbol current_scope id.pident_name var_sym;
        Tpat_symbol var_sym
      end
  in
  {
    tpat_desc;
    tpat_loc = ppat_loc;
  }

and annotate_type env ty =
  let {Ast. pty_desc; pty_loc } = ty in
  let tty_desc =
    match pty_desc with
    | Ast.Pty_any -> Tty_any
    | Ast.Pty_var str -> Tty_var str
    | Ast.Pty_ctor (id, types) ->
      begin
        let current_scope = Env.peek_scope env in
        let type_sym_opt = Scope.find_type_symbol current_scope id.pident_name in
        match type_sym_opt with
        | Some sym ->
          begin
            let types = List.map ~f:(annotate_type env) types in
            Tty_ctor (sym, types)
          end
        | None ->
          begin
            let err = Type_error.make_error pty_loc (Type_error.CannotFindName id.pident_name) in
            Env.add_error env err;
            raise (Type_error.Error err)
          end

      end

    | Ast.Pty_arrow (params, ret) ->
      let t_params = List.map ~f:(annotate_type env) params in
      let t_ret = annotate_type env ret in
      Tty_arrow (t_params, t_ret)

  in
  {
    tty_desc;
    tty_loc = pty_loc;
  }

and annotate_expression (env: Env.t) expr =
  let { Ast. pexp_desc; pexp_loc; _; } = expr in
  let texp_desc =
    match pexp_desc with
    | Pexp_constant cnst -> Texp_constant cnst
    | Pexp_identifier id ->
      begin
        let current_scope = Env.peek_scope env in
        let var_sym_opt = Scope.find_var_symbol current_scope id.pident_name in
        match var_sym_opt with
        | Some sym ->
          Texp_identifier sym

        | None ->
          begin
            let err = Type_error.make_error pexp_loc (Type_error.CannotFindName id.pident_name) in
            Env.add_error env err;
            raise (Type_error.Error err)
          end
      end

    | Pexp_throw expr ->
      Texp_throw (annotate_expression env expr)

    | Pexp_lambda _ -> Texp_lambda

    | Pexp_if { Ast. pif_test; pif_consequent; pif_alternative; pif_loc; } ->
      let tif_test = annotate_expression env pif_test in
      let tif_consequent = annotate_statement env pif_consequent in
      let tif_alternative = Option.map ~f:(annotate_statement env) pif_alternative in
      Texp_if {
        tif_test;
        tif_consequent;
        tif_alternative;
        tif_loc = pif_loc;
      }

    | Pexp_array arr ->
      Texp_array (List.map ~f:(annotate_expression env) arr)
    
    | Pexp_call call ->
      let {Ast. pcallee; pcall_params; pcall_loc } = call in
      let tcallee = annotate_expression env pcallee in
      let tcall_params = List.map ~f:(annotate_expression env) pcall_params in
      Texp_call {
        tcallee;
        tcall_params;
        tcall_loc = pcall_loc;
      }

    | Pexp_member (expr, field) ->
      Texp_member (annotate_expression env expr, field)

    | Pexp_unary (op, expr) ->
      let expr = annotate_expression env expr in
      Texp_unary(op, expr)

    | Pexp_binary (op, left, right) ->
      let left = annotate_expression env left in
      let right = annotate_expression env right in
      Texp_binary(op, left, right)

  in
  {
    texp_desc;
    texp_loc = pexp_loc;
    texp_val = TypeValue.Unknown;
  }

(**
 * pre-scan symbol of root-level definitions of
 * class/function/struct/enum
 *)
let pre_scan_definitions env program =
  let { Ast. pprogram_statements; _; } = program in

  let find_or_add_type_sym name loc =
    let scope = Env.peek_scope env in
    let type_sym = Scope.find_type_symbol scope name in
    match type_sym with
    | Some _ ->
      begin
        let err = Type_error.make_error loc (Type_error.Redefinition name) in
        Env.add_error env err
      end

    | None ->
      begin
        let type_sym = Core_type.TypeSym.mk_local ~scope_id:scope.id name in
        Scope.set_type_symbol scope name type_sym
      end
  in

  List.iter
    ~f:(fun stmt ->
      let { Ast. pstmt_desc; _; } = stmt in
      match pstmt_desc with
      | Pstmt_class cls ->
        begin
          let { Ast. pcls_id; pcls_loc; _; } = cls in
          let id = Option.value_exn pcls_id in
          find_or_add_type_sym id.pident_name pcls_loc;
        end

      | Pstmt_function _fun ->
        begin
          let { Ast. pfun_id; pfun_loc; _; } = _fun in
          let id = Option.value_exn pfun_id in
          find_or_add_type_sym id.pident_name pfun_loc
        end

      | _ -> ()
    )
    pprogram_statements

let annotate env (program: Ast.program) =
  pre_scan_definitions env program;
  let { Ast. pprogram_statements; _; } = program in
  let tprogram_statements =
    List.map ~f:(annotate_statement env) pprogram_statements
  in
  {
    tprogram_statements;
  }
