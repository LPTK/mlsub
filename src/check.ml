open Tuple_fields
open Exp
open Typedefs
open Types

let env0 = env_cons Env_empty Egen

let unimp () = failwith "unimplemented"

(* Returns a A⁻ ≤ A⁺ pair *)
let rec typ_of_tyexp env = function
  | None, _ -> failwith "bad type"
  | Some t, _ -> typ_of_tyexp' env t
and typ_of_tyexp' env : tyexp' -> typ * typ = function
  | Tnamed ({label="any";_}, _) ->
     cons_typ Neg Top, cons_typ Pos Top
  | Tnamed ({label="nothing";_}, _) ->
     cons_typ Neg Bot, cons_typ Pos Bot
  | Tnamed ({label="bool";_}, _) ->
     cons_typ Neg Bool, cons_typ Pos Bool
  | Tnamed ({label="int";_}, _) ->
     cons_typ Neg Int, cons_typ Pos Int
  | Tnamed ({label="string";_}, _) ->
     cons_typ Neg String, cons_typ Pos String
  | Tnamed _ -> assert false
  | Tforall (_vars, _body) -> unimp ()
  | Trecord fields ->
     let ns, ps = typs_of_tuple_tyexp env fields in
     cons_typ Neg (Record ns), cons_typ Pos (Record ps)
  | Tfunc (args, res) ->
     let ans, aps = typs_of_tuple_tyexp env args in
     let rn, rp = typ_of_tyexp env res in
     cons_typ Neg (Func (aps, rn)), cons_typ Pos (Func (ans, rp))
  | Tparen t ->
     typ_of_tyexp env t
  | Tjoin (_s, _t) -> unimp ()
  | Tmeet (_s, _t) -> unimp ()

