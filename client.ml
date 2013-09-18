open Async.Std
open Core.Std
open Printf

let rdr = Reader.create (Async_unix.Fd.stdin ())

let exit = Pervasives.exit

let ns = ref "user"

let eval_message code ns session =
  ([("session", session);
    ("op", "eval");
    ("id", "eval-" ^ (Uuid.to_string (Uuid.create ())));
    ("ns", ns);
    ("code", code ^ "\n")],
   Nrepl.default_actions)

let stdin_message input session =
  let uuid = Uuid.to_string (Uuid.create ()) in
  ([("op", "stdin");
    ("id", uuid);
    ("stdin", input ^ "\n");
    ("session", session)],
   Nrepl.default_actions)

let send_input resp (r,w,p) result =
  match List.Assoc.find resp "session" with
    | Some Bencode.String(session) -> (match result with
        | `Ok input -> Nrepl.send w p (stdin_message input session)
        (* TODO: only exit on EOF in a top-level input request *)
        | `Eof ->
           Nrepl.debug "Eof seen";
           exit 0)
    | None | Some _ -> eprintf "  No session in need-input."

let remove_pending pending id =
  Nrepl.debug ("-p " ^ String.concat ~sep:" " (Hashtbl.keys pending));
  match id with
    | Some Bencode.String(id) -> if Hashtbl.mem pending id then
        Hashtbl.remove pending id
    | None | Some _ -> eprintf "  Unknown message id.\n%!"

let handle_done (r,w,p) _ =
  if Hashtbl.keys p = ["init"] then exit 0

(* TODO: clarify what belongs here vs what goes in Nrepl *)
let rec handler handle_done (r,w,p) raw resp =
  let handle actions k v = match (k, v) with
    | ("out", out) -> actions.Nrepl.out out
    | ("err", out) -> actions.Nrepl.err out
    | ("ex", out) | ("root-ex", out) -> actions.Nrepl.ex out
    | ("value", value) -> actions.Nrepl.value value
    | ("ns", new_ns) -> ns := new_ns
    | ("session", _) | ("id", _) -> ()
    | (k, v) -> printf "  Unknown response: %s %s\n%!" k v in

  let rec execute_actions actions resp =
    match resp with
    | (k, Bencode.String v) :: tl ->
       handle actions k v;
       execute_actions actions tl
    | ("status", Bencode.List _) :: tl ->
       execute_actions actions tl
    | (k, _) :: tl ->
       eprintf "  Unknown response: %s %s\n%!" k raw;
       execute_actions actions tl
    | [] -> () in

  let resp_actions resp =
    let lookup_actions id = match Hashtbl.find p id with
      | Some actions -> actions
      | None -> Nrepl.default_actions in
    match List.Assoc.find resp "id" with
    | Some Bencode.String id -> lookup_actions id
    | Some _ -> eprintf "  Unknown id type\n%!";
                Nrepl.default_actions
    | None -> Nrepl.default_actions in

  let handle_status resp status =
    match status with
      (* TODO: handle messages with multiple status fields by recuring on tl *)
      | Bencode.String "done" :: tl ->
        remove_pending p (List.Assoc.find resp "id");
        handle_done (r,w,p) resp
      | Bencode.String "eval-error" :: tl ->
         Printf.eprintf "%s\n%!" "eval-error";
         execute_actions Nrepl.print_all resp;
         Nrepl.debug raw;
         exit 1
      | Bencode.String "unknown-session" :: tl ->
         eprintf "Unknown session.\n"; exit 1
      | Bencode.String "need-input" :: tl ->
         ignore (Reader.read_line rdr >>| send_input resp (r,w,p)); ()
      | x -> printf "  Unknown status: %s\n%!"
                    (Bencode.marshal (Bencode.List(x))) in

  (* currently if it's a status message we ignore every other field *)
  match List.Assoc.find resp "status" with
    | Some Bencode.List status -> handle_status resp status
    | Some _ -> eprintf "  Unexpected status type: %s\n%!" raw
    | None -> let actions = resp_actions resp in
              match resp with
              | (k, Bencode.String v) :: tl ->
                 handle actions k v;
                 handler handle_done (r,w,p) raw tl
              | (k, _) :: tl ->
                 eprintf "  Unknown int response: %s %s\n%!" k raw;
                 handler handle_done (r,w,p) raw tl
              | [] -> ()

let eval port messages handle_done =
  let handler = handler handle_done in
  let _ = Nrepl.new_session "127.0.0.1" port messages handler in
  never_returns (Scheduler.go ())

(* invoking main functions *)

let rec find_root cwd original =
  match Sys.file_exists (String.concat ~sep:Filename.dir_sep
                           [cwd; "project.clj"]) with
    | `Yes -> cwd
    | `No | `Unknown -> if (Filename.dirname cwd) = cwd then
        original
      else
        find_root (Filename.dirname cwd) original

let splice_args args =
  String.concat ~sep:"\" \"" (List.map args String.escaped)

let main_form =
  Printf.sprintf "(do
                    (require '[clojure.stacktrace :refer [print-cause-trace]])
                    (let [raw (symbol \"%s\")
                          ns (symbol (or (namespace raw) raw))
                          m-sym (if (namespace raw) (symbol (name raw)) '-main)]
                      (require ns)
                      (try ((ns-resolve ns m-sym) \"%s\")
                      (catch Exception e
                        (let [c (:exit-code (ex-data e))]
                          (when-not (and (number? c) (zero? c))
                            (print-cause-trace e)))))))"

let main port args =
  match args with
    | [] -> eprintf "Missing ns argument."; exit 1
    | ns :: args -> let form = main_form ns (splice_args args) in
                    let messages = [eval_message form "user"] in
                    eval port messages handle_done
