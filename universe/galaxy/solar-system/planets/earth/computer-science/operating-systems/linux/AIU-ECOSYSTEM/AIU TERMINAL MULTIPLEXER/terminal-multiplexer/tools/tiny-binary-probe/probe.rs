// probe.rs -- the tiny binary the route decision rests on (D-002).
//
// One job: start, and say so. It is deliberately the smallest program
// that can be a real binary: no library, no dependency, nothing to
// measure but the start itself.
//
// The numbers this program produces are written down in
// research/tiny-binary-probe.org, and they decide one thing: whether
// the phone can BUILD the holder itself (the own route) or whether the
// holder has to be adopted (the adopt route). A probe that is not
// measured is a guess, and a guess about the phone's build cost is how
// a session loses an hour.

fn main() {
    println!("probe: the binary starts");
}
