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

open Lwt.Infix

type acc =
  {
    host: string;
    port: int option;
    username: string;
    password: string;
  }

type mb =
  {
    account: acc;
    mutable mailbox: string;
  }

let connect {account = {host; port; username; password}; _} =
  Core.connect ~host ?port ~username ~password

let mailbox {mailbox; _} =
  mailbox

class message rep uid =
  object (self)
    method fetch_headers =
      connect self # rep >>= fun imap ->
      Core.examine imap (mailbox self # rep) >>= fun () ->
      let strm = Core.uid_fetch imap [uid] [Fetch.Request.rfc822_header] in
      Lwt_stream.next strm >|= fun (_, {Fetch.Response.rfc822_header; _}) ->
      let parts = Re.split Re.(compile (str "\r\n")) rfc822_header in
      let parts = List.filter (function "" -> false | _ -> true) parts in
      let rec loop acc curr = function
        | s :: rest ->
            if s.[0] = '\t' || s.[0] = ' ' then
              loop acc (curr ^ " " ^ String.trim s) rest
            else
              loop (curr :: acc) (String.trim s) rest
        | [] ->
            if curr <> "" then
              List.rev (curr :: acc)
            else
              List.rev acc
      in
      let parts = loop [] "" parts in
      let parts = List.filter (function "" -> false | _ -> true) parts in
      (* List.iter (fun s -> Printf.eprintf "%S\n%!" s) parts; *)
      List.map (fun part ->
          let i =
            match String.index part ':' with
            | i -> i
            | exception Not_found -> String.length part
          in
          String.trim (String.sub part 0 i),
          String.trim (String.sub part (i+1) (String.length part - i - 1))
        ) parts

    method fetch_body =
      connect rep >>= fun imap ->
      Core.examine imap (mailbox rep) >>= fun () ->
      let strm = Core.uid_fetch imap [uid] [Fetch.Request.rfc822] in
      Lwt_stream.next strm >>= fun (_, {Fetch.Response.rfc822; _}) ->
      Lwt.return rfc822

    method rep = rep
  end

class message_set rep query =
  object (self)
    method count =
      connect rep >>= fun imap ->
      Core.examine imap (mailbox rep) >>= fun () ->
      Core.uid_search imap query >|= fun (uids, _) ->
      List.length uids

    method get uid =
      new message rep uid

    method uids =
      connect rep >>= fun imap ->
      Core.examine imap (mailbox rep) >>= fun () ->
      Core.uid_search imap query >|= fun (uids, _) ->
      uids

    method contain_from s =
      new message_set rep Search.(query && from s)

    method is_unseen =
      new message_set rep Search.(query && unseen)

    method copy (dst : mailbox) =
      connect rep >>= fun src_imap ->
      connect dst # rep >>= fun dst_imap ->
      Core.examine src_imap (mailbox self # rep) >>= fun () ->
      Core.select dst_imap (mailbox dst # rep) >>= fun () ->
      Core.uid_search src_imap query >>= fun (uids, _) ->
      let strm = Core.uid_fetch src_imap uids Fetch.Request.[rfc822; flags; internaldate] in
      Lwt_stream.iter_s (fun (_, {Fetch.Response.internaldate; flags; rfc822; _}) ->
          Core.append dst_imap (dst # name) ~flags ~internaldate rfc822
        ) strm

    method rep = rep
  end

and mailbox account mailbox =
  let rep = {account; mailbox} in
  object
    inherit message_set rep Search.all
    method name = mailbox
  end

class account ~host ?port ~username ~password () =
  let acc = {host; port; username; password} in
  object
    method inbox = new mailbox acc "INBOX"
    method list_all =
      let mk (_, _, name) = new mailbox acc name in
      Core.connect ~host ?port ~username ~password >>= fun imap ->
      Core.list imap "%" >|= List.map mk
  end