open! Import

module Page = struct
  type t = Explorer | Settings | About | Editor

  let to_string = function
    | Explorer -> "Explorer"
    | Editor -> "Editor"
    | Settings -> "Settings"
    | About -> "About"

  let all_in_order = [Explorer; Editor; Settings; About]
end

open Page

module Editor_mode = struct
  type format = [`Uri | `Hex | `Michelson | `Metadata_json]
  type t = [`Guess | format]

  let to_string : [< t] -> string = function
    | `Guess -> "guess"
    | `Uri -> "uri"
    | `Hex -> "hex"
    | `Michelson -> "michelson"
    | `Metadata_json -> "metadata"

  let all : t list = [`Guess; `Uri; `Hex; `Michelson; `Metadata_json]

  let explain : t -> _ =
    let open Meta_html in
    function
    | `Metadata_json -> t "Parse and display TZIP-16 Metadata JSON content."
    | `Uri -> t "Parse and display TZIP-16 Metadata URIs."
    | `Michelson ->
        t "Parse and serialize Micheline concrete syntax (Michelson)."
    | `Hex -> t "Parse Hexadecimal Michelson" %% ct "PACK" % t "-ed bytes."
    | `Guess -> t "Use heuristics to guess your intended format."
end

type t =
  { page: [`Page of Page.t | `Changing_to of Page.t] Reactive.var
  ; explorer_input: string Reactive.var
  ; explorer_go: bool Reactive.var
  ; explorer_went: bool Reactive.var
  ; explorer_result: Html_types.div_content_fun Meta_html.H5.elt Async_work.t
  ; editor_content: string Reactive.var
  ; editor_mode: Editor_mode.t Reactive.var
  ; editor_load: bool Reactive.var
  ; editor_should_load: bool Reactive.var
  ; check_micheline_indentation: bool Reactive.var
  ; current_network: Network.t Reactive.var }

let get (state : < gui: t ; .. > Context.t) = state#gui
let local_storage_filename = "tzcomet-editor-input"

module Fragment = struct
  let to_string = Uri.to_string
  let pp = Uri.pp
  let page_to_path page = Fmt.str "/%s" (Page.to_string page |> String.lowercase)

  let make ~page ~dev_mode ~editor_input ~explorer_input ~explorer_go
      ~editor_mode ~check_micheline_indentation ~editor_load =
    let query =
      match explorer_input with "" -> [] | more -> [("explorer-input", [more])]
    in
    let query =
      match editor_input with
      | "" -> query
      | more -> ("editor-input", [more]) :: query in
    let query = if not dev_mode then query else ("dev", ["true"]) :: query in
    let query = if not explorer_go then query else ("go", ["true"]) :: query in
    let query =
      if not check_micheline_indentation then query
      else ("check-micheline-indentation", ["true"]) :: query in
    let query =
      match editor_mode with
      | `Guess -> query
      | other -> ("editor-mode", [Editor_mode.to_string other]) :: query in
    let query =
      if editor_load then ("load-storage", ["true"]) :: query else query in
    Uri.make () ~path:(page_to_path page) ~query

  let change_for_page t page = Uri.with_path t (page_to_path page)

  let parse fragment =
    let uri = Uri.of_string (Uri.pct_decode fragment) in
    let pagename = Uri.path uri |> String.chop_prefix_if_exists ~prefix:"/" in
    let page =
      List.find all_in_order ~f:(fun page ->
          String.equal
            (String.lowercase (Page.to_string page))
            (pagename |> String.lowercase))
      |> Option.value ~default:Explorer in
    let query = Uri.query uri in
    let in_query = List.Assoc.find ~equal:String.equal query in
    let true_in_query q =
      match in_query q with Some ["true"] -> true | _ -> false in
    let dev_mode = true_in_query "dev" in
    let mich_indent = true_in_query "check-micheline-indentation" in
    let explorer_input =
      match in_query "explorer-input" with Some [one] -> one | _ -> "" in
    let editor_mode =
      Option.bind (in_query "editor-mode") (function
        | [] -> None
        | one :: _ ->
            List.find Editor_mode.all ~f:(fun mode ->
                String.equal
                  (String.lowercase (Editor_mode.to_string mode))
                  (one |> String.lowercase)))
      |> Option.value ~default:`Guess in
    let explorer_go = true_in_query "go" in
    let editor_load = true_in_query "load-storage" in
    let editor_input =
      match in_query "editor-input" with Some [one] -> one | _ -> "" in
    ( System.create ~dev_mode ()
    , { page= Reactive.var (`Page page)
      ; explorer_input= Reactive.var explorer_input
      ; explorer_go= Reactive.var explorer_go
      ; explorer_went=
          (* If page is not the explorer we will ignore the command =
             assume it aready happened. *)
          Reactive.var Poly.(page <> Page.Explorer)
      ; explorer_result= Async_work.empty ()
      ; editor_content= Reactive.var editor_input
      ; editor_mode= Reactive.var editor_mode
      ; editor_load= Reactive.var editor_load
      ; editor_should_load=
          Reactive.var (editor_load && String.is_empty editor_input)
      ; check_micheline_indentation= Reactive.var mich_indent
      ; current_network= Reactive.var `Mainnet } )
end

(* in
   { page= Reactive.var page
   ; version_string= None
   ; dev_mode= Reactive.var dev_mode
   ; explorer_input= Reactive.var explorer_input } *)

let set_page state p () = Reactive.set (get state).page p
let page state = (get state).page |> Reactive.get
let explorer_result ctxt = (get ctxt).explorer_result

let current_page_is_not state p =
  Reactive.get (get state).page
  |> Reactive.map ~f:Poly.(function `Page pp | `Changing_to pp -> pp <> p)

let dev_mode state = System.dev_mode state
let dev_mode_bidirectional = System.dev_mode_bidirectional
let explorer_input state = (get state).explorer_input |> Reactive.get
let explorer_input_value state = (get state).explorer_input |> Reactive.peek
let set_explorer_input state = (get state).explorer_input |> Reactive.set

let explorer_input_bidirectional state =
  (get state).explorer_input |> Reactive.Bidirectional.of_var

let save_editor_content ctxt =
  Local_storage.write_file ctxt local_storage_filename
    (Reactive.peek (get ctxt).editor_content)

let set_editor_content state v = Reactive.set (get state).editor_content v
let set_current_network state v = Reactive.set (get state).current_network v
let current_network state = Reactive.peek (get state).current_network

let load_editor_content ctxt =
  match Local_storage.read_file ctxt local_storage_filename with
  | None -> set_editor_content ctxt ""
  | Some s -> set_editor_content ctxt s

let editor_content ctxt =
  let s = get ctxt in
  if Reactive.peek s.editor_should_load then (
    load_editor_content ctxt ;
    Reactive.set s.editor_should_load false ) ;
  (get ctxt).editor_content |> Reactive.Bidirectional.of_var

let editor_mode ctxt = Reactive.get (get ctxt).editor_mode
let set_editor_mode ctxt = Reactive.set (get ctxt).editor_mode

let transform_editor_content ctxt ~f =
  let v = (get ctxt).editor_content in
  let changed = f (Reactive.peek v) in
  Reactive.set v changed

(*
     Automatic saving to make one day?
        let variable = (get ctxt).editor_content in
        Reactive.Bidirectional.make (Reactive.get variable) (fun v ->
           Local_storage.write_file ctxt local_storage_filename v ;
           Reactive.set variable v)
  *)

let check_micheline_indentation ctxt =
  Reactive.peek (get ctxt).check_micheline_indentation

let check_micheline_indentation_bidirectional ctxt =
  Reactive.Bidirectional.of_var (get ctxt).check_micheline_indentation

let make_fragment ?(side_effects = true) ctxt =
  (* WARNING: for now it is important for this to be attached "somewhere"
     in the DOM.
     WARNING-2: this function is used for side effects unrelated to the
     fragment too (system.dev_mode).
  *)
  let open Js_of_ocaml.Url in
  let state = get ctxt in
  let dev = dev_mode ctxt in
  let page =
    Reactive.get state.page
    |> Reactive.map ~f:(function `Page p | `Changing_to p -> p) in
  let explorer_input = Reactive.get state.explorer_input in
  let editor_input = Reactive.get state.editor_content in
  let explorer_go = Reactive.get state.explorer_go in
  Reactive.(
    dev ** page ** explorer_input ** explorer_go ** editor_input
    ** get state.editor_mode
    ** get state.check_micheline_indentation
    ** get state.editor_load)
  |> Reactive.map
       ~f:(fun
            ( dev_mode
            , ( page
              , ( explorer_input
                , ( explorer_go
                  , ( editor_input
                    , (editor_mode, (check_micheline_indentation, editor_load))
                    ) ) ) ) )
          ->
         let now =
           Fragment.(
             let editor_input =
               if String.length editor_input < 40 then editor_input else ""
             in
             make ~page ~dev_mode ~explorer_input ~explorer_go ~editor_input
               ~editor_mode ~check_micheline_indentation ~editor_load) in
         if side_effects then (
           let current = Js_of_ocaml.Url.Current.get_fragment () in
           dbgf "Updating fragment %S → %a" current Fragment.pp now ;
           Current.set_fragment (Fragment.to_string now) ) ;
         now)

let link_to_editor ctxt content ~text =
  let open Meta_html in
  let fragment = make_fragment ~side_effects:false ctxt in
  let href =
    Reactive.(map fragment) ~f:(fun frg ->
        "#" ^ Fragment.(to_string (change_for_page frg Page.Editor))) in
  a
    ~a:
      [ H5.a_href href
      ; H5.a_onclick
          (Tyxml_lwd.Lwdom.attr (fun _ ->
               Reactive.set (get ctxt).editor_should_load false ;
               set_editor_content ctxt text ;
               set_page ctxt (`Changing_to Page.Editor) () ;
               false)) ]
    content

let link_to_explorer ctxt content ~search =
  let open Meta_html in
  let fragment = make_fragment ~side_effects:false ctxt in
  let href =
    Reactive.(map fragment) ~f:(fun frg ->
        "#" ^ Fragment.(to_string (change_for_page frg Page.Explorer))) in
  a
    ~a:
      [ H5.a_href href
      ; H5.a_onclick
          (Tyxml_lwd.Lwdom.attr (fun _ ->
               Reactive.set (get ctxt).explorer_go true ;
               Reactive.set (get ctxt).explorer_went false ;
               set_explorer_input ctxt search ;
               set_page ctxt (`Changing_to Page.Explorer) () ;
               false)) ]
    content

let if_explorer_should_go state f =
  if
    (get state).explorer_go |> Lwd.peek
    && not ((get state).explorer_went |> Lwd.peek)
  then (
    Lwd.set (get state).explorer_went true ;
    f () )
  else ()

module Examples = struct
  type item = string * string

  type t =
    { contracts: item list
    ; uris: item list
    ; metadata_blobs: item list
    ; michelson_bytes: item list
    ; michelson_concretes: item list }

  let get state =
    let https_ok =
      "https://raw.githubusercontent.com/tqtezos/TZComet/8d95f7b/data/metadata_example0.json"
    in
    let hash_of_https_ok =
      (* `sha256sum data/metadata_example0.json` → Achtung, the URL
         above takes about 5 minutes to be up to date with `master` *)
      "5fba33eccc1b310add3e66a76fe7c9cd8267b519f2f78a88b72868936a5cb28d" in
    let sha256_https_ok =
      Fmt.str "sha256://0x%s/%s" hash_of_https_ok (Uri.pct_encode https_ok)
    in
    let sha256_https_ko =
      Fmt.str "sha256://0x%s/%s"
        (String.tr hash_of_https_ok ~target:'9' ~replacement:'1')
        (Uri.pct_encode https_ok) in
    dev_mode state
    |> Reactive.map ~f:(fun dev ->
           let aggl () =
             let all = ref [] in
             let add v desc = all := (v, desc) :: !all in
             let add_dev v desc = if dev then add v desc else () in
             let all () = List.rev !all in
             (add, add_dev, all) in
           let kt1, kt1_dev, kt1_all = aggl () in
           let uri, uri_dev, uri_all = aggl () in
           let mtb, mtb_dev, mtb_all = aggl () in
           let mby, mby_dev, mby_all = aggl () in
           let tzc, tzc_dev, tzc_all = aggl () in
           let kt1_one_view = "KT1V8ghqePSqVW5jYC1T9zj2udQ6qZQjBqNf" in
           kt1_dev "KT1PcrG22mRhK6A8bTSjRhk2wV1o5Vuum2S2"
             "Should not exist any where." ;
           kt1 "KT1TLvewkn73Hb1YTDyX6pE6oD8qVKGTZax3"
             "Just a version string as metadata." ;
           kt1_dev "KT1UYx6muzchTo6CGMcHwDowCQJMNoUPPBLp"
             "Has a URI that points nowhere." ;
           kt1_dev "KT1Peb7x8DfBMnHyyzdSDgpSyAvaZXLuTz5g"
             "Has a URI that is invalid." ;
           kt1_dev "KT1FsTYsKVfyvAuoh4WHNV5ibWbnh55p1XvR"
             "Points to invalid metdaata." ;
           kt1 kt1_one_view "Has one off-chain-view." ;
           kt1_dev "KT1JyuJoEDVaJ5Pfjp6vZsrvZRymyGs59rgw"
             "Has a few views that return bytes (JSON, UTF-8, binary …)" ;
           kt1_dev "KT1T8oqWTAVokcEh2ki56Gyf4QBbsoJE3jjU"
             "Event more weird off-chain-views." ;
           kt1 "KT1W4wh1qDc2g22DToaTfnCtALLJ7jHn38Xc"
             "An NFT collection by “The Alchememist” on Mainnet." ;
           uri https_ok "A valid HTTPS URI." ;
           uri sha256_https_ok "A valid SHA256+HTTPS URI." ;
           uri_dev sha256_https_ko
             "A valid SHA256+HTTPS URI but the hash is not right." ;
           uri
             (Fmt.str "tezos-storage://%s/contents" kt1_one_view)
             "An on-chain pointer to metadata." ;
           uri_dev
             (Fmt.str "tezos-storage://%s.NetXrtZMmJmZSeb/contents"
                kt1_one_view)
             "An on-chain pointer to metadata with chain-id." ;
           uri_dev "tezos-storage:/here"
             "An on-chain pointer that requires a KT1 in context." ;
           uri "ipfs://QmWDcp3BpBjvu8uJYxVqb7JLfr1pcyXsL97Cfkt3y1758o"
             "An IPFS URI to metadata JSON." ;
           uri_dev "ipfs://ldisejdse-dlseidje" "An invalid IPFS URI." ;
           mtb "{}" "Empty, but valid, Metadata" ;
           mtb {json|{"description": "This is just a description."}|json}
             "Metadata with just a description." ;
           let all_mtb_from_lib =
             let open Tezos_contract_metadata.Metadata_contents in
             let rec go n =
               try (n, Example.build n) :: go (n + 1) with _ -> [] in
             go 0 in
           List.iter all_mtb_from_lib ~f:(fun (ith, v) ->
               mtb_dev
                 (Tezos_contract_metadata.Metadata_contents.to_json v)
                 (Fmt.str "Meaningless example #%d" ith)) ;
           mby "0x05030b" "The Unit value, PACKed." ;
           mby
             "050707010000000c486\n\
              56c6c6f20576f726c64\n\
              2102000000260704010\n\
              0000003666f6f010000\n\
              0003626172070401000\n\
              0000474686973010000\n\
              000474686174"
             "Michelson with a (map string string)." ;
           mby_dev "0x05" "Empty but still Michelsonian bytes." ;
           (let tzself f c = Fmt.kstr (f c) "Michelson %S" c in
            List.iter ~f:(tzself tzc)
              ["Unit"; "12"; "\"hello world\""; "(Pair 42 51)"] ;
            List.iter ~f:(tzself tzc_dev)
              ["Unit 12"; "\"hœlló wörld\""; "(Pair 42 51 \"meh\")"]) ;
           { contracts= kt1_all ()
           ; uris= uri_all ()
           ; metadata_blobs= mtb_all ()
           ; michelson_bytes= mby_all ()
           ; michelson_concretes= tzc_all () })
end
