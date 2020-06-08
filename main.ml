open Lexer
open Lexing

open Printf
(*
let parse_line f g =
  try g (f Lexer.read (Lexing.from_string (input_line stdin))) with
  | SyntaxError _ -> fprintf stderr "syntax error\n%!"
  | Parser.Error -> fprintf stderr "parser error\n%!"
;;
*)
open Types;;
open Typecheck;;

(*
let automaton = (constrain (compile_terms (fun f ->
    [f Neg (TVar "x"), TVar "a"; 
     f Pos (TVar "x"), TVar "b"]))
     Pos (TCons (Func (TVar "a", TVar "b"))));;
Format.printf "%a\n%a\n%!" (print_typeterm Pos) (decompile_automaton automaton) print_automaton automaton
*)
  
(*
parse_line Parser.prog (fun s -> 
parse_line Parser.onlytype (fun t ->
  let s1 = s.Typecheck.expr in
  let s2 = compile_terms (fun f -> f Pos t) in
  expand_all_flow s1;
  expand_all_flow s2;
    Format.printf "%a\n%a\n%!"
      print_automaton s1
      print_automaton s2;
    let sub s1 s2 = 
      Format.printf "%a <: %a [%s]\n%!"
        (print_typeterm Pos) (decompile_automaton s1) 
        (print_typeterm Pos) (decompile_automaton s2)
        (match subsumed (fun f -> f s1 s2) with true -> "Y" | false -> "N") in
    sub s1 s2; sub s2 s1))
;;  
*)

  (*
while true do
  parse_line Parser.subsumption (fun (t1, t2) ->
    let s1 = compile_terms (fun f -> f Pos t1)
    and s2 = compile_terms (fun f -> f Pos t2) in
    Format.printf "%a\n%a\n%!"
      print_automaton s1
      print_automaton s2;
    let sub s1 s2 = 
      Format.printf "%a <: %a [%s]\n%!"
        (print_typeterm Pos) (decompile_automaton s1) 
        (print_typeterm Pos) (decompile_automaton s2)
        (match subsumed (fun f -> f s1 s2) with true -> "Y" | false -> "N") in
    sub s1 s2; sub s2 s1)
done

   *)

let run exp =
  let (name, chan) = Filename.open_temp_file ~mode:[Open_wronly] "tmp" "ml" in
  Camlgen.to_caml (Format.formatter_of_out_channel chan) exp;
  close_out chan;
  ignore (Sys.command ("cat "^name ^"; ocaml " ^ name));
  Sys.remove name

let reparse s = compile_terms (fun f -> f Pos (decompile_automaton s))
let recomp s = decompile_automaton (compile_terms (fun f -> f Pos (decompile_automaton s)))

(*
let repl () = 
  while true do

    parse_line Parser.prog
               (fun exp ->
                 let print_err e = Format.printf "%s\n%!" (Types.Reason.fmt e) in
                (try
                  let s = optimise (Typecheck.typecheck print_err gamma0 exp) in
                  Format.printf "%a\n%!" (print_typeterm Pos) (recomp (reparse (reparse (reparse s.Typecheck.expr))))
                with
                | Failure msg -> Format.printf "Typechecking failed: %s\n%!" msg
                | Not_found -> Format.printf "Typechecking failed: Not_found\n%!"
                | Match_failure (file, line, col) -> Format.printf "Match failure in typechecker at %s:%d%d\n%!" file line col);
               (* run exp *) )
    (*parse_line Parser.prog (fun s -> Format.printf "%a\n%!" print_automaton s.Typecheck.expr)*)
  done
*)

let to_dscheme _name s =
  let states = s.expr :: SMap.fold (fun v s ss -> s :: ss) s.environment [] in
  let remap, dstates = Types.determinise states in