(*and typs_of_tuple_tyexp env fields cl = match fields with
  | None, _ -> failwith "bad tuple of types"
  | Some t, _ -> typs_of_tuple_tyexp' env t cl*)
and typs_of_tuple_tyexp env t =
  let t = map_fields (typ_of_tyexp env) t in
  map_fields fst t, map_fields snd t


let rec env_lookup_var env v =
  match env with
  | Env_empty -> failwith (v.label ^ " not in scope")
  | Env_cons { entry = Evals vs; rest; _ } when SymMap.mem v.label vs ->
     if v.shift = 0 then SymMap.find v.label vs else
       env_lookup_var rest { v with shift = v.shift - 1 }
  | Env_cons { rest; _ } ->
     env_lookup_var rest v


let report errs = List.iter (function
   | Incompatible -> failwith "incompat"
   | Missing (`Named k) -> failwith ("missing " ^ k)
   | Missing `Positional -> failwith ("missing pos")
   | Extra _ -> failwith ("extra")) errs

(* When checking a term against a template type,
   I think it's principal to inspect a Tm_typ as long as we don't
   inspect any styps. (???) 
   FIXME: this conflicts with the tendency of cons_typ to make styps. *)
let inspect = function
  | Tm_typ (Tcons cons) ->
     Tm_cons (map_head Neg (fun _pol x -> Tm_typ x) cons)
  | t -> t


let rec check env e (ty : template) =
  match e with
  | None, _ -> failwith "bad exp"
  | Some e, _ -> check' env e ty
and check' env e ty =
  let ty = inspect ty in (* ??? *)
  match e, ty with
  | If (e, ifso, ifnot), ty ->
     check env e (Tm_typ (cons_typ Neg Bool));
     check env ifso ty;
     check env ifnot ty
  | Parens e, ty ->
     check env e ty
  | Tuple fields, Tm_cons (Record tf) ->
     check_fields env fields tf
  | Proj (e, (field, _loc)), ty ->
     (* Because of subtyping, there's a checking form for Proj! *)
     let r = { fpos = [];
               fnamed = SymMap.singleton field ty;
               fnames = [field];
               fopen = `Open } in
     check env e (Tm_cons (Record r))
  | Let (ps, es, body), ty ->
     let vs = bind env SymMap.empty ps es in
     let env = env_cons env (Evals vs) in
     check env body ty
  | Fn (params, ret, body), Tm_cons (Func (ptypes, rtype)) ->
     assert false
  | Pragma "true", Tm_cons Bool -> ()
  | Pragma "false", Tm_cons Bool -> ()
  | e, ty ->
     (* Default case: infer and subtype *)
     let ty' = infer' env e in
     match_type env Pos ty' ty |> report

and check_fields env ef tf =
  fold2_fields () ef tf
    ~left:(fun () _n _e -> failwith "unexpected extra field FIXME open")
    ~right:(fun () _n _ty -> failwith "missing exp for field")
    ~both:(fun () n (e, ety) ty ->
      match n, e with
      | _, Some e ->
         check_or_check env e ety ty
      | Field_positional _, None -> assert false (* pos punning *)
      | Field_named _s, None ->
         failwith "punning unimplemented")

and infer env = function
  | None, _ -> failwith "bad exp"
  | Some e, _ -> let ty = infer' env e in wf_typ Pos env ty; ty
and infer' env = function
  | Lit l -> infer_lit l
  | Var (id, _loc) -> env_lookup_var env id
  | Typed (e, ty) ->
     let tn, tp = typ_of_tyexp env ty in
     check env e (Tm_typ tn); tp
  | Parens e -> infer env e
  | If (e, ifso, ifnot) ->
     check env e (Tm_typ (cons_typ Neg Bool));
     let tyso = infer env ifso and tynot = infer env ifnot in
     (* FIXME: join of typ? *)
     Tsimple (Tstyp_simple (join Pos (approx env env Pos tyso) (approx env env Pos tynot)))
  | Proj (e, (field,_loc)) ->
     let ty = infer env e in
     let res = ref (cons_typ Pos (ident Pos)) in
     let tmpl = Tm_cons (Record { fpos = [];
                                  fnamed = SymMap.singleton field (Tm_unknown res);
                                  fnames = [field]; fopen = `Open }) in
     match_type env Pos ty tmpl |> report;
     !res
  | Tuple fields ->
     cons_typ Pos (Record (infer_fields env fields))
  | Pragma "bot" -> cons_typ Pos Bot
  | Pragma s -> failwith ("pragma: " ^ s)
  | Let (ps, es, body) ->
     let vs = bind env SymMap.empty ps es in
     let env = env_cons env (Evals vs) in
     infer env body
  | Fn (params, ret, body) ->
     assert false
  | _ -> failwith "typechecking unimplemented for this syntax"

and bind env acc ps es =
  let ps_open = (ps.fopen = `Open) in
  let bind_one acc fn p e =
    let ty =
      match fn, p, e with
      | Field_positional _, (None,_), _
      | Field_positional _, _, (None,_) -> assert false (* pos punning *)
      | fn, (Some _, None), (Some e, None) ->
         infer env e
      | fn, (Some _, Some t), (Some e, None)
      | fn, (Some _, None), (Some e, Some t) ->
         let tn, tp = typ_of_tyexp env t in
         check env e (Tm_typ tn);
         tp
      | fn, (Some _, Some pty), (Some e, Some ety) ->
         let ptn, ptp = typ_of_tyexp env pty in
         let etn, etp = typ_of_tyexp env ety in
         check env e (Tm_typ etn);
         match_type env Pos etp (Tm_typ ptn) |> report;
         ptp in
    match p with
    | None, _ -> failwith "punning?"
    | Some p, _ -> check_pat env acc ty p in
  let acc =
    fold2_fields acc ps es
      ~left:(fun _acc _fn _p -> failwith "extra patterns")
      ~right:(fun _acc _fn _e -> failwith "extra values FIXME open")
      ~both:bind_one in
  acc

and check_pat env acc ty = function
  | None, _ -> failwith "bad pat"
  | Some p, _ -> check_pat' env acc ty p
and check_pat' env acc ty = function
  | Pvar (s,_) when SymMap.mem s acc -> failwith "duplicate bindings"
  | Pvar (s,_) ->
     SymMap.add s ty acc
  | Ptuple tp ->
     check_pat_fields env acc ty tp
  | Pparens p -> check_pat env acc ty p
  | Ptyped (p, ty') ->
     let (tn, tp) = typ_of_tyexp env ty' in
     match_type env Neg tn (Tm_typ ty) |> report;
     check_pat env acc tp p

and check_pat_fields env acc ty fs =
  let fs = map_fields (fun (p,ty) -> p, ty, ref (cons_typ Pos (ident Pos))) fs in
  let trec : _ tuple_fields =
    map_fields (fun (p, ty, r) ->
      match ty with
      | None -> Tm_unknown r
      | Some t -> failwith "unimp asc") fs in
  match_type env Pos ty (Tm_cons (Record trec)) |> report;
  fold_fields (fun acc (p, ty, r) ->
    let Some p = p in
    check_pat env acc !r p) acc fs


and infer_lit = function
  | l, _ -> infer_lit' l
and infer_lit' = function
  | Bool _ -> cons_typ Pos Bool
  | Int _ -> cons_typ Pos Int
  | String _ -> cons_typ Pos String

and infer_fields env fs =
  map_fields (function
    | Some e, None -> infer env e
    | Some e, Some ty ->
       let tn, tp = typ_of_tyexp env ty in
       check env e (Tm_typ tn); tp
    | None, _ty -> failwith "punning unimplemented") fs

and check_or_check env e ty1 ty2 =
  match ty1 with
  | None -> check env e ty2
  | Some ty ->
     let tn, tp = typ_of_tyexp env ty in
     check env e (Tm_typ tn);
     match_type env Pos tp ty2 |> report
