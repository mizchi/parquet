///|
fn main {
  @playground.run_playground([], [], [], [], [], "", on_done=fn(_) { () })
  abort("playground bridge is only available on the JS target")
}
