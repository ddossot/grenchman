open Core.Std
open Printf

(* Invoking Leiningen tasks. *)

let port_err =
  "Couldn't read port from ~/.lein/repl-port or $LEIN_REPL_PORT.\n
If Leiningen is not running, launch `lein repl :headless' from outside a
project directory and try again.\n"

let repl_port () =
  let filename = String.concat
                   ~sep:Filename.dir_sep [(Sys.getenv_exn "HOME");
                                          ".lein"; "repl-port"] in
  match Sys.getenv "LEIN_REPL_PORT" with
    | Some port -> int_of_string port
    | None -> match Sys.file_exists filename with
        | `Yes -> int_of_string (In_channel.read_all filename)
        | `No | `Unknown -> eprintf "%s%!" port_err; exit 111

let form = sprintf "(binding [*cwd* \"%s\", *exit-process?* false]
                      (System/setProperty \"leiningen.original.pwd\" \"%s\")

                      (defmethod leiningen.core.eval/eval-in :default
                        [project form]
                        (leiningen.core.eval/eval-in
                          (assoc project :eval-in :nrepl) form))

                      (defmethod leiningen.core.eval/eval-in :trampoline
                        [& _] (throw (Exception. \"trampoline disabled\")))

                      (try (-main \"%s\")
                        (catch clojure.lang.ExceptionInfo e
                          (let [c (:exit-code (ex-data e))]
                            (when-not (and (number? c) (zero? c))
                              (throw e))))))"

let main_message args session =
  let cwd = Sys.getcwd () in
  let root = Client.find_root cwd cwd in
  let form = form root cwd (Client.splice_args args) in
  ([("session", session);
    ("op", "eval");
    ("id", "main");
    ("ns", "leiningen.core.main");
    ("code", form)],
   Nrepl.exit_actions)

let main args =
  let port = repl_port () in
  Client.eval port [main_message args] Client.handle_done
