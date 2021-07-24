open Core_kernel
open Binaryen
open Codegen_env
open Waterlang_typing

module M (S: Dsl.BinaryenModule) = struct
  module Dsl = Dsl.Binaryen(S)
  open Dsl

  let get_binaryen_ty_by_core_ty env (ty: Core_type.TypeValue.t): C_bindings.ty =
    let open Core_type in
    match ty with
    | Ctor sym ->
      if (TypeSym.builtin sym) then (
        match (TypeSym.name sym) with
        | "i32" -> i32
        | "i64" -> i64
        | "f32" -> f32
        | "f64" -> f64
        | "char" -> i32
        | "boolean" -> i32
        | "string" -> (Codegen_env.ptr_ty env)
        | _ -> unreachable
      ) else
        failwith "not builtin"

    | Unit -> none
    | _ -> unreachable


  let get_function_params_type env params =
    let open Typedtree.Function in
    let { params_content; _; } = params in
    let params_arr = List.to_array params_content in
    let types_arr = Array.map
      ~f:(fun param -> param.param_ty |> (get_binaryen_ty_by_core_ty env))
      params_arr
    in
    C_bindings.make_ty_multiples types_arr

  let unwrap_function_return_type (ty: Core_type.TypeValue.t) =
    let open Core_type in
    match ty with
    | TypeValue.Function f ->
      f.tfun_ret

    | _ -> TypeValue.Unknown

  let set_memory env =
    let strings: bytes array = env.data_segment.allocated_str
      |> Data_segment_allocator.StaticStringPool.to_alist
      |> List.map ~f:(fun (_, value) ->
        let open Data_segment_allocator in
        Buffer.contents_bytes value.data
        )
      |> List.to_array
    in
    let passitive = Array.init ~f:(fun _ -> false) (Array.length strings) in
    let offsets = Array.init
      ~f:(fun _ ->
        let offset = env.config.data_segment_offset in
        const_i32_of_int offset
      )
      (Array.length strings)
    in
    let mem_size = env.config.init_mem_size / (64 * 1024) in
    C_bindings.set_memory
      env.module_
      mem_size
      mem_size
      "memory" strings passitive offsets false

  let rec codegen_statements env stat: C_bindings.exp option =
    let open Typedtree.Statement in
    let { spec; _; } = stat in
    match spec with
    | Function_ fun_ ->
      codegen_function env fun_;
      None
    
    | Expr expr ->
      let expr_result = codegen_expression env expr in
      Some expr_result

    | Return expr_opt ->
      let expr = Option.map
        ~f:(codegen_expression env)
        expr_opt
      in
      let return_expr = return_ expr in
      Some return_expr

    | Binding binding ->
      codegen_binding env binding

    | Semi expr ->
      Some(codegen_expression env expr)

    | _ -> None

  and codegen_binding env binding: C_bindings.exp option =
    let init_exp = codegen_expression env binding.binding_init in
    let open Core_type.VarSym in
    let local_id =
      match binding.binding_pat.spec with
      | Typedtree.Pattern.Symbol sym -> sym.id_in_scope
    in
    Some(local_set local_id init_exp)

  and codegen_constant env cnst =
    let open Waterlang_parsing.Ast.Literal in
    match cnst with
    | Integer (content, _) ->
      let value = int_of_string content in
      const_i32_of_int value

    | Float (content, _) ->
      let value = float_of_string content in
      const_f64 value

    | String (content, _, _) ->
      Codegen_env.turn_on_string env;
      let value = Data_segment_allocator.add_static_string env.data_segment content in
      let open Data_segment_allocator in
      let str_len = String.length content in
      call_ String_facility.init_string_fun_name_static
        [|
          const_i32_of_int value.offset;
          (const_i32_of_int str_len);
        |] i32

    | Char ch ->
      let str = Char.to_string ch in
      let _ = Data_segment_allocator.add_static_string env.data_segment str in
      failwith "not implemented"

    | Boolean true ->
      const_i32_of_int 1

    | Boolean false ->
      const_i32_of_int 0

  and codegen_expression env expr: C_bindings.exp =
    let open Typedtree.Expression in
    let { spec; _; } = expr in
    let convert_op raw =
      let open Waterlang_parsing.Asttypes.BinaryOp in
      match raw with
      | Plus -> add_i32
      | Minus -> sub_i32
      | Mult -> mul_i32
      | _ -> failwith "not implemented"
    in
    match spec with
    | Binary(op, left, right) ->
      binary
        (convert_op op)
        (codegen_expression env left)
        (codegen_expression env right)

    | Identifier var_sym ->
      let ty = get_binaryen_ty_by_core_ty env var_sym.def_type in
      local_get var_sym.id_in_scope ty

    | Constant cnst ->
      codegen_constant env cnst

    | Call call ->
      codegen_call env call

    | _ ->
      unreachable_exp()

  and codegen_call env call =
    let open Typedtree.Expression in
    let open Core_type.VarSym in
    let (callee_sym, _) = call.callee.callee_spec in
    let params =
      call.call_params
      |> List.map ~f:(codegen_expression env)
      |> List.to_array
    in
    match callee_sym.spec with
    | Internal
    | ExternalMethod _ ->
      let get_function_name_by_callee callee =
        match callee.callee_spec with
        | (callee_sym, []) -> callee_sym.name
        | (callee_sym, _arr) ->
          callee_sym.name
      in
      let callee_name: string = get_function_name_by_callee call.callee in
      let callee_ty = call.callee.callee_ty in
      let return_ty =
        callee_ty
        |> unwrap_function_return_type
        |> (get_binaryen_ty_by_core_ty env)
      in
      call_ callee_name params return_ty

    | _ ->
      failwith "unreachable"

  and codegen_function env function_ =
    let open Typedtree.Function in
    let params_ty = get_function_params_type env function_.header.params in
    let vars_ty =
      function_.assoc_scope.var_symbols
      |> Scope.SymbolTable.to_alist
      |> List.map
          ~f:(fun (_, var_sym) -> Core_type.VarSym.(get_binaryen_ty_by_core_ty env var_sym.def_type))
      |> List.to_array

    in
    let { body; _; } = function_ in
    let block_contents =
      match body with
      | Fun_block_body block ->
        begin
          let open Typedtree.Block in
          let { body; _; } = block in
          let expressions = 
            body
            |> List.filter_map ~f:(codegen_statements env)
          in
          List.to_array expressions
        end

      | Fun_expression_body expr ->
        [| codegen_expression env expr |]

    in

    let finalizers: C_bindings.exp array =
      function_.assoc_scope.var_symbols
      |> Scope.SymbolTable.to_alist
      |> List.filter_map
        ~f:(fun (_, (sym: Core_type.VarSym.t)) ->
          let open Core_type in
          let open VarSym in
          let open TypeValue in
          match sym.def_type with
          | Ctor type_sym ->
            (match type_sym.spec with
            | TypeSym.Primitive -> None
            | TypeSym.Object ->
              let exp =
                call_ Allocator_facility.release_object_fun_name [| Ptr.local_get sym.id_in_scope |] none
              in
              Some exp

            | _ -> failwith "not implemented 1")
          | _ -> failwith "not implemented 2"
        )
      |> List.to_array
    in
    let exp = block (Array.concat [block_contents; finalizers]) in

    let id = function_.header.id in
    let id_name = id.name in
    let ret_ty =
      id.def_type
      |> unwrap_function_return_type
      |> get_binaryen_ty_by_core_ty env
    in
    let _fun = Dsl.function_ ~name:id_name ~params_ty ~ret_ty ~vars_ty ~content:exp in
    let _ = export_function id_name id_name in
    ()

  and codgen_external_method (env: Codegen_env.t) =
    let scope = env.program.root_scope in
    Scope.SymbolTable.to_alist scope.var_symbols
    |> List.iter
      ~f:(fun (key, value) ->
        let open Core_type.VarSym in
        let def_type = value.def_type in
        match def_type with
        | Core_type.TypeValue.Function fun_type ->
          begin
            let params_ty = 
              fun_type.tfun_params
              |> List.map ~f:(fun (_, t) -> get_binaryen_ty_by_core_ty env t)
              |> List.to_array
              |> C_bindings.make_ty_multiples
            in
            let ret_ty = get_binaryen_ty_by_core_ty env fun_type.tfun_ret in
            match value.spec with
            | ExternalMethod(extern_name, extern_base_name) ->
              Dsl.import_function ~intern_name:key ~extern_name ~extern_base_name ~params_ty ~ret_ty
            | _ -> ()

          end
        | _ -> ()

      );

  and codegen_program (env: Codegen_env.t) =
    C_bindings.set_debug_info (not env.config.release);
    let { Program. tree; _; } = env.program in
    let { Typedtree. tprogram_statements } = tree in
    let _ = List.map ~f:(codegen_statements env) tprogram_statements in

    if Codegen_env.needs_allocator env then (
      Allocator_facility.codegen_allocator_facility env;
    );

    if Codegen_env.needs_string env then (
      String_facility.codegen_string_facility env;
    );

    codgen_external_method env;

    set_memory env
  
end

let codegen program config : string =
  let env = Codegen_env.create config program in
  let module Cg = M(struct
      let m = env.module_
      let ptr_ty = Codegen_env.ptr_ty env
    end)
  in
  Cg.codegen_program env;
  let str = C_bindings.module_emit_text env.module_ in
  str

let codegen_binary env path : unit =
  let module Cg = M(struct
      let m = env.module_
      let ptr_ty = Codegen_env.ptr_ty env
    end)
  in
  Cg.codegen_program env;
  C_bindings.module_emit_binary_to_file env.module_ path;
  let js_glue_content = Js_glue.dump_js_glue env in
  Out_channel.write_all (path ^ ".js") ~data:js_glue_content
