open Cli_utils
open Core
open Waterlang_lex
open Waterlang_typing
open Waterlang_parsing

exception ParseError of Parse_error.t list
exception TypeCheckError of Type_error.t list

(* let parse_string_to_typed_tree ~file_key ~ctx ~type_provider content =
  let result = Parser.parse_string file_key content in
  let env = Waterlang_typing.Env.create ~type_provider ctx in
  let typed_tree =
    match result with
    | Result.Ok { tree; _ } ->
      begin
        (* Ast.pp_program Format.std_formatter program; *)
        Waterlang_typing.Annotate.annotate_program env tree
      end

    | Result.Error errs ->
      raise (ParseError errs)
  in
  typed_tree *)

(* let parse_string_to_program ~file_key ~type_provider content =
  let result = Parser.parse_string file_key content in
  let open_domains = [
    [| "std"; "preclude" |]
  ] in
  let env = Waterlang_typing.Env.create () ~open_domains ~type_provider in
  let typed_tree, include_module_ids =
    match result with
    | Result.Ok { tree; include_module_ids } ->
      begin
        (* Ast.pp_program Format.std_formatter program; *)
        let program = Waterlang_typing.Annotate.annotate env tree in
        Typecheck.type_check env program;

        let typecheck_errors = Waterlang_typing.Env.errors env in
        if not (List.is_empty typecheck_errors) then (
          raise (TypeCheckError typecheck_errors)
        );

        (program, include_module_ids)
        
      end

    | Result.Error errs ->
      raise (ParseError errs)
  in
  typed_tree, include_module_ids *)

module ModuleMap = Hashtbl.Make(String)

type t = {
  (* absolute path => module *)
  module_map: Module.t ModuleMap.t;
  find_paths: string list;
}

let create ~find_paths () = {
  module_map = ModuleMap.create ();
  find_paths;
}

let _create_type_provider env : Type_provider.provider =
  object

    method resolve (mod_id, name) =
      (* find module in find paths *)
      match ModuleMap.find env.module_map mod_id with
      | Some _mod -> (
        let files = Module.files _mod in
        List.fold_until
          ~init:None
          ~f:(fun _ file ->
            let typed_tree = Option.value_exn (Module.(file.typed_tree)) in
            let { Typedtree. tprogram_scope; _ } = typed_tree in
            let first_name = name in
            match Scope.find_var_symbol tprogram_scope first_name with
            | Some sym -> Base.Continue_or_stop.Stop (Some sym)
            | None -> Base.Continue_or_stop.Continue None
          )
          ~finish:(fun item -> item)
          files
      )
      | None -> None

  end

let last_piece_of_path path =
  let parts = Filename.parts path in
  List.last_exn parts

