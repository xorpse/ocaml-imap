(* The MIT License (MIT)

   Copyright (c) 2014 Nicolas Ojeda Bar <n.oje.bar@gmail.com>

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

let (>>=) = Lwt.bind

module Lwtio = struct
  type 'a t = 'a Lwt.t
  let bind = Lwt.bind
  let return = Lwt.return
  let fail = Lwt.fail
  let catch = Lwt.catch
  type mutex = Lwt_mutex.t
  let create_mutex = Lwt_mutex.create
  let is_locked = Lwt_mutex.is_locked
  let with_lock = Lwt_mutex.with_lock
  type input = Lwt_io.input_channel
  type output = Lwt_io.output_channel
  let read_line = Lwt_io.read_line
  let read_exactly ic len =
    let buf = String.create len in
    Lwt_io.read_into_exactly ic buf 0 len >>= fun () ->
    Lwt.return buf
  let write = Lwt_io.write
  let flush = Lwt_io.flush
end

include Imap.Make (Lwtio)

let default_ssl_context =
  let () = Ssl.init () in
  let ctx = Ssl.create_context Ssl.TLSv1 Ssl.Client_context in
  Ssl.set_verify ctx [Ssl.Verify_peer] None;
  ctx

let default_ssl_port = 993

let connect_simple s ?(port=default_ssl_port) host =
  let fd = Lwt_unix.socket Unix.PF_INET Unix.SOCK_DGRAM 0 in
  Lwt_unix.gethostbyname host >>= fun he ->
  Lwt_unix.connect fd (Unix.ADDR_INET (he.Unix.h_addr_list.(0), port)) >>= fun () ->
  Lwt_ssl.ssl_connect fd default_ssl_context >>= fun ssl_sock ->
  let ic = Lwt_ssl.in_channel_of_descr ssl_sock in
  let oc = Lwt_ssl.out_channel_of_descr ssl_sock in
  connect s (ic, oc)

(* let compress s = *)
(*   let aux (ic, oc) = *)
(*     let low = Lwtio.get_low ic in *)
(*     let low = Lwtio.Low.compress low in *)
(*     Lwtio.set_low ic low; *)
(*     Lwtio.set_low oc low; *)
(*     Lwt.return (ic, oc) *)
(*   in *)
(*   compress s aux *)

(* let starttls ?ssl_context s = *)
(*   let aux (ic, oc) = *)
(*     let fd = match Lwtio.Low.get_fd (Lwtio.get_low ic) with *)
(*       | None -> failwith "starttls: no file descriptor" *)
(*       | Some fd -> fd *)
(*     in *)
(*     let low, connect = Lwtio.Low.open_tls ?ssl_context fd in *)
(*     connect () >>= fun () -> *)
(*     Lwtio.set_low ic low; *)
(*     Lwtio.set_low oc low; *)
(*     Lwt.return (ic, oc) *)
(*   in *)
(*   starttls s aux *)