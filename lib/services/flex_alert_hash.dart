// One stable fingerprint per value, for telling a changed page from one that
// has already been seen.
//
// This is deliberately *not* `Object.hash`. Dart seeds that per process — it
// exists to stop hash-flooding attacks, and equal values hash alike only
// inside the run that hashed them. A content hash is the opposite of that:
// it gets written into a snapshot and compared on a later poll, after the
// app has been restarted, possibly days later. Hashing with a per-process
// seed would make every poll look like a change, and an alert that fires on
// every fetch is one nobody reads.
//
// So this is FNV-1a, which is fixed by its specification rather than by the
// process that ran it: the same string gives the same number on every
// device, every run, forever. It is not cryptographic and does not need to
// be — the only thing asked of it is that an unchanged value repeat and a
// changed one very likely not, and at 63 bits across a handful of courses
// the chance of two different sets of marks colliding is negligible.
//
// The mask is 63 bits, not the 64 the algorithm specifies. Dart's `int` is a
// *signed* 64-bit value, so the top bit is a sign: left set, the hash prints
// as a negative number, and `toUnsigned` cannot rescue it because a negative
// int has already lost the distinction between "large unsigned" and
// "negative". Keeping the value under 2^63 costs one bit of the hash and
// keeps every stored snapshot a plain non-negative number.
String stableHash(Iterable<String> parts) {
  var hash = 0xcbf29ce484222325;
  for (final part in parts) {
    for (final unit in part.codeUnits) {
      hash ^= unit;
      hash *= 0x100000001b3;
      hash &= 0x7fffffffffffffff;
    }
    // A separator, so that ('ab', 'c') and ('a', 'bc') hash differently.
    // Without it the parts would run together and two different pages could
    // spell one identical string.
    hash ^= 0x1f;
    hash *= 0x100000001b3;
    hash &= 0x7fffffffffffffff;
  }
  return hash.toString();
}
