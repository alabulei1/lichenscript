open Core_kernel
(*
 * record the dependency of types
 **)

(* num -> [] *)
type t = {
  ty_map: ResizableArray.t;
  root_scope: Scope.t
}

let new_id ctx ty =
  let id = ResizableArray.size ctx.ty_map in
  ResizableArray.push ctx.ty_map ty;
  id

let make_default_type_sym ctx scope =
  let open Core_type in
  let open Core_type.TypeSym in
  let names = [|
    ("u32", Primitive);
    ("i32", Primitive);
    ("u64", Primitive);
    ("i64", Primitive);
    ("f32", Primitive);
    ("f64", Primitive);
    ("char", Primitive);
    ("string", Object);
    ("boolean", Primitive);
  |] in
  Array.iter
    ~f:(fun (name, spec) ->
      let sym = TypeSym.create ~builtin:true  name spec in
      let node = {
        value = TypeValue.TypeDef sym;
        loc = Waterlang_lex.Loc.none;
        deps = [];
        check = none;
      } in
      let id = new_id ctx node in
      Scope.insert_type_symbol scope name id;
    )
    names

let create () =
  let root_scope = Scope.create () in
  let ctx = {
    ty_map = ResizableArray.make 1024;
    root_scope;
  } in
  make_default_type_sym ctx root_scope;
  ctx


let update_node ctx id node =
  ResizableArray.set ctx.ty_map id node

let update_node_type ctx id ty =
  let old_node = ResizableArray.get ctx.ty_map id in
  update_node ctx id { old_node with value = ty }

let size ctx = ResizableArray.size ctx.ty_map

let get_node ctx id =
  ResizableArray.get ctx.ty_map id

let print ctx =
  let rec print_item_by_id id =
    let item = get_node ctx id in
    let open Core_type.TypeValue in
    match item.value with
    | Unknown -> "unkonwn"
    | Any -> "any"
    | Unit -> "unit"
    | Ctor (name, []) -> (
      print_item_by_id name
    )
    | Ctor _ -> "ctor"
    (*
    | Ctor (name, _list) -> (
      name ^ "<>"
    ) *)

    | Class _ -> "class"
    | Function _ -> "function"
    | Module _ -> "module"
    | Array _ -> "array"
    | TypeDef sym ->
      (Core_type.TypeSym.name sym)

  in

  let arr_size = size ctx in
  for i = 0 to (arr_size - 1) do
    let item = get_node ctx i in
    let deps = Buffer.create 64 in
    List.iter ~f:(fun item -> Buffer.add_string deps (Int.to_string item); Buffer.add_string deps " ") item.deps ;
    Format.printf "%d: %s\n" i (Buffer.contents deps);
    Format.printf "\t%s\n\n" (print_item_by_id i);
  done

let root_scope ctx = ctx.root_scope
