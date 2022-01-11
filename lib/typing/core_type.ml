open Core_kernel

module PropsMap = Hashtbl.Make(String)

module rec TypeExpr : sig
  type t =
    | Unknown
    | Any
    | Ctor of int * (t list)
    | Function of t list * t
    | Module of module_type
    | Array of t
    | TypeDef of TypeDef.t

  and module_type = {
    export: t;
  }

  and function_type = {
    tfun_params: (string * t) list;
    tfun_ret: t;
  }

end = struct

  type t =
    | Unknown
    | Any
    | Ctor of int * (t list)
    | Function of t list * t
    | Module of module_type
    | Array of t
    | TypeDef of TypeDef.t

  and module_type = {
    export: t;
  }

  and function_type = {
    tfun_params: (string * t) list;
    tfun_ret: t;
  }

end

and TypeDef : sig
  type module_type = {
    props: TypeExpr.t PropsMap.t;
  }

  and enum_member = {
    enum_mem_name: string;
    enum_mem_fields: t list;
  }

  and enum_type = {
    enum_members: enum_member list;
  }

  and _function = {
    fun_params: TypeExpr.t list;
    fun_return: TypeExpr.t;
  }

  and class_type = {
    tcls_extends:    t option;
    tcls_elements: (string * int) list;
  }

  and spec =
    | Primitive
    | Class of class_type 
    | Alias of TypeExpr.t
    | Module_ of module_type
    | Function of _function
    | Enum of enum_type

  and t = {
    builtin: bool;
    name: string;
    spec: spec;
  }

  val name: t -> string

  val builtin: t -> bool

  val create: ?builtin:bool -> string -> spec -> t

  val create_module: unit -> module_type

  val pp: Format.formatter -> t -> unit

  val (==): t -> t -> bool

end = struct
  type module_type = {
    props: TypeExpr.t PropsMap.t;
  }

  and enum_member = {
    enum_mem_name: string;
    enum_mem_fields: t list;
  }

  and enum_type = {
    enum_members: enum_member list;
  }

  and _function = {
    fun_params: TypeExpr.t list;
    fun_return: TypeExpr.t;
  }

  and class_type = {
    tcls_extends:    t option;
    tcls_elements: (string * int) list;
  }

  and spec =
    | Primitive
    | Class of class_type 
    | Alias of TypeExpr.t
    | Module_ of module_type
    | Function of _function
    | Enum of enum_type

  and t = {
    builtin: bool;
    name: string;
    spec: spec;
  }

  let name sym = sym.name

  let builtin sym = sym.builtin

  let create ?(builtin=false)  name spec =
    {
      builtin;
      name;
      spec;
    }

  let create_module () =
    {
      props = PropsMap.create ();
    }

  let pp formatter (sym: t) =
    Format.pp_print_string formatter sym.name

  let (==) left right =
    match (left.builtin, right.builtin) with
    | (true, true) ->
      String.equal left.name right.name

    | (false, false) ->
      phys_equal left right

    | _ -> false
  
end

let none _ = ()

type node = {
  loc: Lichenscript_lex.Loc.t;
  value: TypeExpr.t;
  deps: int list;
  check: int -> unit;
}

let unknown = {
  loc = Lichenscript_lex.Loc.none;
  value = TypeExpr.Unknown;
  deps = [];
  check = none;
}
