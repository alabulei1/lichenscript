(*
 * Convert TypedTree to C-op
 *)
open Core_kernel
open Lichenscript_parsing.Ast
open Lichenscript_typing
open Lichenscript_typing.Scope
open Lichenscript_typing.Typedtree

type t = {
  ctx: Type_context.t;
  name_map: (int, string) Hashtbl.t;
  mutable tmp_vars_count: int;
  mutable main_function_name: string option;
  mutable class_inits: C_op.Decl.class_init list;
  mutable scope: scope option;

  (* for lambda generation *)
  mutable current_fun_name: string option;
  mutable lambdas: C_op.Decl.lambda_def list;
}

type expr_result = {
  prepend_stmts: C_op.Stmt.t list;
  expr: C_op.Expr.t;
  append_stmts: C_op.Stmt.t list;
}

let create ctx = {
  ctx;
  name_map = Hashtbl.create (module Int);
  tmp_vars_count = 0;
  main_function_name = None;
  class_inits = [];
  scope = None;
  current_fun_name = None;
  lambdas = [];
}

let preserved_name = [| "ret"; "rt"; "this"; "argc"; "argv"; "t" |]

let get_local_var_name realname ty_int =
  if Array.mem preserved_name ~equal:String.equal realname then
    realname ^ "_" ^ (Int.to_string ty_int)
  else
    realname

let rec transform_declaration env decl =
  let open Declaration in
  let { spec; loc; _ } = decl in
  match spec with
  | Class cls -> (
    let specs = transform_class env cls in
    List.map ~f:(fun spec -> { C_op.Decl. spec; loc }) specs
  )
  | Function_ _fun -> (
    let specs = transform_function env _fun in
    let lambdas = env.lambdas in
    env.lambdas <- [];
    let lambda_defs =
      List.map
      ~f:(fun lambda -> { C_op.Decl. spec = LambdaDef lambda; loc })
      lambdas
    in
    let bodys = List.map ~f:(fun spec -> { C_op.Decl. spec; loc }) specs in
    List.append lambda_defs bodys
  )

  | Enum enum -> (
    let specs = transform_enum env enum in
    List.map ~f:(fun spec -> { C_op.Decl. spec; loc }) specs
  )
  | Declare _
  | Import _ -> []

and distribute_name env (name, id) =
  let fun_name = "LCC_" ^ name in
  Hashtbl.set env.name_map ~key:id ~data:fun_name;
  fun_name

(*
 * 1. Scan the function firstly, find out all the lambda expression
 *    and captured variables
 * 2. Transform body
 *)
and transform_function env _fun =
  let open Function in
  let { body; comments; header; scope; _ } = _fun in
  let original_name = header.name in

  env.current_fun_name <- Some original_name;

  let fun_name = distribute_name env (original_name, header.id) in

  if String.equal original_name "main" then (
    env.main_function_name <- Some fun_name
  );

  let result = transform_function_impl env ~name:fun_name ~params:header.params ~scope ~body ~comments in

  env.current_fun_name <- None;

  [ result ]

and transform_function_impl env ~name ~params ~body ~scope ~comments =
  let open Function in

  env.scope <- Some scope;
  env.tmp_vars_count <- 0;

  List.iter
    ~f:(fun { param_name; param_ty; _ } ->
      let param_name, _ = param_name in
      Hashtbl.set env.name_map ~key:param_ty ~data:(get_local_var_name param_name param_ty)
    )
    params.params_content;

  let local_vars = scope#vars in

  let def = ref [] in

  if (List.length local_vars) > 0 then (
    let names =
      List.map
      ~f:(fun (var_name, variable) ->
        Hashtbl.set env.name_map ~key:variable.var_id ~data:(get_local_var_name var_name variable.var_id);
        var_name
      )
      local_vars;
    in
    def := [
      { C_op.Stmt.
        spec = VarDecl names;
        loc = Loc.none;
      }
    ];
  );

  let cleanup =
    if (List.length local_vars) > 0 then (
      List.map
        ~f:(fun (name, _) ->
          { C_op.Stmt.
            spec = Release {
              spec = Ident name;
              loc = Loc.none;
            };
            loc = Loc.none;
          }
        )
        local_vars
    ) else [] in

  let max_tmp_value = ref 0 in

  let stmts =
    List.map
      ~f:(fun stmt ->
        env.tmp_vars_count <- 0;

        let result = transform_statement env stmt in

        if env.tmp_vars_count > !max_tmp_value then (
          max_tmp_value := env.tmp_vars_count
        );

        result
      )
      body.body
    |> List.concat
  in

  let new_body = {
    C_op.Block.
    body = List.concat [ !def; stmts; cleanup ];
    loc = body.loc;
  } in

  let t_fun = {
    C_op.Func.
    name;
    body = new_body;
    tmp_vars_count = env.tmp_vars_count;
    comments;
  } in

  env.scope <- None;
  C_op.Decl.Func t_fun;

