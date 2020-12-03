open Import

module Uri = struct
  let validate uri_code =
    let open Tezos_contract_metadata.Metadata_uri in
    let errors = ref [] in
    let error w src e = errors := (w, src, e) :: !errors in
    let validate_kt1_address s =
      ( try ignore (B58_hashes.check_b58_kt1_hash s) with
      | Failure f -> error `Address s f
      | e -> Fmt.kstr (error `Address s) "%a" Exn.pp e ) ;
      Ok () in
    let validate_network = function
      | "mainnet" | "carthagenet" | "delphinet" | "dalphanet" | "zeronet" ->
          Ok ()
      | s ->
          ( try ignore (B58_hashes.check_b58_chain_id_hash s) with
          | Failure f -> error `Network s f
          | e -> Fmt.kstr (error `Network s) "%a" Exn.pp e ) ;
          Ok () in
    let uri =
      Uri.of_string uri_code |> of_uri ~validate_kt1_address ~validate_network
    in
    (uri, List.rev !errors)

  module Fetcher = struct
    type t = {current_contract: string option Reactive.var}

    let create () = {current_contract= Reactive.var None}
    let get (ctxt : < fetcher: t ; .. > Context.t) = ctxt#fetcher
    let current_contract ctxt = (get ctxt).current_contract

    let set_current_contract ctxt s =
      Reactive.set (get ctxt).current_contract (Some s)

    let unset_current_contract ctxt =
      Reactive.set (get ctxt).current_contract None
  end

  let rec needs_context_address =
    let open Tezos_contract_metadata.Metadata_uri in
    function
    | Storage {address= None; _} -> true
    | Web _ | Storage _ | Ipfs _ -> false
    | Hash {target; _} -> needs_context_address target

  let fetch ?(log = dbgf "Uri.fetch.log: %s") ctxt uri =
    let open Lwt.Infix in
    let logf fmt = Fmt.kstr (fun s -> dbgf "Uri.fetch: %s" s ; log s) fmt in
    let ni s = Fmt.failwith "Not Implemented: %s" s in
    dbgf "FETCCHINGG ============== " ;
    System.slow_step ctxt
    >>= fun () ->
    let rec resolve =
      let open Tezos_contract_metadata.Metadata_uri in
      function
      | Web http ->
          logf "HTTP %S (may fail because of origin policy)" http ;
          Js_of_ocaml_lwt.XmlHttpRequest.(
            get http
            >>= fun frame ->
            dbgf "%s -> code: %d" http frame.code ;
            match frame.code with
            | 200 ->
                logf "HTTP success (%d bytes)" (String.length frame.content) ;
                Lwt.return frame.content
            | other -> Fmt.failwith "Getting %S returned code: %d" http other)
          >>= fun content -> Lwt.return content
      | Ipfs {cid; path} ->
          let gateway = "https://gateway.ipfs.io/ipfs/" in
          let gatewayed = Fmt.str "%s%s%s" gateway cid path in
          logf "IPFS CID %S path %S, adding gateway %S" cid path gateway ;
          resolve (Web gatewayed)
      | Storage {network= None; address; key} ->
          let addr =
            match address with
            | Some s -> s
            | None -> (
              match Reactive.peek (Fetcher.current_contract ctxt) with
              | None -> Fmt.failwith "Missing current contract"
              | Some s -> s ) in
          logf "Using address %S (key = %S)" addr key ;
          Query_nodes.metadata_value ctxt ~address:addr ~key ~log
      | Storage {network= Some network; address; key} ->
          logf "storage %s %a %S" network Fmt.Dump.(option string) address key ;
          Fmt.kstr ni "storage uri with network = %s" network
      | Hash {kind= `Sha256; value; target} -> (
          let expected =
            match Digestif.of_raw_string_opt Digestif.sha256 value with
            | Some s -> s
            | None ->
                Fmt.failwith "%a is not a valid SHA256 hash" Hex.pp
                  (Hex.of_string value) in
          logf "sha256: %a" (Digestif.pp Digestif.sha256) expected ;
          resolve target
          >>= fun content ->
          let obtained = Digestif.digest_string Digestif.sha256 content in
          logf "hash of content: %a" (Digestif.pp Digestif.sha256) obtained ;
          match Digestif.unsafe_compare Digestif.sha256 expected obtained with
          | 0 -> Lwt.return content
          | _ ->
              Fmt.failwith "Hash of content %a is different from expected %a"
                (Digestif.pp Digestif.sha256)
                obtained
                (Digestif.pp Digestif.sha256)
                expected ) in
    resolve uri
end

module Content = struct
  let of_json s =
    try
      let jsonm = Ezjsonm.value_from_string s in
      let contents =
        Json_encoding.destruct
          Tezos_contract_metadata.Metadata_contents.encoding jsonm in
      Ok contents
    with e -> Tezos_error_monad.Error_monad.error_exn e

  type metadata = Tezos_contract_metadata.Metadata_contents.t

  type classified =
    | Tzip_16 of metadata
    | Tzip_12 of
        { metadata: metadata
        ; interface_claim:
            [`Invalid of string | `Just_interface | `Version of string] option
        ; logs: ([`Error | `Info | `Success] * Message.t) list }

  let classify : metadata -> classified =
    let open Tezos_contract_metadata.Metadata_contents in
    let looks_like_tzip_12 ~found metadata =
      let logs = ref [] in
      let log l = logs := (`Info, l) :: !logs in
      let error l = logs := (`Error, l) :: !logs in
      let success l = logs := (`Success, l) :: !logs in
      let interface_claim =
        List.find metadata.interfaces ~f:(String.is_prefix ~prefix:"TZIP-12")
        |> Option.map ~f:(function
             | "TZIP-12" -> `Just_interface
             | itf -> (
               match String.chop_prefix itf ~prefix:"TZIP-12-" with
               | None -> `Invalid itf
               | Some v -> `Version v )) in
      let tokens_field =
        List.find_map metadata.unknown ~f:(function
          | "tokens", json ->
              log Message.(t "Found a" %% ct "\"tokens\"" %% t "field.") ;
              Some json
          | _ -> None) in
      if Option.is_none interface_claim && Option.is_none tokens_field then ()
      else
        let views_validation =
          let _get_balance =
            List.find_map metadata.views ~f:(function
              | view when String.equal view.name "get_balance" -> (
                  List.find view.implementations ~f:(function
                    | Rest_api_query _ -> false
                    | Michelson_storage impl ->
                        let param_ok =
                          match impl.parameter with
                          | Some p -> (
                              Michelson.Partial_type.(
                                match of_type p with
                                | Pair
                                    { left= Leaf {kind= Nat; _}
                                    ; right= Leaf {kind= Address; _} } ->
                                    log
                                      Message.(
                                        ct "get_balance"
                                        %% t "has the right parameter type.") ;
                                    true
                                | _ ->
                                    error
                                      Message.(
                                        t "View" %% ct "get_balance"
                                        %% t "has not the right parameter type.") ;
                                    false) )
                          | None ->
                              error
                                Message.(
                                  t "View" %% ct "get_balance"
                                  %% t "has no parameter type.") ;
                              false in
                        let result_ok =
                          Michelson.Partial_type.(
                            match of_type impl.return_type with
                            | Leaf {kind= Nat; _} ->
                                log
                                  Message.(
                                    ct "get_balance"
                                    %% t "has the right return type.") ;
                                true
                            | _ ->
                                error
                                  Message.(
                                    t "View" %% ct "get_balance"
                                    %% t "has not the right return type.") ;
                                false) in
                        param_ok && result_ok)
                  |> function
                  | Some v -> Some ()
                  | None ->
                      error
                        Message.(
                          t "View" %% ct "get_balance"
                          %% t "has no valid Michelson implementation.") ;
                      None )
              | _ -> None)
            |> function
            | Some _ ->
                success
                  Message.(t "View" %% ct "get_balance" %% t "seems valid.")
            | None ->
                error
                  Message.(t "View" %% ct "get_balance" %% t "seems invalid.")
          in
          () in
        ignore views_validation ;
        found (Tzip_12 {metadata; interface_claim; logs= List.rev !logs}) in
    let exception Found of classified in
    fun metadata ->
      try
        looks_like_tzip_12 ~found:(fun x -> raise (Found x)) metadata ;
        Tzip_16 metadata
      with Found x -> x
end
