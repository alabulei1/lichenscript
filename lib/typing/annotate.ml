(*
 * 1. annotate parsed tree to typed tree
 * 2. resolve top-level variables internally
 * 
 * deeper variables resolution remains to type-check phase
 *)
open Core_kernel
open Core_type
open Scope
open Lichenscript_parsing

module T = Typedtree

let rec annotate_statement ~(prev_deps: int list) env (stmt: Ast.Statement.t) =
  let open Ast.Statement in
  let { spec; loc; attributes; _ } = stmt in
  let deps, spec =
    match spec with
    | Expr expr -> (
      let expr = annotate_expression ~prev_deps env expr in 
      let ty_var = T.Expression.(expr.ty_var) in

      (* the expression may not depends on prev_deps, so next
       * statement should continue to depends on prev deps
       *)
      (List.append prev_deps [ty_var]), (T.Statement.Expr expr)
    )

    | Semi expr -> (
      let expr = annotate_expression ~prev_deps env expr in 
      let ty_var = T.Expression.(expr.ty_var) in

      let node = {
        value = TypeExpr.Ctor(Ref (Env.ty_unit env), []);
        loc;
        deps = List.append prev_deps [ty_var];
        check = none;  (* TODO: check expr is empty *)
      } in

      let id = Type_context.new_id (Env.ctx env) node in
      [id], (T.Statement.Semi expr)
    )

    | While _while -> (
      let { while_test; while_block; while_loc } = _while in
      let while_test = annotate_expression ~prev_deps env while_test in
      let while_block = annotate_block ~prev_deps:[while_test.ty_var] env while_block in
      let next_desp = [ while_block.return_ty ] in
      next_desp, T.Statement.While { while_test; while_block; while_loc }
    )

    | Binding binding -> (
      let { binding_kind; binding_pat; binding_init; binding_loc; _ } = binding in

      let binding_pat, sym_id = annotate_pattern env binding_pat in
      let name =
        let open T.Pattern in
        match binding_pat.spec with
        | Symbol (name, _) -> name
        | EnumCtor _ -> failwith "unimplemented"
      in

      let scope = Env.peek_scope env in
      (* TODO: check redefinition? *)
      scope#new_var_symbol name ~id:sym_id ~kind:binding_kind;

      let binding_init = annotate_expression ~prev_deps env binding_init in

      let ctx = Env.ctx env in
      let node = Type_context.get_node ctx sym_id in
      Type_context.update_node ctx sym_id {
        node with
        deps = List.concat [node.deps; [binding_init.ty_var]; prev_deps ];
        check = (fun id ->
          let expr_node = Type_context.get_node ctx binding_init.ty_var in
          Type_context.update_node_type ctx id expr_node.value
        )
      };

      [sym_id], T.Statement.Binding { T.Statement.
        binding_kind;
        binding_pat;
        binding_init;
        binding_ty_var = sym_id;
        binding_loc;
      }
    )

    (* | Block block -> (
      let block = annotate_block ~prev_deps env block in
      let dep = block.return_ty in
      [dep], (T.Statement.Block block)
    ) *)

    | Break _
    | Continue _
    | Debugger -> prev_deps, failwith "not implment"

    | Return ret_opt -> (
      match ret_opt with
      | Some expr -> (
        let expr = annotate_expression ~prev_deps env expr in
        let ty_var = expr.ty_var in

        Env.add_return_type env ty_var;

        [ty_var], (T.Statement.Return (Some expr))
      )

      | None -> [], (T.Statement.Return None)
    )

    | Empty ->
      prev_deps, T.Statement.Empty
  in
  deps, { T.Statement. spec; loc; attributes }

