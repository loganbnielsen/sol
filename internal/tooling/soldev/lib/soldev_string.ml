let contains_substring ~needle haystack =
  let nlen = String.length needle
  and hlen = String.length haystack in
  let rec go i =
    if i + nlen > hlen
    then false
    else if String.equal (String.sub haystack i nlen) needle
    then true
    else go (i + 1)
  in
  go 0
;;
