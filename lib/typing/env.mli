
type t

val create: ?type_provider:Type_provider.provider -> ?open_domains:(string array list) -> unit -> t

val root_scope: t -> Scope.t

val set_current_scope: t -> Scope.t -> unit

val peek_scope: t -> Scope.t

val add_error: t -> Type_error.t -> unit

val errors: t -> Type_error.t list

val with_new_scope: t -> Scope.t -> (t -> 'a) -> 'a

val set_return_type: t -> Core_type.TypeValue.t option -> unit

val return_type: t -> Core_type.TypeValue.t option

val ty_u32: t -> Core_type.TypeSym.t

val ty_i32: t -> Core_type.TypeSym.t

val ty_f32: t -> Core_type.TypeSym.t

val ty_char: t -> Core_type.TypeSym.t

val ty_string: t -> Core_type.TypeSym.t

val ty_boolean: t -> Core_type.TypeSym.t
