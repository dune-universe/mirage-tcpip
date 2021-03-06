open Common
module Time = Vnetif_common.Time
module B = Vnetif_backends.Basic
module V = Vnetif.Make(B)
module E = Ethernet.Make(V)

module Ipv6 = Ipv6.Make(E)(Mirage_random_test)(Time)(Mclock)
module Udp = Udp.Make(Ipv6)(Mirage_random_test)
open Lwt.Infix

let ip =
  let module M = struct
    type t = Ipaddr.V6.t
    let pp = Ipaddr.V6.pp
    let equal p q = (Ipaddr.V6.compare p q) = 0
  end in
  (module M : Alcotest.TESTABLE with type t = M.t)

type stack = {
  backend : B.t;
  netif : V.t;
  ethif : E.t;
  ip : Ipv6.t;
  udp : Udp.t
}

let get_stack backend address =
  let ip = [address] in
  let netmask = [Ipaddr.V6.Prefix.make 24 address] in
  let gateways = [] in
  Mclock.connect () >>= fun clock ->
  V.connect backend >>= fun netif ->
  E.connect netif >>= fun ethif ->
  Ipv6.connect ~ip ~netmask ~gateways ethif clock >>= fun ip ->
  Udp.connect ip >>= fun udp ->
  Lwt.return { backend; netif; ethif; ip; udp }

let noop = fun ~src:_ ~dst:_ _ -> Lwt.return_unit

let listen ?(tcp = noop) ?(udp = noop) ?(default = noop) stack =
  V.listen stack.netif
    ( E.input stack.ethif
      ~arpv4:(fun _ -> Lwt.return_unit)
      ~ipv4:(fun _ -> Lwt.return_unit)
      ~ipv6:(
        Ipv6.input stack.ip
          ~tcp:tcp
          ~udp:udp
          ~default:(fun ~proto:_ -> default))) >>= fun _ -> Lwt.return_unit

let udp_message = Cstruct.of_string "hello on UDP over IPv6"

let check_for_one_udp_packet netif on_received_one ~src ~dst buf =
  Alcotest.(check ip) "sender address" (Ipaddr.V6.of_string_exn "fc00::23") src;
  Alcotest.(check ip) "receiver address" (Ipaddr.V6.of_string_exn "fc00::45") dst;
  (match Udp_packet.Unmarshal.of_cstruct buf with
  | Ok (_, payload) ->
    Alcotest.(check cstruct) "payload is correct" udp_message payload
  | Error m -> Alcotest.fail m);
  (try Lwt.wakeup_later on_received_one () with _ -> () (* the first succeeds, the rest raise *));
  (*after receiving 1 packet, disconnect stack so test can continue*)
  V.disconnect netif

let send_forever sender receiver_address udp_message =
  let rec loop () =
    Printf.fprintf stderr "Udp.write\n%!";
    Udp.write sender.udp ~dst:receiver_address ~dst_port:1234 udp_message
    >|= Rresult.R.get_ok >>= fun () ->
    Time.sleep_ns (Duration.of_ms 50) >>= fun () ->
    loop () in
  loop ()

let pass_udp_traffic () =
  let sender_address = Ipaddr.V6.of_string_exn "fc00::23" in
  let receiver_address = Ipaddr.V6.of_string_exn "fc00::45" in
  let backend = B.create () in
  get_stack backend sender_address >>= fun sender ->
  get_stack backend receiver_address >>= fun receiver ->
  let received_one, on_received_one = Lwt.task () in
  Lwt.pick [
    listen receiver ~udp:(check_for_one_udp_packet receiver.netif on_received_one);
    listen sender;
    send_forever sender receiver_address udp_message;
    received_one; (* stop on the first packet *)
      Time.sleep_ns (Duration.of_ms 3000) >>= fun () ->
      Alcotest.fail "UDP packet should have been received";
  ]

let suite = [
  "Send a UDP packet from one IPV6 stack and check it is received by another", `Quick, pass_udp_traffic;
]
