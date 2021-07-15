open Core_kernel
open Core_type

module SymbolTable = Hashtbl.Make_binable(String)

type t = {
  prev: t option;
  id: int;
  var_symbols: VarSym.t SymbolTable.t;
  type_symbols: TypeSym.t SymbolTable.t;
}

let id scope = scope.id

let create ?prev id =
  {
    prev;
    id;
    var_symbols = SymbolTable.create ();
    type_symbols = SymbolTable.create ();
  }

let find_or_create_var_symbol scope name =
  let opt = SymbolTable.find scope.var_symbols name in
  match opt with
  | Some sym -> sym
  | None ->
    let sym = VarSym.mk_local ~scope_id:scope.id name in
    let _ =  SymbolTable.add scope.var_symbols ~key:name ~data:sym in
    sym

let find_or_create_type_symbol scope name =
  let opt = SymbolTable.find scope.type_symbols name in
  match opt with
  | Some sym -> sym
  | None ->
    let sym = TypeSym.mk_local ~scope_id:scope.id name in
    let _ =  SymbolTable.add scope.type_symbols ~key:name ~data:sym in
    sym

let find_type_symbol scope name =
  SymbolTable.find scope.type_symbols name

let set_type_symbol scope name sym =
  SymbolTable.set scope.type_symbols ~key:name ~data:sym;
