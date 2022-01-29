(*
 * This file is part of LichenScript Compiler.
 *
 * LichenScript Compiler is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
 *
 * LichenScript Compiler is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with LichenScript Compiler. If not, see <https://www.gnu.org/licenses/>.
 *)
open Core_kernel
open Core_type
open Lichenscript_parsing

module IntHash = Hashtbl.Make(Int)
module T = Typedtree

(*
 * Type check deeply, check every expressions
 **)
type env = {
  ctx: Type_context.t;
  mutable scope: Scope.scope;
}

let get_global_type_val env =
  let root_scope = Type_context.root_scope env.ctx in
  root_scope#find_type_symbol

let unwrap_global_type name env =
  Option.value_exn (get_global_type_val env name)

let[@warning "-unused-value-declaration"]
  ty_u32 = unwrap_global_type "u32"

let[@warning "-unused-value-declaration"]
  ty_i32 = unwrap_global_type "i32"

let[@warning "-unused-value-declaration"]
  ty_f32 = unwrap_global_type "f32"

let[@warning "-unused-value-declaration"]
  ty_char = unwrap_global_type "char"

let[@warning "-unused-value-declaration"]
  ty_boolean = unwrap_global_type "boolean"

let[@warning "-unused-value-declaration"]
  ty_unit =unwrap_global_type "unit"

let with_scope env scope cb =
  let prev = env.scope in
  env.scope <- scope;
  let result = cb env in
  env.scope <- prev;
  result

let rec typecheck_module ctx ~debug (typedtree: T.program) =
  try
    let { T. tprogram_declarations; tprogram_scope; _ } = typedtree in
    let env = {
      ctx;
      scope = tprogram_scope;
    } in
    List.iter ~f:(check_declaration env) tprogram_declarations;
    if debug then (
      Type_context.print ctx
    );
  with e ->
    if debug then (
      Type_context.print ctx
    );
    raise e

and check_declaration env decl =
  let open T.Declaration in
  match decl.spec with
  | Class cls -> check_class env cls
  | Function_ _fun -> check_function env _fun
  | Declare _ -> ()
  | Enum _ ->  ()
  | Import _ -> ()

and check_function env _fun =
  let open T.Function in
  let { scope; body; _ } = _fun in
  with_scope env scope (fun env ->
    check_block env body
  )

and check_block env blk =
  let open T.Block in
  let { body; scope; return_ty; _ } = blk in
  with_scope env scope (fun env ->
    List.iter
      ~f:(check_statement env)
      body;
    let last_opt = List.last body in
    match last_opt with
    | Some { Typedtree.Statement. spec = Expr expr ; _ } -> (
      let ty_var = Typedtree.Expression.(expr.ty_var) in
      Type_context.update_node_type env.ctx return_ty (TypeExpr.Ref ty_var)
    )

    | _ -> (
      let unit_type = ty_unit env in
      Type_context.update_node_type env.ctx return_ty (TypeExpr.Ctor(Ref unit_type, []))
    )
  )

and check_statement env stmt =
  let open T.Statement in
  match stmt.spec with
  | Expr expr -> check_expression env expr
  | Semi expr ->
    (* TODO: check return is unit *)
    check_expression env expr

  | While { while_test; while_block; _ } -> (
    check_expression env while_test; (* TODO: check boolean? *)
    List.iter ~f:(check_statement env) while_block.body
  )

  | Binding binding -> (
    let { binding_ty_var; binding_init; _ } = binding in
    check_expression env binding_init;
    let expr_node = Type_context.get_node env.ctx binding_init.ty_var in
    Type_context.update_node_type env.ctx binding_ty_var expr_node.value
  )

  | Break _ -> ()

  | Continue _ -> ()

  | Debugger -> ()

  | Return expr -> (
    Option.iter ~f:(check_expression env) expr
  )

  | Empty -> ()

and check_expression_if env if_spec =
  let open T.Expression in
  let { if_test; if_consequent; if_alternative; _ } = if_spec in
  check_expression env if_test;
  List.iter ~f:(check_statement env) if_consequent.body;
  (match if_alternative with
  | Some (If_alt_block blk) -> (
    List.iter ~f:(check_statement env) blk.body;
  )
  | Some (If_alt_if desc) -> (
    check_expression_if env desc
  )

  | None -> ()
  );

  (* TODO: check return of two branches *)
  ()