(* let rec load_library_by_dir id_list env std_dir =
  let abs_path = Filename.realpath std_dir in

  let lib_name = last_piece_of_path abs_path in

  let module_id = lib_name::id_list in
  let module_id_str = get_mod_id module_id in
  match ModuleMap.find env.module_map module_id_str with
  | Some _ -> ()
  | None -> (
    let lib_entry_file = Filename.concat abs_path "lib.wt" in
    (match (Sys.file_exists lib_entry_file) with
    | `No -> raise (FileNotFound lib_entry_file)
    | _ -> ()
    );

    let entry_file_content = In_channel.read_all lib_entry_file in
    let file_key = File_key.LibFile lib_entry_file in
    let type_provider = create_type_provider env in
    let typed_tree, child_modules =
      parse_string_to_program ~file_key:(Some file_key) ~type_provider entry_file_content
    in
    let id = List.rev (lib_name::id_list) |> List.to_array in
    let _mod = Module.create ~path:abs_path ~id ~id_str:module_id_str typed_tree in
    ModuleMap.set env.module_map ~key:module_id_str ~data:_mod;
    List.iter
      ~f:(fun item ->
        load_library_by_dir module_id env (Filename.concat std_dir item)
      )
      child_modules
  ) *)

let print_loc_title ~prefix loc_opt =
  Loc. (
    match loc_opt.source with
    | Some source -> (
      print_error_prefix ();
      let source_str = Format.asprintf "%a" Waterlang_lex.File_key.pp source in
      Out_channel.printf "%s in %s\n" prefix (TermColor.bold ^ source_str ^ TermColor.reset)
    )
    | None -> ()
  )

let allow_suffix = Re.Pcre.regexp "^(.+)\\.wt$"

let insert_moudule_file env ~mod_path file =
  match ModuleMap.find env.module_map mod_path with
  | Some m ->
    Module.add_file m file

  | None -> (
    failwith (Format.sprintf "unexpected: can not find mod %s" mod_path)
  )

let rec compile_file_to_path ~ctx ~mod_path env path =
  let file_content = In_channel.read_all path in
  let file_key = File_key.LibFile path in
  let ast =
    match Parser.parse_string (Some file_key) file_content with
    | Result.Ok ast -> ast
    | Result.Error err ->
      raise (ParseError err)
  in

  let imports = Ast.(
    let collected_imports =
    List.fold
      ~init:[]
      ~f:(fun acc item ->
        let open Ast.Declaration in
        match item.spec with
        | Import import -> import::acc
        | _ -> acc
      )
      ast.tree.pprogram_declarations
    in
    let preclude = {
      Ast.Declaration.
      source = "std/preclude";
      source_loc = Loc.none;
    } in
    List.rev (preclude::collected_imports)
  ) in

  List.iter
    ~f:(fun import ->
      let open Ast.Declaration in
      let { source; _ } = import in
      let find_paths = env.find_paths in
      let result =
        List.fold
          ~init:None
          ~f:(fun acc path ->
            match acc with
            | Some _ -> acc
            | None ->
              let path = Filename.concat path source in
              if Sys.is_directory_exn path then (
                Some path
              ) else None
          )
          find_paths in
      match result with
      | Some path ->
        parse_module_by_dir ~ctx env path
      | None ->
        failwith (Format.sprintf "can not find module %s" source)
    )
    imports;

  (* parse and create env, do annotation when all files are parsed
   * because annotation stage needs all exported symbols are resolved
   *)
  let typed_env = Waterlang_typing.Env.create ~type_provider:(Type_provider.default_provider) ctx in

  (* add all top level symbols to typed_env *)
  let { Ast. pprogram_top_level; _ } = ast.tree in
  Hashtbl.iter_keys
    ~f:(fun key ->
      let open Core_type in
      let node = {
        value = TypeExpr.Unknown;
        loc = Waterlang_lex.Loc.none;
        deps = [];
        check = none;
      } in
      let new_id = Type_context.new_id (Env.ctx typed_env) node in
      Scope.insert_var_symbol (Env.peek_scope typed_env) key new_id
    )
    pprogram_top_level.names
    ;

  let file =
    { Module.
      path;
      ast = Some ast.tree;
      typed_env;
      typed_tree = None;
    }
  in
  insert_moudule_file env ~mod_path file

(* recursive all files in the path *)
and parse_module_by_dir ~ctx env dir_path =
  let iterate_parse_file mod_path =
    ModuleMap.set env.module_map ~key:mod_path ~data:(Module.create ~full_path:mod_path ());
    let children = Sys.ls_dir mod_path in
    (* only compile files in this level *)
    List.iter
      ~f:(fun item ->
        let child_path = Filename.concat mod_path item in
        if Sys.is_file_exn child_path then (
          let test_result = Re.exec allow_suffix child_path |> Re.Group.all in
          if Array.length test_result > 1 then ((* is a .wt file *)
            compile_file_to_path ~ctx ~mod_path env child_path
          )
        ) else ()
      )
      children
  in
  let full_path = Filename.realpath dir_path in
  if not (ModuleMap.mem env.module_map full_path) then (
    iterate_parse_file full_path
  )

let annotate_all_modules env =
  ModuleMap.iter
    ~f:(fun m ->
      let files = Module.files m in
      let files =
        List.map
          ~f:(fun file -> 
            let { Module. typed_env; ast; _ } = file in
            let typed_tree = Waterlang_typing.Annotate.annotate_program typed_env (Option.value_exn ast) in
            { file with
              (* clear the ast to released memory,
               * but don't know if there are other references
               *)
              ast = None;
              typed_tree = Some typed_tree;
            }
          )
          files
      in
      Module.set_files m files
    )
    env.module_map

let typecheck_all_modules ~ctx env =
  annotate_all_modules env;
  (* let type_provider = create_type_provider env in *)
  ModuleMap.iter
    ~f:(fun m -> 
      let files = Module.files m in
      let files =
        List.map
          ~f:(fun file ->
            let errors = Typecheck.type_check ctx (Option.value_exn file.typed_tree) in
            if (List.length errors) > 0 then (
              raise (TypeCheckError errors)
            );
            { file with typed_tree = file.typed_tree }
          )
          files
      in
      Module.set_files m files
    )
    env.module_map

(*
 * 1. parse all files with .wt of find path
 * 2. parse all program files with .wt of find path
 * 3. type check one by one
 *
 * All the files should be annotated before type check,
 * because cyclic dependencies is allowed.
 * Annotated parsed tree remain the "holes" to type check
 *)
let rec compile_file_path ~std_dir ~build_dir entry_file_path =
  if Option.is_none std_dir then (
    Format.printf "std library is not found\n";
    ignore (exit 1)
  );
  try
    (* ctx is a typing context for all modules *)
    let ctx = Waterlang_typing.Type_context.create () in
    let env = create ~find_paths:[ Option.value_exn std_dir ] () in

    (* parse the entry file *)
    let dir_of_entry = Filename.dirname entry_file_path in
    parse_module_by_dir ~ctx env dir_of_entry;

    typecheck_all_modules ~ctx env;

    (* open std.preclude to module scope *)
    (* let content = In_channel.read_all entry_file_path in
    let file_key = File_key.SourceFile entry_file_path in *)

    let main_mod = ModuleMap.find_exn env.module_map "hello_world" in
    let file = List.hd_exn (Module.files main_mod) in
    
    let typed_tree = Module.(file.typed_tree) in

    (* TODO: compile other modules *)
    let output = Waterlang_c.codegen ~ctx (Option.value_exn typed_tree) in
    let mod_name = entry_file_path |> Filename.dirname |> last_piece_of_path in
    let output_path = write_to_file build_dir mod_name output in
    let build_dir = Option.value_exn build_dir in
    write_runtime_files build_dir;
    let bin_name = entry_file_path |> last_piece_of_path |> (Filename.chop_extension) in
    write_makefiles ~bin_name build_dir [ (mod_name, output_path) ];
    run_make_in_dir build_dir;
  with
    | TypeCheckError errors ->
      List.iter
        ~f:(fun err ->
          let { Type_error. spec; loc; ctx } = err in
          print_loc_title ~prefix:"type error" loc;
          let start = loc.start in
          Format.printf "%d:%d %a\n" start.line start.column (Type_error.PP.error_spec ~ctx) spec
        )
        errors

    | Parse_error.Error errors
    | ParseError errors ->
      List.iter
        ~f:(fun err ->
          let { Parse_error. perr_loc; _ } = err in
          print_loc_title ~prefix:"parse error" perr_loc;
          let start = perr_loc.start in
          Format.printf "%d:%d %a\n" start.line start.column Parse_error.PP.error err
        )
        errors

    | Type_error.Error e ->
      let { Type_error. spec; loc; ctx } = e in
      print_loc_title ~prefix:"type error" loc;
      let start = loc.start in
      Format.printf "%d:%d %a\n" start.line start.column (Type_error.PP.error_spec ~ctx) spec

    (* | e ->
      let string = Exn.to_string e in
      print_error_prefix ();
      Out_channel.printf "%s\n" string;
      let stack = Printexc.get_backtrace () in
      Out_channel.print_string TermColor.grey;
      Out_channel.print_string stack;
      Out_channel.print_string TermColor.reset;
      Out_channel.print_endline "" *)

and write_to_file build_dir mod_name content: string =
  let build_dir =
    match build_dir with
    | Some v -> v
    | None -> Filename.concat Filename.temp_dir_name "waterlang"
  in
  (match Sys.file_exists build_dir with
  | `No -> (
    Unix.mkdir_p build_dir
  )
  | _ -> ()
  );
  let output_file_path = Filename.concat build_dir (mod_name ^ ".c") in
  Out_channel.write_all output_file_path ~data:content;
  output_file_path

and write_runtime_files build_dir =
  List.iter
    ~f:(fun (name, content) ->
      let output_path = Filename.concat build_dir name in
      Out_channel.write_all output_path ~data:content
    )
    Embed.contents

and write_makefiles ~bin_name build_dir mods =
  let output_path = Filename.concat build_dir "Makefile" in
  let open Makefile in
  let c_srcs = List.fold ~init:"runtime.c" ~f:(fun acc (m, _) -> (acc ^ " " ^ m ^ ".c")) mods in
  let entries = List.concat [
    [
      {
        entry_name = "all";
        deps = List.concat [ ["runtime"]; (List.map ~f:(fun (m, _) -> m) mods)];
        content = Format.sprintf "cc %s -o %s" c_srcs bin_name;
      };
      {
        entry_name = "runtime";
        deps = ["runtime.c"; "runtime.h"];
        content = "cc -c runtime.c";
      }
    ];
    List.map
      ~f:(fun (m, output) -> {
        entry_name = m;
        deps = [];
        content = "cc -c " ^ (Filename.basename output)
      })
      mods;
  ] in
  let data = to_string entries in
  Out_channel.write_all output_path ~data

and run_make_in_dir build_dir =
  Out_channel.printf "Spawn to build in %s\n" (TermColor.bold ^ build_dir ^ TermColor.reset);
  Out_channel.flush Out_channel.stdout;
  Out_channel.flush Out_channel.stderr;
  match Unix.fork () with
  | `In_the_child -> 
    Unix.chdir build_dir;
    Unix.exec ~prog:"make" ~argv:["make";] () |> ignore

  | `In_the_parent pid ->
    ignore (Unix.waitpid pid)