and annotate_expression ~prev_deps env expr : T.Expression.t =
  let open Ast.Expression in
  let { spec; loc; attributes; } = expr in
  let root_scope = Type_context.root_scope (Env.ctx env) in
  let ty_var, spec = 
    match spec with
    | Constant cnst -> (
      let open Ast.Literal in
      let ty_var =
        match cnst with
        | Integer _ ->
          Option.value_exn (root_scope#find_type_symbol "i32")

        | Char _ ->
          Option.value_exn (root_scope#find_type_symbol "char")

        (* 'c' *)
        | String _ ->
          Option.value_exn (root_scope#find_type_symbol "string")

        | Float _ ->
          Option.value_exn (root_scope#find_type_symbol "f32")

        | Boolean _ -> 
          Option.value_exn (root_scope#find_type_symbol "boolean")

      in

      let node = {
        value = TypeExpr.Ctor(Ref ty_var, []);
        loc = loc;
        check = none;
        deps = [ty_var];
      } in

      let node_id = Type_context.new_id (Env.ctx env) node in

      node_id, (T.Expression.Constant cnst)
    )

    | Identifier id -> (
      let ty_var_opt = (Env.peek_scope env)#find_var_symbol id.pident_name in
      match ty_var_opt with
      | Some variable -> (
        Env.capture_variable env ~name:id.pident_name;
        variable.var_id, (T.Expression.Identifier (id.pident_name, variable.var_id))
      )

      | _ ->
        let err_spec = Type_error.CannotFindName id.pident_name in
        let err = Type_error.make_error (Env.ctx env) id.pident_loc err_spec in
        raise (Type_error.Error err)
    )

    | Lambda lambda -> (
      let lambda_scope = new scope ~prev:(Env.peek_scope env) () in
      Env.with_new_scope env lambda_scope (fun env ->
        let prev_in_lambda = Env.in_lambda env in

        Env.set_in_lambda env true;
        let { lambda_params; lambda_return_ty; lambda_body } = lambda in

        let params, deps = annotate_function_params env lambda_params in

        let lambda_return_ty, ret_deps =
          match lambda_return_ty with
          | Some t ->
            let t, deps = annotate_type env t in
            t, deps
          | None -> (
            let none_type = Env.ty_unit env in
            TypeExpr.Ctor(Ref none_type, []), []
          )
        in

        let lambda_body = annotate_expression ~prev_deps:(List.append deps ret_deps) env lambda_body in

        let node = {
          value = TypeExpr.Unknown;
          loc = loc;
          check = none;
          deps = [lambda_body.ty_var];
        } in

        let node_id = Type_context.new_id (Env.ctx env) node in

        Env.set_in_lambda env prev_in_lambda;

        node_id, T.Expression.Lambda {
          lambda_params = params;
          lambda_body;
          lambda_return_ty;
          lambda_scope;
        }
      )
    )

    | If _if -> (
      let id, spec = annotate_expression_if ~prev_deps env _if in
      id, T.Expression.If spec
    )

    | Array arr_list  -> (
      let a_list = List.map ~f:(annotate_expression ~prev_deps env) arr_list in
      let deps = List.map ~f:(fun expr -> expr.ty_var) a_list in

      let ty_var = Type_context.new_id (Env.ctx env) {
        value = TypeExpr.Unknown;
        loc;
        deps;
        (* TODO: check expression *)
        check = (fun id ->
          if List.is_empty arr_list then (
            Type_context.update_node_type (Env.ctx env) id TypeExpr.(Array Unknown)
          ) else (
            let first = List.hd_exn a_list in
            let first_type = T.Expression.(first.ty_var) in
            let first_node = Type_context.get_node (Env.ctx env) first_type in
            Type_context.update_node_type (Env.ctx env) id TypeExpr.(Array first_node.value)
          )
        );
      } in

      ty_var, (T.Expression.Array a_list)
    )

    | Call call ->
      let ty_var, spec = annotate_expression_call ~prev_deps env loc call in
      ty_var, (T.Expression.Call spec)

    | Member (expr, name) -> (
      let expr = annotate_expression ~prev_deps env expr in
      let ctx = Env.ctx env in
      let scope = Env.peek_scope env in
      let member_name = name.pident_name in
      let node = {
        value = TypeExpr.Unknown;
        loc;
        deps = List.append prev_deps [expr.ty_var];
        check = (fun id ->
          let expr_node = Type_context.get_node ctx expr.ty_var in
          let member_type_opt = Check_helper.find_member_of_type ctx ~scope expr_node.value member_name in
          match member_type_opt with
          (* maybe it's a getter *)
          | Some (TypeDef ({ spec = ClassMethod { method_get_set = Some Getter; method_return; _ }; _ }, _), _) -> (
            Type_context.update_node_type ctx id method_return
          )

          | Some (ty_expr, _) ->
            Type_context.update_node_type ctx id ty_expr

          | None ->
            let err = Type_error.(make_error ctx loc (CannotReadMember(member_name, expr_node.value))) in
            raise (Type_error.Error err)

        );
      } in
      let id = Type_context.new_id ctx node in
      id, T.Expression.Member(expr, name)
    )

    | Index(expr, index_expr) -> (
      let expr = annotate_expression ~prev_deps env expr in
      let index_expr = annotate_expression ~prev_deps env index_expr in
      let node = {
        value = TypeExpr.Unknown;
        deps = [ expr.ty_var; index_expr.ty_var ];
        loc;
        check = (fun id ->
          let ctx = Env.ctx env in
          let node = Type_context.get_node ctx expr.ty_var in
          match (Check_helper.try_unwrap_array ctx node.value) with
          | Some t ->
            Type_context.update_node_type ctx id t

          | None -> (
            let err = Type_error.(make_error ctx loc (CannotGetIndex node.value)) in
            raise (Type_error.Error err)
          )
        );
      } in

      let id = Type_context.new_id (Env.ctx env) node in

      id, (T.Expression.Index(expr, index_expr))
    )

    | Unary _ -> -1, failwith "not implemented"

    | Binary (op, left, right) -> (
      let left = annotate_expression ~prev_deps env left in
      let right = annotate_expression ~prev_deps env right in
      let open T.Expression in
      let node = {
        value = TypeExpr.Unknown;
        deps = [left.ty_var; right.ty_var];
        loc;
        check = (fun id ->
          let ctx = Env.ctx env in
          let left_node = Type_context.get_node ctx left.ty_var in
          let right_node = Type_context.get_node ctx right.ty_var in
          let open Asttypes in
          match op with
          | BinaryOp.Plus -> (
            if not (Check_helper.type_addable ctx left_node.value right_node.value) then (
              let err = Type_error.(make_error ctx loc (CannotApplyBinary (op, left_node.value, right_node.value))) in
              raise (Type_error.Error err)
            );
            Type_context.update_node_type ctx id left_node.value;
          )

          | BinaryOp.Minus
          | BinaryOp.Mult
          | BinaryOp.Div
            -> (
            if not (Check_helper.type_arithmetic ctx left_node.value right_node.value) then (
              let err = Type_error.(make_error ctx loc (CannotApplyBinary (op, left_node.value, right_node.value))) in
              raise (Type_error.Error err)
            );
            Type_context.update_node_type ctx id left_node.value;
          )

          | BinaryOp.Mod
          | BinaryOp.BitAnd
          | BinaryOp.Xor
          | BinaryOp.BitOr
            -> (
            if not (Check_helper.type_arithmetic_integer ctx left_node.value right_node.value) then (
              let err = Type_error.(make_error ctx loc (CannotApplyBinary (op, left_node.value, right_node.value))) in
              raise (Type_error.Error err)
            );
            Type_context.update_node_type ctx id left_node.value;
          )

          | BinaryOp.Equal
          | BinaryOp.NotEqual
          | BinaryOp.LessThan
          | BinaryOp.LessThanEqual
          | BinaryOp.GreaterThan
          | BinaryOp.GreaterThanEqual
            -> (
              if not (Check_helper.type_logic_compareable ctx left_node.value right_node.value) then (
                let err = Type_error.(make_error ctx loc (CannotApplyBinary (op, left_node.value, right_node.value))) in
                raise (Type_error.Error err)
              );
              let bool_ty = Env.ty_boolean env in
              Type_context.update_node_type ctx id (TypeExpr.Ctor (Ref bool_ty, []));
            )

          | _ -> (
              if not (Check_helper.type_logic_compareable ctx left_node.value right_node.value) then (
                let err = Type_error.(make_error ctx loc (CannotApplyBinary (op, left_node.value, right_node.value))) in
                raise (Type_error.Error err)
              );
          )
        );
      } in
      let id = Type_context.new_id (Env.ctx env) node in

      id, (T.Expression.Binary(op, left, right))
    )

    | Update _ -> -1, failwith "not implemented"

    | Assign (op, id, expr) -> (
      let expr = annotate_expression ~prev_deps env expr in
      let scope = Env.peek_scope env in
      let ctx = Env.ctx env in
      let name, ty_int =
        match scope#find_var_symbol id.pident_name with
        | Some var ->
          (* check all find_var_symbol to captured *)
          Env.capture_variable env ~name:id.pident_name;
          (id.pident_name, var.var_id)
        | None -> (
          let err = Type_error.(make_error ctx loc (CannotFindName id.pident_name)) in
          raise (Type_error.Error err)
        )
      in
      let unit_type = Env.ty_unit env in
      let value = (TypeExpr.Ctor (Ref unit_type, [])) in
      let next_id = Type_context.new_id ctx {
        value;
        deps = [ expr.ty_var; ty_int ];
        loc;
        check = (fun _ ->
          let variable = Option.value_exn (scope#find_var_symbol name) in
          (match variable.var_kind with
          | Ast.Pvar_const -> (
            let err = Type_error.(make_error ctx loc CannotAssignToConstVar) in
            raise (Type_error.Error err)
          )
          | _ -> ());
          let sym_node = Type_context.get_node ctx ty_int in
          let expr_node = Type_context.get_node ctx expr.ty_var in
          if not (Check_helper.type_assinable ctx sym_node.value expr_node.value) then (
            let err = Type_error.(make_error ctx loc (NotAssignable(sym_node.value, expr_node.value))) in
            raise (Type_error.Error err)
          )
        );
      } in
      next_id, Assign(op, (name, ty_int), expr)
    )

    | Block block -> (
      let block = annotate_block ~prev_deps env block in
      T.Block.(block.return_ty), (T.Expression.Block block)
    )

    | Init init -> (
      let { init_loc; init_name; init_elements } = init in
      let ctx = Env.ctx env in
      let type_int = (Env.peek_scope env)#find_type_symbol init_name.pident_name in
      let deps = ref [] in

      let annotate_element elm =
        match elm with
        | InitSpread expr -> (
          let expr = annotate_expression ~prev_deps env expr in
          deps := expr.ty_var::!deps;
          T.Expression.InitSpread expr
        )
        | InitEntry { init_entry_loc; init_entry_key; init_entry_value } -> (
          let init_entry_value =
            Option.map
            ~f:(fun expr ->
              let expr' = annotate_expression ~prev_deps env expr in
              deps := expr'.ty_var::!deps;
              expr'
            )
            init_entry_value
          in
          T.Expression.InitEntry {
            init_entry_loc;
            init_entry_key;
            init_entry_value;
          }
        )
      in

      match type_int with
      | Some v -> (
        let node = {
          value = TypeExpr.Ctor(Ref v, []);
          loc = init_loc;
          deps = List.rev !deps;
          (* TODO: check props and expressions *)
          check = none;
        } in
        let node_id = Type_context.new_id ctx node in
        node_id, T.Expression.Init{
          init_loc;
          init_name = (init_name.pident_name, v);
          init_elements = List.map ~f:annotate_element init_elements;
        } 
      )
      | None -> (
        let err = Type_error.(make_error ctx init_loc (CannotFindName init_name.pident_name)) in
        raise (Type_error.Error err)
      )

    )

    | Match _match -> (
      let { match_expr; match_clauses; match_loc } = _match in
      let match_expr = annotate_expression ~prev_deps env match_expr in

      let annotate_clause clause =
        let open Ast.Expression in
        let { clause_pat; clause_consequent; clause_loc } = clause in
        let clause_pat, clause_deps = annotate_pattern env clause_pat in
        let clause_consequent = annotate_expression ~prev_deps:[clause_deps] env clause_consequent in
        { T.Expression.
          clause_pat;
          clause_consequent;
          clause_loc;
        }
      in

      let match_clauses = List.map ~f:annotate_clause match_clauses in
      let clauses_deps = List.map ~f:(fun clause -> T.Expression.(clause.clause_consequent.ty_var)) match_clauses in

      let node = {
        Core_type.
        value = Unknown;
        deps = List.append [match_expr.ty_var] clauses_deps;
        check = (fun id ->
          let ty =
            if List.is_empty match_clauses then (
              let ty_unit = Env.ty_unit env in
              TypeExpr.Ctor(Ref ty_unit, [])
            ) else (
              (* TODO: better way to check every clauses *)
              List.fold
                ~init:TypeExpr.Unknown
                ~f:(fun acc item ->
                  let ctx = Env.ctx env in
                  let node_expr = Type_context.deref_node_type ctx item in
                  match (acc, node_expr) with
                  | TypeExpr.Unknown, _ ->
                    node_expr

                  | (TypeExpr.Ctor(c1, [])), (TypeExpr.Ctor (c2, [])) ->  (
                    let c1_def = Type_context.deref_type ctx c1 in
                    let c2_def = Type_context.deref_type ctx c2 in
                    (match (c1_def, c2_def) with
                    | (TypeExpr.TypeDef (left_sym, _), TypeExpr.TypeDef (right_sym, _)) -> (
                      if TypeDef.(left_sym == right_sym) then ()
                      else
                        let err = Type_error.(make_error (Env.ctx env) match_loc (NotAllTheCasesReturnSameType(c1_def, c2_def))) in
                        raise (Type_error.Error err)
                    )
                    | _ -> (
                      let err = Type_error.(make_error (Env.ctx env) match_loc (NotAllTheCasesReturnSameType(c2_def, c2_def))) in
                      raise (Type_error.Error err)
                    ));

                    acc
                  )

                  | _ -> (
                    acc
                  )
                )
                clauses_deps
            )
          in
          Type_context.update_node_type (Env.ctx env) id ty
        );
        loc = match_loc;
      } in

      let id = Type_context.new_id (Env.ctx env) node in

      id, (T.Expression.Match { T.Expression.
        match_expr;
        match_clauses;
        match_loc;
      })
    )

    | This
    | Super -> failwith "not implemented this"

  in
  { T.Expression.
    spec;
    loc;
    attributes;
    ty_var;
  }

and annotate_expression_call ~prev_deps env loc call =
  let open Ast.Expression in
  let { callee; call_params; call_loc } = call in

  let callee = annotate_expression ~prev_deps env callee in
  let call_params = List.map ~f:(annotate_expression ~prev_deps env) call_params in

  let params_deps = List.map ~f:(fun expr -> expr.ty_var) call_params in

  let ty_var = Type_context.new_id (Env.ctx env) {
    value = TypeExpr.Unknown;
    loc;
    deps = List.append [ T.Expression.(callee.ty_var) ] params_deps;
    check = (fun id ->
      let ctx = Env.ctx env in
      let ty_int = callee.ty_var in
      let deref_type_expr = Type_context.deref_node_type ctx ty_int  in
      match deref_type_expr with
      | TypeExpr.Lambda(_params, ret) -> (
        (* TODO: check call params *)
        Type_context.update_node_type ctx id ret
      )
      | _ ->
        begin
          let _ty_def = Check_helper.find_construct_of ctx deref_type_expr in
          match deref_type_expr with
          | TypeExpr.TypeDef ({ TypeDef. spec = Function _fun; _ }, _) ->
            (* TODO: check call params *)
            Type_context.update_node_type ctx id _fun.fun_return

          | TypeExpr.TypeDef ({ TypeDef. spec = ClassMethod _method; _ }, _) ->
            (* TODO: check call params *)
            Type_context.update_node_type ctx id _method.method_return

          | TypeExpr.TypeDef ({ TypeDef. spec = EnumCtor enum_ctor; _}, _) -> (
            let super_id = enum_ctor.enum_ctor_super_id in
            Type_context.update_node_type ctx id (TypeExpr.Ctor (Ref super_id, []))
          )

          | _ -> (
            let err = Type_error.(make_error ctx call_loc (NotCallable deref_type_expr)) in
            raise (Type_error.Error err)
          )
        end
    );
  } in

  ty_var, { T.Expression. callee; call_params; call_loc }

and annotate_expression_if ~prev_deps env _if =
  let open Ast.Expression in
  let { if_test; if_consequent; if_alternative; if_loc } = _if in

  let if_test = annotate_expression env ~prev_deps if_test in
  let if_consequent = annotate_block ~prev_deps:[if_test.ty_var] env if_consequent in
  let alt_deps = ref [] in
  let if_alternative =
    Option.map
    ~f:(fun alt ->
      match alt with
      | If_alt_block block ->
        let blk = annotate_block ~prev_deps:[if_test.ty_var] env block in
        alt_deps := [blk.return_ty];
        T.Expression.If_alt_block blk

      | If_alt_if else_if ->
        let id, else_if = annotate_expression_if ~prev_deps:[if_test.ty_var] env else_if in
        alt_deps := [id];
        T.Expression.If_alt_if else_if

    )
    if_alternative
  in

  let node = {
    value = TypeExpr.Unknown;
    loc = if_loc;
    check = none;
    deps = List.append [if_consequent.return_ty] !alt_deps;
  } in

  let node_id = Type_context.new_id (Env.ctx env) node in
  node_id, { T.Expression.
    if_test;
    if_consequent;
    if_alternative;
    if_loc;
  }

and annotate_block ~prev_deps env block : T.Block.t =
  let open Ast.Block in
  let { body; loc } = block in
  let body_dep, body_stmts =
    List.fold_map
      ~init:prev_deps
      ~f:(fun prev_deps stmt ->
        annotate_statement ~prev_deps env stmt
      )
      body
  in
  let node = {
    value = TypeExpr.Unknown;
    deps = body_dep;
    loc;
    check = (fun id ->
      let ctx = Env.ctx env in
      let last_opt = List.last body_stmts in
      match last_opt with
      | Some { Typedtree.Statement. spec = Expr expr ; _ } -> (
        let ty_var = Typedtree.Expression.(expr.ty_var) in
        Type_context.update_node_type ctx id (TypeExpr.Ref ty_var)
      )

      | _ -> (
        let unit_type = Env.ty_unit env in
        Type_context.update_node_type ctx id (TypeExpr.Ctor(Ref unit_type, []))
      )
    );
  } in
  let return_ty = Type_context.new_id (Env.ctx env) node in
  { T.Block.
    body = body_stmts;
    loc;
    return_ty;
  }

and annotate_declaration env decl : T.Declaration.t =
  let open Ast.Declaration in
  let { spec; loc; attributes } = decl in
  let ty_var, spec =
    match spec with
    | Class _class -> (
      let open Typedtree.Declaration in
      let _class = annotate_class env _class in
      let _, ty_int = _class.cls_id in
      ty_int, T.Declaration.Class _class
    )

    | Function_ _fun -> (
      let open Typedtree.Function in
      let _fun = annotate_function env _fun in
      _fun.ty_var, T.Declaration.Function_ _fun
    )

    | Declare declare -> (
      let { decl_spec; decl_visibility; decl_loc } = declare in
      match decl_spec with
      | DeclFunction declare_fun -> (
        let { Ast.Function. id; params; return_ty; _ } = declare_fun in

        let params, params_types = annotate_function_params env params in

        let scope = Env.peek_scope env in
        let ty_id =
          match scope#find_var_symbol id.pident_name with
          | Some v -> v.var_id
          | None -> failwith (Format.sprintf "unexpected: %s is not added to scope\n" id.pident_name)
        in

        let fun_return, fun_return_deps =
          match return_ty with
          | Some ty -> (
            annotate_type env ty
          )
          | None -> (
            let unit_ty = Env.ty_unit env in
            TypeExpr.Ctor(Ref unit_ty, []), []
          )
        in

        let ty_def = {
          TypeDef.
          builtin = false;
          name = id.pident_name;
          spec = Function {
            fun_params = [];
            fun_return;
          }
        } in

        Type_context.update_node (Env.ctx env) ty_id {
          value = TypeExpr.TypeDef(ty_def, ty_id);
          deps = List.append params_types fun_return_deps;
          loc = decl_loc;
          check = none;
        };

        (match List.last attributes with
        | Some { Ast. attr_name = { txt = "external"; _ }; attr_payload = ext_name::_; _ } ->
          Type_context.set_external_symbol (Env.ctx env) ty_id ext_name

        | _ ->
          let open Type_error in
          let err = make_error (Env.ctx env) loc DeclareFunctionShouldSpecificExternal in
          raise (Error err)
        );

        let header = {
          T.Function.
          name = (Identifier.(id.pident_name), ty_id);
          name_loc= Identifier.(id.pident_loc) ;
          params;
        } in

        ty_id, (T.Declaration.Declare {
          T.Declaration.
          decl_visibility;
          decl_ty_var = ty_id;
          decl_spec = T.Declaration.DeclFunction header;
          decl_loc;
        })
      )
    )

    | Enum enum ->
      let enum = annotate_enum env enum in
      let _, ty_var = T.Enum.(enum.name) in
      ty_var, T.Declaration.Enum enum

    | Import import -> -1, T.Declaration.Import import

  in
  let result = { T.Declaration. spec; loc; attributes } in

  (* record the declaration for linking stage *)
  if ty_var >= 0 then (
    let open Type_context in
    let ctx = Env.ctx env in
    Hashtbl.set ctx.declarations ~key:ty_var ~data:result
  );

  result

(*
 * class annotation is done in two phase
 * 1. scan all methods and properties, infer `this`
 * 2. annotate all methods and collect dependencies
 *
 *)
and annotate_class env cls =
  let open Ast.Declaration in

  let cls_var = Option.value_exn ((Env.peek_scope env)#find_var_symbol cls.cls_id.pident_name) in

  let prev_scope = Env.peek_scope env in
  let class_scope = new class_scope ~prev:prev_scope () in

  List.iter
    ~f:(fun ident ->
      class_scope#insert_generic_type_symbol ident.pident_name;
    )
    cls.cls_type_vars;

  let tcls_static_elements = ref [] in
  let tcls_elements = ref [] in
  let props_deps = ref [] in
  let method_deps = ref [] in

  let ctx = Env.ctx env in
  (* prescan class property and method *)
  List.iter
    ~f:(fun item ->
      match item with
      | Cls_method _method -> (
        let { cls_method_name; cls_method_visibility; cls_method_loc; cls_method_modifier; _ } = _method in
        let node = {
          value = TypeExpr.Unknown;
          deps = [];
          loc = cls_method_loc;
          check = none;
        } in
        let node_id = Type_context.new_id ctx node in
        match cls_method_modifier with
        | (Some Cls_modifier_static) -> (
          tcls_static_elements := (cls_method_name.pident_name, node_id)::!tcls_static_elements;
        )

        | _ -> (
          tcls_elements := ((cls_method_name.pident_name, node_id)::!tcls_elements);
          class_scope#insert_cls_element
            { Scope.ClsElm.
              name = (cls_method_name.pident_name, node_id);
              spec = Method;
              visibility = cls_method_visibility;
            }
        )
      )
      | Cls_property property -> (
        let { cls_property_name; cls_property_type; cls_property_loc; cls_property_visibility; _  } = property in
        let property_ty, deps = annotate_type env cls_property_type in
        let node = {
          value = property_ty;
          deps;
          loc = cls_property_loc;
          check = none;
        } in
        let node_id = Type_context.new_id ctx node in
        tcls_elements := ((cls_property_name.pident_name, node_id)::!tcls_elements);

        (*
         * the class itself depends on all the properties
         * all the method depends on the class
         *)
         props_deps := node_id::(!props_deps);

        class_scope#insert_cls_element
          { Scope.ClsElm.
            name = (cls_property_name.pident_name, node_id);
            spec = Property;
            visibility = cls_property_visibility;
          }
      )

      | Cls_declare declare -> (
        let { cls_decl_method_name; cls_decl_method_loc; cls_decl_method_get_set; cls_decl_method_attributes; _ } = declare in
        let node = {
          value = TypeExpr.Unknown;
          deps = [];
          loc = cls_decl_method_loc;
          check = none;
        } in
        let node_id = Type_context.new_id ctx node in

        (match List.last cls_decl_method_attributes with
        | Some { Ast. attr_name = { txt = "external"; _ }; attr_payload = ext_name::_; _ } ->
          Type_context.set_external_symbol (Env.ctx env) node_id ext_name

        | _ ->
          let open Type_error in
          let err = make_error (Env.ctx env) cls_decl_method_loc DeclareFunctionShouldSpecificExternal in
          raise (Error err)
        );

        tcls_elements := ((cls_decl_method_name.pident_name, node_id)::!tcls_elements);
        match cls_decl_method_get_set with
        | Some Cls_getter -> 
          class_scope#insert_cls_element
            { Scope.ClsElm.
              name = (cls_decl_method_name.pident_name, node_id);
              spec = Getter;
              (* temporary use public here *)
              visibility = Some Asttypes.Pvisibility_public;
            }

        | Some Cls_setter ->
          class_scope#insert_cls_element
            { Scope.ClsElm.
              name = cls_decl_method_name.pident_name, node_id;
              spec = Setter;
              (* temporary use public here *)
              visibility = Some Asttypes.Pvisibility_public;
            }

        | None ->
          class_scope#insert_cls_element
            { Scope.ClsElm.
              name = cls_decl_method_name.pident_name, node_id;
              spec = Method;
              (* temporary use public here *)
              visibility = Some Asttypes.Pvisibility_public;
            }
      )

    )
    cls.cls_body.cls_body_elements;

  (* depend on the base class *)
  Option.iter
    ~f:(fun extend ->
      let var = (Env.peek_scope env)#find_var_symbol extend.pident_name in
      match var with
      | Some var ->
        props_deps := (var.var_id)::!props_deps;

      | None -> (
        let err = Type_error.(make_error (Env.ctx env) extend.pident_loc (CannotFindName extend.pident_name)) in
        raise (Type_error.Error err)
      )
    )
    cls.cls_extends;

  let annotate_class_body body =
    let { cls_body_elements; cls_body_loc; } = body in
    let cls_body_elements =
      List.map ~f:(fun elm ->
        match elm with
        | Cls_method _method -> (
          let method_scope = new scope ~prev:(Env.peek_scope env) () in
          let { cls_method_attributes; cls_method_visibility; cls_method_modifier; cls_method_name; cls_method_params; cls_method_loc; cls_method_body; cls_method_return_ty; _ } = _method in
          let method_id =
            match cls_method_modifier with
            | Some Ast.Declaration.Cls_modifier_static -> (
              let result = List.find ~f:(fun (name, _) -> String.equal name cls_method_name.pident_name) !tcls_static_elements in
              match result with
              | Some (_, id) -> id
              | None ->
                failwith (Format.sprintf "unexpected: can not find static class method %s" cls_method_name.pident_name)
            )

            | _ -> (
              match (class_scope#find_cls_element cls_method_name.pident_name ClsElm.Method) with
              | Some ({ name = _, method_id; _ }) -> method_id
              | None -> failwith (Format.sprintf "unexpected: can not find class method %s" cls_method_name.pident_name)
            )
          in
          let method_is_virtual =
            match cls_method_modifier with
            | Some Ast.Declaration.Cls_modifier_virtual
            | Some Ast.Declaration.Cls_modifier_override -> true
            | _ -> false
          in
          Env.with_new_scope env method_scope (fun env ->
            let cls_method_params, cls_method_params_deps = annotate_function_params env cls_method_params in
            let cls_method_body = annotate_block ~prev_deps:cls_method_params_deps env cls_method_body in

            let this_deps = ref !props_deps in

            this_deps := Typedtree.Block.(cls_method_body.return_ty)::(!this_deps);

            (* check return *)
            let _collected_returns = Env.take_return_types env in

            let method_return, return_ty_deps =
              match cls_method_return_ty with
              | Some ty -> annotate_type env ty
              | None -> (
                let unit_type = Env.ty_unit env in
                TypeExpr.(Ctor (Ref unit_type, [])), [unit_type]
              )
            in

            let new_type =
              match _method.cls_method_modifier with
              | Some Cls_modifier_static -> { TypeDef.
                builtin = false;
                name = cls_method_name.pident_name;
                spec = Function {
                  fun_params = [];
                  fun_return = method_return;
                };
              }
              | _ -> { TypeDef.
                builtin = false;
                name = cls_method_name.pident_name;
                spec = ClassMethod {
                  method_cls_id = cls_var.var_id;
                  method_get_set = None;
                  method_is_virtual;
                  method_params = [];
                  method_return;
                };
              }
            in

            (* class method deps *)
            method_deps := List.append !method_deps [method_id];

            this_deps := List.append !this_deps return_ty_deps;

            Type_context.map_node ctx
              ~f:(fun node -> {
                node with
                deps = List.rev !this_deps
                |> List.filter
                  ~f:(fun id -> id <> cls_var.var_id)
                ;
                value = (TypeExpr.TypeDef(new_type, method_id));
              })
              method_id
              ;
            T.Declaration.Cls_method {
              T.Declaration.
              cls_method_attributes;
              cls_method_visibility;
              cls_method_modifier;
              cls_method_params;
              cls_method_name = (cls_method_name.pident_name, method_id);
              cls_method_scope = Some method_scope;
              cls_method_body;
              cls_method_loc;
            }
          )
        )
        | Cls_property prop -> (
          let { cls_property_visibility; cls_property_loc; cls_property_name; _ } = prop in
          T.Declaration.Cls_property {
            T.Declaration.
            cls_property_loc;
            cls_property_visibility;
            cls_property_name;
          }
        )

        | Cls_declare declare -> (
          let { cls_decl_method_attributes; cls_decl_method_name; cls_decl_method_params; cls_decl_method_loc; cls_decl_method_return_ty; cls_decl_method_get_set; _ } = declare in

          let find_flag =
            match cls_decl_method_get_set with
            | Some Ast.Declaration.Cls_getter -> ClsElm.Getter
            | Some Ast.Declaration.Cls_setter -> ClsElm.Setter
            | None -> ClsElm.Method
          in

          let declare_id =
            match (class_scope#find_cls_element cls_decl_method_name.pident_name find_flag) with
            | Some ({ name = _, id; _ }) -> id
            | None -> failwith (Format.sprintf "unexpected: can not find class method %s" cls_decl_method_name.pident_name)
          in

          let cls_decl_method_params, cls_method_params_deps = annotate_function_params env cls_decl_method_params in

          let method_return, return_ty_deps =
            match cls_decl_method_return_ty with
            | Some ty -> annotate_type env ty
            | None -> (
              let unit_type = Env.ty_unit env in
              TypeExpr.(Ctor (Ref unit_type, [])), [unit_type]
            )
          in

          let method_get_set =
            Option.map
            ~f:(fun get_set ->
              match get_set with
              | Ast.Declaration.Cls_getter -> TypeDef.Getter
              | Ast.Declaration.Cls_setter -> TypeDef.Setter
            )
            cls_decl_method_get_set
          in

          let new_type =
            { TypeDef.
              builtin = false;
              name = cls_decl_method_name.pident_name;
              spec = ClassMethod {
                method_cls_id = cls_var.var_id;
                method_get_set;
                method_is_virtual = false;
                method_params = [];
                method_return;
              };
            }
          in

          Type_context.map_node ctx
            ~f:(fun node -> {
              node with
              deps = (List.append cls_method_params_deps return_ty_deps)
              |> List.filter
                ~f:(fun id -> id <> cls_var.var_id)
              ;
              value = (TypeExpr.TypeDef(new_type, declare_id));
            })
            declare_id
            ;

          T.Declaration.Cls_declare {
            cls_decl_method_attributes;
            cls_decl_method_loc;
            cls_decl_method_name = cls_decl_method_name.pident_name, declare_id;
            cls_decl_method_params;
          }
        )
      )
      cls_body_elements
    in
    { T.Declaration. cls_body_elements; cls_body_loc}
  in

  Env.with_new_scope env class_scope (fun _env ->
    let { cls_id; cls_visibility; cls_type_vars = _; cls_loc; cls_body; cls_comments; _ } = cls in
    let tcls_name = cls_id.pident_name in
    let cls_id = tcls_name, cls_var.var_id in
    let cls_body = annotate_class_body cls_body in

    (* reduced all method and elements here *)
    Type_context.map_node ctx 
      ~f:(fun node -> {
        node with
        value = TypeExpr.TypeDef (
          { TypeDef.
            builtin = false;
            name = cls.cls_id.pident_name;
            spec = Class {
              tcls_name;
              tcls_extends = None;
              tcls_elements = List.rev !tcls_elements;
              tcls_static_elements = List.rev !tcls_static_elements;
            };
          },
          cls_var.var_id
        );
        loc = cls.cls_loc;
        deps = 
          (* remove self-reference *)
          List.filter
          ~f:(fun id -> id <> cls_var.var_id)
          (if List.is_empty !method_deps then List.rev !props_deps else List.rev !method_deps);
      })
      cls_var.var_id;

    { T.Declaration. cls_id; cls_visibility; cls_body; cls_loc; cls_comments; }
  )

and annotate_an_def_identifer env ident =
  let open Identifier in
  let { pident_name; pident_loc } = ident in
  let node = {
    Core_type.
    loc = pident_loc;
    value = TypeExpr.Unknown;
    check = none;
    deps = [];
  } in
  let id = Type_context.new_id (Env.ctx env) node in
  pident_name, id

and annotate_pattern env pat =
  let open Ast.Pattern in
  let { spec; loc } = pat in
  let scope = Env.peek_scope env in
  let id, spec =
    match spec with
    | Identifier ident -> (
      let first_char = String.get ident.pident_name 0 in
      (* It's a enum contructor *)
      if Char.is_uppercase first_char then (
        Env.capture_variable env ~name:ident.pident_name;

        let ctor_var = scope#find_var_symbol ident.pident_name in
        if Option.is_none ctor_var then (
          let err = Type_error.(make_error (Env.ctx env) ident.pident_loc (NotAEnumConstructor ident.pident_name)) in
          raise (Type_error.Error err)
        );
        let ctor = Option.value_exn ctor_var in
        ctor.var_id, (T.Pattern.Symbol (ident.pident_name, ctor.var_id))
      ) else (
        let name, id = annotate_an_def_identifer env ident in
        id, (T.Pattern.Symbol (name, id))
      )
    )

    | EnumCtor(id, pat) -> (
      let ctor_var = scope#find_var_symbol id.pident_name in
      if Option.is_none ctor_var then (
        let err = Type_error.(make_error (Env.ctx env) loc (CannotFindName id.pident_name)) in
        raise (Type_error.Error err)
      );
      let ctor_var = Option.value_exn ctor_var in

      let param_pat, pat_id = annotate_pattern env pat in

      pat_id, (T.Pattern.EnumCtor (
        (id.pident_name, ctor_var.var_id),
        param_pat
      ))
    )

  in
  { T.Pattern. spec; loc }, id

(* only collect deps, construct value in type check *)
and annotate_type env ty : (TypeExpr.t * int list) =
  let open Ast.Type in
  let { spec; _ } = ty in
  let deps = ref [] in
  let scope = Env.peek_scope env in
  match spec with
  | Ty_any -> TypeExpr.Any, []
  | Ty_ctor(ctor, params) -> (
    let { Identifier. pident_name; pident_loc } = ctor in

    let params, params_deps = List.map ~f:(annotate_type env) params |> List.unzip in
    deps := List.concat (!deps::params_deps);

    if scope#is_generic_type_symbol pident_name then
      TypeExpr.Ctor (TypeSymbol pident_name, params), !deps
    else (
      let ty_var_opt = (Env.peek_scope env)#find_type_symbol pident_name in
      match ty_var_opt with
      | Some ty_var -> (
        (* TODO: find ctor in the scope *)
        TypeExpr.Ctor (Ref ty_var, params), ty_var::!deps
      )

      | None -> (
        (Env.peek_scope env)#print_type_symbols;
        let ctx = Env.ctx env in
        let err_spec = Type_error.CannotFindName pident_name in
        let err = Type_error.make_error ctx pident_loc err_spec in
        raise (Type_error.Error err)
      )
    )

  )
  | Ty_array target -> (
    let target_type, target_type_deps = annotate_type env target in
    TypeExpr.Array target_type, target_type_deps
  )

  | Ty_arrow (params, result) -> (
    let params, params_types_deps = List.map ~f:(annotate_type env) params |> List.unzip in
    let return_type, return_type_deps = annotate_type env result in
    deps := List.concat ((!deps)::return_type_deps::params_types_deps);
    TypeExpr.Lambda(params, return_type), !deps
  )

and annotate_function_params env params = 
  let open Ast.Function in
  let annoate_param param =
    let { param_name; param_ty; param_loc; param_rest } = param in
    let param_name = annotate_an_def_identifer env param_name in
    let _, param_id = param_name in
    let deps = ref [] in
    let value = ref TypeExpr.Unknown in
    Option.iter
      ~f:(fun ty ->
        let param_ty, param_ty_deps = annotate_type env ty in
        deps := List.append param_ty_deps !deps;
        value := param_ty;
      )
      param_ty
    ;
    let node = {
      loc = param_loc;
      value = !value;
      deps = !deps;
      check = none;  (* check init *)
    } in
    Type_context.update_node (Env.ctx env) param_id node;
    { T.Function.
      param_name;
      param_ty = param_id;
      param_loc;
      param_rest;
    }, param_id
  in

  let { params_content; params_loc } = params in
  let params, params_types = List.map ~f:annoate_param params_content |> List.unzip in
  { T.Function. params_content = params; params_loc }, params_types

and annotate_function env fun_ =
  let open Ast.Function in

  let prev_scope = Env.peek_scope env in
  let fun_scope = new scope ~prev:prev_scope () in

  Env.with_new_scope env fun_scope (fun env ->
    let { visibility = _visibility; header; body; loc; comments; } = fun_ in

    let fun_id_opt = prev_scope#find_var_symbol header.id.pident_name in
    if Option.is_none fun_id_opt then (
      failwith (Format.sprintf "unexpected: function id %s is not added in parsing stage" header.id.pident_name)
    );
    let fun_id = (Option.value_exn fun_id_opt).var_id in
    let name_node = Type_context.get_node (Env.ctx env) fun_id in
    let fun_deps = ref [] in

    let name_node = {
      name_node with
      loc;
    } in
    Type_context.update_node (Env.ctx env) fun_id name_node;

    (*
     * differnt from TypeScript
     * if no return type is defined, use 'unit' type
     * do not try to infer from block, that's too complicated
     *)
    let return_ty, return_ty_Deps =
      match header.return_ty with
      | Some type_expr ->
        annotate_type env type_expr
      | None ->
        let unit_type = Env.ty_unit env in
        TypeExpr.Ctor(Ref unit_type, []), []
    in

    fun_deps := List.append !fun_deps return_ty_Deps;

    let params, params_types = annotate_function_params env header.params in

    (* add all params into scope *)
    List.iter
      ~f:(fun param -> 
        let name, _ = param.param_name in
        fun_scope#new_var_symbol name ~id:param.param_ty ~kind:Ast.Pvar_let;
      )
      params.params_content;

    let body = annotate_block ~prev_deps:params_types env body in
    let collected_returns = Env.take_return_types env in

    (* defined return *)
    fun_deps := body.return_ty::(!fun_deps);
    fun_deps := List.append !fun_deps collected_returns;

    Type_context.update_node (Env.ctx env) fun_id {
      name_node with
      value = TypeExpr.Unknown;  (* it's an typedef *)
      (* deps = return_id::params_types; *)
      deps = !fun_deps;
      check = (fun id ->
        let ctx = Env.ctx env in
        let block_node = Type_context.get_node ctx body.return_ty in
        (* if no return statements, use last statement of block *)
        if List.is_empty collected_returns then (
          if not (Check_helper.type_assinable ctx return_ty block_node.value) then (
            let open Type_error in
            let spec = CannotReturn(return_ty, block_node.value) in
            let err = make_error ctx block_node.loc spec in
            raise (Error err)
          );
          (* Type_context.update_node_type ctx id return_ty *)
        ) else (
          (* there are return statements, check every statments *)
          List.iter
            ~f:(fun return_ty_var ->
              let return_ty_node = Type_context.get_node ctx return_ty_var in
              if not (Check_helper.type_assinable ctx return_ty return_ty_node.value) then (
                let open Type_error in
                let spec = CannotReturn(return_ty, return_ty_node.value) in
                let err = make_error ctx return_ty_node.loc spec in
                raise (Error err)
              )
            )
            collected_returns
        );
        let type_def = { TypeDef.
          builtin = false;
          name = fun_.header.id.pident_name;
          spec = Function {
            fun_params = [];
            fun_return = return_ty;
          };
        } in
        Type_context.update_node_type ctx id (TypeExpr.TypeDef(type_def, id))
      );
    };
    { T.Function.
      header = {
        name = (header.id.pident_name, fun_id);
        name_loc = header.id.pident_loc;
        params;
      };
      scope = fun_scope;
      body;
      ty_var = fun_id;
      comments;
    }
  )

and annotate_enum env enum =
  let open Ast.Enum in
  let { visibility; name; loc; cases; type_vars } = enum in
  let ctx = Env.ctx env in
  let scope = Env.peek_scope env in
  let variable = Option.value_exn (scope#find_var_symbol name.pident_name) in

  let scope = new scope ~prev:scope () in

  let type_vars_names =
    List.map
      ~f:(fun ident ->
        scope#insert_generic_type_symbol ident.pident_name;

        ident.pident_name
      )
      type_vars
  in

  Env.with_new_scope env scope (fun env ->
    let annotate_case index _case =
      let { case_name; case_fields; case_loc } = _case in
      let member_var = Option.value_exn (scope#find_var_symbol case_name.pident_name) in

      let fields_types, deps = List.map ~f:(annotate_type env) case_fields |> List.unzip in

      let first_char = String.get case_name.pident_name 0 in
      if not (Char.is_uppercase first_char) then (
        let err = Type_error.(make_error ctx case_name.pident_loc (CapitalizedEnumMemeber case_name.pident_name)) in
        raise (Type_error.Error err)
      );

      Type_context.map_node
        ctx
        ~f:(fun node -> {
          node with
          deps = List.concat ([variable.var_id]::deps);
          loc = case_loc;
          check = (fun id ->
            let ty_def = {
              TypeDef.
              enum_ctor_tag_id = index;
              enum_ctor_name = case_name.pident_name;
              enum_ctor_super_id = variable.var_id;
              enum_ctor_params = [];
            } in
            Type_context.update_node_type ctx id (TypeExpr.TypeDef({
              builtin = false;
              name = case_name.pident_name;
              spec = EnumCtor ty_def;
            }, id))
          )
        })
        member_var.var_id
      ;

      { T.Enum.
        case_name = (case_name.pident_name, member_var.var_id);
        case_fields = fields_types;
        case_loc;
      }, member_var.var_id 
    in

    let cases, _cases_deps = List.mapi ~f:annotate_case cases |> List.unzip in

    Type_context.map_node
      ctx
      ~f:(fun node ->
        let enum_params =
          List.map
          ~f:(fun id -> Identifier.(id.pident_name))
          type_vars
        in
        { node with
          (* deps = cases_deps; *)
          deps = [];
          loc;
          check = (fun id ->
            let ty_def = {
              TypeDef.
              enum_members = [];
              enum_params;
            } in
            Type_context.update_node_type ctx id (TypeExpr.TypeDef({
              builtin = false;
              name = name.pident_name;
              spec = Enum ty_def;
            }, id))
          )
        }
      )
      variable.var_id;

    { T.Enum.
      visibility;
      name = (name.pident_name, variable.var_id);
      type_vars = type_vars_names;
      cases;
      loc;
    }
  )

let annotate_program env (program: Ast.program) =
  let { Ast. pprogram_declarations; pprogram_top_level = _; pprogram_loc; _; } = program in

  let tprogram_declarations = List.map ~f:(annotate_declaration env) pprogram_declarations in

  let deps =
    List.fold
      ~init:[]
      ~f:(fun acc decl -> 
        let open T.Declaration in
        let { spec; _ } = decl in
        match spec with
        | Class cls -> (
          let { cls_id = (_, ty_var); _} = cls in
          ty_var::acc
        )

        | Function_ _fun -> (
          let open T.Function in
          let { ty_var; _ } = _fun in
          ty_var::acc
        )

        | Declare declare -> (
          let { decl_ty_var; _ } = declare in
          decl_ty_var::acc
        )

        | Enum enum -> (
          let open T.Enum in
          let { name = (_, ty_var); _ } = enum in
          ty_var::acc
        )

        | Import _ -> acc
        
      )
      tprogram_declarations
  in

  let val_ =
    {
      value = TypeExpr.Unknown;
      loc = pprogram_loc;
      deps;
      check = none;
    }
  in
  let ty_var = Type_context.new_id (Env.ctx env) val_ in
  let tree = { T.
    tprogram_declarations;
    tprogram_scope = Env.module_scope env;
    ty_var
  } in
  tree
