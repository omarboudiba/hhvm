(**
 * Copyright (c) 2017, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
*)

(*
This is a really dumbed-down RHL prover for showing equivalence of two
bytecode function bodies. The assertion language is just conjunctions of
equalities between local variables on the two sides, and there's no proper
fixed point iteration at all. Still, it should cope with different labels,
different uses of locals and some simple variations in control-flow
*)
open Core
open Hhbc_ast
open Local

(* Refs storing the adata for the two programs; they're written in semdiff
   and accessed in equiv
*)
let adata1_ref = ref ([] : Hhas_adata.t list)
let adata2_ref = ref ([] : Hhas_adata.t list)

let rec lookup_adata id data_dict =
match data_dict with
 | [] -> failwith "adata lookup failed"
 | ad :: rest -> if Hhas_adata.id ad = id
                 then Hhas_adata.value ad
                 else lookup_adata id rest

(* an individual prop is an equation between local variables
  To start with this means that they are both defined and equal
  or that they are both undefined
  We can usefully use more refined relations, but let's try
  the simplest for now
*)
type prop = Local.t * Local.t
module PropSet = Set.Make(struct type t = prop let compare = compare end)
module VarSet = Set.Make(struct type t = Local.t let compare = compare end)

(* along with pc, we track the current exception handler context
   this should be understood as a list of which exception handlers
   we are currently (dynamically) already within. The static part
   is dealt with via parents *)
type exnmapvalue = Fault_handler of int | Catch_handler of int
let ip_of_emv emv = match emv with
  | Fault_handler n
  | Catch_handler n -> n

module EMVMap = MyMap.Make(struct type t = exnmapvalue let compare = compare end)
type handlerstack = exnmapvalue list

type epc = handlerstack * int
let succ ((hs,pc) : epc) = (hs,pc+1)
let ip_of_pc (_hs,pc) = pc
let hs_of_pc (hs,_pc) = hs

module PcpMap = MyMap.Make(struct type t = epc*epc let compare=compare end)

(* now an assertion is a set of props, read as conjunction
   paired with two sets of local variables
   The reading is
   s,s' \in [[props, vs, vs']] iff
    \forall (v,v')\in props, s v = s' v' /\
    \forall v\in Vars\vs, s v = unset /\
    \forall v'\in Vars\vs', s' v' = unset
   *)
type assertion = PropSet.t * VarSet.t * VarSet.t
let (entry_assertion : assertion) = (PropSet.empty,VarSet.empty,VarSet.empty)
module AsnSet = Set.Make(struct type t = assertion let compare=compare end)

exception Labelexn
module  LabelMap = MyMap.Make(struct type t = Label.t let compare = compare end)

(* Refactored version of exception table structures, to improve efficiency a bit
   and to cope with new try-catch-end structure, which doesn't have explicit
   labels for the handlers
   First pass constructs labelmap and a map from the indices of TryCatchBegin
   instructions to the index of their matching TryCatchMiddle
*)
type tcstackentry = Stack_label of Label.t | Stack_tc of int
let make_label_try_maps prog =
 let rec loop p n trycatchstack labelmap trymap =
  match p with
  | [] -> (labelmap, trymap)
  | i :: is -> (match i with
     | ILabel l ->
         loop is (n+1) trycatchstack (LabelMap.add l n labelmap) trymap
     | ITry (TryCatchLegacyBegin l)
     | ITry (TryFaultBegin l) ->
         loop is (n+1) (Stack_label l :: trycatchstack) labelmap trymap
     | ITry TryCatchBegin ->
         loop is (n+1) (Stack_tc n :: trycatchstack) labelmap trymap
     | ITry TryCatchMiddle ->
         (match trycatchstack with
           | Stack_tc m :: rest ->
             loop is (n+1) rest labelmap (IMap.add m n trymap)
           | _ -> raise Labelexn
           )
     | ITry TryCatchLegacyEnd
     | ITry TryFaultEnd ->
         (match trycatchstack with
           | Stack_label _l :: rest ->
              loop is (n+1) rest labelmap trymap
           | _ -> raise Labelexn)
     (* Note that we do nothing special for TryCatchEnd, which seems a useless
        instruction *)
     | _ -> loop is (n+1) trycatchstack labelmap trymap) in
  loop prog 0 [] LabelMap.empty IMap.empty