and transform_statement ?ret env stmt =
  let open Statement in
  let { spec; loc; _ } = stmt in
  let transform_return_expr expr =
    let tmp = transform_expression env expr in
    let ret = Option.value ~default:"ret" ret in
    let assign = {
      C_op.Expr.
      spec = Assign(ret, tmp.expr);
      loc;
    } in
    let expr = {
      C_op.Stmt.
      spec = Expr assign;
      loc;
    } in
    List.concat [ tmp.prepend_stmts; [ expr ]; tmp.append_stmts ]
  in
  match spec with
  | Expr expr -> transform_return_expr expr

  | Semi expr -> (
    let tmp = transform_expression env expr in
    let expr = {
      C_op.Stmt.
      spec = Expr tmp.expr;
      loc;
    } in
    List.concat [ tmp.prepend_stmts; [ expr ]; tmp.append_stmts ]
  )

  | While { while_test; while_block; while_loc } -> (
    let transform_expression = transform_expression env while_test in

    let bodys = List.map ~f:(transform_statement env) while_block.body |> List.concat in
    let body = {
      C_op.Block.
      body = bodys;
      loc = while_block.loc;
    } in

    List.concat [
      transform_expression.prepend_stmts;
      [
        { C_op.Stmt.
          spec = While(transform_expression.expr, body);
          loc = while_loc;
        }
      ];
      transform_expression.append_stmts;
    ]
  )

  | Binding binding -> (
    let original_name =
      match binding.binding_pat with
      | { spec = Pattern.Symbol (name, _); _ } -> name
      | _ -> failwith "unrechable"
    in
    let scope = Option.value_exn env.scope in

    let should_var_captured variable =
      if !(variable.var_captured) then (
        match variable.var_kind with
        | Pvar_let -> true
        | _ -> false
      ) else
        false
    in

    let variable = Option.value_exn (scope#find_var_symbol original_name) in

    let name = Hashtbl.find_exn env.name_map binding.binding_ty_var in
    let init_expr = transform_expression env binding.binding_init in


    let assign_expr =
      if should_var_captured variable then (
        let init_expr = {  C_op.Expr.
          spec = NewRef init_expr.expr;
          loc = Loc.none;
        } in
        { C_op.Expr.
          spec = Assign(name, init_expr);
          loc = Loc.none;
        }
      ) else
        { C_op.Expr.
          spec = Assign(name, init_expr.expr);
          loc = Loc.none;
        }
    in

    List.concat [
      init_expr.prepend_stmts;
      [
        { C_op.Stmt.
          spec = Expr assign_expr;
          loc = binding.binding_loc;
        }
      ];
      init_expr.append_stmts;
    ]
  )

  | Break _ -> [
    { C_op.Stmt.
      spec = Break;
      loc;
    }
  ]

  | Continue _ -> [
    { C_op.Stmt.
      spec = Continue;
      loc;
    }
  ]
  | Debugger -> []

  | Return ret_opt ->
    Option.map ~f:transform_return_expr ret_opt
    |> Option.value ~default:[]

  | Empty -> []

and gen_release_temp id =
  { C_op.Stmt.
    spec = Release {
      C_op.Expr.
      spec = Temp id;
      loc = Loc.none;
    };
    loc = Loc.none;
  }

and auto_release_expr env ~prepend_stmts ~append_stmts expr =
  let tmp_id = env.tmp_vars_count in
  env.tmp_vars_count <- env.tmp_vars_count + 1;

  let assign_expr = {
    C_op.Expr.
    spec = Assign(("t[" ^ (Int.to_string tmp_id) ^ "]"), expr);
    loc = Loc.none;
  } in

  let prepend_stmt = {
    C_op.Stmt.
    spec = Expr assign_expr;
    loc = Loc.none;
  } in

  prepend_stmts := prepend_stmt::!prepend_stmts;

  let result = C_op.Expr.Temp tmp_id in

  append_stmts := (gen_release_temp tmp_id)::!append_stmts;

  result

and transform_expression env expr =
  let open Expression in
  let { spec; loc; ty_var; _ } = expr in
  let prepend_stmts = ref [] in
  let append_stmts = ref [] in
  let expr_spec =
    match spec with
    | Constant literal -> (
      let open Literal in
      match literal with
      | String(content, _, _) -> 
        auto_release_expr env ~prepend_stmts ~append_stmts ({
          C_op.Expr.
          spec = NewString content;
          loc = Loc.none;
        })

      | Integer(content, _) ->
        C_op.Expr.NewInt content

      | _ ->
        failwith "unimplemented"
    )

    | Identifier (_, id) -> (
      let name = Hashtbl.find_exn env.name_map id in
      C_op.Expr.Ident name
    )

    | Lambda lambda_content -> (
      let fun_name = Option.value_exn ~message:"current function name not found" env.current_fun_name in
      let lambda_fun_name = "LCC_" ^ fun_name ^ "_lambda_" ^ (Int.to_string ty_var) in

      let capturing_variables = lambda_content.lambda_scope#capturing_variables in

      let capturing_names = Array.create ~len:(Scope.CapturingVarMap.length capturing_variables) "" in

      Scope.CapturingVarMap.iteri
      ~f:(fun ~key ~data -> 
        let variable_opt = lambda_content.lambda_scope#find_var_symbol key in
        let variable = Option.value_exn variable_opt in
        let ty_int = variable.var_id in
        let name = Hashtbl.find_exn env.name_map ty_int in
        Array.set capturing_names data name
      )
      capturing_variables;

      let lambda =  {
        C_op.Decl.
        lambda_gen_name = lambda_fun_name;
        lambda_content;
        lambda_ty = ty_var;
      } in

      env.lambdas <- lambda::env.lambdas;

      let tmp = {
        C_op.Expr.
        spec = NewLambda(lambda_fun_name, capturing_names);
        loc;
      } in
      auto_release_expr env ~prepend_stmts ~append_stmts tmp
    )

    | If _
    | Array _ -> failwith "n1"

    | Call call -> (
      let open Expression in
      let { callee; call_params; _ } = call in
      match callee with
      | { spec = Identifier (_, id); _ } -> (
        let params_struct = List.map ~f:(transform_expression env) call_params in

        let prepend, params, append = List.map ~f:(fun expr -> expr.prepend_stmts, expr.expr, expr.append_stmts) params_struct |> List.unzip3 in

        prepend_stmts := List.append !prepend_stmts (List.concat prepend);
        append_stmts := List.append !append_stmts (List.concat append);
        match Type_context.find_external_symbol env.ctx id with

        | Some ext_name -> (

          (* external method *)
          C_op.Expr.ExternalCall(ext_name, params)
        )

        (* it's a local function *)
        | None -> (
          let callee_node = Type_context.get_node env.ctx callee.ty_var in
          let deref_type = Check_helper.deref_type env.ctx callee_node.value in
          match deref_type with
          | Core_type.TypeExpr.Lambda _ -> (
            let transformed_callee = transform_expression env callee in
            prepend_stmts := List.append !prepend_stmts (List.append !prepend_stmts transformed_callee.prepend_stmts);
            append_stmts := List.append !append_stmts (List.append !append_stmts transformed_callee.append_stmts);
            C_op.Expr.CallLambda(transformed_callee.expr, [])
          )

          | _ ->
            let ctor_opt = Check_helper.find_construct_of env.ctx id in
            let _, ctor_ty_id = Option.value_exn ctor_opt in
            let name = Hashtbl.find_exn env.name_map ctor_ty_id in
            C_op.Expr.ExternalCall(name, params)
        )

      )

      | _ -> (
        let ty_id = callee.ty_var in
        let ctor_opt = Check_helper.find_construct_of env.ctx ty_id in
        let _, ctor_ty_id = Option.value_exn ctor_opt in
        let name = Hashtbl.find_exn env.name_map ctor_ty_id in
        C_op.Expr.ExternalCall(name, [])
      )
    )

    | Member _
    | Unary _ -> failwith "n"

    | Binary (op, left, right) -> (
      let left' = transform_expression env left in
      let right' = transform_expression env right in

      prepend_stmts := List.concat [!prepend_stmts; left'.prepend_stmts; right'.prepend_stmts];
      append_stmts := List.concat [!append_stmts; left'.append_stmts; right'.append_stmts];

      C_op.Expr.I32Binary(op, left'.expr, right'.expr)
    )

    | Update _ -> failwith "update"
    | Assign ((_, id), expr) -> (
      let name = Hashtbl.find_exn env.name_map id in
      let expr' = transform_expression env expr in

      prepend_stmts := List.append !prepend_stmts expr'.prepend_stmts;
      append_stmts := List.append !append_stmts expr'.append_stmts;

      C_op.Expr.Assign(name, expr'.expr)
    )

    | Init { init_name; _ } -> (
      let _, init_name_id = init_name in
      let fun_name = Hashtbl.find_exn env.name_map init_name_id in
      C_op.Expr.ExternalCall(fun_name ^ "_init", [])
    )

    | Block block -> (
      let tmp_id = env.tmp_vars_count in
      env.tmp_vars_count <- env.tmp_vars_count + 1;

      let stmts = transform_block ~ret_id:tmp_id env block in

      prepend_stmts := List.append !prepend_stmts stmts;

      C_op.Expr.Temp tmp_id
    )

    | Match _match -> (
      let { match_expr; match_clauses; _ } = _match in
      let match_expr = transform_expression env match_expr in
      let result_tmp = env.tmp_vars_count in
      env.tmp_vars_count <- env.tmp_vars_count + 1;

      prepend_stmts := List.append !prepend_stmts
        [{
          C_op.Stmt.
          spec = Expr {
            C_op.Expr.
            spec = Assign ("t[" ^ (Int.to_string result_tmp) ^ "]", {
              spec = Null;
              loc = Loc.none;
            });
            loc = Loc.none;
          };
          loc = Loc.none;
        }];

      let tmp_counter = ref [] in

      List.iter
        ~f:(fun clause ->
          let saved_tmp_count = env.tmp_vars_count in
          let test_expr = transform_pattern_to_test env match_expr.expr clause.clause_pat in

          let body = transform_expression env clause.clause_consequent in

          prepend_stmts := List.append
            !prepend_stmts
            [{
              C_op.Stmt.
              spec = If (test_expr, {
                C_op.Block.
                body = List.concat [
                  body.prepend_stmts;
                  [{ C_op.Stmt.
                    spec = Expr {
                      spec = Assign("t[" ^ (Int.to_string result_tmp) ^ "]", body.expr);
                      loc = Loc.none;
                    };
                    loc = Loc.none;
                  }];
                  body.append_stmts;
                ];
                loc = Loc.none;
              });
              loc = Loc.none;
            }];

          tmp_counter := env.tmp_vars_count::(!tmp_counter);
          env.tmp_vars_count <- saved_tmp_count;
        )
        match_clauses;

      (* use the max tmp vars *)
      env.tmp_vars_count <- List.fold ~init:0 ~f:(fun acc item -> if item > acc then item else acc) !tmp_counter;

      C_op.Expr.Temp result_tmp
    )

  in
  {
    prepend_stmts = !prepend_stmts;
    expr = {
      spec = expr_spec;
      loc;
    };
    append_stmts = !append_stmts;
  }

and transform_block env ~ret_id block =
  let ret = "t[" ^ (Int.to_string ret_id) ^ "]" in
  let stmts = List.map ~f:(transform_statement ~ret env) block.body |> List.concat in
  stmts

and transform_pattern_to_test env match_expr pat =
  let open Pattern in
  let { spec; loc } = pat in
  match spec with
  | Symbol (name, name_id) -> (
    let ctor_opt = Check_helper.find_construct_of env.ctx name_id in
    let ctor, _ = Option.value_exn ~message:(Format.sprintf "find enum ctor failed: %s %d" name name_id) ctor_opt in
    let enum_ctor = Core_type.TypeDef.(
      match ctor.spec with
      | EnumCtor v -> v
      | _ -> failwith "n"
    ) in
    { C_op.Expr.
      spec = TagEqual(match_expr, enum_ctor.enum_ctor_tag_id);
      loc;
    }
  )
  | EnumCtor ((_name, name_id), _child) -> (
    let ctor_opt = Check_helper.find_construct_of env.ctx name_id in
    let ctor, _ = Option.value_exn ctor_opt in
    let enum_ctor = Core_type.TypeDef.(
      match ctor.spec with
      | EnumCtor v -> v
      | _ -> failwith "n"
    ) in
    { C_op.Expr.
      spec = TagEqual(match_expr, enum_ctor.enum_ctor_tag_id);
      loc;
    }
  )

and transform_class env cls: C_op.Decl.spec list =
  let open Declaration in
  let { cls_id; cls_body; _ } = cls in
  let original_name, _ = cls_id in
  let fun_name = distribute_name env cls_id in
  let finalizer_name = fun_name ^ "_finalizer" in

  let properties =
    List.fold
      ~init:[]
      ~f:(fun acc elm ->
        match elm with
        | Cls_method _ -> acc
        | Cls_property prop -> (
          let { cls_property_name; _ } = prop in
          cls_property_name.pident_name::acc
        )
      )
      cls_body.cls_body_elements;
  in

  let methods: C_op.Decl.spec list = 
    List.fold
      ~init:[]
      ~f:(fun acc elm ->
        match elm with
        | Cls_method _method -> (
          let { cls_method_name; cls_method_params; cls_method_body; cls_method_scope; _ } = _method in
          (* let fun_name = distribute_name env cls_method_name in *)
          let origin_method_name, method_id = cls_method_name in
          let new_name = original_name ^ "_" ^ origin_method_name in
          let new_name = distribute_name env (new_name, method_id) in
          let _fun =
            transform_function_impl
              env
              ~name:new_name
              ~params:cls_method_params
              ~scope:(Option.value_exn cls_method_scope)
              ~body:(Option.value_exn cls_method_body)
              ~comments:[]
          in

          _fun::acc
          (* { C_op.Decl. spec = _fun; loc = cls_method_loc }::acc *)
        )
        | Cls_property _ -> acc
      )
      cls_body.cls_body_elements;
  in

  env.class_inits <- { C_op.Decl.
    class_id_name = fun_name ^ "_class_id";
    class_def_name = fun_name ^ "_def";
  }::env.class_inits;

  let cls = {
    C_op.Decl.
    name = fun_name;
    original_name;
    finalizer_name;
    properties;
  } in

  List.append [ (C_op.Decl.Class cls) ] methods

and transform_enum env enum =
  let open Enum in
  let { cases; _ } = enum in
  List.mapi
    ~f:(fun index case ->
      let new_name = distribute_name env case.case_name in
      C_op.Decl.EnumCtor {
        enum_ctor_name = new_name;
        enum_ctor_tag_id = index;
        enum_cotr_params_size = List.length case.case_fields;
      }
    )
    cases

type result = {
  main_function_name: string option;
  declarations: C_op.Decl.t list;
  global_class_init: string option;
}

let transform_declarations ctx declarations =
  let env = create ctx in

  let declarations =
    List.map ~f:(transform_declaration env) declarations
    |> List.concat
  in

  let declarations, global_class_init =
    if List.is_empty env.class_inits then
      declarations, None
    else (
      let name = "LC_class_init" in
      (List.append declarations [{
        C_op.Decl.
        spec = GlobalClassInit(name, List.rev env.class_inits);
        loc = Loc.none;
      }]), Some name
    )
  in

  {
    main_function_name = env.main_function_name;
    declarations;
    global_class_init;
  }
