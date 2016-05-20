(** Build system. *)
open Printf
let failwithf fmt = ksprintf (fun s () -> failwith s) fmt

(* This is necessary to query findlib *)
let () = Findlib.init ()

module String = struct
  include String
  let hash = Hashtbl.hash
  let equal = ( = )
end

module List = struct
  include List
  include ListLabels
end

module Digraph = struct
  module G = Graph.Persistent.Digraph.Concrete(String)
  include G

  module Dfs = Graph.Traverse.Dfs(G)
  module Topological = Graph.Topological.Make(G)
end

module Info = struct
  type name = [`Lib of string | `App of string]
  type condition = [
    | `Pkgs_installed
  ]
  type item = {
    name : name ;
    libs : string list ;
    pkgs : string list ;
    build_if : condition list ;
  }
  type t = item list

  let is_lib item = match item.name with `Lib _ -> true | `App _ -> false
  let is_app item = match item.name with `Lib _ -> false | `App _ -> true

  let names t = List.map t ~f:(fun x -> match x.name with `Lib s | `App s -> s)
  let name_as_string = function `Lib x | `App x -> x

  let is_uniq (l : string list) : bool =
    let m = List.length l in
    let n = List.length (List.sort_uniq ~cmp:compare l) in
    m = n

  let libs t = List.filter ~f:is_lib t
  let apps t = List.filter ~f:is_app t

  let get t name =
    try List.find t ~f:(fun x -> x.name = name)
    with Not_found -> failwith ("Unknown library " ^ (name_as_string name))

  let findlib_packages =
    Fl_package_base.list_packages ()

  let rec should_build items i =
    List.for_all i.build_if ~f:(function
        | `Pkgs_installed ->
          List.for_all i.pkgs ~f:(List.mem ~set:findlib_packages)
      )
    &&
    List.for_all i.libs ~f:(fun lib ->
        should_build items (get items (`Lib lib))
      )

  let dependance_graph items =
    List.fold_left items ~init:Digraph.empty ~f:(fun accu item ->
        match item.name with
        | `App _ -> accu
        | `Lib lib ->
          accu
          |> fun g -> Digraph.add_vertex g lib
          |> fun g -> List.fold_left item.libs ~init:g ~f:(fun accu dep ->
                          Digraph.add_edge accu lib dep
                        )
      )

  let lib_dependance_graph items =
    List.filter items ~f:(function
        | { name = `App _ } -> false
        | { name = `Lib _ } -> true
      )
    |> dependance_graph

  let of_list items =
    let libs = names (libs items) in
    let apps = names (apps items) in
    if not (is_uniq libs) then
      failwith "lib names must be unique"
    else if not (is_uniq apps) then
      failwith "app names must be unique"
    else if Digraph.Dfs.has_cycle (lib_dependance_graph items) then
      failwith "Cycle detected in Info.t"
    else
      items

  let libs_direct t name = (get t name).libs

  let rec libs_all t name =
    let item = get t name in
    item.libs
    @(
      List.map item.libs ~f:(fun x -> libs_all t (`Lib x))
      |> List.flatten
    )
    |> List.sort_uniq ~cmp:compare

  let pkgs_direct t name = (get t name).pkgs

  let rec pkgs_all t name =
    let item = get t name in
    item.pkgs
    @(
      List.map item.libs ~f:(fun x -> pkgs_all t (`Lib x))
      |> List.flatten
    )
    |> List.sort_uniq ~cmp:compare

end

module type PROJECT = sig
  val name : string
  val version : string
  val info : Info.t
  val ocamlinit_postfix : string list
end

module Make(Project:PROJECT) : sig
  val modules_of_dir : string -> string list
  val plugin : Ocamlbuild_plugin.hook -> unit
  val dispatch : unit -> unit
end = struct
  open Ocamlbuild_plugin

  (* override the one from Ocamlbuild_plugin *)
  module List = struct
    include List
    include ListLabels
  end

  let readdir dir : string list =
    match Sys.file_exists dir && Sys.is_directory dir with
    | false -> []
    | true -> (Sys.readdir dir |> Array.to_list)

  let all_pkgs : string list =
    List.map (Project.info :> Info.item list) ~f:(fun x -> x.Info.pkgs)
    |> List.flatten
    |> List.sort_uniq ~cmp:compare

  let list_diff big small =
    List.filter big ~f:(fun x -> not (List.mem x small))

  let undeclared_item_check found given =
    if found <> given then (
      let unknowns = list_diff found given in
      failwithf
        "some items are mentionned but not defined: %s"
        (String.concat " " unknowns) ()
    )

  let should_build item =
    Info.get Project.info item
    |> Info.should_build Project.info

  let all_libs : string list =
    let found =
      readdir "lib"
      |> List.filter ~f:(fun x -> Sys.is_directory ("lib"/x))
      |> List.sort ~cmp:compare
    in
    let given =
      Info.libs Project.info
      |> Info.names
      |> List.sort ~cmp:compare
    in
    undeclared_item_check found given ;
    given

  let all_libs_to_build =
    List.filter all_libs ~f:(fun lib ->
        should_build (`Lib lib)
      )

  let topologically_sorted_libs =
    Digraph.Topological.fold (fun h t -> h :: t) (Info.lib_dependance_graph Project.info) []

  let all_apps : string list =
    let found =
      readdir "app"
      |> List.map ~f:Filename.chop_extension
      |> List.sort ~cmp:compare
    in
    let given =
      Info.apps Project.info
      |> Info.names
      |> List.sort ~cmp:compare
    in
    undeclared_item_check found given ;
    given

  let all_apps_to_build =
    List.filter all_apps ~f:(fun app ->
        should_build (`App app)
      )


  let modules_of_file filename : string list =
    List.fold_left [".ml"; ".mli"; ".ml.m4"; ".mll"; ".mly"; ".atd"]
      ~init:[] ~f:(fun accum suffix ->
        let new_items = match suffix with
          | ".atd" -> (
            if Filename.check_suffix filename suffix then (
              Filename.chop_suffix filename suffix
              |> fun x -> [x^"_j"; x^"_t"]
            )
            else
              []
          )
          | _ -> (
            if Filename.check_suffix filename suffix then
              [Filename.chop_suffix filename suffix]
            else
              []
          )
        in
        new_items@accum
      )

  let modules_of_dir dir : string list =
    readdir dir
    |> List.map ~f:modules_of_file
    |> List.concat
    |> List.sort_uniq ~cmp:compare
    |> List.map ~f:String.capitalize

  (* returns names of C files in a dir (without their .c
     extension!) *)
  let c_units_of_dir dir : string list =
    readdir dir
    |> List.filter ~f:(fun p -> Filename.check_suffix p ".c")
    |> List.map ~f:Filename.chop_extension

  let h_files_of_dir dir : string list =
    readdir dir
    |> List.filter ~f:(fun p -> Filename.check_suffix p ".h")

  let git_commit =
    if Sys.file_exists ".git" then
      sprintf "Some \"%s\""
        (
          Ocamlbuild_pack.My_unix.run_and_read "git rev-parse HEAD"
          |> fun x -> String.sub x 0 (String.length x - 1)
        )
    else
      "None"

  let tags_lines : string list =
    [
      "true: thread, bin_annot, annot, short_paths, safe_string, debug";
      "true: warn(A-4-33-41-42-44-45-48)";
      "true: use_menhir";
      "\"lib\": include";
    ]
    (* === for-pack tags *)
    @(
      List.map all_libs_to_build ~f:(fun x ->
          sprintf
            "<lib/%s/*.cmx>: for-pack(%s_%s)"
            x (String.capitalize Project.name) x )
    )
    (* === use_foo for libs *)
    @(
      let libs = (Info.libs Project.info :> Info.item list) in
      List.map libs ~f:(fun lib ->
          lib.Info.name, Info.libs_direct Project.info lib.Info.name
        )
      |> List.filter ~f:(function (_,[]) -> false | (_,_) -> true)
      |> List.map ~f:(fun (name,libs) ->
          sprintf "<lib/%s/*>: %s"
            (Info.name_as_string name)
            (String.concat ", " (List.map libs ~f:(sprintf "use_%s_%s" Project.name)))
        )
    )
    (* === use_foo_stub tags for cm{a,xa,xs} *)
    @(
      all_libs_to_build
      |> List.filter ~f:(fun lib ->
          c_units_of_dir ("lib"/lib) <> []
        )
      |> List.map ~f:(fun x ->
          sprintf "<lib/%s_%s.{cma,cmxa,cmxs}>: use_%s_%s_stub"
            Project.name x Project.name x
        )
    )
    (* === package tags for libs *)
    @(
      let libs = (Info.libs Project.info :> Info.item list) in
      List.map libs ~f:(fun lib ->
          lib.Info.name, Info.pkgs_all Project.info lib.Info.name
        )
      |> List.filter ~f:(function (_,[]) -> false | (_,_) -> true)
      |> List.map ~f:(fun (name,pkgs) ->
          sprintf "<lib/%s/*>: %s"
            (Info.name_as_string name)
            (String.concat ", " (List.map pkgs ~f:(sprintf "package(%s)")))
        )
    )
    (* === use_foo for apps *)
    @(
      let apps = (Info.apps Project.info :> Info.item list) in
      List.map apps ~f:(fun app ->
          app.Info.name, Info.libs_direct Project.info app.Info.name )
      |> List.filter ~f:(function (_,[]) -> false | (_,_) -> true)
      |> List.map ~f:(fun (name,libs) ->
          sprintf "<app/%s.*>: %s"
            (Info.name_as_string name)
            (String.concat ", " (List.map libs ~f:(sprintf "use_%s_%s" Project.name)))
        )
    )
    (* === package tags for apps *)
    @(
      let apps = (Info.apps Project.info :> Info.item list) in
      List.map apps ~f:(fun app ->
          app.Info.name, Info.pkgs_all Project.info app.Info.name )
      |> List.filter ~f:(function (_,[]) -> false | (_,_) -> true)
      |> List.map ~f:(fun (name,pkgs) ->
          sprintf "<app/%s.*>: %s"
            (Info.name_as_string name)
            (String.concat "," (List.map pkgs ~f:(sprintf "package(%s)")))
        )
    )
    (* === use_foo_stub for apps *)
    @(
      let apps = (Info.apps Project.info :> Info.item list) in
      List.map apps ~f:(fun app ->
          app.Info.name, Info.libs_all Project.info app.Info.name )
      |> List.filter ~f:(function (_,[]) -> false | (_,_) -> true)
      |> List.map ~f:(fun (name,libs) ->
          sprintf "<app/%s.*>: %s"
            (Info.name_as_string name)
            (String.concat
               ","
               (List.map libs ~f:(sprintf "use_%s_%s" Project.name)))
        )
    )

  let mlpack_file dir : string list =
    if not (Sys.file_exists dir && Sys.is_directory dir) then
      failwithf "cannot create mlpack file for dir %s" dir ()
    else (
      modules_of_dir dir
      |> List.map ~f:(fun x -> dir/x)
    )

  let mllib_file dir lib : string list =
    let path = dir / lib in
    if not (Sys.file_exists path && Sys.is_directory path) then
      failwithf "cannot create mllib file for dir %s" path ()
    else [ dir / String.capitalize (Project.name ^ "_" ^ lib) ]

  let clib_file dir lib =
    let path = dir / lib in
    match c_units_of_dir path with
    | [] -> None
    | xs ->
      Some (List.map xs ~f:(fun x -> lib ^ "/" ^ x ^ ".o"))

  let merlin_file : string list =
    [
      "S ./lib/**";
      "S ./app/**";
      "B ./_build/lib";
      "B ./_build/lib/**";
      "B ./_build/app/**";
      "B +threads";
      "PKG solvuu_build";
    ]
    @(
      List.map all_pkgs ~f:(fun x -> sprintf "PKG %s" x)
    )

  let meta_file : string list =
    List.map all_libs_to_build ~f:(fun x ->
        let lib_name = sprintf "%s_%s" Project.name x in
        let requires : string list =
          (Info.pkgs_all Project.info (`Lib x))
          @(List.map
              (Info.libs_direct Project.info (`Lib x))
              ~f:(sprintf "%s.%s" Project.name)
           )
        in
        [
          sprintf "package \"%s\" (" x;
          sprintf "  directory = \"%s\"" x;
          sprintf "  version = \"%s\"" Project.version;
          sprintf "  archive(byte) = \"%s.cma\"" lib_name;
          sprintf "  archive(native) = \"%s.cmxa\"" lib_name;
          sprintf "  requires = \"%s\"" (String.concat " " requires);
          sprintf "  exists_if = \"%s.cma\"" lib_name;
          sprintf ")";
        ]
      )
    |> List.flatten
    |> List.filter ~f:((<>) "")

  let install_file : string list =
    let suffixes = [
      "a";"annot";"cma";"cmi";"cmo";"cmt";"cmti";"cmx";"cmxa";
      "cmxs";"dll";"o"]
    in
    (
      List.map all_libs_to_build ~f:(fun lib ->
          List.map suffixes ~f:(fun suffix ->
              sprintf "  \"?_build/lib/%s_%s.%s\" { \"%s/%s_%s.%s\" }"
                Project.name lib suffix
                lib Project.name lib suffix
            )
        )
      |> List.flatten
      |> fun l -> "  \"_build/META\""::l
                  |> fun l -> ["lib: ["]@l@["]"]
    )
    @(
      let lines =
        List.map all_libs_to_build ~f:(fun lib ->
            sprintf "  \"?_build/lib/dll%s_%s_stub.so\"" Project.name lib
          )
      in
      "stublibs: [" :: lines @ ["]"]
    )
    @(
      List.map all_apps_to_build ~f:(fun app ->
          List.map ["byte"; "native"] ~f:(fun suffix ->
              sprintf "  \"?_build/app/%s.%s\" {\"%s\"}" app suffix app
            )
        )
      |> List.flatten
      |> function
      | [] -> []
      | l -> ["bin: ["]@l@["]"]
    )

  let ocamlinit_file =
    [
      "let () =" ;
      "  try Topdirs.dir_directory (Sys.getenv \"OCAML_TOPLEVEL_PATH\")" ;
      "  with Not_found -> ()" ;
      ";;" ;
      "" ;
      "#use \"topfind\";;" ;
      "#thread;;" ;
      sprintf "#require \"%s\";;" (String.concat " " all_pkgs) ;
      "" ;
      "(* Load each lib provided by this project. *)" ;
      "#directory \"_build/lib\";;" ;
    ]
    @(List.map topologically_sorted_libs ~f:(fun lib ->
        sprintf "#load \"%s_%s.cma\";;" Project.name lib
      )
     )
    @ [
      "" ;
      "open Core.Std;;" ;
      "open Async.Std;;"
    ]
    @ Project.ocamlinit_postfix

  let makefile_rules_file : string list =
    let map_name xs = List.map xs ~f:(sprintf "%s_%s" Project.name) in
    let native =
      List.concat [
        map_name all_libs_to_build |> List.map ~f:(sprintf "lib/%s.cmxa") ;
        map_name all_libs_to_build |> List.map ~f:(sprintf "lib/%s.cmxs") ;
        List.map all_apps_to_build ~f:(sprintf "app/%s.native") ;
      ]
      |> String.concat " "
      |> sprintf "native: %s"
    in
    let byte =
      List.concat [
        map_name all_libs_to_build |> List.map ~f:(sprintf "lib/%s.cma") ;
        List.map all_apps_to_build ~f:(sprintf "app/%s.byte") ;
      ]
      |> String.concat " "
      |> sprintf "byte: %s"
    in
    let static = [
      "default: byte project_files.stamp";

      "%.cma %.cmxa %.cmxs %.native %.byte lib/%.mlpack:";
      "\t$(OCAMLBUILD) $@";

      "project_files.stamp META:";
      "\t$(OCAMLBUILD) $@";

      sprintf ".merlin %s.install .ocamlinit:" Project.name;
      "\t$(OCAMLBUILD) $@ && ln -s _build/$@ $@";

      "clean:";
      "\t$(OCAMLBUILD) -clean";

      ".PHONY: default native byte clean";
    ]
    in
    static@[native ; byte]

  let make_static_file path contents =
    let contents = List.map contents ~f:(sprintf "%s\n") in
    rule path ~prod:path (fun _ _ ->
        Seq [
          Cmd (Sh (sprintf "mkdir -p %s" (Filename.dirname path)));
          Echo (contents,path);
        ]
      )

  let plugin = function
    | Before_options -> (
        Options.use_ocamlfind := true;
        List.iter tags_lines ~f:Ocamlbuild_pack.Configuration.parse_string
      )
    | After_rules -> (
        rule "m4: ml.m4 -> ml"
          ~prod:"%.ml"
          ~dep:"%.ml.m4"
          (fun env _ ->
             let ml_m4 = env "%.ml.m4" in
             Cmd (S [
                 A "m4";
                 A "-D"; A ("VERSION=" ^ Project.version);
                 A "-D"; A ("GIT_COMMIT=" ^ git_commit);
                 P ml_m4;
                 Sh ">";
                 P (env "%.ml");
               ]) )
        ;

        rule "atd: .atd -> _t.ml, _t.mli"
          ~dep:"%.atd"
          ~prods:["%_t.ml"; "%_t.mli"]
          (fun env _ ->
             Cmd (S [A "atdgen"; A "-t"; A "-j-std"; P (env "%.atd")])
          )
        ;

        rule "atd: .atd -> _j.ml, _j.mli"
          ~dep:"%.atd"
          ~prods:["%_j.ml"; "%_j.mli"]
          (fun env _ ->
             Cmd (S [A "atdgen"; A "-j"; A "-j-std"; P (env "%.atd")])
          )
        ;

        List.iter all_libs_to_build ~f:(fun lib ->
            make_static_file
              (sprintf "lib/%s_%s.mlpack" Project.name lib)
              (mlpack_file ("lib"/lib))
          );

        List.iter all_libs_to_build ~f:(fun lib ->
            make_static_file
              (sprintf "lib/%s_%s.mllib" Project.name lib)
              (mllib_file "lib" lib)
          );

        List.iter all_libs_to_build ~f:(fun lib ->
            let lib_name = sprintf "%s_%s" Project.name lib in
            let lib_tag = sprintf "use_%s_%s" Project.name lib in
            flag ["link";"ocaml";lib_tag] (S[A"-I"; P "lib"]);
            ocaml_lib ~tag_name:lib_tag ~dir:"lib" ("lib/" ^ lib_name) ;
            dep ["ocaml";"byte";lib_tag] [sprintf "lib/%s.cma" lib_name] ;
            dep ["ocaml";"native";lib_tag] [sprintf "lib/%s.cmxa" lib_name]
          );

        List.iter all_libs_to_build ~f:(fun lib ->
            match clib_file "lib" lib with
            | None -> ()
            | Some file ->
              let cstub = sprintf "%s_%s_stub" Project.name lib in
              let stub_tag = "use_"^cstub in
              let headers =
                h_files_of_dir ("lib"/lib)
                |> List.map ~f:(fun x -> "lib"/lib/x)
              in
              dep ["c" ; "compile"] headers ;
              dep ["link";"ocaml";stub_tag] [
                sprintf "lib/lib%s.a" cstub ;
              ] ;
              flag
                ["link";"ocaml";"byte";stub_tag]
                (S[A"-dllib";A("-l"^cstub);A"-cclib";A("-l"^cstub)]) ;
              flag
                ["link";"ocaml";"native";stub_tag]
                (S[A"-cclib";A("-l"^cstub)]) ;
              make_static_file
                (sprintf "lib/lib%s.clib" cstub)
                file
          ) ;

        make_static_file ".merlin" merlin_file;
        make_static_file "META" meta_file;
        make_static_file (sprintf "%s.install" Project.name) install_file;
        make_static_file ".ocamlinit" ocamlinit_file;
        make_static_file "Makefile.rules" makefile_rules_file ;

        rule "project files"
          ~stamp:"project_files.stamp"
          (fun _ build ->
             let project_files = [
                 [".merlin"];
                 [".ocamlinit"];
               ]
             in
             List.map (build project_files) ~f:Outcome.good
             |> List.map ~f:(fun result ->
                 Cmd (S [A "ln"; A "-sf";
                         P ((Filename.basename !Options.build_dir)/result);
                         P Pathname.pwd] )
               )
             |> fun l -> Seq l
          )
      )
    | _ -> ()

  let dispatch () = dispatch plugin

end
