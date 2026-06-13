///|
enum DecimalSign {
  Positive
  Negative
  NaN
  PosInfinity
  NegInfinity
} derive(Eq, Show, Debug)

///|
struct PgDecimal {
  sign : DecimalSign
  weight : Int // Int16 range in practice
  dscale : Int // Int16 range in practice (>= 0)
  digits : Array[Int] // each entry in 0..=9999
} derive(Show, Debug)

///|
pub impl @pgclient.ToSql for PgDecimal with format(_, _) {
  @pgclient.WireFormat::Binary
}

///|
pub impl @pgclient.ToSql for PgDecimal with accepts(_, type_) {
  type_.oid == NUMERIC_OID
}

///|
pub impl @pgclient.ToSql for PgDecimal with moonbit_type_name(_) {
  "PgDecimal"
}

///|
pub impl @pgclient.ToSql for PgDecimal with to_sql(self, _, buf) {
  //(Int, Int, Int, Int, Array[Int])
  let (ndigits, weight, sign_raw, dscale, digits) = match self.sign {
    NaN => (0, 0, SIGN_NAN, 0, [])
    PosInfinity => (0, 0, SIGN_PINF, 0, [])
    NegInfinity => (0, 0, SIGN_NINF, 0, [])
    Positive =>
      (self.digits.length(), self.weight, SIGN_POS, self.dscale, self.digits)
    Negative =>
      (self.digits.length(), self.weight, SIGN_NEG, self.dscale, self.digits)
  }
  buf.write_int16_be(Int16::from_int(ndigits))
  buf.write_int16_be(Int16::from_int(weight))
  buf.write_int16_be(Int16::from_int(sign_raw))
  buf.write_int16_be(Int16::from_int(dscale))
  for i = 0; i < digits.length(); i = i + 1 {
    buf.write_int16_be(Int16::from_int(digits[i]))
  }
  No
}

///|
pub impl @pgclient.FromSql for PgDecimal with accepts(type_) {
  type_.oid == NUMERIC_OID
}

///|
pub impl @pgclient.FromSql for PgDecimal with moonbit_type_name() {
  "PgDecimal"
}

///|
pub impl @pgclient.FromSql for PgDecimal with from_sql(_, format, raw) {
  match format {
    @pgclient.WireFormat::Binary => {
      if raw.length() < 8 {
        raise UnexpectedNullorInvalid(
          "PgDecimal -> @Decimal.Decimal. Raw bytes - \{raw}",
        )
      }
      let (ndigits, weight, sign_raw, dscale, digit_bytes) = match raw {
        [
          i16be(ndigits),
          i16be(weight),
          i16be(sign),
          i16be(dscale),
          .. digit_bytes,
        ] => (ndigits, weight, sign, dscale, digit_bytes)
        _ =>
          raise UnexpectedNullorInvalid(
            "PgDecimal -> @Decimal.Decimal. Raw bytes - \{raw}",
          )
      }

      let sign : DecimalSign = match sign_raw {
        SIGN_POS => Positive
        SIGN_NEG => Negative
        SIGN_NAN => NaN
        SIGN_PINF => PosInfinity
        SIGN_NINF => NegInfinity
        _other =>
          raise UnexpectedNullorInvalid(
            "PgDecimal -> @Decimal.Decimal. Raw bytes - \{raw}",
          )
      }
      if sign == NaN || sign == PosInfinity || sign == NegInfinity {
        return PgDecimal::{ sign, weight: 0, dscale: 0, digits: [] }
      }

      let digits = parse_numeric_digits(digit_bytes, ndigits, [])

      return PgDecimal::{ sign, weight, dscale, digits }
    }
    _ =>
      raise UnexpectedNullorInvalid(
        "PgDecimal -> @Decimal.Decimal. Raw bytes - \{raw}",
      )
  }
}

///|
fn parse_numeric_digits(
  bytes : BytesView,
  count : Int,
  acc : Array[Int],
) -> Array[Int] raise {
  if count == 0 {
    return acc
  }

  match bytes {
    [i16be(digit), .. rest] =>
      parse_numeric_digits(rest, count - 1, [..acc, digit])
    _ => fail("Invalid numeric digit array")
  }
}

///|
const SIGN_POS : Int = 0x0000

///|
const SIGN_NEG : Int = 0x4000

///|
const SIGN_NAN : Int = 0xC000

///|
const SIGN_PINF : Int = 0xD000

///|
const SIGN_NINF : Int = 0xF000

