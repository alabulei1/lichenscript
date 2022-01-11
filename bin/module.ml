open Core
open Lichenscript_parsing
open Lichenscript_typing

type file = {
	path: string;
	ast: Ast.program option;
	typed_env: Env.t;
  typed_tree: Typedtree.program option;
	extern_modules: string list;  (* full id *)
}

type export = {
  export_name: string;
  export_var: Scope.variable;
}

(* prev export * new export *)
exception ReexportSymbol of (export * export)

type t = {
  mod_full_path: string;
  mutable files: file list;
  exports: (string, export) Hashtbl.t;
}

let create ~full_path () =
  {
    mod_full_path = full_path;
    files = [];
    exports = Hashtbl.create (module String);
  }

let add_file env file =
  env.files <- file::env.files

let files env = List.rev env.files

let set_files env files =
  env.files <- files

let finalize_module_exports env =
  List.iter
    ~f:(fun file ->
      let typed_env = file.typed_env in
      let module_scope = Env.peek_scope typed_env in
      let vars = module_scope#vars in
      List.iter
        ~f:(fun (name, ty_var) -> 
          let visibility = module_scope#get_visibility name in
          match visibility with
          | Some Asttypes.Pvisibility_public -> (
            let export = {
              export_name = name;
              export_var = ty_var;
            } in
            (match Hashtbl.find env.exports name with
            | Some old_export -> (
              raise (ReexportSymbol (old_export, export))
            )
            | None -> ()
            );
            Hashtbl.set env.exports ~key:name ~data:export;
          )

          | _ -> ()
        )
        vars
    )
    env.files

let find_export env ~name =
  Hashtbl.find env.exports name