and check_expression env expr =
  let open T.Expression in
  let expr_loc = expr.loc in
  match expr.spec with
  | Constant _ -> ()

  | Identifier _ -> ()

  | Lambda lambda -> check_lambda env lambda

  | If if_desc -> check_expression_if env if_desc

  | Array arr_list -> (
    if List.is_empty arr_list then (
      Type_context.update_node_type env.ctx expr.ty_var TypeExpr.(Array Any)
    ) else (
      (* TODO: check every expressions are the same *)
      List.iter ~f:(check_expression env) arr_list;
      let first = List.hd_exn arr_list in
      let first_type = T.Expression.(first.ty_var) in
      let first_node = Type_context.get_node env.ctx first_type in
      Type_context.update_node_type env.ctx expr.ty_var TypeExpr.(Array first_node.value)
    )
  )

  | Call { callee; call_params; _ } -> (
    check_expression env callee;
    List.iter ~f:(check_expression env) call_params;
    let ctx = env.ctx in
    let ty_int = callee.ty_var in
    let deref_type_expr = Type_context.deref_node_type ctx ty_int  in
    match deref_type_expr with
    | TypeExpr.Lambda(_params, ret) -> (
      (* TODO: check call params *)
      Type_context.update_node_type ctx expr.ty_var ret
    )
    | _ ->
      begin
        let _ty_def = Check_helper.find_construct_of ctx deref_type_expr in
        match deref_type_expr with
        | TypeExpr.TypeDef { TypeDef. spec = Function _fun; _ } ->
          (* TODO: check call params *)
          Type_context.update_node_type ctx expr.ty_var _fun.fun_return

        | TypeExpr.TypeDef { TypeDef. spec = ClassMethod _method; _ } ->
          (* TODO: check call params *)
          Type_context.update_node_type ctx expr.ty_var _method.method_return

        | TypeExpr.TypeDef { TypeDef. spec = EnumCtor enum_ctor; _} -> (
          let super_id = enum_ctor.enum_ctor_super_id in
          Type_context.update_node_type ctx expr.ty_var (TypeExpr.Ctor (Ref super_id, []))
        )

        | _ -> (
          let err = Type_error.(make_error ctx expr_loc (NotCallable deref_type_expr)) in
          raise (Type_error.Error err)
        )
      end

  )

  | Member (main_expr, name) -> (
    check_expression env main_expr;
    let expr_node = Type_context.get_node env.ctx main_expr.ty_var in
    let member_type_opt =
      Check_helper.find_member_of_type env.ctx ~scope:env.scope expr_node.value name.pident_name
    in
    match member_type_opt with
    (* maybe it's a getter *)
    | Some (TypeDef { spec = ClassMethod { method_get_set = Some Getter; method_return; _ }; _ }, _) -> (
      Type_context.update_node_type env.ctx expr.ty_var method_return
    )

    | Some (ty_expr, _) ->
      Type_context.update_node_type env.ctx expr.ty_var ty_expr

    | None ->
      let err = Type_error.(make_error env.ctx expr_loc (CannotReadMember(name.pident_name, expr_node.value))) in
      raise (Type_error.Error err)

  )

  | Index (expr, index_expr) -> (
    check_expression env index_expr;
    check_expression env expr;

    let node = Type_context.get_node env.ctx expr.ty_var in
    match (Check_helper.try_unwrap_array env.ctx node.value) with
    | Some t ->
      Type_context.update_node_type env.ctx expr.ty_var t

    | None -> (
      let err = Type_error.(make_error env.ctx expr_loc (CannotGetIndex node.value)) in
      raise (Type_error.Error err)
    )
  )

  | Unary _ -> failwith "unary"

  | Binary (op, left, right) -> (
    check_expression env left;
    check_expression env right;
    let left_node = Type_context.get_node env.ctx left.ty_var in
    let right_node = Type_context.get_node env.ctx right.ty_var in
    let ctx = env.ctx in
    let loc = expr_loc in
    let id = expr.ty_var in
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
        let bool_ty = ty_boolean env in
        Type_context.update_node_type ctx id (TypeExpr.Ctor (Ref bool_ty, []));
      )

    | _ -> (
        if not (Check_helper.type_logic_compareable ctx left_node.value right_node.value) then (
          let err = Type_error.(make_error ctx loc (CannotApplyBinary (op, left_node.value, right_node.value))) in
          raise (Type_error.Error err)
        );
    )
  )

  | Assign (_, left, right) -> (
    check_expression env left;
    check_expression env right;
    let ctx = env.ctx in
    let scope = env.scope in
    (match left with
    | { T.Expression. spec = Identifier (name, _); _ } -> (
      let variable = Option.value_exn (scope#find_var_symbol name) in

      (match variable.var_kind with
      | Ast.Pvar_const -> (
        let err = Type_error.(make_error ctx expr_loc CannotAssignToConstVar) in
        raise (Type_error.Error err)
      )
      | _ -> ());
    )

    | { spec = Member(main_expr, name) ; _ } -> (
      let main_expr_type = Type_context.deref_node_type ctx main_expr.ty_var in
      let member_opt = Check_helper.find_member_of_type ctx ~scope:env.scope main_expr_type name.pident_name in
      match member_opt with
      | Some _ -> ()
      | None -> (
        let err = Type_error.(make_error ctx expr_loc (CannotReadMember(name.pident_name, main_expr_type))) in
        raise (Type_error.Error err)
      )
    )

    | { spec = Index(main_expr, value_expr) ; _ } -> (
      let main_expr_type = Type_context.deref_node_type ctx main_expr.ty_var in
      let value_type = Type_context.deref_node_type ctx value_expr.ty_var in
      if not (Check_helper.is_array ctx main_expr_type) then (
        let err = Type_error.(make_error ctx main_expr.loc OnlyAssignArrayIndexAlpha) in
        raise (Type_error.Error err)
      );
      if not (Check_helper.is_i32 ctx value_type) then (
        let err = Type_error.(make_error ctx value_expr.loc OnlyI32InIndexAlpha) in
        raise (Type_error.Error err)
      )
    )

    | _ -> ()
    );

    let sym_node = Type_context.get_node ctx left.ty_var in
    let expr_node = Type_context.get_node ctx right.ty_var in
    if not (Check_helper.type_assinable ctx sym_node.value expr_node.value) then (
      let err = Type_error.(make_error ctx expr_loc (NotAssignable(sym_node.value, expr_node.value))) in
      raise (Type_error.Error err)
    )

  )

  | Block blk -> check_block env blk

  | Init { init_elements; _ } -> (
    List.iter
      ~f:(fun elm ->
        match elm with
        | InitEntry { init_entry_value; _ } ->
          check_expression env init_entry_value

        | InitSpread spread ->
          check_expression env spread

      )
      init_elements
  )

  | Match _match -> (
    let { match_clauses; match_loc; _ } = _match in
    let ty =
      if List.is_empty match_clauses then (
        let ty_unit = ty_unit env in
        TypeExpr.Ctor(Ref ty_unit, [])
      ) else (
        (* TODO: better way to check every clauses *)
        List.fold
          ~init:TypeExpr.Unknown
          ~f:(fun acc clause ->
            let consequent = clause.clause_consequent in
            check_expression env consequent;
            let node_expr = Type_context.deref_node_type env.ctx consequent.ty_var in
            match (acc, node_expr) with
            | TypeExpr.Unknown, _ ->
              node_expr

            | (TypeExpr.Ctor(c1, [])), (TypeExpr.Ctor (c2, [])) ->  (
              let c1_def = Type_context.deref_type env.ctx c1 in
              let c2_def = Type_context.deref_type env.ctx c2 in
              (match (c1_def, c2_def) with
              | (TypeExpr.TypeDef left_sym, TypeExpr.TypeDef right_sym) -> (
                if TypeDef.(left_sym == right_sym) then ()
                else
                  let err = Type_error.(make_error env.ctx match_loc (NotAllTheCasesReturnSameType(c1_def, c2_def))) in
                  raise (Type_error.Error err)
              )
              | _ -> (
                let err = Type_error.(make_error env.ctx match_loc (NotAllTheCasesReturnSameType(c2_def, c2_def))) in
                raise (Type_error.Error err)
              ));

              acc
            )

            | _ -> (
              acc
            )
          )
          match_clauses
      )
    in
    Type_context.update_node_type env.ctx expr.ty_var ty
  )

  | This
  | Super -> ()
  | _ -> failwith "unexpected"

and check_lambda _env _lambda =
  ()

and check_class env cls =
  let open T.Declaration in
  let { cls_body; _ } = cls in
  let { cls_body_elements; _ } = cls_body in
  List.iter
    ~f:(fun elm ->
      match elm with
      | Cls_property _ -> ()

      | Cls_method { cls_method_scope; cls_method_body; _ } -> (
        with_scope env (Option.value_exn cls_method_scope) (fun env ->
          check_block env cls_method_body
        )
      )

      | Cls_declare _ -> ()

    )
    cls_body_elements
