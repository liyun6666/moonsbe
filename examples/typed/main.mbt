///|
/// A separate consumer package uses generated records and enums directly.
fn main raise {
  let args = @env.args()[2:].to_owned()
  guard args.length() == 2 else { abort("usage: INPUT.bin OUTPUT.bin") }
  let car = @car.Car::decode(@fs.read_file_to_bytes(args[0]))
  assert_eq(car.f_serial_number, 1234UL)
  assert_eq(car.f_available, @car.T)
  assert_eq(car.f_code, @car.A)
  assert_eq(car.f_engine.f_booster.f_boost_type, @car.NITROUS)
  assert_eq(car.f_fuel_figures.length(), 3)
  assert_eq(car.f_performance_figures[1].f_acceleration.length(), 3)
  assert_eq(car.f_manufacturer, "Honda")
  assert_eq(car.f_activation_code, "abcdef")
  let bytes = car.encode()
  @fs.write_bytes_to_file(args[1], bytes)
  println("Typed generated consumer passed: \{bytes.length()} bytes")
}
