type observation =
  { quota_name : string
  ; limit_gb : int
  ; used_gb : int
  }

val governing_quota : string
val free_gb : observation -> int
val observation_of_json : ?quota:string -> string -> (observation, string) result
val describe : observation -> string
val sufficient : observation:observation -> required_gb:int -> (unit, string) result
