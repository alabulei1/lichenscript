(*
 * Definition of C op
 * used for data generation
 *
 * Primarily, flatten the expressions
 * to declarations.
 *)

open Lichenscript_lex
open Lichenscript_parsing

module%gen rec Decl : sig

  type _class = {
    name: string;
    original_name: string;
    finalizer_name: string;
    properties: string list;
  }
  [@@deriving show]

  type class_init = {
    class_id_name: string;
    class_def_name: string;
  }
  [@@deriving show]

  type spec =
  | Func of Func.t
  | Class of _class
  | GlobalClassInit of string * class_init list
  [@@deriving show]

  type t = {
    spec: spec;
    loc: Loc.t;
  }
  [@@deriving show]

end
 = Decl

and Stmt : sig

  type spec =
  | If
  | While of Expr.t * Block.t
  | Expr of Expr.t
  | VarDecl of string list
  | Continue
  | Break
  | Retain of Expr.t
  | Release of Expr.t
  [@@deriving show]

  type t = {
    spec: spec;
    loc: Loc.t;
  }
  [@@deriving show]

end
  = Stmt

and Expr : sig

  type spec =
  | NewString of string
  | NewInt of string
  | NewFloat of string
  | NewChar of char 
  | NewBoolean of bool
  | I32Binary of Asttypes.BinaryOp.t * t * t
  | Call of int * t list
  | Assign of string * t
  | ExternalCall of string * t list
  | Ident of string 
  | Temp of int

  and t = {
    loc: Loc.t;
    spec: spec;
  }
  [@@deriving show]

end
  = Expr

and Func : sig

  type t = {
    name: string;
    tmp_vars_count: int;
    body: Block.t;
    comments: Loc.t Lichenscript_lex.Comment.t list;
  }
  [@@deriving show]
  
end
  = Func

and Block : sig

  type t = {
    loc: Loc.t;
    body: Stmt.t list;
  }
  [@@deriving show]

end
  = Block
