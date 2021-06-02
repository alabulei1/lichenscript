
module Loc = Waterlang_lex.Loc

type constant =
  Const_int of int
| Const_char of char
| Const_string of string * Loc.t * string option
| Const_float of string
| Const_int32 of int32
| Const_int64 of int64
| Const_nativeint of nativeint

type 'a loc = {
  txt : 'a;
  loc : Loc.t;
}
