(* The MIT License (MIT)

   Copyright (c) 2015-2018 Nicolas Ojeda Bar <n.oje.bar@gmail.com>

   Permission is hereby granted, free of charge, to any person obtaining a copy
   of this software and associated documentation files (the "Software"), to deal
   in the Software without restriction, including without limitation the rights
   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
   copies of the Software, and to permit persons to whom the Software is
   furnished to do so, subject to the following conditions:

   The above copyright notice and this permission notice shall be included in
   all copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
   SOFTWARE. *)

open Response

type buffer =
  {
    get_line: (string -> unit) -> unit;
    get_exactly: int -> (string -> unit) -> unit;
    mutable line: string;
    mutable pos: int;
  }

let some x = Some x

type 'a t =
  buffer -> (('a, string * int) result -> unit) -> unit

let return x _ k =
  k (Ok x)

let ( *> ) p q buf k =
  p buf (function
      | Ok () ->
          q buf k
      | Error _ as e ->
          k e
    )

let ( <* ) p q buf k =
  p buf (function
      | Ok _ as o ->
          q buf (function
              | Ok () ->
                  k o
              | Error _ as e ->
                  k e
            )
      | Error _ as e ->
          k e
    )

let ( <$> ) f p buf k =
  p buf (function
      | Ok x ->
          k (Ok (f x))
      | Error _ as e ->
          k e
    )

let ( >>= ) p f buf k =
  p buf (function
      | Ok x ->
          f x buf k
      | Error _ as e ->
          k e
    )

let ( >|= ) p f buf k =
  p buf (function
      | Ok x ->
          k (Ok (f x))
      | Error _ as e ->
          k e
    )

let error buf k =
  k (Error (buf.line, buf.pos))

let is_eol buf k =
  k (Ok (buf.pos >= String.length buf.line))

let eol =
  is_eol >>= function
  | true -> return ()
  | false -> error

let curr buf k =
  if buf.pos >= String.length buf.line then
    k (Ok '\000')
  else
    k (Ok buf.line.[buf.pos])

let next buf k =
  assert (buf.pos < String.length buf.line);
  buf.pos <- buf.pos + 1;
  k (Ok ())

let take n buf k =
  if buf.pos + n > String.length buf.line then
    (buf.pos <- String.length buf.line; error buf k);
  let s = String.sub buf.line buf.pos n in
  buf.pos <- buf.pos + n;
  k (Ok s)

let char c =
  curr >>= fun c1 -> if c1 = c then next else error

let take_while1 f buf k =
  let pos0 = buf.pos in
  let pos = ref pos0 in
  while !pos < String.length buf.line && f buf.line.[!pos] do
    incr pos
  done;
  if pos0 = !pos then
    error buf k
  else begin
    buf.pos <- !pos;
    k (Ok (String.sub buf.line pos0 (!pos - pos0)))
  end

(*
   CHAR           =  %x01-7F
                          ; any 7-bit US-ASCII character,
                            excluding NUL

   CTL            =  %x00-1F / %x7F
                          ; controls

   ATOM-CHAR       = <any CHAR except atom-specials>

   atom-specials   = "(" / ")" / "{" / SP / CTL / list-wildcards /
                     quoted-specials / resp-specials

   quoted-specials = DQUOTE / "\\"

   resp-specials   = "]"

   list-wildcards  = "%" / "*"

   atom            = 1*ATOM-CHAR
*)

let is_atom_char = function
  | '(' | ')' | '{' | ' '
  | '\x00' .. '\x1F' | '\x7F'
  | '%' | '*' | '"' | '\\' | ']' -> false
  | '\x01' .. '\x7F' -> true
  | _ -> false

let atom =
  take_while1 is_atom_char

let cmd =
  take_while1 @@ function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' -> true
    | _ -> false


(*
   quoted          = DQUOTE *QUOTED-CHAR DQUOTE

   QUOTED-CHAR     = <any TEXT-CHAR except quoted-specials> /
                     '\\' quoted-specials
*)

let quoted_char =
  curr >>= function
  | '\\' ->
      next *> curr >>= begin function
      | '\\' | '"' as c ->
          next *> return c
      | _ ->
          error
      end
  | '"' ->
      error
  | '\x01'..'\x7f' as c ->
      next *> return c
  | _ ->
      error

let quoted =
  let rec loop b =
    curr >>= function
    | '"' ->
        next *> return (Buffer.contents b)
    | _ ->
        quoted_char >>= fun c -> Buffer.add_char b c; loop b
  in
  char '"' >>= fun () -> loop (Buffer.create 17)

(*
   number          = 1*DIGIT
                       ; Unsigned 32-bit integer
                       ; (0 <= n < 4,294,967,296)

   nz-number       = digit-nz *DIGIT
                       ; Non-zero unsigned 32-bit integer
                       ; (0 < n < 4,294,967,296)

   uniqueid        = nz-number
                       ; Strictly ascending
*)

let is_digit = function
  | '0'..'9' -> true
  | _ -> false

let number =
  let f s = Scanf.sscanf s "%lu" (fun n -> n) in
  f <$> take_while1 is_digit

let nz_number =
  number

let uniqueid =
  number

(*
   literal         = "{" number "}" CRLF *CHAR8
                       ; Number represents the number of CHAR8s

   string          = quoted / literal
*)

let get_exactly n buf k =
  buf.get_exactly n (fun s -> k (Ok s))

let get_line buf k =
  buf.get_line (fun s -> buf.line <- s; buf.pos <- 0; k (Ok ()))

let literal =
  char '{' *> number >>= fun n ->
  char '}' *> eol *> get_exactly (Int32.to_int n) >>= fun s ->
  get_line *> return s

let imap_string =
  curr >>= function
  | '"' ->
      quoted
  | '{' ->
      literal
  | _ ->
      error

(*
   ASTRING-CHAR   = ATOM-CHAR / resp-specials

   astring         = 1*ASTRING-CHAR / string
*)

let is_astring_char c =
  is_atom_char c || c = ']'

let astring =
  curr >>= function
  | '"' | '{' ->
      imap_string
  | _ ->
      take_while1 is_astring_char

(*
   nil             = "NIL"

   nstring         = string / nil
*)

let nstring =
  curr >>= function
  | '"' | '{' ->
      imap_string
  | _ ->
      char 'N' *> char 'I' *> char 'L' *> return ""

let lift_nstring s = if s = "" then None else Some s

(*
   TEXT-CHAR       = <any CHAR except CR and LF>

   text            = 1*TEXT-CHAR
*)

let is_text_char = function
  | '\r' | '\n' -> false
  | '\x01' .. '\x7F' -> true
  | _ -> false

let text =
  is_eol >>= function
  | true ->
      return ""
  | false ->
      take_while1 is_text_char

let is_text_other_char = function
  | ']' -> false
  | c -> is_text_char c

let text_1 =
  is_eol >>= function
  | true ->
      return ""
  | false ->
      take_while1 is_text_other_char

(*
   mbx-list-sflag  = "\Noselect" / "\Marked" / "\Unmarked"
                       ; Selectability flags; only one per LIST response

   mbx-list-oflag  = "\Noinferiors" / flag-extension
                       ; Other flags; multiple possible per LIST response

   mbx-list-flags  = *(mbx-list-oflag SP) mbx-list-sflag
                     *(SP mbx-list-oflag) /
                     mbx-list-oflag *(SP mbx-list-oflag)

   HasChildren = "\HasChildren"

   HasNoChildren = "\HasNoChildren"

   mbx-list-oflag =/  use-attr
                    ; Extends "mbx-list-oflag" from IMAP base [RFC3501]

   use-attr        =  "\All" / "\Archive" / "\Drafts" / "\Flagged" /
                      "\Junk" / "\Sent" / "\Trash" / use-attr-ext

   use-attr-ext    =  '\\' atom
                       ; Reserved for future extensions.  Clients
                       ; MUST ignore list attributes they do not understand
                       ; Server implementations MUST NOT generate
                       ; extension attributes except as defined by
                       ; future Standards-Track revisions of or
                       ; extensions to this specification.
*)

let mbx_flag =
  let open MailboxFlag in
  char '\\' *> atom >|= begin fun a ->
    match String.lowercase_ascii a with
    | "noselect" -> Noselect
    | "marked" -> Marked
    | "unmarked" -> Unmarked
    | "noinferiors" -> Noinferiors
    | "haschildren" -> HasChildren
    | "hasnochildren" -> HasNoChildren
    | "all" -> All
    | "archive" -> Archive
    | "drafts" -> Drafts
    | "flagged" -> Flagged
    | "junk" -> Junk
    | "sent" -> Sent
    | "trash" -> Trash
    | _ -> Extension a
  end

let delim =
  curr >>= function
  | '"' ->
      some <$> (char '"' *> quoted_char <* char '"')
  | _ ->
      char 'N' *> char 'I' *> char 'L' *> return None

(*
   mailbox         = "INBOX" / astring
                       ; INBOX is case-insensitive.  All case variants of
                       ; INBOX (e.g., "iNbOx") MUST be interpreted as INBOX
                       ; not as an astring.  An astring which consists of
                       ; the case-insensitive sequence "I" "N" "B" "O" "X"
                       ; is considered to be INBOX and not an astring.
                       ;  Refer to section 5.1 for further
                       ; semantic details of mailbox names.
*)

let is_inbox s =
  String.length s = String.length "INBOX" &&
  String.uppercase_ascii s = "INBOX"

let mailbox =
  astring >|= fun s -> if is_inbox s then "INBOX" else s

(*
   mailbox-list    = "(" [mbx-list-flags] ")" SP
                      (DQUOTE QUOTED-CHAR DQUOTE / nil) SP mailbox
*)

let plist p =
  char '(' *> curr >>= function
  | ')' ->
      next *> return []
  | _ ->
      let rec loop acc =
        curr >>= function
        | ' ' ->
            next *> p >>= fun x -> loop (x :: acc)
        | ')' ->
            next *> return (List.rev acc)
        | _ ->
            error
      in
      p >>= fun x -> loop [x]

let mailbox_list =
  plist mbx_flag >>= fun flags ->
  char ' ' *> delim >>= fun delim ->
  char ' ' *> mailbox >>= fun mbox ->
  return (flags, delim, mbox)

(*
   auth-type       = atom
                       ; Defined by [SASL]

   capability      = ("AUTH=" auth-type) / atom
                       ; New capabilities MUST begin with "X" or be
                       ; registered with IANA as standard or
                       ; standards-track
*)

let capability =
  let open Capability in
  atom >|= function
  | "COMPRESS=DEFLATE" -> COMPRESS_DEFLATE
  | "CONDSTORE" -> CONDSTORE
  | "ESEARCH" -> ESEARCH
  | "ENABLE" -> ENABLE
  | "IDLE" -> IDLE
  | "LITERAL+" -> LITERALPLUS
  | "LITERAL-" -> LITERALMINUS
  | "UTF8=ACCEPT" -> UTF8_ACCEPT
  | "UTF8=ONLY" -> UTF8_ONLY
  | "NAMESPACE" -> NAMESPACE
  | "ID" -> ID
  | "QRESYNC" -> QRESYNC
  | "UIDPLUS" -> UIDPLUS
  | "UNSELECT" -> UNSELECT
  | "XLIST" -> XLIST
  | "AUTH=PLAIN" -> AUTH_PLAIN
  | "AUTH=LOGIN" -> AUTH_LOGIN
  | "XOAUTH2" -> XOAUTH2
  | "X-GM-EXT-1"  -> X_GM_EXT_1
  | a -> OTHER a

(*
   seq-number      = nz-number / "*"
                       ; message sequence number (COPY, FETCH, STORE
                       ; commands) or unique identifier (UID COPY,
                       ; UID FETCH, UID STORE commands).
                       ; * represents the largest number in use.  In
                       ; the case of message sequence numbers, it is
                       ; the number of messages in a non-empty mailbox.
                       ; In the case of unique identifiers, it is the
                       ; unique identifier of the last message in the
                       ; mailbox or, if the mailbox is empty, the
                       ; mailbox's current UIDNEXT value.
                       ; The server should respond with a tagged BAD
                       ; response to a command that uses a message
                       ; sequence number greater than the number of
                       ; messages in the selected mailbox.  This
                       ; includes "*" if the selected mailbox is empty.

   seq-range       = seq-number ":" seq-number
                       ; two seq-number values and all values between
                       ; these two regardless of order.
                       ; Example: 2:4 and 4:2 are equivalent and indicate
                       ; values 2, 3, and 4.
                       ; Example: a unique identifier sequence range of
                       ; 3291:* includes the UID of the last message in
                       ; the mailbox, even if that value is less than 3291.

   sequence-set    = (seq-number / seq-range) *("," sequence-set)
                       ; set of seq-number values, regardless of order.
                       ; Servers MAY coalesce overlaps and/or execute the
                       ; sequence in any order.
                       ; Example: a message sequence number set of
                       ; 2,4:7,9,12:* for a mailbox with 15 messages is
                       ; equivalent to 2,4,5,6,7,9,12,13,14,15
                       ; Example: a message sequence number set of *:4,5:7
                       ; for a mailbox with 10 messages is equivalent to
                       ; 10,9,8,7,6,5,4,5,6,7 and MAY be reordered and
                       ; overlap coalesced to be 4,5,6,7,8,9,10.

   uid-set         = (uniqueid / uid-range) *("," uid-set)

   uid-range       = (uniqueid ":" uniqueid)
                     ; two uniqueid values and all values
                     ; between these two regards of order.
                     ; Example: 2:4 and 4:2 are equivalent.
*)

let mod_sequence_value =
  let f s = Scanf.sscanf s "%Lu" (fun n -> n) in
  f <$> take_while1 is_digit

let uid_range =
  uniqueid >>= fun n -> curr >>= function
  | ':' ->
      next *> uniqueid >|= fun m -> (n, m)
  | _ ->
      return (n, n)

let uid_set =
  let rec loop acc =
    curr >>= function
    | ',' ->
        next *> uid_range >>= fun r -> loop (r :: acc)
    | _ ->
        return (List.rev acc)
  in
  uid_range >>= fun r -> loop [r]

let sequence_set =
  uid_set

let set =
  sequence_set

(*
   flag-extension  = "\\" atom
                       ; Future expansion.  Client implementations
                       ; MUST accept flag-extension flags.  Server
                       ; implementations MUST NOT generate
                       ; flag-extension flags except as defined by
                       ; future standard or standards-track
                       ; revisions of this specification.

   flag-keyword    = atom

   flag            = "\Answered" / "\Flagged" / "\Deleted" /
                     "\Seen" / "\Draft" / flag-keyword / flag-extension
                       ; Does not include "\Recent"

   flag-perm       = flag / "\*"

   flag-fetch      = flag / "\Recent"
*)

let flag_gen recent any =
  let open Flag in
  curr >>= function
  | '\\' ->
      next *> curr >>= begin function
      | '*' when any ->
          next *> return Any
      | _ ->
          atom >|= begin fun a ->
            match String.lowercase_ascii a with
            | "recent" when recent -> Recent
            | "answered" -> Answered
            | "flagged" -> Flagged
            | "deleted" -> Deleted
            | "seen" -> Seen
            | "draft" -> Draft
            | _ -> Extension a
          end
      end
  | _ ->
      atom >|= fun a -> Keyword a

let flag =
  flag_gen false false

let flag_fetch =
  flag_gen true false

let flag_perm =
  flag_gen false true

(*
   capability-data = "CAPABILITY" *(SP capability) SP "IMAP4rev1"
                     *(SP capability)
                       ; Servers MUST implement the STARTTLS, AUTH=PLAIN,
                       ; and LOGINDISABLED capabilities
                       ; Servers which offer RFC 1730 compatibility MUST
                       ; list "IMAP4" as the first capability.

   resp-text-code  = "ALERT" /
                     "BADCHARSET" [SP "(" astring *(SP astring) ")" ] /
                     capability-data / "PARSE" /
                     "PERMANENTFLAGS" SP "("
                     [flag-perm *(SP flag-perm)] ")" /
                     "READ-ONLY" / "READ-WRITE" / "TRYCREATE" /
                     "UIDNEXT" SP nz-number / "UIDVALIDITY" SP nz-number /
                     "UNSEEN" SP nz-number /
                     atom [SP 1*<any TEXT-CHAR except "]">]

   resp-text-code      =/ "HIGHESTMODSEQ" SP mod-sequence-value /
                          "NOMODSEQ" /
                          "MODIFIED" SP set

   resp-text-code      =/ "CLOSED"

   append-uid      = uniqueid

   resp-code-apnd  = "APPENDUID" SP nz-number SP append-uid

   resp-code-copy  = "COPYUID" SP nz-number SP uid-set SP uid-set

   resp-text-code  =/ resp-code-apnd / resp-code-copy / "UIDNOTSTICKY"
                     ; incorporated before the expansion rule of
                     ;  atom [SP 1*<any TEXT-CHAR except "]">]
                     ; that appears in [IMAP]

   resp-text-code =/ "COMPRESSIONACTIVE"


   resp-text-code =/  "USEATTR"
                    ; Extends "resp-text-code" from
                    ; IMAP [RFC3501]
*)

let append_uid =
  uniqueid

let slist p =
  let rec loop acc =
    curr >>= function
    | ' ' ->
        next *> p >>= fun x -> loop (x :: acc)
    | _ ->
        return (List.rev acc)
  in
  loop []

let resp_text_code =
  let open Code in
  char '[' *> atom >>= begin function
  | "ALERT" ->
      return ALERT
  | "BADCHARSET" ->
      curr >>= begin function
      | ' ' ->
          next *> plist astring >|= fun l -> BADCHARSET l
      | _ ->
          return (BADCHARSET [])
      end
  | "CAPABILITY" ->
      slist capability >|= fun l -> CAPABILITY l
  | "PARSE" ->
      return PARSE
  | "PERMANENTFLAGS" ->
      char ' ' *> plist flag_perm >|= fun l -> PERMANENTFLAGS l
  | "READ-ONLY" ->
      return READ_ONLY
  | "READ-WRITE" ->
      return READ_WRITE
  | "TRYCREATE" ->
      return TRYCREATE
  | "UIDNEXT" ->
      char ' ' *> nz_number >|= fun n -> UIDNEXT n
  | "UIDVALIDITY" ->
      char ' ' *> nz_number >|= fun n -> UIDVALIDITY n
  | "UNSEEN" ->
      char ' ' *> nz_number >|= fun n -> UNSEEN n
  | "CLOSED" ->
      return CLOSED
  | "HIGHESTMODSEQ" ->
      char ' ' *> mod_sequence_value >|= fun n -> HIGHESTMODSEQ n
  | "NOMODSEQ" ->
      return NOMODSEQ
  | "MODIFIED" ->
      char ' ' *> set >|= fun set -> MODIFIED set
  | "APPENDUID" ->
      char ' ' *> nz_number >>= fun n ->
      char ' ' *> append_uid >|= fun uid -> APPENDUID (n, uid)
  | "COPYUID" ->
      char ' ' *> nz_number >>= fun n ->
      char ' ' *> set >>= fun s1 ->
      char ' ' *> set >|= fun s2 ->
      COPYUID (n, s1, s2)
  | "UIDNOTSTICKY" ->
      return UIDNOTSTICKY
  | "COMPRESSIONACTIVE" ->
      return COMPRESSIONACTIVE
  | "USEATTR" ->
      return USEATTR
  | a ->
      curr >>= begin function
      | ' ' ->
          text_1 >|= fun x -> OTHER (a, Some x)
      | _ ->
          return (OTHER (a, None))
      end
  end <* char ']'

(*
   resp-text       = ["[" resp-text-code "]" SP] text
*)

let resp_text =
  curr >>= begin function ' ' -> next | _ -> return () end >>= fun () ->
  curr >>= begin function '[' -> resp_text_code | _ -> return Response.Code.NONE end >>= fun c ->
  curr >>= begin function ' ' -> next | _ -> return () end >>= fun () ->
  text >|= fun t -> (c, t)

let search_sort_mod_seq =
  char '(' *> atom >>= begin function
  | "MODSEQ" ->
      char ' ' *> mod_sequence_value
  | _ ->
      error
  end <* char ')'

(*
   address         = "(" addr-name SP addr-adl SP addr-mailbox SP
                     addr-host ")"

   addr-adl        = nstring
                       ; Holds route from [RFC-2822] route-addr if
                       ; non-NIL

   addr-host       = nstring
                       ; NIL indicates [RFC-2822] group syntax.
                       ; Otherwise, holds [RFC-2822] domain name

   addr-mailbox    = nstring
                       ; NIL indicates end of [RFC-2822] group; if
                       ; non-NIL and addr-host is NIL, holds
                       ; [RFC-2822] group name.
                       ; Otherwise, holds [RFC-2822] local-part
                       ; after removing [RFC-2822] quoting

   addr-name       = nstring
                       ; If non-NIL, holds phrase from [RFC-2822]
                       ; mailbox after removing [RFC-2822] quoting
*)

let address =
  char '(' *> nstring >>= fun ad_name ->
  char ' ' *> nstring >>= fun ad_adl ->
  char ' ' *> nstring >>= fun ad_mailbox ->
  char ' ' *> nstring >>= fun ad_host ->
  char ')' *> return {Envelope.Address.ad_name; ad_adl; ad_mailbox; ad_host}

(*
   envelope        = "(" env-date SP env-subject SP env-from SP
                     env-sender SP env-reply-to SP env-to SP env-cc SP
                     env-bcc SP env-in-reply-to SP env-message-id ")"

   env-bcc         = "(" 1*address ")" / nil

   env-cc          = "(" 1*address ")" / nil

   env-date        = nstring

   env-from        = "(" 1*address ")" / nil

   env-in-reply-to = nstring

   env-message-id  = nstring

   env-reply-to    = "(" 1*address ")" / nil

   env-sender      = "(" 1*address ")" / nil

   env-subject     = nstring

   env-to          = "(" 1*address ")" / nil
*)

let address_list =
  curr >>= function
  | '(' ->
      let rec loop acc =
        curr >>= function
        | ')' ->
            next *> return (List.rev acc)
        | _ ->
          address >>= fun ad -> loop (ad :: acc)
      in
      next *> loop []
  | _ ->
      char 'N' *> char 'I' *> char 'L' *> return []

let envelope =
  char '(' *> nstring >>= fun env_date ->
  char ' ' *> nstring >>= fun env_subject ->
  char ' ' *> address_list >>= fun env_from ->
  char ' ' *> address_list >>= fun env_sender ->
  char ' ' *> address_list >>= fun env_reply_to ->
  char ' ' *> address_list >>= fun env_to ->
  char ' ' *> address_list >>= fun env_cc ->
  char ' ' *> address_list >>= fun env_bcc ->
  char ' ' *> nstring >>= fun env_in_reply_to ->
  char ' ' *> nstring >>= fun env_message_id ->
  char ')' *> return {Envelope.env_date;
                      env_subject;
                      env_from;
                      env_sender;
                      env_reply_to;
                      env_to;
                      env_cc;
                      env_bcc;
                      env_in_reply_to;
                      env_message_id}


(*
   body-extension  = nstring / number /
                      "(" body-extension *(SP body-extension) ")"
                       ; Future expansion.  Client implementations
                       ; MUST accept body-extension fields.  Server
                       ; implementations MUST NOT generate
                       ; body-extension fields except as defined by
                       ; future standard or standards-track
                       ; revisions of this specification.
*)

let _body_extension =
  error

(*
   body-fld-param  = "(" string SP string *(SP string SP string) ")" / nil

   body-fld-enc    = (DQUOTE ("7BIT" / "8BIT" / "BINARY" / "BASE64"/
                     "QUOTED-PRINTABLE") DQUOTE) / string

   body-fld-id     = nstring

   body-fld-desc   = nstring

   body-fld-octets = number

   body-fields     = body-fld-param SP body-fld-id SP body-fld-desc SP
                     body-fld-enc SP body-fld-octets
*)

let body_fld_param =
  curr >>= function
  | '(' ->
      plist (imap_string >>= fun x -> char ' ' *> imap_string >|= fun y -> (x, y))
  | _ ->
      char 'N' *> char 'I' *> char 'L' *> return []

let body_fld_octets =
  Int32.to_int <$> number

let body_fields =
  let open MIME.Response.Fields in
  body_fld_param >>= fun fld_params ->
  char ' ' *> (some <$> nstring) >>= fun fld_id ->
  char ' ' *> (some <$> nstring) >>= fun fld_desc ->
  char ' ' *> imap_string >>= fun fld_enc ->
  char ' ' *> body_fld_octets >|= fun fld_octets ->
  {fld_params; fld_id; fld_desc; fld_enc; fld_octets}

(*
   body-fld-md5    = nstring

   body-fld-dsp    = "(" string SP body-fld-param ")" / nil

   body-fld-lang   = nstring / "(" string *(SP string) ")"

   body-fld-loc    = nstring

   body-ext-1part  = body-fld-md5 [SP body-fld-dsp [SP body-fld-lang
                     [SP body-fld-loc *(SP body-extension)]]]
                       ; MUST NOT be returned on non-extensible
                       ; "BODY" fetch

   body-ext-mpart  = body-fld-param [SP body-fld-dsp [SP body-fld-lang
                     [SP body-fld-loc *(SP body-extension)]]]
                       ; MUST NOT be returned on non-extensible
                       ; "BODY" fetch
*)

let body_fld_md5 =
  nstring

let body_fld_dsp =
  curr >>= function
  | '(' ->
      next *> imap_string >>= fun s ->
      char ' ' *> body_fld_param >>= fun l ->
      char ')' *> return (Some (s, l))
  | _ ->
      char 'N' *> char 'I' *> char 'L' *> return None

let body_fld_lang =
  curr >>= function
  | '(' ->
      plist imap_string
  | _ ->
      nstring >|= function "" -> [] | s -> [s]

let body_fld_loc =
  nstring

let body_ext_1part =
  let open MIME.Response.Extension in
  body_fld_md5 >>= fun _md5 ->
  curr >>= function
  | ' ' ->
      next *> body_fld_dsp >>= fun ext_dsp ->
      curr >>= begin function
      | ' ' ->
          next *> body_fld_lang >>= fun ext_lang ->
          curr >>= begin function
          | ' ' ->
              next *> body_fld_loc >|= fun ext_loc ->
              {ext_dsp; ext_lang; ext_loc; ext_ext = []}
          | _ ->
              return {ext_dsp; ext_lang; ext_loc = ""; ext_ext = []}
          end
      | _ ->
          return {ext_dsp; ext_lang = []; ext_loc = ""; ext_ext = []}
      end
  | _ ->
      return {ext_dsp = None; ext_lang = []; ext_loc = ""; ext_ext = []}

let body_ext_mpart =
  body_fld_param >>= fun p ->
  begin curr >>= function
    | ' ' ->
        next *> body_fld_dsp >>= fun _ ->
        curr >>= begin function
        | ' ' ->
            next *> body_fld_lang >>= fun _ ->
            curr >>= begin function
            | ' ' ->
                next *> body_fld_loc >|= ignore
            | _ ->
                return ()
            end
        | _ ->
            return ()
        end
    | _ ->
        return ()
  end *> return p

(*
   body-fld-lines  = number

   media-subtype   = string
                       ; Defined in [MIME-IMT]

   media-basic     = ((DQUOTE ("APPLICATION" / "AUDIO" / "IMAGE" /
                     "MESSAGE" / "VIDEO") DQUOTE) / string) SP
                     media-subtype
                       ; Defined in [MIME-IMT]

   media-message   = DQUOTE "MESSAGE" DQUOTE SP DQUOTE "RFC822" DQUOTE
                       ; Defined in [MIME-IMT]

   media-text      = DQUOTE "TEXT" DQUOTE SP media-subtype
                       ; Defined in [MIME-IMT]

   body-type-basic = media-basic SP body-fields
                       ; MESSAGE subtype MUST NOT be "RFC822"

   body-type-msg   = media-message SP body-fields SP envelope
                     SP body SP body-fld-lines

   body-type-text  = media-text SP body-fields SP body-fld-lines

   body-type-1part = (body-type-basic / body-type-msg / body-type-text)
                     [SP body-ext-1part]

   body-type-mpart = 1*body SP media-subtype
                     [SP body-ext-mpart]

   body            = "(" (body-type-1part / body-type-mpart) ")"
*)

let fix f =
  let rec p buf k = f p buf k in
  f p

let body_fld_lines =
  Int32.to_int <$> number

let body_type_msg body =
  body_fields >>= fun fields ->
  char ' ' *> envelope >>= fun envelope ->
  char ' ' *> body >>= fun b ->
  char ' ' *> body_fld_lines >|= fun fld_lines ->
  MIME.Response.Message (fields, envelope, b, fld_lines)

let body_type_text media_subtype =
  body_fields >>= fun fields ->
  char ' ' *> body_fld_lines >|= fun fld_lines ->
  MIME.Response.Text (media_subtype, fields, fld_lines)

let body_type_basic media_type media_subtype =
  body_fields >|= fun fields ->
  MIME.Response.Basic (media_type, media_subtype, fields)

let body_type_1part body =
  imap_string >>= fun media_type ->
  char ' ' *> imap_string >>= fun media_subtype ->
  begin match media_type, media_subtype with
  | "MESSAGE", "RFC822" ->
      char ' ' *> body_type_msg body
  | "TEXT", _ ->
      char ' ' *> body_type_text media_subtype
  | _ ->
      char ' ' *> body_type_basic media_type media_subtype
  end >>= fun body ->
  begin curr >>= function
  | ' ' ->
      next *> body_ext_1part >>= fun _ -> return ()
  | _ ->
      return ()
  end *> return body

let body_type_mpart body =
  let rec loop acc =
    curr >>= function
    | ' ' ->
        next *> imap_string >>= fun media_subtype ->
        begin curr >>= function
        | ' ' ->
            next *> body_ext_mpart
        | _ ->
            return []
        end >|= fun params ->
        MIME.Response.Multipart (List.rev acc, media_subtype, params)
    | _ ->
        body >>= fun b -> loop (b :: acc)
  in
  loop []

let body body =
  char '(' *> curr >>= begin function
  | '(' ->
      body_type_mpart body
  | _ ->
      body_type_1part body
  end <* char ')'

let body =
  fix body

(*
   DIGIT           =  %x30-39
                          ; 0-9

   date-day-fixed  = (SP DIGIT) / 2DIGIT
                       ; Fixed-format version of date-day

   date-month      = "Jan" / "Feb" / "Mar" / "Apr" / "May" / "Jun" /
                     "Jul" / "Aug" / "Sep" / "Oct" / "Nov" / "Dec"

   time            = 2DIGIT ":" 2DIGIT ":" 2DIGIT
                       ; Hours minutes seconds

   zone            = ("+" / "-") 4DIGIT
                       ; Signed four-digit value of hhmm representing
                       ; hours and minutes east of Greenwich (that is,
                       ; the amount that the given time differs from
                       ; Universal Time).  Subtracting the timezone
                       ; from the given time will give the UT form.
                       ; The Universal Time zone is "+0000".

   date-year       = 4DIGIT

   date-time       = DQUOTE date-day-fixed "-" date-month "-" date-year
                     SP time SP zone DQUOTE
*)

(* DD-MMM-YYYY HH:MM:SS +ZZZZ *)
let date_time =
  char '"' *> take 26 <* char '"'


(*
   header-fld-name = astring

   header-list     = "(" header-fld-name *(SP header-fld-name) ")"

   section-msgtext = "HEADER" / "HEADER.FIELDS" [".NOT"] SP header-list /
                     "TEXT"
                       ; top-level or MESSAGE/RFC822 part

   section-part    = nz-number *("." nz-number)
                       ; body part nesting

   section-spec    = section-msgtext / (section-part ["." section-text])

   section-text    = section-msgtext / "MIME"
                       ; text other than actual body part (headers, etc.)

   section         = "[" [section-spec] "]"
*)


let header_fld_name = astring

let header_list = plist astring

let section_msgtext tok =
  let open MIME.Section in
  match tok with
  | "HEADER" -> return HEADER
  | "HEADER.FIELDS" -> char ' ' *> header_list >|= fun l -> HEADER_FIELDS l
  | "HEADER.FIELDS.NOT" -> char ' ' *> header_list >|= fun l -> HEADER_FIELDS_NOT l
  | "TEXT" -> return TEXT
  | _ -> error

let period_list p =
  let rec loop acc =
    curr >>= function
    | '.' ->
        next *> p >>= fun x -> loop (x :: acc)
    | _ ->
        return (List.rev acc)
  in loop []

let section_part =
  nz_number >>= fun n -> period_list nz_number >|= fun l -> n :: l

let section_text =
  let open MIME.Section in
  atom >>= function
  | "MIME" -> return MIME
  | tok -> section_msgtext tok

let section_spec = curr >>= function
  | '1'..'9' -> section_part >>= fun p -> curr >>= begin function
    | '.' -> next *> section_text >|= fun m -> (p, Some m)
    | _ -> return (p, None)
  end
  | _ -> atom >>= section_msgtext >|= fun m -> ([], Some m)

let section =
  let open MIME.Section in
  char '[' *> curr >>= function
  | ']' -> next *> return ([], None)
  | _ -> section_spec >>= fun s -> char ']' *> return s

(*
   msg-att-static  = "ENVELOPE" SP envelope / "INTERNALDATE" SP date-time /
                     "RFC822" [".HEADER" / ".TEXT"] SP nstring /
                     "RFC822.SIZE" SP number /
                     "BODY" ["STRUCTURE"] SP body /
                     "BODY" section ["<" number ">"] SP nstring /
                     "UID" SP uniqueid
                       ; MUST NOT change for a message

   msg-att-dynamic = "FLAGS" SP "(" [flag-fetch *(SP flag-fetch)] ")"
                       ; MAY change for a message

   msg-att         = "(" (msg-att-dynamic / msg-att-static)
                      *(SP (msg-att-dynamic / msg-att-static)) ")"

   permsg-modsequence  = mod-sequence-value
                          ;; per message mod-sequence

   mod-sequence-value  = 1*DIGIT
                          ;; Positive unsigned 64-bit integer
                          ;; (mod-sequence)
                          ;; (1 <= n < 18,446,744,073,709,551,615)

   fetch-mod-resp      = "MODSEQ" SP "(" permsg-modsequence ")"

   msg-att-dynamic     =/ fetch-mod-resp

   msg-att-dynamic     =/ "X-GM-LABELS" SP "(" [astring 0*(SP astring)] ")" / nil
                          ; https://developers.google.com/gmail/imap_extensions

   msg-att-static      =/ "X-GM-MSGID" SP mod-sequence-value /
                          "X-GM-THRID" SP mod-sequecne-value
                          ; https://developers.google.com/gmail/imap_extensions
*)

let permsg_modsequence =
  mod_sequence_value

let msg_att =
  let open Fetch.MessageAttribute in
  cmd >>= function
  | "FLAGS" ->
      char ' ' *> plist flag_fetch >|= fun l -> FLAGS l
  | "MODSEQ" ->
      char ' ' *> char '(' *> permsg_modsequence >>= fun n -> char ')' *> return (MODSEQ n)
  | "X-GM-LABELS" ->
      char ' ' *> curr >>= begin function
      | '(' ->
          plist astring >|= fun l -> X_GM_LABELS l
      | _ ->
          char 'N' *> char 'I' *> char 'L' *> return (X_GM_LABELS [])
      end
  | "ENVELOPE" ->
      char ' ' *> envelope >|= fun e -> ENVELOPE e
  | "INTERNALDATE" ->
      char ' ' *> date_time >|= fun s -> INTERNALDATE s
  | "RFC822.HEADER" ->
      char ' ' *> nstring >|= fun s -> RFC822_HEADER s
  | "RFC822.TEXT" ->
      char ' ' *> nstring >|= fun s -> RFC822_TEXT s
  | "RFC822.SIZE" ->
      char ' ' *> number >|= fun n -> RFC822_SIZE (Int32.to_int n)
  | "RFC822" ->
      char ' ' *> nstring >|= fun s -> RFC822 s
  | "BODYSTRUCTURE" ->
      char ' ' *> body >|= (fun b -> BODYSTRUCTURE b)
  | "BODY" -> curr >>= begin function
    | '[' -> section >>= fun (sn, m) ->
        let s = (List.map Int32.to_int sn, m) in
        curr >>= begin function
        | '<' -> next *> number >>= fun _n -> char '>' *> char ' ' *> nstring >|= fun x ->
            BODY_SECTION (s, lift_nstring x)
        | ' ' -> next *> nstring >|= fun x ->
            BODY_SECTION (s, lift_nstring x)
        | _ -> error
        end
    | _ -> char ' ' *> body >|= fun b -> BODY b
    end
  | "UID" ->
      char ' ' *> uniqueid >|= fun n -> UID n
  | "X-GM-MSGID" ->
      char ' ' *> mod_sequence_value >|= fun n -> X_GM_MSGID n
  | "X-GM-THRID" ->
      char ' ' *> mod_sequence_value >|= fun n -> X_GM_THRID n
  | _ ->
      error

(*
   status          = "STATUS" SP mailbox SP
                     "(" status-att *(SP status-att) ")"

   status-att      = "MESSAGES" / "RECENT" / "UIDNEXT" / "UIDVALIDITY" /
                     "UNSEEN"

   status-att-list =  status-att SP number *(SP status-att SP number)

   mod-sequence-valzer = "0" / mod-sequence-value

   status-att-val      =/ "HIGHESTMODSEQ" SP mod-sequence-valzer
                          ;; extends non-terminal defined in [IMAPABNF].
                          ;; Value 0 denotes that the mailbox doesn't
                          ;; support persistent mod-sequences
                          ;; as described in Section 3.1.2
*)

let mod_sequence_valzer =
  let f s = Scanf.sscanf s "%Lu" (fun n -> n) in
  f <$> take_while1 is_digit

let status_att =
  let open Status.MailboxAttribute in
  atom >>= function
  | "MESSAGES" ->
      char ' ' *> number >|= fun n -> MESSAGES (Int32.to_int n)
  | "RECENT" ->
      char ' ' *> number >|= fun n -> RECENT (Int32.to_int n)
  | "UIDNEXT" ->
      char ' ' *> number >|= fun n -> UIDNEXT n
  | "UIDVALIDITY" ->
      char ' ' *> number >|= fun n -> UIDVALIDITY n
  | "UNSEEN" ->
      char ' ' *> number >|= fun n -> UNSEEN (Int32.to_int n)
  | "HIGHESTMODSEQ" ->
      char ' ' *> mod_sequence_valzer >|= fun n -> HIGHESTMODSEQ n
  | _ ->
      error

let known_ids =
  uid_set


(*
   resp-cond-state = ("OK" / "NO" / "BAD") SP resp-text
                       ; Status condition

   mailbox-data    =  "FLAGS" SP flag-list / "LIST" SP mailbox-list /
                      "LSUB" SP mailbox-list / "SEARCH" *(SP nz-number) /
                      "STATUS" SP mailbox SP "(" [status-att-list] ")" /
                      number SP "EXISTS" / number SP "RECENT"

   message-data    = nz-number SP ("EXPUNGE" / ("FETCH" SP msg-att))

   resp-cond-bye   = "BYE" SP resp-text

   response-data   = "*" SP (resp-cond-state / resp-cond-bye /
                     mailbox-data / message-data / capability-data) CRLF

   search-sort-mod-seq = "(" "MODSEQ" SP mod-sequence-value ")"

   mailbox-data        =/ "SEARCH" [1*(SP nz-number) SP
                          search-sort-mod-seq]

   known-uids          =  sequence-set
                          ;; sequence of UIDs, "*" is not allowed

   expunged-resp       =  "VANISHED" [SP "(EARLIER)"] SP known-uids

   message-data        =/ expunged-resp

   enable-data   = "ENABLED" *(SP capability)

   resp-cond-bye   = "BYE" SP resp-text

   resp-cond-auth  = ("OK" / "PREAUTH") SP resp-text
                       ; Authentication condition

   response-data =/ "*" SP enable-data CRLF
*)

let response_data =
  let open Response.Untagged in
  char '*' *> char ' ' *> curr >>= function
  | '0'..'9' ->
      number >>= fun n ->
      char ' ' *> atom >>= begin function
      | "EXISTS" ->
          return (EXISTS (Int32.to_int n))
      | "RECENT" ->
          return (RECENT (Int32.to_int n))
      | "EXPUNGE" ->
          return (EXPUNGE n)
      | "FETCH" ->
          char ' ' *> plist msg_att >|= fun x -> FETCH (n, x)
      | _ ->
          error
      end
  | _ ->
      atom >>= begin function
      | "OK" ->
          resp_text >|= fun (code, text) -> State (OK (code, text))
      | "NO" ->
          resp_text >|= fun (code, text) -> State (NO (code, text))
      | "BAD" ->
          resp_text >|= fun (code, text) -> State (BAD (code, text))
      | "BYE" ->
          resp_text >|= fun (code, text) -> BYE (code, text)
      | "FLAGS" ->
          char ' ' *> plist flag >|= fun l -> FLAGS l
      | "LIST" ->
          char ' ' *> mailbox_list >|= fun (xs, c, m) -> LIST (xs, c, m)
      | "LSUB" ->
          char ' ' *> mailbox_list >|= fun (xs, c, m) -> LSUB (xs, c, m)
      | "SEARCH" ->
          let rec loop acc =
            curr >>= function
            | ' ' ->
                next *> curr >>= begin function
                | '(' ->
                    search_sort_mod_seq >|= fun n -> SEARCH (List.rev acc, Some n)
                | _ ->
                    nz_number >>= fun n -> loop (n :: acc)
                end
            | _ ->
                return (SEARCH (List.rev acc, None))
          in
          loop []
      | "STATUS" ->
          char ' ' *> mailbox >>= fun mbox ->
          char ' ' *> plist status_att >|= fun l -> STATUS (mbox, l)
      | "CAPABILITY" ->
          slist capability >|= fun l -> CAPABILITY l
      | "ENABLED" ->
          slist capability >|= fun l -> ENABLED l
      | "PREAUTH" ->
          resp_text >|= fun (code, text) -> PREAUTH (code, text)
      | "VANISHED" ->
          char ' ' *> curr >>= begin function
          | '(' ->
              next *> atom >>= begin function
              | "EARLIER" -> char ')'
              | _ -> error
              end >>= fun () ->
              char ' ' *> known_ids >|= fun ids -> VANISHED_EARLIER ids
          | _ ->
              known_ids >|= fun ids -> VANISHED ids
          end
      | _ ->
          error
      end

(*
   greeting        = "*" SP (resp-cond-auth / resp-cond-bye) CRLF

   continue-req    = "+" SP (resp-text / base64) CRLF

   tag             = 1*<any ASTRING-CHAR except "+">

   response-tagged = tag SP resp-cond-state CRLF

   response-fatal  = "*" SP resp-cond-bye CRLF
                       ; Server closes connection immediately

   response-done   = response-tagged / response-fatal
*)

let is_tag_char = function
  | '+' -> false
  | c -> is_astring_char c

let tag =
  take_while1 is_tag_char

let resp_cond_state =
  let open Response.State in
  atom >>= function
  | "OK" ->
      resp_text >|= fun (code, text) -> OK (code, text)
  | "NO" ->
      resp_text >|= fun (code, text) -> NO (code, text)
  | "BAD" ->
      resp_text >|= fun (code, text) -> BAD (code, text)
  | _ ->
      error

let response =
  get_line *> curr >>= function
  | '+' ->
      next *> resp_text >|= fun (_, x) -> Cont x
  | '*' ->
      response_data >|= fun x -> Untagged x
  | _ ->
      tag >>= fun tag -> char ' ' *> resp_cond_state >|= fun st -> Tagged (tag, st)

exception F of string * int

let parse s =
  let off = ref 0 in
  let get_line k =
    let i =
      match String.index_from s !off '\n' with
      | i -> i
      | exception Not_found -> String.length s
    in
    let s = String.sub s !off (i - !off) in
    off := i + 1;
    k s
  in
  let get_exactly n k =
    assert (!off + n <= String.length s);
    let s = String.sub s !off n in
    off := !off + n;
    k s
  in
  let buf = {get_line; get_exactly; line = ""; pos = 0} in
  let result = ref (Cont "") in
  match response buf (function Ok u -> result := u | Error (s, pos) -> raise (F (s, pos))) with
  | () ->
      !result |> Response.sexp_of_t |> Sexplib.Sexp.to_string_hum |> print_endline
  | exception F (line, pos) ->
      Printf.eprintf "Parsing error:\n%s\n%s^\n" line (String.make pos ' ')

let%expect_test _ =
  parse {|+ YGgGCSqGSIb3EgECAgIAb1kwV6ADAgEFoQMCAQ+iSzBJoAMC|};
  [%expect {| (Cont YGgGCSqGSIb3EgECAgIAb1kwV6ADAgEFoQMCAQ+iSzBJoAMC) |}]

let%expect_test _ =
  parse {|+ YDMGCSqGSIb3EgECAgIBAAD/////6jcyG4GE3KkTzBeBiVHe|};
  [%expect {| (Cont YDMGCSqGSIb3EgECAgIBAAD/////6jcyG4GE3KkTzBeBiVHe) |}]

let%expect_test _ =
  parse {|+|};
  [%expect {| (Cont "") |}]

let%expect_test _ =
  parse {|+ Ready for literal data|};
  [%expect {| (Cont "Ready for literal data") |}]

let%expect_test _ =
  parse {|+ Ready for additional command text|};
  [%expect {| (Cont "Ready for additional command text") |}]

let%expect_test _ =
  parse {|abcd OK CAPABILITY completed|};
  [%expect {| (Tagged abcd (OK NONE "CAPABILITY completed")) |}]

let%expect_test _ =
  parse {|efgh OK STARTLS completed|};
  [%expect {| (Tagged efgh (OK NONE "STARTLS completed")) |}]

let%expect_test _ =
  parse {|ijkl OK CAPABILITY completed|};
  [%expect {| (Tagged ijkl (OK NONE "CAPABILITY completed")) |}]

let%expect_test _ =
  parse {|a002 OK NOOP completed|};
  [%expect {| (Tagged a002 (OK NONE "NOOP completed")) |}]

let%expect_test _ =
  parse {|a047 OK NOOP completed|};
  [%expect {| (Tagged a047 (OK NONE "NOOP completed")) |}]

let%expect_test _ =
  parse {|A023 OK LOGOUT completed|};
  [%expect {| (Tagged A023 (OK NONE "LOGOUT completed")) |}]

let%expect_test _ =
  parse {|a001 OK CAPABILITY completed|};
  [%expect {| (Tagged a001 (OK NONE "CAPABILITY completed")) |}]

let%expect_test _ =
  parse {|a002 OK Begin TLS negotiation now|};
  [%expect {| (Tagged a002 (OK NONE "Begin TLS negotiation now")) |}]

let%expect_test _ =
  parse {|a003 OK CAPABILITY completed|};
  [%expect {| (Tagged a003 (OK NONE "CAPABILITY completed")) |}]

let%expect_test _ =
  parse {|a004 OK LOGIN completed|};
  [%expect {| (Tagged a004 (OK NONE "LOGIN completed")) |}]

let%expect_test _ =
  parse {|A001 OK GSSAPI authentication successful|};
  [%expect {| (Tagged A001 (OK NONE "GSSAPI authentication successful")) |}]

let%expect_test _ =
  parse {|a001 OK LOGIN completed|};
  [%expect {| (Tagged a001 (OK NONE "LOGIN completed")) |}]

let%expect_test _ =
  parse {|A142 OK [READ-WRITE] SELECT completed|};
  [%expect {| (Tagged A142 (OK READ_WRITE "SELECT completed")) |}]

let%expect_test _ =
  parse {|A932 OK [READ-ONLY] EXAMINE completed|};
  [%expect {| (Tagged A932 (OK READ_ONLY "EXAMINE completed")) |}]

let%expect_test _ =
  parse {|A003 OK CREATE completed|};
  [%expect {| (Tagged A003 (OK NONE "CREATE completed")) |}]

let%expect_test _ =
  parse {|A004 OK CREATE completed|};
  [%expect {| (Tagged A004 (OK NONE "CREATE completed")) |}]

let%expect_test _ =
  parse {|A682 OK LIST completed|};
  [%expect {| (Tagged A682 (OK NONE "LIST completed")) |}]

let%expect_test _ =
  parse {|A683 OK DELETE completed|};
  [%expect {| (Tagged A683 (OK NONE "DELETE completed")) |}]

let%expect_test _ =
  parse {|A684 NO Name "foo" has inferior hierarchical names|};
  [%expect {| (Tagged A684 (NO NONE "Name \"foo\" has inferior hierarchical names")) |}]

let%expect_test _ =
  parse {|A685 OK DELETE Completed|};
  [%expect {| (Tagged A685 (OK NONE "DELETE Completed")) |}]

let%expect_test _ =
  parse {|A686 OK LIST completed|};
  [%expect {| (Tagged A686 (OK NONE "LIST completed")) |}]

let%expect_test _ =
  parse {|A687 OK DELETE Completed|};
  [%expect {| (Tagged A687 (OK NONE "DELETE Completed")) |}]

let%expect_test _ =
  parse {|A82 OK LIST completed|};
  [%expect {| (Tagged A82 (OK NONE "LIST completed")) |}]

let%expect_test _ =
  parse {|A83 OK DELETE completed|};
  [%expect {| (Tagged A83 (OK NONE "DELETE completed")) |}]

let%expect_test _ =
  parse {|A84 OK DELETE Completed|};
  [%expect {| (Tagged A84 (OK NONE "DELETE Completed")) |}]

let%expect_test _ =
  parse {|* CAPABILITY IMAP4rev1 STARTTLS AUTH=GSSAPI|};
  [%expect {|
    (Untagged
     (CAPABILITY ((OTHER IMAP4rev1) (OTHER STARTTLS) (OTHER AUTH=GSSAPI)))) |}]

let%expect_test _ =
  parse {|* CAPABILITY IMAP4rev1 AUTH=GSSAPI AUTH=PLAIN|};
  [%expect {| (Untagged (CAPABILITY ((OTHER IMAP4rev1) (OTHER AUTH=GSSAPI) AUTH_PLAIN))) |}]

let%expect_test _ =
  parse {|* 22 EXPUNGE|};
  [%expect {| (Untagged (EXPUNGE 22)) |}]

let%expect_test _ =
  parse {|* 23 EXISTS|};
  [%expect {| (Untagged (EXISTS 23)) |}]

let%expect_test _ =
  parse {|* 3 RECENT|};
  [%expect {| (Untagged (RECENT 3)) |}]

let%expect_test _ =
  parse {|* 14 FETCH (FLAGS (\Seen \Deleted))|};
  [%expect {|
    (Untagged (FETCH 14 ((FLAGS (Seen Deleted))))) |}]

let%expect_test _ =
  parse {|* BYE IMAP4rev1 Server logging out|};
  [%expect {| (Untagged (BYE NONE "IMAP4rev1 Server logging out")) |}]

let%expect_test _ =
  parse {|* CAPABILITY IMAP4rev1 STARTTLS LOGINDISABLED|};
  [%expect {|
    (Untagged
     (CAPABILITY ((OTHER IMAP4rev1) (OTHER STARTTLS) (OTHER LOGINDISABLED)))) |}]

let%expect_test _ =
  parse {|* CAPABILITY IMAP4rev1 AUTH=PLAIN|};
  [%expect {| (Untagged (CAPABILITY ((OTHER IMAP4rev1) AUTH_PLAIN))) |}]

let%expect_test _ =
  parse {|* OK IMAP4rev1 Server|};
  [%expect {| (Untagged (State (OK NONE "IMAP4rev1 Server"))) |}]

let%expect_test _ =
  parse {|* 172 EXISTS|};
  [%expect {| (Untagged (EXISTS 172)) |}]

let%expect_test _ =
  parse {|* 1 RECENT|};
  [%expect {| (Untagged (RECENT 1)) |}]

let%expect_test _ =
  parse {|* OK [UNSEEN 12] Message 12 is first unseen|};
  [%expect {| (Untagged (State (OK (UNSEEN 12) "Message 12 is first unseen"))) |}]

let%expect_test _ =
  parse {|* OK [UIDVALIDITY 3857529045] UIDs valid|};
  [%expect {| (Untagged (State (OK (UIDVALIDITY -437438251) "UIDs valid"))) |}]

let%expect_test _ =
  parse {|* OK [UIDNEXT 4392] Predicted next UID|};
  [%expect {| (Untagged (State (OK (UIDNEXT 4392) "Predicted next UID"))) |}]

let%expect_test _ =
  parse {|* FLAGS (\Answered \Flagged \Deleted \Seen \Draft)|};
  [%expect {| (Untagged (FLAGS (Answered Flagged Deleted Seen Draft))) |}]

let%expect_test _ =
  parse {|* OK [PERMANENTFLAGS (\Deleted \Seen \*)] Limited|};
  [%expect {|
    (Untagged (State (OK (PERMANENTFLAGS (Deleted Seen Any)) Limited))) |}]

let%expect_test _ =
  parse {|* 17 EXISTS|};
  [%expect {| (Untagged (EXISTS 17)) |}]

let%expect_test _ =
  parse {|* 2 RECENT|};
  [%expect {| (Untagged (RECENT 2)) |}]

let%expect_test _ =
  parse {|* OK [UNSEEN 8] Message 8 is first unseen|};
  [%expect {| (Untagged (State (OK (UNSEEN 8) "Message 8 is first unseen"))) |}]

let%expect_test _ =
  parse {|* OK [UIDNEXT 4392] Predicted next UID|};
  [%expect {| (Untagged (State (OK (UIDNEXT 4392) "Predicted next UID"))) |}]

let%expect_test _ =
  parse {|* FLAGS (\Answered \Flagged \Deleted \Seen \Draft)|};
  [%expect {| (Untagged (FLAGS (Answered Flagged Deleted Seen Draft))) |}]

let%expect_test _ =
  parse {|* OK [PERMANENTFLAGS ()] No permanent flags permitted|};
  [%expect {|
    (Untagged (State (OK (PERMANENTFLAGS ()) "No permanent flags permitted"))) |}]

let%expect_test _ =
  parse {|* LIST () "/" blurdybloop|};
  [%expect {|
    (Untagged (LIST () (/) blurdybloop)) |}]

let%expect_test _ =
  parse {|* LIST (\Noselect) "/" foo|};
  [%expect {|
    (Untagged (LIST (Noselect) (/) foo)) |}]

let%expect_test _ =
  parse {|* LIST () "/" foo/bar|};
  [%expect {|
    (Untagged (LIST () (/) foo/bar)) |}]

let%expect_test _ =
  parse {|* LIST (\Noselect) "/" foo|};
  [%expect {|
    (Untagged (LIST (Noselect) (/) foo)) |}]

let%expect_test _ =
  parse {|* LIST () "." blurdybloop|};
  [%expect {|
    (Untagged (LIST () (.) blurdybloop)) |}]

let%expect_test _ =
  parse {|* LIST () "." foo|};
  [%expect {|
    (Untagged (LIST () (.) foo)) |}]

let%expect_test _ =
  parse {|* LIST () "." foo.bar|};
  [%expect {|
    (Untagged (LIST () (.) foo.bar)) |}]

let%expect_test _ =
  parse {|* LIST () "." foo.bar|};
  [%expect {|
    (Untagged (LIST () (.) foo.bar)) |}]

let%expect_test _ =
  parse {|A85 OK LIST completed|};
  [%expect {| (Tagged A85 (OK NONE "LIST completed")) |}]

let%expect_test _ =
  parse {|* LIST (\Noselect) "." foo|};
  [%expect {|
    (Untagged (LIST (Noselect) (.) foo)) |}]

let%expect_test _ =
  parse {|A86 OK LIST completed|};
  [%expect {| (Tagged A86 (OK NONE "LIST completed")) |}]

let%expect_test _ =
  parse {|* LIST () "/" blurdybloop|};
  [%expect {|
    (Untagged (LIST () (/) blurdybloop)) |}]

let%expect_test _ =
  parse {|* LIST (\Noselect) "/" foo|};
  [%expect {|
    (Untagged (LIST (Noselect) (/) foo)) |}]

let%expect_test _ =
  parse {|* LIST () "/" foo/bar|};
  [%expect {|
    (Untagged (LIST () (/) foo/bar)) |}]

let%expect_test _ =
  parse {|A682 OK LIST completed|};
  [%expect {| (Tagged A682 (OK NONE "LIST completed")) |}]

let%expect_test _ =
  parse {|A683 OK RENAME completed|};
  [%expect {| (Tagged A683 (OK NONE "RENAME completed")) |}]

let%expect_test _ =
  parse {|A684 OK RENAME Completed|};
  [%expect {| (Tagged A684 (OK NONE "RENAME Completed")) |}]

let%expect_test _ =
  parse {|* LIST () "/" sarasoop|};
  [%expect {|
    (Untagged (LIST () (/) sarasoop)) |}]

let%expect_test _ =
  parse {|* LIST (\Noselect) "/" zowie|};
  [%expect {|
    (Untagged (LIST (Noselect) (/) zowie)) |}]

let%expect_test _ =
  parse {|* LIST () "/" zowie/bar|};
  [%expect {|
    (Untagged (LIST () (/) zowie/bar)) |}]

let%expect_test _ =
  parse {|A685 OK LIST completed|};
  [%expect {| (Tagged A685 (OK NONE "LIST completed")) |}]

let%expect_test _ =
  parse {|* LIST () "." INBOX|};
  [%expect {|
    (Untagged (LIST () (.) INBOX)) |}]

let%expect_test _ =
  parse {|* LIST () "." INBOX.bar|};
  [%expect {|
    (Untagged (LIST () (.) INBOX.bar)) |}]

let%expect_test _ =
  parse {|Z432 OK LIST completed|};
  [%expect {| (Tagged Z432 (OK NONE "LIST completed")) |}]

let%expect_test _ =
  parse {|Z433 OK RENAME completed|};
  [%expect {| (Tagged Z433 (OK NONE "RENAME completed")) |}]

let%expect_test _ =
  parse {|* LIST () "." INBOX|};
  [%expect {|
    (Untagged (LIST () (.) INBOX)) |}]

let%expect_test _ =
  parse {|* LIST () "." INBOX.bar|};
  [%expect {|
    (Untagged (LIST () (.) INBOX.bar)) |}]

let%expect_test _ =
  parse {|* LIST () "." old-mail|};
  [%expect {|
    (Untagged (LIST () (.) old-mail)) |}]

let%expect_test _ =
  parse {|Z434 OK LIST completed|};
  [%expect {| (Tagged Z434 (OK NONE "LIST completed")) |}]

let%expect_test _ =
  parse {|A002 OK SUBSCRIBE completed|};
  [%expect {| (Tagged A002 (OK NONE "SUBSCRIBE completed")) |}]

let%expect_test _ =
  parse {|A002 OK UNSUBSCRIBE completed|};
  [%expect {| (Tagged A002 (OK NONE "UNSUBSCRIBE completed")) |}]

let%expect_test _ =
  parse {|* LIST (\Noselect) "/" ""|};
  [%expect {|
    (Untagged (LIST (Noselect) (/) "")) |}]

let%expect_test _ =
  parse {|A101 OK LIST Completed|};
  [%expect {| (Tagged A101 (OK NONE "LIST Completed")) |}]

let%expect_test _ =
  parse {|* LIST (\Noselect) "." #news.|};
  [%expect {|
    (Untagged (LIST (Noselect) (.) #news.)) |}]

let%expect_test _ =
  parse {|A102 OK LIST Completed|};
  [%expect {| (Tagged A102 (OK NONE "LIST Completed")) |}]

let%expect_test _ =
  parse {|* LIST (\Noselect) "/" /|};
  [%expect {|
    (Untagged (LIST (Noselect) (/) /)) |}]

let%expect_test _ =
  parse {|A103 OK LIST Completed|};
  [%expect {| (Tagged A103 (OK NONE "LIST Completed")) |}]

let%expect_test _ =
  parse {|* LIST (\Noselect) "/" ~/Mail/foo|};
  [%expect {|
    (Untagged (LIST (Noselect) (/) ~/Mail/foo)) |}]

let%expect_test _ =
  parse {|* LIST () "/" ~/Mail/meetings|};
  [%expect {|
    (Untagged (LIST () (/) ~/Mail/meetings)) |}]

let%expect_test _ =
  parse {|A202 OK LIST completed|};
  [%expect {| (Tagged A202 (OK NONE "LIST completed")) |}]

let%expect_test _ =
  parse {|* LSUB () "." #news.comp.mail.mime|};
  [%expect {|
    (Untagged (LSUB () (.) #news.comp.mail.mime)) |}]

let%expect_test _ =
  parse {|* LSUB () "." #news.comp.mail.misc|};
  [%expect {|
    (Untagged (LSUB () (.) #news.comp.mail.misc)) |}]

let%expect_test _ =
  parse {|A002 OK LSUB completed|};
  [%expect {| (Tagged A002 (OK NONE "LSUB completed")) |}]

let%expect_test _ =
  parse {|* LSUB (\NoSelect) "." #news.comp.mail|};
  [%expect {|
    (Untagged (LSUB (Noselect) (.) #news.comp.mail)) |}]

let%expect_test _ =
  parse {|A003 OK LSUB completed|};
  [%expect {| (Tagged A003 (OK NONE "LSUB completed")) |}]

let%expect_test _ =
  parse {|* STATUS blurdybloop (MESSAGES 231 UIDNEXT 44292)|};
  [%expect {| (Untagged (STATUS blurdybloop ((MESSAGES 231) (UIDNEXT 44292)))) |}]

let%expect_test _ =
  parse {|A042 OK STATUS completed|};
  [%expect {| (Tagged A042 (OK NONE "STATUS completed")) |}]

let%expect_test _ =
  parse {|A003 OK APPEND completed|};
  [%expect {| (Tagged A003 (OK NONE "APPEND completed")) |}]

let%expect_test _ =
  parse {|FXXZ OK CHECK Completed|};
  [%expect {| (Tagged FXXZ (OK NONE "CHECK Completed")) |}]

let%expect_test _ =
  parse {|A341 OK CLOSE completed|};
  [%expect {| (Tagged A341 (OK NONE "CLOSE completed")) |}]

let%expect_test _ =
  parse {|* 3 EXPUNGE|};
  [%expect {| (Untagged (EXPUNGE 3)) |}]

let%expect_test _ =
  parse {|* 3 EXPUNGE|};
  [%expect {| (Untagged (EXPUNGE 3)) |}]

let%expect_test _ =
  parse {|* 5 EXPUNGE|};
  [%expect {| (Untagged (EXPUNGE 5)) |}]

let%expect_test _ =
  parse {|* 8 EXPUNGE|};
  [%expect {| (Untagged (EXPUNGE 8)) |}]

let%expect_test _ =
  parse {|A202 OK EXPUNGE completed|};
  [%expect {| (Tagged A202 (OK NONE "EXPUNGE completed")) |}]

let%expect_test _ =
  parse {|* SEARCH 2 84 882|};
  [%expect {| (Untagged (SEARCH (2 84 882) ())) |}]

let%expect_test _ =
  parse {|A282 OK SEARCH completed|};
  [%expect {| (Tagged A282 (OK NONE "SEARCH completed")) |}]

let%expect_test _ =
  parse {|* SEARCH|};
  [%expect {| (Untagged (SEARCH () ())) |}]

let%expect_test _ =
  parse {|A283 OK SEARCH completed|};
  [%expect {| (Tagged A283 (OK NONE "SEARCH completed")) |}]

let%expect_test _ =
  parse {|* SEARCH 43|};
  [%expect {| (Untagged (SEARCH (43) ())) |}]

let%expect_test _ =
  parse {|A284 OK SEARCH completed|};
  [%expect {| (Tagged A284 (OK NONE "SEARCH completed")) |}]

let%expect_test _ =
  parse {|A654 OK FETCH completed|};
  [%expect {| (Tagged A654 (OK NONE "FETCH completed")) |}]

let%expect_test _ =
  parse {|* 2 FETCH (FLAGS (\Deleted \Seen))|};
  [%expect {|
    (Untagged (FETCH 2 ((FLAGS (Deleted Seen))))) |}]

let%expect_test _ =
  parse {|* 3 FETCH (FLAGS (\Deleted))|};
  [%expect {|
    (Untagged (FETCH 3 ((FLAGS (Deleted))))) |}]

let%expect_test _ =
  parse {|* 4 FETCH (FLAGS (\Deleted \Flagged \Seen))|};
  [%expect {|
    (Untagged (FETCH 4 ((FLAGS (Deleted Flagged Seen))))) |}]

let%expect_test _ =
  parse {|A003 OK STORE completed|};
  [%expect {| (Tagged A003 (OK NONE "STORE completed")) |}]

let%expect_test _ =
  parse {|A003 OK COPY completed|};
  [%expect {| (Tagged A003 (OK NONE "COPY completed")) |}]

let%expect_test _ =
  parse {|* 23 FETCH (FLAGS (\Seen) UID 4827313)|};
  [%expect {|
    (Untagged (FETCH 23 ((FLAGS (Seen)) (UID 4827313)))) |}]

let%expect_test _ =
  parse {|* 24 FETCH (FLAGS (\Seen) UID 4827943)|};
  [%expect {|
    (Untagged (FETCH 24 ((FLAGS (Seen)) (UID 4827943)))) |}]

let%expect_test _ =
  parse {|* 25 FETCH (FLAGS (\Seen) UID 4828442)|};
  [%expect {|
    (Untagged (FETCH 25 ((FLAGS (Seen)) (UID 4828442)))) |}]

let%expect_test _ =
  parse {|A999 OK UID FETCH completed|};
  [%expect {| (Tagged A999 (OK NONE "UID FETCH completed")) |}]

let%expect_test _ =
  parse {|* CAPABILITY IMAP4rev1 XPIG-LATIN|};
  [%expect {| (Untagged (CAPABILITY ((OTHER IMAP4rev1) (OTHER XPIG-LATIN)))) |}]

let%expect_test _ =
  parse {|a441 OK CAPABILITY completed|};
  [%expect {| (Tagged a441 (OK NONE "CAPABILITY completed")) |}]

let%expect_test _ =
  parse {|A442 OK XPIG-LATIN ompleted-cay|};
  [%expect {| (Tagged A442 (OK NONE "XPIG-LATIN ompleted-cay")) |}]

let%expect_test _ =
  parse {|* OK IMAP4rev1 server ready|};
  [%expect {| (Untagged (State (OK NONE "IMAP4rev1 server ready"))) |}]

let%expect_test _ =
  parse {|* OK [ALERT] System shutdown in 10 minutes|};
  [%expect {| (Untagged (State (OK ALERT "System shutdown in 10 minutes"))) |}]

let%expect_test _ =
  parse {|A001 OK LOGIN Completed|};
  [%expect {| (Tagged A001 (OK NONE "LOGIN Completed")) |}]

let%expect_test _ =
  parse {|* NO Disk is 98% full, please delete unnecessary data|};
  [%expect {|
    (Untagged
     (State (NO NONE "Disk is 98% full, please delete unnecessary data"))) |}]

let%expect_test _ =
  parse {|A222 OK COPY completed|};
  [%expect {| (Tagged A222 (OK NONE "COPY completed")) |}]

let%expect_test _ =
  parse {|* NO Disk is 98% full, please delete unnecessary data|};
  [%expect {|
    (Untagged
     (State (NO NONE "Disk is 98% full, please delete unnecessary data"))) |}]

let%expect_test _ =
  parse {|* NO Disk is 99% full, please delete unnecessary data|};
  [%expect {|
    (Untagged
     (State (NO NONE "Disk is 99% full, please delete unnecessary data"))) |}]

let%expect_test _ =
  parse {|A223 NO COPY failed: disk is full|};
  [%expect {| (Tagged A223 (NO NONE "COPY failed: disk is full")) |}]

let%expect_test _ =
  parse {|* BAD Command line too long|};
  [%expect {| (Untagged (State (BAD NONE "Command line too long"))) |}]

let%expect_test _ =
  parse {|* BAD Empty command line|};
  [%expect {| (Untagged (State (BAD NONE "Empty command line"))) |}]

let%expect_test _ =
  parse {|* BAD Disk crash, attempting salvage to a new disk!|};
  [%expect {| (Untagged (State (BAD NONE "Disk crash, attempting salvage to a new disk!"))) |}]

let%expect_test _ =
  parse {|* OK Salvage successful, no data lost|};
  [%expect {| (Untagged (State (OK NONE "Salvage successful, no data lost"))) |}]

let%expect_test _ =
  parse {|A443 OK Expunge completed|};
  [%expect {| (Tagged A443 (OK NONE "Expunge completed")) |}]

let%expect_test _ =
  parse {|* PREAUTH IMAP4rev1 server logged in as Smith|};
  [%expect {| (Untagged (PREAUTH NONE "IMAP4rev1 server logged in as Smith")) |}]

let%expect_test _ =
  parse {|* BYE Autologout; idle for too long|};
  [%expect {| (Untagged (BYE NONE "Autologout; idle for too long")) |}]

let%expect_test _ =
  parse {|* CAPABILITY IMAP4rev1 STARTTLS AUTH=GSSAPI XPIG-LATIN|};
  [%expect {|
    (Untagged
     (CAPABILITY
      ((OTHER IMAP4rev1) (OTHER STARTTLS) (OTHER AUTH=GSSAPI) (OTHER XPIG-LATIN)))) |}]

let%expect_test _ =
  parse {|* LIST (\Noselect) "/" ~/Mail/foo|};
  [%expect {|
    (Untagged (LIST (Noselect) (/) ~/Mail/foo)) |}]

let%expect_test _ =
  parse {|* LSUB () "." #news.comp.mail.misc|};
  [%expect {|
    (Untagged (LSUB () (.) #news.comp.mail.misc)) |}]

let%expect_test _ =
  parse {|* STATUS blurdybloop (MESSAGES 231 UIDNEXT 44292)|};
  [%expect {| (Untagged (STATUS blurdybloop ((MESSAGES 231) (UIDNEXT 44292)))) |}]

let%expect_test _ =
  parse {|* SEARCH 2 3 6|};
  [%expect {| (Untagged (SEARCH (2 3 6) ())) |}]

let%expect_test _ =
  parse {|* FLAGS (\Answered \Flagged \Deleted \Seen \Draft)|};
  [%expect {| (Untagged (FLAGS (Answered Flagged Deleted Seen Draft))) |}]

let%expect_test _ =
  parse {|* 23 EXISTS|};
  [%expect {| (Untagged (EXISTS 23)) |}]

let%expect_test _ =
  parse {|* 5 RECENT|};
  [%expect {| (Untagged (RECENT 5)) |}]

let%expect_test _ =
  parse {|* 44 EXPUNGE|};
  [%expect {| (Untagged (EXPUNGE 44)) |}]

let%expect_test _ =
  parse {|* 23 FETCH (FLAGS (\Seen) RFC822.SIZE 44827)|};
  [%expect {|
    (Untagged (FETCH 23 ((FLAGS (Seen)) (RFC822_SIZE 44827)))) |}]

let%expect_test _ =
  parse {|A001 OK LOGIN completed|};
  [%expect {| (Tagged A001 (OK NONE "LOGIN completed")) |}]

let%expect_test _ =
  parse {|A044 BAD No such command as "BLURDYBLOOP"|};
  [%expect {| (Tagged A044 (BAD NONE "No such command as \"BLURDYBLOOP\"")) |}]

let%expect_test _ =
  parse {|* OK IMAP4rev1 Service Ready|};
  [%expect {| (Untagged (State (OK NONE "IMAP4rev1 Service Ready"))) |}]

let%expect_test _ =
  parse {|a001 OK LOGIN completed|};
  [%expect {| (Tagged a001 (OK NONE "LOGIN completed")) |}]

let%expect_test _ =
  parse {|* 18 EXISTS|};
  [%expect {| (Untagged (EXISTS 18)) |}]

let%expect_test _ =
  parse {|* FLAGS (\Answered \Flagged \Deleted \Seen \Draft)|};
  [%expect {| (Untagged (FLAGS (Answered Flagged Deleted Seen Draft))) |}]

let%expect_test _ =
  parse {|* 2 RECENT|};
  [%expect {| (Untagged (RECENT 2)) |}]

let%expect_test _ =
  parse {|* OK [UNSEEN 17] Message 17 is the first unseen message|};
  [%expect {|
    (Untagged (State (OK (UNSEEN 17) "Message 17 is the first unseen message"))) |}]

let%expect_test _ =
  parse {|* OK [UIDVALIDITY 3857529045] UIDs valid|};
  [%expect {| (Untagged (State (OK (UIDVALIDITY -437438251) "UIDs valid"))) |}]

let%expect_test _ =
  parse {|a002 OK [READ-WRITE] SELECT completed|};
  [%expect {| (Tagged a002 (OK READ_WRITE "SELECT completed")) |}]

let%expect_test _ =
  parse {|* 12 FETCH (FLAGS (\Seen) INTERNALDATE "17-Jul-1996 02:44:25 -0700")|};
  [%expect {|
    (Untagged
     (FETCH 12 ((FLAGS (Seen)) (INTERNALDATE "17-Jul-1996 02:44:25 -0700")))) |}]

let%expect_test _ =
  parse {|a003 OK FETCH completed|};
  [%expect {| (Tagged a003 (OK NONE "FETCH completed")) |}]

let%expect_test _ =
  parse {|* 172 EXISTS|};
  [%expect {| (Untagged (EXISTS 172)) |}]

let%expect_test _ =
  parse {|* 1 RECENT|};
  [%expect {| (Untagged (RECENT 1)) |}]

let%expect_test _ =
  parse {|* OK [UNSEEN 12] Message 12 is first unseen|};
  [%expect {| (Untagged (State (OK (UNSEEN 12) "Message 12 is first unseen"))) |}]

let%expect_test _ =
  parse {|* OK [UIDVALIDITY 3857529045] UIDs valid|};
  [%expect {| (Untagged (State (OK (UIDVALIDITY -437438251) "UIDs valid"))) |}]

let%expect_test _ =
  parse {|* OK [UIDNEXT 4392] Predicted next UID|};
  [%expect {| (Untagged (State (OK (UIDNEXT 4392) "Predicted next UID"))) |}]

let%expect_test _ =
  parse {|* FLAGS (\Answered \Flagged \Deleted \Seen \Draft)|};
  [%expect {| (Untagged (FLAGS (Answered Flagged Deleted Seen Draft))) |}]

let%expect_test _ =
  parse {|* OK [PERMANENTFLAGS (\Deleted \Seen \*)] Limited|};
  [%expect {|
    (Untagged (State (OK (PERMANENTFLAGS (Deleted Seen Any)) Limited))) |}]

let%expect_test _ =
  parse {|* OK [HIGHESTMODSEQ 715194045007]|};
  [%expect {| (Untagged (State (OK (HIGHESTMODSEQ 715194045007) ""))) |}]

let%expect_test _ =
  parse {|A142 OK [READ-WRITE] SELECT completed|};
  [%expect {| (Tagged A142 (OK READ_WRITE "SELECT completed")) |}]

let%expect_test _ =
  parse {|* 172 EXISTS|};
  [%expect {| (Untagged (EXISTS 172)) |}]

let%expect_test _ =
  parse {|* 1 RECENT|};
  [%expect {| (Untagged (RECENT 1)) |}]

let%expect_test _ =
  parse {|* OK [UNSEEN 12] Message 12 is first unseen|};
  [%expect {| (Untagged (State (OK (UNSEEN 12) "Message 12 is first unseen"))) |}]

let%expect_test _ =
  parse {|* OK [UIDVALIDITY 3857529045] UIDs valid|};
  [%expect {| (Untagged (State (OK (UIDVALIDITY -437438251) "UIDs valid"))) |}]

let%expect_test _ =
  parse {|* OK [UIDNEXT 4392] Predicted next UID|};
  [%expect {| (Untagged (State (OK (UIDNEXT 4392) "Predicted next UID"))) |}]

let%expect_test _ =
  parse {|* FLAGS (\Answered \Flagged \Deleted \Seen \Draft)|};
  [%expect {| (Untagged (FLAGS (Answered Flagged Deleted Seen Draft))) |}]

let%expect_test _ =
  parse {|* OK [PERMANENTFLAGS (\Deleted \Seen \*)] Limited|};
  [%expect {|
    (Untagged (State (OK (PERMANENTFLAGS (Deleted Seen Any)) Limited))) |}]

let%expect_test _ =
  parse {|* OK [NOMODSEQ] Sorry, this mailbox format doesn't support|};
  [%expect {|
    (Untagged (State (OK NOMODSEQ "Sorry, this mailbox format doesn't support"))) |}]

let%expect_test _ =
  parse {|A142 OK [READ-WRITE] SELECT completed|};
  [%expect {| (Tagged A142 (OK READ_WRITE "SELECT completed")) |}]

let%expect_test _ =
  parse {|* 1 FETCH (UID 4 MODSEQ (12121231000))|};
  [%expect {| (Untagged (FETCH 1 ((UID 4) (MODSEQ 12121231000)))) |}]

let%expect_test _ =
  parse {|* 2 FETCH (UID 6 MODSEQ (12121230852))|};
  [%expect {| (Untagged (FETCH 2 ((UID 6) (MODSEQ 12121230852)))) |}]

let%expect_test _ =
  parse {|* 4 FETCH (UID 8 MODSEQ (12121230956))|};
  [%expect {| (Untagged (FETCH 4 ((UID 8) (MODSEQ 12121230956)))) |}]

let%expect_test _ =
  parse {|a103 OK Conditional Store completed|};
  [%expect {| (Tagged a103 (OK NONE "Conditional Store completed")) |}]

let%expect_test _ =
  parse {|* 50 FETCH (MODSEQ (12111230047))|};
  [%expect {| (Untagged (FETCH 50 ((MODSEQ 12111230047)))) |}]

let%expect_test _ =
  parse {|a104 OK Store (conditional) completed|};
  [%expect {| (Tagged a104 (OK NONE "Store (conditional) completed")) |}]

let%expect_test _ =
  parse {|* OK [HIGHESTMODSEQ 12111230047]|};
  [%expect {| (Untagged (State (OK (HIGHESTMODSEQ 12111230047) ""))) |}]

let%expect_test _ =
  parse {|* 50 FETCH (MODSEQ (12111230048))|};
  [%expect {| (Untagged (FETCH 50 ((MODSEQ 12111230048)))) |}]

let%expect_test _ =
  parse {|c101 OK Store (conditional) completed|};
  [%expect {| (Tagged c101 (OK NONE "Store (conditional) completed")) |}]

let%expect_test _ =
  parse {|* 5 FETCH (MODSEQ (320162350))|};
  [%expect {| (Untagged (FETCH 5 ((MODSEQ 320162350)))) |}]

let%expect_test _ =
  parse {|d105 OK [MODIFIED 7,9] Conditional STORE failed|};
  [%expect {| (Tagged d105 (OK (MODIFIED ((7 7) (9 9))) "Conditional STORE failed")) |}]

let%expect_test _ =
  parse {|* 7 FETCH (MODSEQ (320162342) FLAGS (\Seen \Deleted))|};
  [%expect {|
    (Untagged (FETCH 7 ((MODSEQ 320162342) (FLAGS (Seen Deleted))))) |}]

let%expect_test _ =
  parse {|* 5 FETCH (MODSEQ (320162350))|};
  [%expect {| (Untagged (FETCH 5 ((MODSEQ 320162350)))) |}]

let%expect_test _ =
  parse {|* 9 FETCH (MODSEQ (320162349) FLAGS (\Answered))|};
  [%expect {|
    (Untagged (FETCH 9 ((MODSEQ 320162349) (FLAGS (Answered))))) |}]

let%expect_test _ =
  parse {|d105 OK [MODIFIED 7,9] Conditional STORE failed|};
  [%expect {| (Tagged d105 (OK (MODIFIED ((7 7) (9 9))) "Conditional STORE failed")) |}]

let%expect_test _ =
  parse {|a102 OK [MODIFIED 12] Conditional STORE failed|};
  [%expect {| (Tagged a102 (OK (MODIFIED ((12 12))) "Conditional STORE failed")) |}]

let%expect_test _ =
  parse {|* 100 FETCH (MODSEQ (303181230852))|};
  [%expect {| (Untagged (FETCH 100 ((MODSEQ 303181230852)))) |}]

let%expect_test _ =
  parse {|* 102 FETCH (MODSEQ (303181230852))|};
  [%expect {| (Untagged (FETCH 102 ((MODSEQ 303181230852)))) |}]

let%expect_test _ =
  parse {|* 150 FETCH (MODSEQ (303181230852))|};
  [%expect {| (Untagged (FETCH 150 ((MODSEQ 303181230852)))) |}]

let%expect_test _ =
  parse {|a106 OK [MODIFIED 101] Conditional STORE failed|};
  [%expect {| (Tagged a106 (OK (MODIFIED ((101 101))) "Conditional STORE failed")) |}]

let%expect_test _ =
  parse {|* 101 FETCH (MODSEQ (303011130956) FLAGS ($Processed))|};
  [%expect {|
    (Untagged (FETCH 101 ((MODSEQ 303011130956) (FLAGS ((Keyword $Processed)))))) |}]

let%expect_test _ =
  parse {|a107 OK|};
  [%expect {| (Tagged a107 (OK NONE "")) |}]

let%expect_test _ =
  parse {|* 101 FETCH (MODSEQ (303011130956) FLAGS (\Deleted \Answered))|};
  [%expect {|
    (Untagged (FETCH 101 ((MODSEQ 303011130956) (FLAGS (Deleted Answered))))) |}]

let%expect_test _ =
  parse {|b107 OK|};
  [%expect {| (Tagged b107 (OK NONE "")) |}]

let%expect_test _ =
  parse {|* 101 FETCH (MODSEQ (303181230852))|};
  [%expect {| (Untagged (FETCH 101 ((MODSEQ 303181230852)))) |}]

let%expect_test _ =
  parse {|b108 OK Conditional Store completed|};
  [%expect {| (Tagged b108 (OK NONE "Conditional Store completed")) |}]

let%expect_test _ =
  parse {|* 100 FETCH (MODSEQ (303181230852))|};
  [%expect {| (Untagged (FETCH 100 ((MODSEQ 303181230852)))) |}]

let%expect_test _ =
  parse {|* 101 FETCH (MODSEQ (303011130956) FLAGS ($Processed))|};
  [%expect {|
    (Untagged (FETCH 101 ((MODSEQ 303011130956) (FLAGS ((Keyword $Processed)))))) |}]

let%expect_test _ =
  parse {|* 102 FETCH (MODSEQ (303181230852))|};
  [%expect {| (Untagged (FETCH 102 ((MODSEQ 303181230852)))) |}]

let%expect_test _ =
  parse {|* 150 FETCH (MODSEQ (303181230852))|};
  [%expect {| (Untagged (FETCH 150 ((MODSEQ 303181230852)))) |}]

let%expect_test _ =
  parse {|a106 OK [MODIFIED 101] Conditional STORE failed|};
  [%expect {| (Tagged a106 (OK (MODIFIED ((101 101))) "Conditional STORE failed")) |}]

let%expect_test _ =
  parse {|* 100 FETCH (MODSEQ (303181230852))|};
  [%expect {| (Untagged (FETCH 100 ((MODSEQ 303181230852)))) |}]

let%expect_test _ =
  parse {|* 101 FETCH (MODSEQ (303011130956) FLAGS (\Deleted \Answered))|};
  [%expect {|
    (Untagged (FETCH 101 ((MODSEQ 303011130956) (FLAGS (Deleted Answered))))) |}]

let%expect_test _ =
  parse {|* 102 FETCH (MODSEQ (303181230852))|};
  [%expect {| (Untagged (FETCH 102 ((MODSEQ 303181230852)))) |}]

let%expect_test _ =
  parse {|* 150 FETCH (MODSEQ (303181230852))|};
  [%expect {| (Untagged (FETCH 150 ((MODSEQ 303181230852)))) |}]

let%expect_test _ =
  parse {|a106 OK [MODIFIED 101] Conditional STORE failed|};
  [%expect {| (Tagged a106 (OK (MODIFIED ((101 101))) "Conditional STORE failed")) |}]

let%expect_test _ =
  parse {|* 101 FETCH (MODSEQ (303181230852))|};
  [%expect {| (Untagged (FETCH 101 ((MODSEQ 303181230852)))) |}]

let%expect_test _ =
  parse {|b108 OK Conditional Store completed|};
  [%expect {| (Tagged b108 (OK NONE "Conditional Store completed")) |}]

let%expect_test _ =
  parse {|* 100 FETCH (MODSEQ (303181230852))|};
  [%expect {| (Untagged (FETCH 100 ((MODSEQ 303181230852)))) |}]

let%expect_test _ =
  parse {|* 101 FETCH (MODSEQ (303011130956) FLAGS ($Processed \Deleted))|};
  [%expect {|
    (Untagged
     (FETCH 101 ((MODSEQ 303011130956) (FLAGS ((Keyword $Processed) Deleted))))) |}]

let%expect_test _ =
  parse {|* 102 FETCH (MODSEQ (303181230852))|};
  [%expect {| (Untagged (FETCH 102 ((MODSEQ 303181230852)))) |}]

let%expect_test _ =
  parse {|* 150 FETCH (MODSEQ (303181230852))|};
  [%expect {| (Untagged (FETCH 150 ((MODSEQ 303181230852)))) |}]

let%expect_test _ =
  parse {|a106 OK Conditional STORE completed|};
  [%expect {| (Tagged a106 (OK NONE "Conditional STORE completed")) |}]

let%expect_test _ =
  parse {|* 1 FETCH (MODSEQ (320172342) FLAGS (\SEEN))|};
  [%expect {|
    (Untagged (FETCH 1 ((MODSEQ 320172342) (FLAGS (Seen))))) |}]

let%expect_test _ =
  parse {|* 3 FETCH (MODSEQ (320172342) FLAGS (\SEEN))|};
  [%expect {|
    (Untagged (FETCH 3 ((MODSEQ 320172342) (FLAGS (Seen))))) |}]

let%expect_test _ =
  parse {|B001 NO [MODIFIED 2] Some of the messages no longer exist.|};
  [%expect {|
    (Tagged B001 (NO (MODIFIED ((2 2))) "Some of the messages no longer exist.")) |}]

let%expect_test _ =
  parse {|* 4 EXPUNGE|};
  [%expect {| (Untagged (EXPUNGE 4)) |}]

let%expect_test _ =
  parse {|* 4 EXPUNGE|};
  [%expect {| (Untagged (EXPUNGE 4)) |}]

let%expect_test _ =
  parse {|* 4 EXPUNGE|};
  [%expect {| (Untagged (EXPUNGE 4)) |}]

let%expect_test _ =
  parse {|* 4 EXPUNGE|};
  [%expect {| (Untagged (EXPUNGE 4)) |}]

let%expect_test _ =
  parse {|* 2 FETCH (MODSEQ (320172340) FLAGS (\Deleted \Answered))|};
  [%expect {|
    (Untagged (FETCH 2 ((MODSEQ 320172340) (FLAGS (Deleted Answered))))) |}]

let%expect_test _ =
  parse {|B002 OK NOOP Completed.|};
  [%expect {| (Tagged B002 (OK NONE "NOOP Completed.")) |}]

let%expect_test _ =
  parse {|* 2 FETCH (MODSEQ (320180050) FLAGS (\SEEN \Flagged))|};
  [%expect {|
    (Untagged (FETCH 2 ((MODSEQ 320180050) (FLAGS (Seen Flagged))))) |}]

let%expect_test _ =
  parse {|b003 OK Conditional Store completed|};
  [%expect {| (Tagged b003 (OK NONE "Conditional Store completed")) |}]

let%expect_test _ =
  parse {|* 1 FETCH (UID 4 MODSEQ (65402) FLAGS (\Seen))|};
  [%expect {|
    (Untagged (FETCH 1 ((UID 4) (MODSEQ 65402) (FLAGS (Seen))))) |}]

let%expect_test _ =
  parse {|* 2 FETCH (UID 6 MODSEQ (75403) FLAGS (\Deleted))|};
  [%expect {|
    (Untagged (FETCH 2 ((UID 6) (MODSEQ 75403) (FLAGS (Deleted))))) |}]

let%expect_test _ =
  parse {|* 4 FETCH (UID 8 MODSEQ (29738) FLAGS ($NoJunk $AutoJunk))|};
  [%expect {|
    (Untagged
     (FETCH 4
      ((UID 8) (MODSEQ 29738) (FLAGS ((Keyword $NoJunk) (Keyword $AutoJunk)))))) |}]

let%expect_test _ =
  parse {|s100 OK FETCH completed|};
  [%expect {| (Tagged s100 (OK NONE "FETCH completed")) |}]

let%expect_test _ =
  parse {|* 1 FETCH (MODSEQ (624140003))|};
  [%expect {| (Untagged (FETCH 1 ((MODSEQ 624140003)))) |}]

let%expect_test _ =
  parse {|* 2 FETCH (MODSEQ (624140007))|};
  [%expect {| (Untagged (FETCH 2 ((MODSEQ 624140007)))) |}]

let%expect_test _ =
  parse {|* 3 FETCH (MODSEQ (624140005))|};
  [%expect {| (Untagged (FETCH 3 ((MODSEQ 624140005)))) |}]

let%expect_test _ =
  parse {|a OK Fetch complete|};
  [%expect {| (Tagged a (OK NONE "Fetch complete")) |}]

let%expect_test _ =
  parse {|* FLAGS (\Answered \Flagged \Deleted \Seen \Draft)|};
  [%expect {| (Untagged (FLAGS (Answered Flagged Deleted Seen Draft))) |}]

let%expect_test _ =
  parse {|* OK [PERMANENTFLAGS (\Answered \Deleted \Seen \*)] Limited|};
  [%expect {|
    (Untagged (State (OK (PERMANENTFLAGS (Answered Deleted Seen Any)) Limited))) |}]

let%expect_test _ =
  parse {|* 7 FETCH (MODSEQ (2121231000))|};
  [%expect {| (Untagged (FETCH 7 ((MODSEQ 2121231000)))) |}]

let%expect_test _ =
  parse {|A160 OK Store completed|};
  [%expect {| (Tagged A160 (OK NONE "Store completed")) |}]

let%expect_test _ =
  parse {|* 7 FETCH (FLAGS (\Deleted \Answered) MODSEQ (12121231000))|};
  [%expect {|
    (Untagged (FETCH 7 ((FLAGS (Deleted Answered)) (MODSEQ 12121231000)))) |}]

let%expect_test _ =
  parse {|C180 OK Noop completed|};
  [%expect {| (Tagged C180 (OK NONE "Noop completed")) |}]

let%expect_test _ =
  parse {|* 7 FETCH (FLAGS (\Deleted \Answered) MODSEQ (12121231000))|};
  [%expect {|
    (Untagged (FETCH 7 ((FLAGS (Deleted Answered)) (MODSEQ 12121231000)))) |}]

let%expect_test _ =
  parse {|D210 OK Noop completed|};
  [%expect {| (Tagged D210 (OK NONE "Noop completed")) |}]

let%expect_test _ =
  parse {|* 7 FETCH (MODSEQ (12121231777))|};
  [%expect {| (Untagged (FETCH 7 ((MODSEQ 12121231777)))) |}]

let%expect_test _ =
  parse {|A240 OK Store completed|};
  [%expect {| (Tagged A240 (OK NONE "Store completed")) |}]

let%expect_test _ =
  parse {|* 7 FETCH (FLAGS (\Deleted \Answered \Seen) MODSEQ (12))|};
  [%expect {|
    (Untagged (FETCH 7 ((FLAGS (Deleted Answered Seen)) (MODSEQ 12)))) |}]

let%expect_test _ =
  parse {|C270 OK Noop completed|};
  [%expect {| (Tagged C270 (OK NONE "Noop completed")) |}]

let%expect_test _ =
  parse {|D300 OK Noop completed|};
  [%expect {| (Tagged D300 (OK NONE "Noop completed")) |}]

let%expect_test _ =
  parse {|* 7 FETCH (MODSEQ (12121245160))|};
  [%expect {| (Untagged (FETCH 7 ((MODSEQ 12121245160)))) |}]

let%expect_test _ =
  parse {|A330 OK Store completed|};
  [%expect {| (Tagged A330 (OK NONE "Store completed")) |}]

let%expect_test _ =
  parse {|* 7 FETCH (FLAGS (\Deleted) MODSEQ (12121245160))|};
  [%expect {|
    (Untagged (FETCH 7 ((FLAGS (Deleted)) (MODSEQ 12121245160)))) |}]

let%expect_test _ =
  parse {|C360 OK Noop completed|};
  [%expect {| (Tagged C360 (OK NONE "Noop completed")) |}]

let%expect_test _ =
  parse {|* 7 FETCH (FLAGS (\Deleted) MODSEQ (12121245160))|};
  [%expect {|
    (Untagged (FETCH 7 ((FLAGS (Deleted)) (MODSEQ 12121245160)))) |}]

let%expect_test _ =
  parse {|D390 OK Noop completed|};
  [%expect {| (Tagged D390 (OK NONE "Noop completed")) |}]

let%expect_test _ =
  parse {|* SEARCH 2 5 6 7 11 12 18 19 20 23 (MODSEQ 917162500)|};
  [%expect {| (Untagged (SEARCH (2 5 6 7 11 12 18 19 20 23) (917162500))) |}]

let%expect_test _ =
  parse {|a OK Search complete|};
  [%expect {| (Tagged a (OK NONE "Search complete")) |}]

let%expect_test _ =
  parse {|* SEARCH|};
  [%expect {| (Untagged (SEARCH () ())) |}]

let%expect_test _ =
  parse {|t OK Search complete, nothing found|};
  [%expect {| (Tagged t (OK NONE "Search complete, nothing found")) |}]

let%expect_test _ =
  parse {|* STATUS blurdybloop (MESSAGES 231 UIDNEXT 44292)|};
  [%expect {| (Untagged (STATUS blurdybloop ((MESSAGES 231) (UIDNEXT 44292)))) |}]

let%expect_test _ =
  parse {|A042 OK STATUS completed|};
  [%expect {| (Tagged A042 (OK NONE "STATUS completed")) |}]

let%expect_test _ =
  parse {|* 172 EXISTS|};
  [%expect {| (Untagged (EXISTS 172)) |}]

let%expect_test _ =
  parse {|* 1 RECENT|};
  [%expect {| (Untagged (RECENT 1)) |}]

let%expect_test _ =
  parse {|* OK [UNSEEN 12] Message 12 is first unseen|};
  [%expect {| (Untagged (State (OK (UNSEEN 12) "Message 12 is first unseen"))) |}]

let%expect_test _ =
  parse {|* OK [UIDVALIDITY 3857529045] UIDs valid|};
  [%expect {| (Untagged (State (OK (UIDVALIDITY -437438251) "UIDs valid"))) |}]

let%expect_test _ =
  parse {|* OK [UIDNEXT 4392] Predicted next UID|};
  [%expect {| (Untagged (State (OK (UIDNEXT 4392) "Predicted next UID"))) |}]

let%expect_test _ =
  parse {|* FLAGS (\Answered \Flagged \Deleted \Seen \Draft)|};
  [%expect {| (Untagged (FLAGS (Answered Flagged Deleted Seen Draft))) |}]

let%expect_test _ =
  parse {|* OK [PERMANENTFLAGS (\Deleted \Seen \*)] Limited|};
  [%expect {|
    (Untagged (State (OK (PERMANENTFLAGS (Deleted Seen Any)) Limited))) |}]

let%expect_test _ =
  parse {|* OK [HIGHESTMODSEQ 715194045007]|};
  [%expect {| (Untagged (State (OK (HIGHESTMODSEQ 715194045007) ""))) |}]

let%expect_test _ =
  parse {|A142 OK [READ-WRITE] SELECT completed, CONDSTORE is now enabled|};
  [%expect {| (Tagged A142 (OK READ_WRITE "SELECT completed, CONDSTORE is now enabled")) |}]

let%expect_test _ =
  parse {|* ESEARCH (TAG "a") ALL 1:3,5 MODSEQ 1236|};
  [%expect {|
    Parsing error:
    * ESEARCH (TAG "a") ALL 1:3,5 MODSEQ 1236
             ^ |}]

let%expect_test _ =
  parse {|a OK Extended SEARCH completed|};
  [%expect {| (Tagged a (OK NONE "Extended SEARCH completed")) |}]

let%expect_test _ =
  parse {|* ESEARCH (TAG "a") ALL 5,3,2,1 MODSEQ 1236|};
  [%expect {|
    Parsing error:
    * ESEARCH (TAG "a") ALL 5,3,2,1 MODSEQ 1236
             ^ |}]

let%expect_test _ =
  parse {|a OK Extended SORT completed|};
  [%expect {| (Tagged a (OK NONE "Extended SORT completed")) |}]

let%expect_test _ =
  parse {|* 101 FETCH (MODSEQ (303011130956) FLAGS ($Processed \Deleted))|};
  [%expect {|
    (Untagged
     (FETCH 101 ((MODSEQ 303011130956) (FLAGS ((Keyword $Processed) Deleted))))) |}]

let%expect_test _ =
  parse {|* 464 EXISTS|};
  [%expect {| (Untagged (EXISTS 464)) |}]

let%expect_test _ =
  parse {|* 3 RECENT|};
  [%expect {| (Untagged (RECENT 3)) |}]

let%expect_test _ =
  parse {|* OK [UIDVALIDITY 3857529045] UIDVALIDITY|};
  [%expect {| (Untagged (State (OK (UIDVALIDITY -437438251) UIDVALIDITY))) |}]

let%expect_test _ =
  parse {|* OK [UIDNEXT 550] Predicted next UID|};
  [%expect {| (Untagged (State (OK (UIDNEXT 550) "Predicted next UID"))) |}]

let%expect_test _ =
  parse {|* OK [HIGHESTMODSEQ 90060128194045007] Highest mailbox|};
  [%expect {| (Untagged (State (OK (HIGHESTMODSEQ 90060128194045007) "Highest mailbox"))) |}]

let%expect_test _ =
  parse {|* OK [UNSEEN 12] Message 12 is first unseen|};
  [%expect {| (Untagged (State (OK (UNSEEN 12) "Message 12 is first unseen"))) |}]

let%expect_test _ =
  parse {|* FLAGS (\Answered \Flagged \Draft \Deleted \Seen)|};
  [%expect {| (Untagged (FLAGS (Answered Flagged Draft Deleted Seen))) |}]

let%expect_test _ =
  parse {|* OK [PERMANENTFLAGS (\Answered \Flagged \Draft)]|};
  [%expect {|
    (Untagged (State (OK (PERMANENTFLAGS (Answered Flagged Draft)) ""))) |}]

let%expect_test _ =
  parse {|A02 OK [READ-WRITE] Sorry, UIDVALIDITY mismatch|};
  [%expect {| (Tagged A02 (OK READ_WRITE "Sorry, UIDVALIDITY mismatch")) |}]

let%expect_test _ =
  parse {|* OK [CLOSED]|};
  [%expect {| (Untagged (State (OK CLOSED ""))) |}]

let%expect_test _ =
  parse {|* 100 EXISTS|};
  [%expect {| (Untagged (EXISTS 100)) |}]

let%expect_test _ =
  parse {|* 11 RECENT|};
  [%expect {| (Untagged (RECENT 11)) |}]

let%expect_test _ =
  parse {|* OK [UIDVALIDITY 67890007] UIDVALIDITY|};
  [%expect {| (Untagged (State (OK (UIDVALIDITY 67890007) UIDVALIDITY))) |}]

let%expect_test _ =
  parse {|* OK [UIDNEXT 600] Predicted next UID|};
  [%expect {| (Untagged (State (OK (UIDNEXT 600) "Predicted next UID"))) |}]

let%expect_test _ =
  parse {|* OK [HIGHESTMODSEQ 90060115205545359] Highest|};
  [%expect {| (Untagged (State (OK (HIGHESTMODSEQ 90060115205545359) Highest))) |}]

let%expect_test _ =
  parse {|* OK [UNSEEN 7] There are some unseen|};
  [%expect {| (Untagged (State (OK (UNSEEN 7) "There are some unseen"))) |}]

let%expect_test _ =
  parse {|* FLAGS (\Answered \Flagged \Draft \Deleted \Seen)|};
  [%expect {| (Untagged (FLAGS (Answered Flagged Draft Deleted Seen))) |}]

let%expect_test _ =
  parse {|* OK [PERMANENTFLAGS (\Answered \Flagged \Draft)]|};
  [%expect {|
    (Untagged (State (OK (PERMANENTFLAGS (Answered Flagged Draft)) ""))) |}]

let%expect_test _ =
  parse {|* VANISHED (EARLIER) 41,43:116,118,120:211,214:540|};
  [%expect {|
    (Untagged
     (VANISHED_EARLIER ((41 41) (43 116) (118 118) (120 211) (214 540)))) |}]

let%expect_test _ =
  parse {|* 49 FETCH (UID 117 FLAGS (\Seen \Answered) MODSEQ (12111230047))|};
  [%expect {|
    (Untagged
     (FETCH 49 ((UID 117) (FLAGS (Seen Answered)) (MODSEQ 12111230047)))) |}]

let%expect_test _ =
  parse {|* 50 FETCH (UID 119 FLAGS (\Draft $MDNSent) MODSEQ (12111230047))|};
  [%expect {|
    (Untagged
     (FETCH 50
      ((UID 119) (FLAGS (Draft (Keyword $MDNSent))) (MODSEQ 12111230047)))) |}]

let%expect_test _ =
  parse {|* 51 FETCH (UID 541 FLAGS (\Seen $Forwarded) MODSEQ (12111230047))|};
  [%expect {|
    (Untagged
     (FETCH 51
      ((UID 541) (FLAGS (Seen (Keyword $Forwarded))) (MODSEQ 12111230047)))) |}]

let%expect_test _ =
  parse {|A03 OK [READ-WRITE] mailbox selected|};
  [%expect {| (Tagged A03 (OK READ_WRITE "mailbox selected")) |}]

let%expect_test _ =
  parse {|* 10003 EXISTS|};
  [%expect {| (Untagged (EXISTS 10003)) |}]

let%expect_test _ =
  parse {|* 4 RECENT|};
  [%expect {| (Untagged (RECENT 4)) |}]

let%expect_test _ =
  parse {|* OK [UIDVALIDITY 67890007] UIDVALIDITY|};
  [%expect {| (Untagged (State (OK (UIDVALIDITY 67890007) UIDVALIDITY))) |}]

let%expect_test _ =
  parse {|* OK [UIDNEXT 30013] Predicted next UID|};
  [%expect {| (Untagged (State (OK (UIDNEXT 30013) "Predicted next UID"))) |}]

let%expect_test _ =
  parse {|* OK [HIGHESTMODSEQ 90060115205545359] Highest mailbox|};
  [%expect {| (Untagged (State (OK (HIGHESTMODSEQ 90060115205545359) "Highest mailbox"))) |}]

let%expect_test _ =
  parse {|* OK [UNSEEN 7] There are some unseen messages in the mailbox|};
  [%expect {|
    (Untagged
     (State (OK (UNSEEN 7) "There are some unseen messages in the mailbox"))) |}]

let%expect_test _ =
  parse {|* FLAGS (\Answered \Flagged \Draft \Deleted \Seen)|};
  [%expect {| (Untagged (FLAGS (Answered Flagged Draft Deleted Seen))) |}]

let%expect_test _ =
  parse {|* OK [PERMANENTFLAGS (\Answered \Flagged \Draft)]|};
  [%expect {|
    (Untagged (State (OK (PERMANENTFLAGS (Answered Flagged Draft)) ""))) |}]

let%expect_test _ =
  parse {|* VANISHED (EARLIER) 1:2,4:5,7:8,10:11,13:14,89|};
  [%expect {| (Untagged (VANISHED_EARLIER ((1 2) (4 5) (7 8) (10 11) (13 14) (89 89)))) |}]

let%expect_test _ =
  parse {|* 1 FETCH (UID 3 FLAGS (\Seen \Answered $Important) MODSEQ (90060115194045027))|};
  [%expect {|
    (Untagged
     (FETCH 1
      ((UID 3) (FLAGS (Seen Answered (Keyword $Important)))
       (MODSEQ 90060115194045027)))) |}]

let%expect_test _ =
  parse {|* OK [BADCHARSET ({10}
holachau12 {3}
abc)]|};
  [%expect {|
    (Untagged (State (OK (BADCHARSET (holachau12 abc)) ""))) |}]

let%expect_test _ =
  parse {|* 1 FETCH (BODYSTRUCTURE (("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 274 5 NIL NIL NIL)("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" 1916 11 NIL NIL NIL) "ALTERNATIVE" ("BOUNDARY" "--==_mimepart_58c9502f27460_5ee23f9b5d4edc381239aa" "CHARSET" "UTF-8") NIL NIL))|};
  [%expect {|
    Parsing error:
    * 1 FETCH (BODYSTRUCTURE (("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 274 5 NIL NIL NIL)("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" 1916 11 NIL NIL NIL) "ALTERNATIVE" ("BOUNDARY" "--==_mimepart_58c9502f27460_5ee23f9b5d4edc381239aa" "CHARSET" "UTF-8") NIL NIL))
                                                                                                                                                                                                                                                                           ^ |}]
