open Core.Std
open Batsh_ast

type variable_entry = {
  name : string;
  global : bool;
}
with sexp_of

type variable_table = (string, variable_entry) Hashtbl.t

let sexp_of_variable_table (vtable : variable_table) : Sexp.t =
  Sexp.List (Hashtbl.fold vtable ~init: []
               ~f: (fun ~key ~data acc ->
                   let item = (sexp_of_variable_entry data) in
                   item :: acc
                 )
            )

type function_entry =
  | Declaration
  | Defination of variable_table
with sexp_of

type t = {
  functions : (string, function_entry) Hashtbl.t;
  globals : variable_table;
}
with sexp_of

module Scope = struct
  type t =
    | GlobalScope of variable_table
    | FunctionScope of (string * variable_table)
  with sexp_of

  let variables (scope : t) : variable_table =
    match scope with
    | GlobalScope variables -> variables
    | FunctionScope (_, variables) -> variables

  let find_variable
      (scope: t)
      ~(name: string)
    =
    Hashtbl.find (variables scope) name

  let fold
      (scope: t)
      ~(init: 'a)
      ~(f: string -> bool -> 'a -> 'a) =
    let vtable = variables scope in
    Hashtbl.fold vtable ~init
      ~f: (fun ~key ~data acc -> f data.name data.global acc)

  let rec add_temporary_variable
      (scope: t)
    :identifier =
    let random_string = Random.bits () |> Int.to_string
                        |> Digest.string |> Digest.to_hex in
    let name = "TMP_" ^ (String.prefix random_string 4) in
    match find_variable scope ~name with
    | None ->
      (* Add to symbol table *)
      let variables = variables scope in
      Hashtbl.add_exn variables ~key: name ~data: {name; global = false};
      name
    | Some _ ->
      (* Duplicated, try again *)
      add_temporary_variable scope
end

let process_identifier
    (scope: variable_table)
    (ident: identifier)
    ~(global: bool) =
  Hashtbl.change scope ident (fun original ->
      let entry = Some {
          name = ident;
          global = global;
        }
      in
      match original with
      | None -> entry
      | Some existing ->
        if global && not existing.global then
          entry
        else
          original
    )

let rec process_leftvalue
    (scope: variable_table)
    (lvalue: leftvalue)
    ~(global: bool) =
  match lvalue with
  | Identifier ident ->
    process_identifier scope ident ~global
  | ListAccess (lvalue, _) ->
    process_leftvalue scope lvalue ~global

let process_statement
    (scope: variable_table)
    (stmt: statement) =
  match stmt with
  | Assignment (lvalue, _) -> process_leftvalue scope lvalue ~global: false
  | Global ident -> process_identifier scope ident ~global: true
  | _ -> ()

let process_function
    functions
    func =
  let name, _, stmts = func in
  match Hashtbl.find functions name with
  | Some _ -> () (* TODO duplicate *)
  | None ->
    let variables = Hashtbl.create ~hashable: String.hashable () in
    Hashtbl.change functions name (fun original ->
        (* TODO declaration *)
        Some (Defination variables)
      );
    List.iter stmts ~f: (process_statement variables)

let process_toplevel (symtable: t) (topl: toplevel) =
  match topl with
  | Statement stmt -> process_statement symtable.globals stmt
  | Function func -> process_function symtable.functions func

let create (ast: Batsh_ast.t) :t =
  let symtable = {
    functions = Hashtbl.create ~hashable: String.hashable ();
    globals = Hashtbl.create ~hashable: String.hashable ()
  } in
  List.iter ast ~f: (process_toplevel symtable);
  symtable

let scope (symtable: t) (name: string) : Scope.t =
  let variables = match Hashtbl.find_exn symtable.functions name with
    | Declaration -> failwith "No such function"
    | Defination variables -> variables
  in
  Scope.FunctionScope (name, variables)

let global_scope (symtable: t) : Scope.t =
  Scope.GlobalScope symtable.globals
