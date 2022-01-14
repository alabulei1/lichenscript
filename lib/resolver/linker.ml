(*
 * Collect the references between all top-level declarations,
 * traverse from entry.
 *
 * Which is called tree-shaking.
 *)
open Core_kernel
open Lichenscript_typing
open Lichenscript_typing.Typedtree

type env = {
  ctx: Type_context.t;
  top_level_deps: (int list) Array.t;
}

let create ~ctx () =
  let open Type_context in
  let top_level_deps = Array.create ~len:(ResizableArray.size ctx.ty_map) [] in
  {
    ctx;
    top_level_deps;
  }

let rec collect_deps env =
  Hashtbl.iteri
    ~f:(collect_declaration env)
    env.ctx.declarations

and collect_declaration env ~key:_ ~data:decl =
  let open Declaration in
  match decl.spec with
  | Class _ -> ()

  | Function_ _fun -> (
    let id = _fun.header.id in
    let header_refs = collect_function_header _fun.header in

    Array.set env.top_level_deps id header_refs
  )

  | Declare _decare -> ()

  | Enum _ -> (
    failwith "enum"
  )

  | Import _ -> ()

and collect_function_header header =
  let open Function in
  let refs = ref [] in
  let { params; _ } = header in

  List.iter
    ~f:(fun param ->
      refs := param.param_ty::(!refs)
    )
    params.params_content;

  List.rev !refs


(*
 * Figure out all reached nodes
 *)
let assemble_optimize_tree env (entry: int) =
  let reach_node = Array.create ~len:(ResizableArray.size env.ctx.ty_map) false in

  let rec iterate_node id = 
    if Array.get reach_node id then
      ()
    else (
      Array.set reach_node id true;
      let deps = Array.get env.top_level_deps id in
      List.iter ~f:iterate_node deps
    )
  in

  iterate_node entry;

  reach_node