(* Second pass constructs exception table, mapping instruction indices to
   the index of their closest handler, together with an indication of what kind
   that is, and also the parent relation
   Not sure if we need the type of handlers in the parent relation
   A fault handler can certainly have a catch handler as parent
   but I don't think catch handlers actually need parents...
*)

let make_exntable prog labelmap trymap =
 let rec loop p n trycatchstack exnmap parents =
  match p with
  | [] -> (exnmap,parents)
  | i::is -> (match i with
    | ITry (TryCatchLegacyBegin l)
    | ITry (TryFaultBegin l) ->
     let nl = LabelMap.find l labelmap in
     let emv = match l with
      | Label.Catch _ -> Catch_handler nl
      | Label.Fault _ -> Fault_handler nl
      | _ -> raise Labelexn in
       (match trycatchstack with
         | [] -> loop is (n+1) (emv :: trycatchstack) exnmap parents
         | (Fault_handler _n2 | Catch_handler _n2 as h2) :: _hs ->
            loop is (n+1) (emv :: trycatchstack)
            (IMap.add n h2 exnmap)
            (IMap.add nl h2 parents))
              (* parent of l is l2 ONLY FOR FAULTS ?? *)
     | ITry TryCatchBegin ->
       let nl = IMap.find n trymap in (* find corresponding middle *)
       let emv = Catch_handler nl in
        (match trycatchstack with
          | [] -> loop is (n+1) (emv :: trycatchstack) exnmap parents
          | (Fault_handler _n2 | Catch_handler _n2 as h2) :: _hs ->
             loop is (n+1) (emv :: trycatchstack)
             (IMap.add n h2 exnmap)
             (IMap.add nl h2 parents))
               (* parent of l is l2 I SUSPECT THIS IS UNNECESSARY *)
      | ITry TryCatchMiddle ->
        (match trycatchstack with
          | Catch_handler _ :: rest -> loop is (n+1) rest exnmap parents
          | _ -> raise Labelexn)
      | ITry TryFaultEnd ->
        (match trycatchstack with
          | Fault_handler _ :: rest -> loop is (n+1) rest exnmap parents
          | _ -> raise Labelexn)
      | ITry TryCatchLegacyEnd ->
       (match trycatchstack with
         | Catch_handler _ :: rest -> loop is (n+1) rest exnmap parents
         | _ -> raise Labelexn
       )
     | _ -> (match trycatchstack with
             | [] -> loop is (n+1) trycatchstack exnmap parents
             | h :: _hs ->
              loop is (n+1) trycatchstack (IMap.add n h exnmap) parents)
          )
   in loop prog 0 [] IMap.empty IMap.empty

(* Moving string functions into rhl so that I can use them in debugging *)