///|
pub fn PgDecimal::to_string(pg : PgDecimal) -> String {
  match pg.sign {
    NaN => return "NaN"
    PosInfinity => return "Infinity"
    NegInfinity => return "-Infinity"
    _ => ()
  }

  if pg.digits.is_empty() {
    return if pg.sign == Negative { "-0" } else { "0" }
  }

  let out = StringBuilder::new()

  if pg.sign == Negative {
    out.write_string("-")
  }

  let groups_before_decimal = pg.weight + 1

  // Integer part
  if groups_before_decimal <= 0 {
    out.write_string("0")
  } else {
    for i = 0; i < groups_before_decimal; i = i + 1 {
      let group = if i < pg.digits.length() { pg.digits[i] } else { 0 }

      if i == 0 {
        out.write_string(group.to_string())
      } else {
        out.write_string(group.to_string().pad_start(4, '0'))
      }
    }
  }

  // Fractional part
  if pg.dscale > 0 {
    out.write_string(".")

    let frac = StringBuilder::new()

    if groups_before_decimal < 0 {
      for i = 0; i < -groups_before_decimal; i = i + 1 {
        frac.write_string("0000")
      }

      for digit in pg.digits {
        frac.write_string(digit.to_string().pad_start(4, '0'))
      }
    } else {
      let start = if groups_before_decimal > pg.digits.length() {
        pg.digits.length()
      } else {
        groups_before_decimal
      }

      for i = start; i < pg.digits.length(); i = i + 1 {
        frac.write_string(pg.digits[i].to_string().pad_start(4, '0'))
      }
    }

    let frac_text = frac.to_string().pad_end(pg.dscale, '0')

    out.write_string(frac_text[0:pg.dscale].to_owned())
  }

  out.to_string()
}

///|
/// Parse a decimal string (e.g. `"123.45"`, `"-0.001"`, `"NaN"`) into a
/// `PgDecimal`.
///
fn PgDecimal::from_string(s : String) -> PgDecimal raise {
  let s = s.trim()

  match s {
    "NaN" | "nan" => return { sign: NaN, weight: 0, dscale: 0, digits: [] }
    "Infinity" | "+Infinity" | "inf" | "+inf" =>
      return { sign: PosInfinity, weight: 0, dscale: 0, digits: [] }
    "-Infinity" | "-inf" =>
      return { sign: NegInfinity, weight: 0, dscale: 0, digits: [] }
    _ => ()
  }

  let (sign, unsigned) = match s[0:1] {
    "-" => (Negative, s[1:])
    "+" => (Negative, s[1:])
    _ => (Positive, s)
  }

  let (int_part, frac_part) = match unsigned.split(".").to_array() {
    [i] => (i, "")
    [i, f] => (i, f.to_owned())
    _ => fail("Invalid decimal")
  }

  let dscale = frac_part.length()

  // Integer groups (left padded)
  let int_groups = if int_part == "" {
    []
  } else {
    decimal_to_base10000_left(int_part)
  }

  // Fraction groups (right padded)
  let frac_groups = if frac_part == "" {
    []
  } else {
    decimal_to_base10000_right(frac_part)
  }

  let all_digits = int_groups + frac_groups

  // Find first non-zero group
  let mut first = 0
  while first < all_digits.length() && all_digits[first] == 0 {
    first = first + 1
  }

  if first == all_digits.length() {
    return { sign: Positive, weight: 0, dscale, digits: [] }
  }

  // Find last non-zero group
  let mut last = all_digits.length() - 1
  while last >= first && all_digits[last] == 0 {
    last = last - 1
  }

  let digits = all_digits[first:last + 1].to_owned()

  let weight = int_groups.length() - first - 1

  { sign, weight, dscale, digits }
}

///|
fn decimal_to_base10000_left(s : StringView) -> Array[Int] raise {
  let pad = (4 - s.length() % 4) % 4
  let padded = "0".repeat(pad) + s.to_owned()

  let result = []

  for i = 0; i < padded.length(); i = i + 4 {
    result.push(@string.parse_int(padded[i:i + 4]))
  }

  result
}

///|
fn decimal_to_base10000_right(s : StringView) -> Array[Int] raise {
  let pad = (4 - s.length() % 4) % 4
  let padded = s + "0".repeat(pad)

  let result = []

  for i = 0; i < padded.length(); i = i + 4 {
    result.push(@string.parse_int(padded[i:i + 4]))
  }

  result
}

///|
pub fn PgDecimal::of_decimal(s : @decimal.Decimal) -> PgDecimal raise {
  s.to_string() |> PgDecimal::from_string()
}

///|
pub fn PgDecimal::to_decimal(self : Self) -> @decimal.Decimal raise {
  match @decimal.Decimal::from_string(self.to_string()) {
    Some(decimal) => decimal
    _ => fail("Invalid decimal string")
  }
}

///|
test "pg_decimal roundtrip" {
  let cases = [
    "0", "1", "-1", "123.45", "-123.45", "12345678.90", "0.0012", "0.00000012", "0.000000000123",
    "-0.00000012", "999999999999999999999999999999.999999999999", "10000", "100000000",
    "1.0000", "0.0001", "0.0000000000000001",
  ]

  for text in cases {
    let pg = PgDecimal::from_string(text)
    let roundtrip = PgDecimal::to_string(pg)

    assert_eq(roundtrip, text)
  }
}

///|
test "negative weight roundtrip" {
  let text = "0.00000012"

  let pg = PgDecimal::from_string(text)

  assert_eq(pg.weight, -2)
  assert_eq(pg.digits, [12])

  assert_eq(PgDecimal::to_string(pg), text)
}
