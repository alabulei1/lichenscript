open Waterlang_lex

type kind =
  | Local
  | Global

let counter = ref 0

module rec TypeValue : sig
  type numeric_type =
    | Num_u32
    | Num_i32
    | Num_u64
    | Num_i64
    | Num_f32
    | Num_f64

  type t =
    | Unknown
    | Any
    | Numeric of numeric_type
    | String
    | Ctor of TypeSym.t
    | Class of class_type

  and class_type = {
    tcls_name:       TypeSym.t;
    tcls_extends:    TypeSym.t option;
    tcls_methods:    class_method_type list;
    tcls_properties: class_property_type list;
  }

  and class_method_type = {
    tcls_method_name: TypeSym.t;
    tcls_method_params: t list;
  }

  and class_property_type = {
    tcls_property_name: TypeSym.t;
    tcls_property_type: t;
  }

end =
  TypeValue
and TypeSym: sig
  type t = {
    name:     string;
    kind:     kind;
    mutable value:       TypeValue.t;
    scope_id: int;
    builtin:  bool;
  }

  val mk_builtin_global: scope_id:int -> string -> t

  val mk_local: scope_id:int -> string ->t

  val bind_value: t -> TypeValue.t -> unit

end = struct
  type t = {
    name:     string;
    kind:     kind;
    mutable value:    TypeValue.t;
    scope_id: int;
    builtin:  bool;
  }

  let mk_builtin_global ~scope_id name =
    let tsym_id = !counter in
    counter := tsym_id + 1;
    {
      name = name;
      kind = Global;
      value = TypeValue.Unknown;
      scope_id = scope_id;
      builtin = true;
    }
  
  let mk_local ~scope_id name =
    let vsym_id = !counter in
    counter := vsym_id + 1;
    {
      name = name;
      kind = Local;
      value = TypeValue.Unknown;
      scope_id = scope_id;
      builtin = false;
    }

  let bind_value sym v =
    sym.value <- v;

end

and VarSym : sig
  type t = {
    name:     string;
    def_type: TypeSym.t option;
    def_loc:  Loc.t option;
    kind:     kind;
    scope_id: int;
    builtin:  bool
  }

  val mk_local: scope_id:int -> string -> t

end = struct
  type t = {
    name:     string;
    def_type: TypeSym.t option;
    def_loc:  Loc.t option;
    kind:     kind;
    scope_id: int;
    builtin:  bool
  }

  let mk_local ~scope_id name =
    let vsym_id = !counter in
    counter := vsym_id + 1;
    {
      name = name;
      def_type = None;
      def_loc = None;
      kind = Local;
      scope_id = scope_id;
      builtin = false;
    }
  
end