let propstostring props = String.concat " "
(List.map ~f:(fun (v,v') -> "(" ^ (Hhbc_hhas.string_of_local_id v) ^ "," ^
 (Hhbc_hhas.string_of_local_id v') ^ ")") (PropSet.elements props))

let varsettostring vs = "{" ^ String.concat ","
  (List.map ~f:(fun v -> Hhbc_hhas.string_of_local_id v) (VarSet.elements vs)) ^
  "}"

let asntostring (props,vs,vs') = propstostring props ^ varsettostring vs ^ varsettostring vs'

let asnsettostring asns = "<" ^ String.concat ","
 (List.map ~f:asntostring (AsnSet.elements asns)) ^ ">"

let string_of_pc (hs,ip) = String.concat " "
 (List.map ~f:(fun h -> string_of_int (ip_of_emv h)) hs)
                           ^ ";" ^ string_of_int ip
let labasnstostring ((l1,l2),asns) = "[" ^ (string_of_pc l1) ^ "," ^
  (string_of_pc l2) ^ "->" ^ (asnsettostring asns) ^ "]\n"
let labasntostring ((l1,l2),asns) = "[" ^ (string_of_pc l1) ^ "," ^
    (string_of_pc l2) ^ "->" ^ (asntostring asns) ^ "]\n"
let labasnlisttostring l = String.concat "" (List.map ~f:labasntostring l)
let labasnsmaptostring asnmap = String.concat ""
 (List.map ~f:labasnstostring (PcpMap.bindings asnmap))

(* add equality between v1 and v2 to an assertion
   removing any existing relation between them *)
let addeq_asn v1 v2 (props,vs,vs') =
  let stripped = PropSet.filter (fun (x1,x2) -> x1 != v1 && x2 != v2) props in
      (PropSet.add (v1,v2) stripped, VarSet.add v1 vs, VarSet.add v2 vs')

(* Unset both v1 and v2, could remove overlap with above and make one-sided *)
let addunseteq_asn v1 v2 (props,vs,vs') =
  let stripped = PropSet.filter (fun (x1,x2) -> x1 != v1 && x2 != v2) props in
    (stripped, VarSet.add v1 vs, VarSet.add v2 vs')

(* simple-minded entailment between assertions *)
let entails_asns (props2,vs2,vs2') (props1,vs1,vs1') =
  (PropSet.for_all (fun ((v,v') as prop) -> PropSet.mem prop props2
                    || not (VarSet.mem v vs2 || VarSet.mem v' vs2')) props1)
  &&
  VarSet.subset vs2 vs1
  &&
  VarSet.subset vs2' vs1'


(* need to deal with the many local-manipulating instructions
   Want to know when two instructions are equal up to an assertion
   and also to return a modified assertion in case that holds
   Note that we only track unnamed locals
*)
let asn_entails_equal (props,vs,vs') l l' =
 PropSet.mem (l,l') props
 || not (VarSet.mem l vs || VarSet.mem l' vs')

let reads asn l l' =
 match l, l' with
  | Named s, Named s' -> if s=s' then Some asn else None
  | Unnamed _, Unnamed _ ->
  if asn_entails_equal asn l l'
                 then Some asn
                 else None
  | _, _ -> None

let check_instruct_get asn i i' =
match i, i' with
 | CGetL l, CGetL l'
 | CGetQuietL l, CGetQuietL l'
 | CGetL2 l, CGetL2 l'
 | CGetL3 l, CGetL3 l'
 | CUGetL l, CUGetL l'
 | PushL l, PushL l' (* TODO: this also unsets but don't track that yet *)
    -> reads asn l l' (* these instructions read locals *)
 | ClsRefGetL (l,cr), ClsRefGetL (l',cr') ->
   if cr = cr' then reads asn l l' else None
 | VGetL (Local.Named s), VGetL (Local.Named s')
   when s=s' -> Some asn
 | VGetL _, _
 | _, VGetL _ -> None (* can't handle the possible aliasing here, so bail *)
 (* default case, require literally equal instructions *)
 | _, _ -> if i = i' then Some asn else None

 let check_instruct_isset asn i i' =
 match i, i' with
 | IssetL l, IssetL l'
 | EmptyL l, EmptyL l'
  -> reads asn l l'
 | IsTypeL (l,op), IsTypeL (l',op') ->
   if op = op' then reads asn l l' else None
 | _,_ -> if i=i' then Some asn else None

(* TODO: allow one-sided writes to dead variables - this shows up
  in one of the tests *)
let writes asn l l' =
match l, l' with
 | Named s, Named s' -> if s=s' then Some asn else None
 | Unnamed _, Unnamed _ ->
    Some (addeq_asn l l' asn)
 | _, _ -> None

(* We could be a bit more refined in tracking set/unset status of named locals
   but it might not make much difference, so leaving it out for now
*)
 let writesunset asn l l' =
 match l, l' with
  | Named s, Named s' -> if s=s' then Some asn else None
  | Unnamed _, Unnamed _ ->
     Some (addunseteq_asn l l' asn)
  | _, _ -> None

let check_instruct_mutator asn i i' =
 match i, i' with
  | SetL l, SetL l'
  | BindL l, BindL l'
   -> writes asn l l'
  | UnsetL l, UnsetL l'
    -> writesunset asn l l'
  | SetOpL (l,op), SetOpL (l',op') ->
     if op=op' then
      match reads asn l l' with
       | None -> None
       | Some newasn -> writes newasn l l' (* actually, newasn=asn, of course *)
     else None
     (* that's something that both reads and writes *)
  | IncDecL (l,op), IncDecL (l',op') ->
    if op=op' then
    match reads asn l l' with
     | None -> None
     | Some newasn -> writes newasn l l'
    else None
  | _,_ -> if i=i' then Some asn else None

let check_instruct_call asn i i' =
 match i, i' with
  | FPassL (_,_), _
  | _, FPassL (_,_) -> None (* if this is pass by reference, might get aliasing
                               so just wimp out for now *)
  | _,_ -> if i=i' then Some asn else None

let check_instruct_base asn i i' =
 match i,i' with
  | BaseNL (l,op), BaseNL (l',op') ->
    if op=op' then reads asn l l'
    else None
    (* All these depend on the string names of locals never being the ones
    we're tracking with the analysis *)
  | FPassBaseNL (n,l), FPassBaseNL (n',l') ->
     if n=n' then reads asn l l'
     else None
  | BaseGL (l,mode), BaseGL(l',mode') ->
     if mode = mode' then reads asn l l'
     else None (* don't really know if this is right *)
  | FPassBaseGL (n,l), FPassBaseGL (n',l') ->
     if n=n' then reads asn l l'
     else None
  | BaseSL (l,n), BaseSL (l',n') ->
     if n=n' then reads asn l l'
     else None
  | BaseL (l,mode), BaseL (l',mode') ->
     if mode=mode' then reads asn l l'
     else None
  | FPassBaseL (n,l), FPassBaseL (n',l') ->
    if n = n' then reads asn l l'
    else None
  | _, _ -> if i=i' then Some asn else None

let check_instruct_final asn i i' =
  match i, i' with
   | SetWithRefLML (l1,l2), SetWithRefLML (l1',l2') ->
      (match reads asn l1 l1' with
        | None -> None
        | Some newasn -> reads newasn l2 l2')
  (* I'm guessing wildly here! *)
   | SetWithRefRML l, SetWithRefRML l' -> reads asn l l'
   | _, _ -> if i=i' then Some asn else None

(* Iterators. My understanding is that the initializers either jump to the
specified label with no access to locals, or write the first value of the
iteration to the locals given in the instruction. Since this is control-flow,
we need to return further stuff to check, rather than just the newprops that
will hold for the next instruction
*)
exception IterExn (* just a sanity check *)
let check_instruct_iterator asn i i' =
 match i, i' with
  | IterInit (it,lab,l), IterInit (it',lab',l')
  | WIterInit (it,lab,l), WIterInit (it',lab',l')
  | MIterInit (it,lab,l), MIterInit (it',lab',l')
  | IterNext (it,lab,l), IterNext (it',lab',l')
  | WIterNext (it,lab,l), WIterNext (it',lab',l')
  | MIterNext (it,lab,l), MIterNext (it',lab',l')  ->
    if it = it' (* not tracking correspondence between iterators yet *)
    then (writes asn l l', (* next instruction's state *)
          [((lab,lab'),asn)])  (* additional assertions to check *)
    else (None,[]) (* fail *)
  | IterInitK (it,lab,l1,l2), IterInitK (it',lab',l1',l2')
  | WIterInitK (it,lab,l1,l2), WIterInitK (it',lab',l1',l2')
  | MIterInitK (it,lab,l1,l2), MIterInitK (it',lab',l1',l2')
  | IterNextK (it,lab,l1,l2), IterNextK (it',lab',l1',l2')
  | WIterNextK (it,lab,l1,l2), WIterNextK (it',lab',l1',l2')
  | MIterNextK (it,lab,l1,l2), MIterNextK (it',lab',l1',l2')  ->
    if it = it'
    then match writes asn l1 l1' with
           | None -> (None,[])
           | Some newasn ->
             (writes newasn l2 l2', (* wrong if same local?? *)
              [((lab,lab'),asn)])
    else (None,[]) (* fail *)
  | IterBreak (_,_) , _
  | _ , IterBreak (_,_) -> raise IterExn (* should have been dealt with
                                            along with other control flow *)
  | _ , _ -> if i=i' then (Some asn,[]) else (None,[])

let check_instruct_misc asn i i' =
 match i,i' with
  | InitThisLoc l, InitThisLoc l' ->
      writes asn l l'
  | StaticLoc (l,str), StaticLoc (l',str')
  | StaticLocInit (l,str), StaticLocInit (l',str') ->
     if str=str' then writes asn l l'
     else None
  | AssertRATL (_l,_rat), AssertRATL (_l',_rat') ->
     Some asn (* Think this is a noop for us, could do something different *)
  | Silence (l, Start), Silence(l',Start) ->
     writes asn l l'
  | Silence (l, End), Silence(l',End) ->
     reads asn l l'
  | GetMemoKeyL (Local.Named s), GetMemoKeyL (Local.Named s')
    when s = s' -> Some asn
  | GetMemoKeyL _, _
  | _, GetMemoKeyL _ -> None (* wimp out if not same named local *)
  | MemoSet (count, Local.Unnamed first, local_count),
    MemoSet(count', Local.Unnamed first', local_count')
    when count=count' && local_count = local_count' ->
      let rec loop loop_asn local local' count =
       match reads loop_asn (Local.Unnamed local) (Local.Unnamed local') with
        | None -> None
        | Some new_asn ->
           if count = 1 then Some new_asn
           else loop new_asn (local+1) (local' + 1) (count - 1)
       in loop asn first first' local_count
  | MemoSet (_,_,_), _
  | _, MemoSet (_,_,_) -> None
  | MemoGet (count, Local.Unnamed first, local_count),
    MemoGet(count', Local.Unnamed first', local_count')
    when count=count' && local_count = local_count' ->
      let rec loop loop_asn local local' count =
       match reads loop_asn (Local.Unnamed local) (Local.Unnamed local') with
        | None -> None
        | Some new_asn ->
           if count = 1 then Some new_asn
           else loop new_asn (local+1) (local' + 1) (count - 1)
       in loop asn first first' local_count
   (* yes, I did just copy-paste there. Should combine patterns !*)
  | MemoGet (_,_,_), _
  | _, MemoGet(_,_,_) -> None (* wimp out again *)
  | _, _ -> if i=i' then Some asn else None


let rec drop n l =
 match n with | 0 -> l | _ -> drop (n-1) (List.tl_exn l)

(* abstracting this out in case we want to change it from a list later *)
let add_todo (pc,pc') asn todo = ((pc,pc'),asn) :: todo

let lookup_assumption (pc,pc') assumed =
 match PcpMap.get (pc,pc') assumed with
  | None -> AsnSet.empty
  | Some asns -> asns

let add_assumption (pc,pc') asn assumed =
  let prev = lookup_assumption (pc,pc') assumed in
  let updated = AsnSet.add asn prev in (* this is a clumsy union *)
  PcpMap.add (pc,pc') updated assumed

let equiv prog prog' startlabelpairs =
 let (labelmap, trymap) = make_label_try_maps prog in
 let (exnmap, exnparents) = make_exntable prog labelmap trymap in
 let (labelmap', trymap') = make_label_try_maps prog' in
 let (exnmap', exnparents') = make_exntable prog' labelmap' trymap' in

 let rec check pc pc' asn assumed todo =
   let try_specials () = specials pc pc' asn assumed todo in

   (* This could be more one-sided, but can't allow one side to leave the
      frame and the other to go to a handler.
      Still, seems no real reason to require the same kind of
      handler on both sides
    *)
   let exceptional_todo () =
    match IMap.get (ip_of_pc pc) exnmap, IMap.get (ip_of_pc pc') exnmap' with
     | None, None -> Some todo
     | Some (Fault_handler h), Some (Fault_handler h') ->
        let epc = (Fault_handler h :: hs_of_pc pc, h) in
        let epc' = (Fault_handler h' :: hs_of_pc pc', h') in
         Some (add_todo (epc,epc') asn todo)
     | Some (Catch_handler h), Some (Catch_handler h') ->
       (* So catches aren't going to be left with an unwind, so we don't
          need to add them to the stack. What I'm not sure about is if the
          catch handler code will always be covered by all the fault handlers
          it needs to be, so that we could actually set the stack to []
          here?
       *)
        let epc = (hs_of_pc pc, h) in
        let epc' = (hs_of_pc pc', h') in
         Some (add_todo (epc,epc') asn todo)
     | _,_ -> None
      (* here we've got a mismatch between the handlers on the two sides
         so we return None so that our caller can decide what to do
      *)
    in

   let nextins () =
    match exceptional_todo () with
     | Some newtodo ->
        check (succ pc) (succ pc') asn
              (add_assumption (pc,pc') asn assumed) newtodo
     | None -> try_specials ()
   in

   let nextinsnewasn newasn =
    match exceptional_todo () with
     | Some newtodo ->
        check (succ pc) (succ pc') newasn
              (add_assumption (pc,pc') asn assumed) newtodo
     | None -> try_specials ()
   in

   if List.length (hs_of_pc pc) > 10 (* arbitrary limit *)
   then (prerr_endline (string_of_pc pc); failwith "Runaway handlerstack")
   else
   let previous_assumptions = lookup_assumption (pc,pc') assumed in
    if AsnSet.exists (fun assasn -> entails_asns asn assasn)
                     previous_assumptions
    (* that's a clumsy attempt at entailment asn => \bigcup prev_asses *)
    then donext assumed todo
    else
      if AsnSet.cardinal previous_assumptions > 2 (* arbitrary bound *)
      then try_specials ()
      else
       (
       let i = List.nth_exn prog (ip_of_pc pc) in
       let i' = List.nth_exn prog' (ip_of_pc pc') in
       match i, i' with
        (* one-sided stuff for jumps, labels, comments *)
        | IContFlow(Jmp lab), _
        | IContFlow(JmpNS lab), _ ->
         check (hs_of_pc pc, LabelMap.find lab labelmap) pc' asn
               (add_assumption (pc,pc') asn assumed) todo
        | ITry _, _
        | ILabel _, _
        | IComment _, _ ->
           check (succ pc) pc' asn (add_assumption (pc,pc') asn assumed) todo

        | _, IContFlow(Jmp lab')
        | _, IContFlow(JmpNS lab') ->
              check pc (hs_of_pc pc', LabelMap.find lab' labelmap') asn
                    (add_assumption (pc,pc') asn assumed) todo
        | _, ITry _
        | _, ILabel _
        | _, IComment _ ->
              check pc (succ pc') asn (add_assumption (pc,pc') asn assumed) todo
        | IContFlow (JmpZ lab), IContFlow (JmpZ lab')
        | IContFlow (JmpNZ lab), IContFlow (JmpNZ lab') ->
           check (succ pc) (succ pc') asn
             (add_assumption (pc,pc') asn assumed)
             (add_todo ((hs_of_pc pc, LabelMap.find lab labelmap),
                (hs_of_pc pc', LabelMap.find lab' labelmap')) asn todo)
        | IContFlow RetC, IContFlow RetC
        | IContFlow RetV, IContFlow RetV ->
           donext assumed todo
        | IContFlow Unwind, IContFlow Unwind ->
           (* TODO: this should be one side at a time, except it's
            a bit messy to deal with the case where we leave this
            frame altogether, in which case the two should agree, so
            I'm only dealing with the matching case
            *)
            (match hs_of_pc pc, hs_of_pc pc' with
               | [],[] -> try_specials () (* unwind not in handler! *)
               | ((Fault_handler h | Catch_handler h) ::hs),
                 ((Fault_handler h' | Catch_handler h') ::hs') ->
                 let leftside = match IMap.get h exnparents with
                   | None -> hs
                   | Some h2 -> h2::hs in
                 let  rightside = match IMap.get h' exnparents' with
                   | None -> hs'
                   | Some h2' -> h2'::hs' in
                 (match leftside, rightside with
                   | [],[] -> donext assumed todo (* both jump out*)
                   | (hh::_), (hh'::_) ->
                     check (leftside, ip_of_emv hh)
                           (rightside,ip_of_emv hh')
                           asn
                           (add_assumption (pc,pc') asn assumed)
                           todo
                   | _,_ -> try_specials ())
               | _,_ -> try_specials ()) (* mismatch *)
        | IContFlow Throw, IContFlow Throw ->
            (match IMap.get (ip_of_pc pc) exnmap,
                   IMap.get (ip_of_pc pc') exnmap' with
             | None, None ->  donext assumed todo (* both leave *)
             | Some (Fault_handler hip as h), Some (Fault_handler hip' as h') ->
                  let hes = h :: (hs_of_pc pc) in
                  let hes' = h' :: (hs_of_pc pc') in
                   check (hes,hip) (hes',hip') asn
                   (add_assumption (pc,pc') asn assumed)
                   todo
             | Some (Catch_handler hip), Some (Catch_handler hip') ->
                   let hes = (hs_of_pc pc) in
                   let hes' = (hs_of_pc pc') in
                    check (hes,hip) (hes',hip') asn
                    (add_assumption (pc,pc') asn assumed)
                    todo
             | _,_ -> try_specials ()) (* leaves/stays -> mismatch *)
        | IContFlow _, IContFlow _ -> try_specials ()
        (* next block have no interesting controls flow or local
           variable effects
           TODO: Some of these are not actually in this class!
        *)
        | IBasic ins, IBasic ins' ->
           if ins = ins' then nextins()
           else try_specials ()
        | ILitConst (Array id), ILitConst (Array id')
        | ILitConst (Dict id), ILitConst (Dict id')
        | ILitConst (Vec id), ILitConst (Vec id')
        | ILitConst (Keyset id), ILitConst (Keyset id') ->
          let tv = lookup_adata id (!adata1_ref) in
          let tv' = lookup_adata id' (!adata2_ref) in
          if tv = tv' then nextins()
          else try_specials ()
        | ILitConst ins, ILitConst ins' ->
           if ins = ins' then nextins()
           else try_specials ()
        (* special cases for exiting the whole program *)
        | IOp Hhbc_ast.Exit, IOp Hhbc_ast.Exit ->
           donext assumed todo
        | IOp (Fatal op), IOp (Fatal op') ->
           if op=op' then donext assumed todo
           else try_specials ()
        | IOp ins, IOp ins' ->
           if ins = ins' then nextins()
           else try_specials ()
        | ISpecialFlow ins, ISpecialFlow ins' ->
           if ins = ins' then nextins()
           else try_specials ()
        | ICall ins, ICall ins' ->
           if ins = ins' then nextins()
           else try_specials ()
        | IAsync ins, IAsync ins' ->
           if ins = ins' then nextins()
           else try_specials ()
        | IGenerator ins, IGenerator ins' ->
           if ins = ins' then nextins()
           else try_specials ()
        | IIncludeEvalDefine ins, IIncludeEvalDefine ins' ->
           if ins = ins' then nextins()
           else try_specials ()

        | IGet ins, IGet ins' ->
           (match check_instruct_get asn ins ins' with
             | None -> try_specials ()
             | Some newasn -> nextinsnewasn newasn)
        | IIsset ins, IIsset ins' ->
           (match check_instruct_isset asn ins ins' with
             | None -> try_specials ()
             | Some newasn -> nextinsnewasn newasn)
        | IMutator ins, IMutator ins' ->
           (match check_instruct_mutator asn ins ins' with
             | None -> try_specials ()
             | Some newasn -> nextinsnewasn newasn)
        | IBase ins, IBase ins' ->
           (match check_instruct_base asn ins ins' with
             | None -> try_specials ()
             | Some newasn -> nextinsnewasn newasn)
        | IFinal ins, IFinal ins' ->
           (match check_instruct_final asn ins ins' with
             | None -> try_specials ()
             | Some newasn -> nextinsnewasn newasn)
        | IMisc ins, IMisc ins' ->
           (match check_instruct_misc asn ins ins' with
             | None -> try_specials ()
             | Some newasn -> nextinsnewasn newasn)
        (* iterator instructions have multiple exit points, so have
           to add to todos as well as looking at next instruction
           TODO: exceptional exits from here *)
        | IIterator ins, IIterator ins' ->
           (match check_instruct_iterator asn ins ins' with
             | (None, _) -> try_specials ()
             | (Some newasn, newtodos) ->
                let striptodos = List.map newtodos (fun ((l,l'),asn) ->
                 ( ((hs_of_pc pc, LabelMap.find l labelmap),
                    (hs_of_pc pc', LabelMap.find l' labelmap'))
                     ,asn)) in
                check (succ pc) (succ pc') newasn
                 (add_assumption (pc,pc') asn assumed)
                 (List.fold_left striptodos ~init:todo
                   ~f:(fun td ((pc,pc'),asn) -> add_todo (pc,pc') asn td)))
        (* if they're different classes altogether, give up *)
        | _, _ -> try_specials ()
       )
and donext assumed todo =
 match todo with
  | [] -> None (* success *)
  | ((pc,pc'),asn)::rest -> check pc pc' asn assumed rest

  (* check is more or less uniform - it deals with matching instructions
     modulo local variable matching, and simple control-flow differences.
     specials deals with slightly deeper, ad hoc properties of particular
     instructions, or sequences.
     We assume we've already called check on the two pcs, so don't have
     an appropriate assumed assertion, and the instructions aren't the same
     *)
and specials pc pc' ((props,vs,vs') as asn) assumed todo =
  let i = List.nth_exn prog (ip_of_pc pc) in
  let i' = List.nth_exn prog' (ip_of_pc pc') in
  match i, i' with
   (* first, special case of unset on one side *)
   | IMutator (UnsetL l), _ ->
      let newprops = PropSet.filter (fun (x1,_x2) -> x1 != l) props in
      let newasn = (newprops, VarSet.remove l vs, vs') in
        check (succ pc) pc' newasn (add_assumption (pc,pc') asn assumed) todo
   | _, IMutator (UnsetL l') ->
      let newprops = PropSet.filter (fun (_x1,x2) -> x2 != l') props in
      let newasn = (newprops, vs, VarSet.remove l' vs') in
      check pc (succ pc') newasn (add_assumption (pc,pc') asn assumed) todo
   | _, _ -> (
     (* having looked at individual instructions, try some known special
        sequences. This is *really* hacky, and I should work out how
        to do it more generally, but it'll do for now
        Remark - really want a nicer way of doing rule-based programming
        without nasty nested matches. Order of testing is annoyingly delicate
        at the moment
     *)
        let prog_from_pc = drop (ip_of_pc pc) prog in
        let prog_from_pc' = drop (ip_of_pc pc') prog' in
        (* a funny almost no-op that shows up sometimes *)
        match prog_from_pc, prog_from_pc' with
         | (IMutator (SetL l1) :: IBasic PopC :: IGet (PushL l2) :: _), _
           when l1 = l2 ->
             let newprops = PropSet.filter (fun (x1,_x2) -> x1 != l1) props in
             let newasn = (newprops, VarSet.remove l1 vs, vs') in
               check (succ (succ (succ pc))) pc' newasn
                     (add_assumption (pc,pc') asn assumed) todo
         | _, (IMutator (SetL l1) :: IBasic PopC :: IGet (PushL l2) :: _)
            when l1 = l2 ->
             let newprops = PropSet.filter (fun (_x1,x2) -> x2 != l1) props in
             let newasn = (newprops, vs, VarSet.remove l1 vs') in
               check pc (succ (succ (succ pc'))) newasn
                        (add_assumption (pc,pc') asn assumed) todo

         (* Peephole equations for negation combined with conditional jumps *)
         | (IContFlow (JmpZ lab) :: _), (IOp Not :: IContFlow (JmpNZ lab') :: _)
         | (IContFlow (JmpNZ lab) :: _), (IOp Not :: IContFlow (JmpZ lab') :: _)
         -> check (succ pc) (succ (succ pc')) asn
           (add_assumption (pc,pc') asn assumed)
           (add_todo ((hs_of_pc pc, LabelMap.find lab labelmap),
              (hs_of_pc pc', LabelMap.find lab' labelmap')) asn todo)
         | (IOp Not :: IContFlow (JmpNZ lab) :: _), (IContFlow (JmpZ lab') :: _)
         | (IOp Not :: IContFlow (JmpZ lab) :: _), (IContFlow (JmpNZ lab') :: _)
         -> check (succ (succ pc)) (succ pc') asn
           (add_assumption (pc,pc') asn assumed)
           (add_todo ((hs_of_pc pc, LabelMap.find lab labelmap),
              (hs_of_pc pc', LabelMap.find lab' labelmap')) asn todo)
              
        (* associativity of concatenation, restricted to the case
           where the last thing concatenated is a literal constant
        *)
        | (ILitConst (String s) :: IOp Concat :: IOp Concat :: _),
          (IOp Concat :: ILitConst (String s') :: IOp Concat :: _)
        | (IOp Concat :: ILitConst (String s') :: IOp Concat :: _),
          (ILitConst (String s) :: IOp Concat :: IOp Concat :: _)
          when s = s' ->
          check (succ (succ (succ pc))) (succ (succ (succ pc'))) asn
                (add_assumption (pc,pc') asn assumed) todo
        (* OK, we give up *)
         | _, _ -> Some (pc, pc', asn, assumed, todo)
     )
in
 (* We always start from ip,ip'=0 for the top entry to the function/method, but
  also take startlabelpairs, which is  list of pairs of labels from the two
  programs, as alternative entry points. These are used for default param
  values *)
  let initialtodo = List.map ~f:(fun (lab,lab') ->
   ((([],LabelMap.find lab labelmap), ([],LabelMap.find lab' labelmap')),
     entry_assertion )) startlabelpairs in
 check ([],0) ([],0)  entry_assertion PcpMap.empty initialtodo