(*  Types.print_automaton (Symbol.to_string name) (fun s -> try (remap s).Types.DState.id with Not_found -> -1) Format.std_formatter (fun f -> f "t" s.Typecheck.expr);
  Types.print_automaton (Symbol.to_string name) (fun s -> s.Types.State.id) Format.std_formatter 
    (fun f -> f "t" (clone (fun f -> f (remap s.expr))));*)

  (* let minim = Types.minimise dstates in
  let remap x = minim (remap x) in  *)
(*  Types.print_automaton (Symbol.to_string name) (fun s -> s.Types.State.id) Format.std_formatter 
    (fun f -> f "t" (clone (fun f -> f (remap s.expr))));*)
  { d_environment = SMap.map remap s.environment; d_expr = remap s.expr }


let check gamma = function
    | `Exp (name, exp) ->
    let errored = ref false in
    let print_err e = errored := true in
    let s = optimise (Typecheck.typecheck print_err gamma exp) in
    if !errored then begin (* Note: `!errored` does NOT mean `not errored` >_< *)
      Format.printf "val res : <type error>\n%!";
      gamma
    end else begin
      let s = to_dscheme name s in
      Format.printf "val %s : %a\n%!" (Symbol.to_string name) (print_typeterm Pos) 
        (decompile_automaton (Types.clone (fun f -> f (Location.one Location.internal) s.Typecheck.d_expr)));
      SMap.add name s gamma
    end
    | `Subs (t1,t2) ->
       let s1 = compile_terms (fun f -> f Pos t1)
       and s2 = compile_terms (fun f -> f Pos t2) in
       let d2 = to_dscheme () { environment = SMap.empty; expr = s2 } in
       let sub s1 s2 = 
         Format.printf "[%s] %a <: %a\n%!"
           (match subsumed (fun f -> f Pos s1 d2.d_expr) with true -> "Y" | false -> "N")
           (print_typeterm Pos) (decompile_automaton s1) 
           (print_typeterm Pos) (decompile_automaton s2)
           in
       sub s1 s2;
       gamma
       
let process file =
  try ignore (List.fold_left check gamma0 (Source.parse_modlist (Location.of_file file)))
  with
  | Failure msg -> Format.printf "Typechecking failed: %s\n%!" msg
  | Match_failure (file, line, col) -> Format.printf "Match failure in typechecker at %s:%d%d\n%!" file line col

let repl () =
  Format.set_margin 1000;
  let module Loc : Location.Locator = struct
    let pos (p, p') : Location.t = Location.Loc (Location.of_string "<input>", 0, 0)
  end in
  let module L = Lexer.Make (Loc) in
  let module P = Parser.Make (Loc) in
  let module I = P.MenhirInterpreter in
  let gamma = ref gamma0 in
  while true do
    let buf = Lexing.from_string (input_line stdin) in
    let exprs = P.modlist L.read buf in
    List.iter (fun expr ->
      gamma := check !gamma expr) exprs
  done

let () =
  if Array.length Sys.argv = 1 then repl ()
  else Array.iter process (Array.sub Sys.argv 1 (Array.length Sys.argv - 1))

(*

while true do
  parse_line Parser.onlytype (fun t -> Format.printf "%a\n%!" (print_typeterm Pos) t)
done

*)

(*
let parse_with_error lexbuf =
  try Some (Parser.prog Lexer.read lexbuf) with
  | SyntaxError _ | Parser.Error ->
    fprintf stderr "nope\n%!"; None

(* part 1 *)
let rec parse_and_print lexbuf =
  match parse_with_error lexbuf with
  | Some value ->
    printf "%s\n%!" value
  | None -> ();;

while true do
  parse_and_print (Lexing.from_string (input_line stdin))
done
*)

(*
let loop filename () =
  let inx = In_channel.create filename in
  let lexbuf = Lexing.from_channel inx in
  lexbuf.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = filename };
  parse_and_print lexbuf;
  In_channel.close inx

(* part 2 *)
let () =
  Command.basic ~summary:"Parse and display JSON"
    Command.Spec.(empty +> anon ("filename" %: file))
    loop 
  |> Command.run
*)
