let main x =
  match x with
  | 0 -> match x with
         | 0 -> 1
         |  _ -> 2
  | _ -> match x with
         | 0 -> 3
         | _ -> 4

external val bottom : 'a = "nil"
let () = bottom main
