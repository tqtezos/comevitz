open! Import

module Node_status = struct
  type t = Uninitialized | Non_responsive of string | Ready of string
end

open Node_status

module Node = struct
  type t = {name: string; prefix: string; status: (float * Node_status.t) Var.t}

  let create name prefix =
    {name; prefix; status= Var.create "node-status" (0., Uninitialized)}

  let rpc_get node path =
    let open Lwt in
    let uri = Fmt.str "%s/%s" node.prefix path in
    Js_of_ocaml_lwt.XmlHttpRequest.(
      get uri
      >>= fun frame ->
      dbgf "%s %s code: %d" node.prefix path frame.code ;
      match frame.code with
      | 200 -> return frame.content
      | other -> Fmt.failwith "Getting %S returned code: %d" path other)

  let ping node =
    let open Lwt in
    Js_of_ocaml_lwt.XmlHttpRequest.(
      Fmt.kstr get "%s/chains/main/blocks/head/metadata" node.prefix
      >>= fun frame ->
      dbgf "%s metadata code: %d" node.name frame.code ;
      let new_status =
        match frame.code with
        | 200 ->
            dbgf "%s metadata content: %s" node.name frame.content ;
            Ready frame.content
        | other -> Non_responsive (Fmt.str "Return-code: %d" other) in
      return new_status)

  let micheline_of_json s =
    let json =
      match Ezjsonm.value_from_string s with
      | `O (("code", code) :: _) -> code
      | other -> other in
    let enc =
      Tezos_micheline.Micheline.canonical_encoding ~variant:"custom"
        Data_encoding.string in
    let mich = Data_encoding.Json.destruct enc json in
    Tezos_micheline.Micheline.root mich

  let metadata_big_map state_handle node ~address ~log =
    let open Lwt in
    let get = rpc_get node in
    let log fmt = Fmt.kstr log fmt in
    Fmt.kstr get "/chains/main/blocks/head/context/contracts/%s/storage" address
    >>= fun storage_string ->
    log "Got raw storage: %s" storage_string ;
    let mich_storage = micheline_of_json storage_string in
    log "As concrete: %a"
      Tezos_contract_metadata.Contract_storage.pp_arbitrary_micheline
      mich_storage ;
    State.slow_step state_handle
    >>= fun () ->
    Fmt.kstr get "/chains/main/blocks/head/context/contracts/%s/script" address
    >>= fun script_string ->
    log "Got raw script: %s…" (String.prefix script_string 30) ;
    let mich_storage_type =
      micheline_of_json script_string
      |> Tezos_micheline.Micheline.strip_locations
      |> Tezos_contract_metadata.Contract_storage.get_storage_type_exn in
    log "Storage type: %a"
      Tezos_contract_metadata.Contract_storage.pp_arbitrary_micheline
      mich_storage_type ;
    State.slow_step state_handle
    >>= fun () ->
    let bgs =
      Tezos_contract_metadata.Contract_storage.find_metadata_big_maps
        ~storage_node:mich_storage ~type_node:mich_storage_type in
    match bgs with
    | [] -> Fmt.failwith "Contract has no valid %%metadata big-map!"
    | _ :: _ :: _ ->
        Fmt.failwith "Contract has too many %%metadata big-maps: %s"
          ( oxfordize_list bgs ~map:Z.to_string
              ~sep:(fun () -> ",")
              ~last_sep:(fun () -> ", and ")
          |> String.concat ~sep:"" )
    | [one] -> return one

  let bytes_value_of_big_map_at_string node ~big_map_id ~key ~log =
    let open Lwt in
    let hash_string = B58_hashes.b58_script_id_hash_of_michelson_string key in
    Fmt.kstr (rpc_get node) "/chains/main/blocks/head/context/big_maps/%s/%s"
      (Z.to_string big_map_id) hash_string
    >>= fun bytes_raw_value ->
    Fmt.kstr log "bytes raw value: %s" bytes_raw_value ;
    let content =
      match Ezjsonm.value_from_string bytes_raw_value with
      | `O [("bytes", `String b)] -> Hex.to_string (`Hex b)
      | _ -> Fmt.failwith "Cannot find bytes in %s" bytes_raw_value in
    return content
end

type t =
  { nodes: Node.t list Var.t
  ; wake_up_call: unit Lwt_condition.t
  ; loop_started: bool Var.t
  ; loop_interval: float Var.t }

let create nodes =
  { nodes=
      Var.create "list-of-nodes" nodes
        ~eq:(List.equal Node.(fun na nb -> String.equal na.prefix nb.prefix))
  ; wake_up_call= Lwt_condition.create ()
  ; loop_started= Var.create "loop-started" false
  ; loop_interval= Var.create "loop-interval" 10. }

let nodes t = t.nodes

let _global =
  create
    [ Node.create "Carthagenet-GigaNode" "https://testnet-tezos.giganode.io"
    ; Node.create "Mainnet-GigaNode" "https://mainnet-tezos.giganode.io"
    ; Node.create "Dalphanet-GigaNode" "https://dalphanet-tezos.giganode.io"
    ; Node.create "Carthagenet-SmartPy" "https://carthagenet.smartpy.io"
    ; Node.create "Mainnet-SmartPy" "https://mainnet.smartpy.io"
    ; Node.create "Delphinet-SmartPy" "https://delphinet.smartpy.io" ]

let wake_up_update_loop t = Lwt_condition.broadcast t.wake_up_call ()

let start_update_loop t =
  let open Lwt in
  ignore_result
    (let rec loop count =
       let sleep_time = Var.value t.loop_interval in
       dbgf "update-loop %d (%f s)" count sleep_time ;
       Var.value t.nodes
       |> List.fold ~init:return_unit ~f:(fun prevm nod ->
              prevm
              >>= fun () ->
              catch
                (fun () ->
                  pick
                    [ ( Js_of_ocaml_lwt.Lwt_js.sleep 5.
                      >>= fun () ->
                      dbgf "%s timeout in start_update_loop" nod.Node.name ;
                      return (Non_responsive "Time-out while getting status") )
                    ; ( Node.ping nod
                      >>= fun res ->
                      dbgf "%s returned to start_update_loop" nod.name ;
                      return res ) ])
                (fun e ->
                  return (Non_responsive (Fmt.str "Error: %a" Exn.pp e)))
              >>= fun new_status ->
              dbgf "got status for %s" nod.name ;
              let now = (new%js Js_of_ocaml.Js.date_now)##valueOf in
              Var.set nod.status (now, new_status) ;
              return ())
       >>= fun () ->
       pick
         [ Js_of_ocaml_lwt.Lwt_js.sleep sleep_time
         ; Lwt_condition.wait t.wake_up_call ]
       >>= fun () ->
       Var.set t.loop_interval (Float.min (sleep_time *. 1.4) 90.) ;
       loop (count + 1) in
     loop 0)

let ensure_update_loop t =
  match Var.value t.loop_started with
  | true -> ()
  | false ->
      start_update_loop t ;
      Var.set t.loop_started true

let find_node_with_contract node_list addr =
  let open Lwt in
  catch
    (fun () ->
      Lwt_list.find_s
        (fun node ->
          catch
            (fun () ->
              Fmt.kstr (Node.rpc_get node)
                "/chains/main/blocks/head/context/contracts/%s/storage" addr
              >>= fun _ -> return_true)
            (fun _ -> return_false))
        (nodes node_list |> Var.value))
    (fun _ -> Fmt.failwith "Cannot find a node that knows about %S" addr)

let metadata_value state_handle nodes ~address ~key ~log =
  let open Lwt in
  let logf f = Fmt.kstr log f in
  find_node_with_contract nodes address
  >>= fun node ->
  logf "Found contract with node %S" node.name ;
  Node.metadata_big_map state_handle node ~address ~log
  >>= fun big_map_id ->
  logf "Metadata big-map: %s" (Z.to_string big_map_id) ;
  Node.bytes_value_of_big_map_at_string node ~big_map_id ~key ~log


let table_of_statuses node_list =
  let open RD in
  let node_status node =
    let node_metadata _date json =
      let open Ezjsonm in
      try
        let j = value_from_string json in
        let field f j =
          try List.Assoc.find_exn ~equal:String.equal (get_dict j) f
          with _ ->
            Fmt.failwith "Cannot find %S in %s" f
              (value_to_string ~minify:true j) in
        code ~a:[ (* Fmt.kstr a_ "%.03f" date *) ]
          [ Fmt.kstr txt "Level: %d"
              (field "level" j |> field "level" |> get_int) ]
      with e ->
        code [Fmt.kstr txt "Failed to parse the Metadata JSON: %a" Exn.pp e]
    in
    Reactive.div
      (Var.map_to_list node.Node.status
         ~f:
           Node_status.(
             fun (date, status) ->
               let show s = [code [s]] in
               match status with
               | Uninitialized -> show (txt "Uninitialized")
               | Non_responsive reason ->
                   show (Fmt.kstr txt "Non-responsive: %s" reason)
               | Ready metadata -> [node_metadata date metadata])) in
  tablex
    ~a:[a_class ["table"; "table-bordered"; "table-hover"]]
    ~thead:
      (thead
         [ tr
             [ th [txt "Name"]; th [txt "URI-prefix"]; th [txt "Status"]
             ; th [txt "Latest Ping"] ] ])
    [ Reactive.tbody
        (Var.map_to_list (nodes node_list) ~f:(fun nodes ->
             List.map nodes ~f:(fun node ->
                 let open Node in
                 let open Node_status in
                 tr ~a:[a_style "height: 3em"]
                   [ td
                       ~a:
                         [ Reactive.a_class
                             ( Var.signal node.status
                             |> React.S.map (function
                                  | _, Uninitialized -> ["bg-warning"]
                                  | _, Non_responsive _ -> ["bg-danger"]
                                  | _, Ready _ -> ["bg-success"]) ) ]
                       [em [txt node.name]]; td [code [txt node.prefix]]
                   ; td [node_status node]
                   ; td
                       [ Reactive.code
                           (Var.map_to_list node.status ~f:(fun (date, _) ->
                                let date_string =
                                  (new%js Js_of_ocaml.Js.date_fromTimeValue
                                     date)##toISOString
                                  |> Js_of_ocaml__Js.to_string in
                                [txt date_string])) ] ]))) ]
