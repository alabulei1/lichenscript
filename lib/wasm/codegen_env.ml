open Core_kernel

module StaticStringPool = Map.Make(String)

let allocator_facility_flag = 0b00000001
let string_facility_flag    = 0b00000010

type t = {
  module_: C_bindings.m;
  output_filename: string;
  config: Config.t;
  mutable facilities_flags: int;
  mutable static_string_pool: int StaticStringPool.t;
}

let create ?output_filename config =
  {
    module_ = C_bindings.make_module();
    output_filename = Option.value output_filename ~default:"test";
    config;
    facilities_flags = 0;
    static_string_pool = StaticStringPool.empty;
  }

let add_static_string env str =
  let opt = StaticStringPool.find env.static_string_pool str in
  match opt with
  | Some result -> result
  | None ->
    let id = StaticStringPool.length env.static_string_pool in
    let next = StaticStringPool.set env.static_string_pool ~key:str ~data:id in
    env.static_string_pool <- next;
    id

let turn_on_allocator env =
  env.facilities_flags <- env.facilities_flags lor allocator_facility_flag

let turn_on_string env =
  turn_on_allocator env;
  env.facilities_flags <- env.facilities_flags lor string_facility_flag

let needs_allocator env =
  not (Int.equal (env.facilities_flags land allocator_facility_flag) 0)

let needs_string env =
  not (Int.equal (env.facilities_flags land string_facility_flag) 0)

let ptr_ty env =
  match env.config.arch with
  | Config.ARCH_WASM32 ->
    C_bindings.make_ty_int32 ()

  | Config.ARCH_WASM64 ->
    C_bindings.make_ty_int64 ()

let ptr_size env =
  match env.config.arch with
  | Config.ARCH_WASM32 -> 4
  | Config.ARCH_WASM64 -> 8
