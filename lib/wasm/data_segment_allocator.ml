open Core_kernel

module StaticStringPool = Hashtbl.Make(String)

type data = {
  offset: int;
  data: Buffer.t;
}

type t = {
  begin_offset: int;
  mutable allocated_offset: int;
  allocated_str: data StaticStringPool.t;
}

let init_with_begin_offset begin_offset =
  {
    begin_offset;
    allocated_offset = begin_offset;
    allocated_str = StaticStringPool.create ();
  }

let add_static_string allocator str =
  let opt = StaticStringPool.find allocator.allocated_str str in
  match opt with
  | Some result -> result
  | None ->
    let encoded_buffer = String_utils.u8string_to_buffer str in
    let data =
      {
        data = encoded_buffer;
        offset = allocator.allocated_offset;
      }
    in
    let new_offset = allocator.allocated_offset + (Buffer.length encoded_buffer) in
    allocator.allocated_offset <- new_offset;
    StaticStringPool.set allocator.allocated_str ~key:str ~data;
    data
