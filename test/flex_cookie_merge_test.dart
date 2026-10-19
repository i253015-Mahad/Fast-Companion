// TEMPORARY — Phase 0 diagnostic. Covers the cookie fold the page dump
// depends on, because a malformed Cookie header would kill every fetch in
// the run rather than just one. Delete with the rest of the dump tooling.
import 'package:fast_companion/services/flex_page_dump.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('adds a cookie that is not there yet', () {
    final out = FlexPageDump.mergeCookies(
      'PHPSESSID=old1; other=x',
      'laravel_session=new2; path=/; httponly',
    );
    expect(out, contains('PHPSESSID=old1'));
    expect(out, contains('other=x'));
    expect(out, contains('laravel_session=new2'));
  });

  test('replaces a cookie the portal rotated', () {
    // This is the whole point: replaying the old value is what got the
    // first run bounced to sign-in after three requests.
    final out = FlexPageDump.mergeCookies(
      'PHPSESSID=old1',
      'PHPSESSID=new1; path=/; HttpOnly',
    );
    expect(out, 'PHPSESSID=new1');
    expect(out, isNot(contains('old1')));
  });

  test('splits the Set-Cookie headers the client joined with commas', () {
    // `http` flattens several Set-Cookie headers into one string, but a
    // comma also appears inside Expires — that one must not be read as
    // the start of another cookie.
    const header =
        'PHPSESSID=new1; path=/; HttpOnly, '
        'laravel_session=new2; expires=Wed, 21 Oct 2026 07:28:00 GMT; '
        'Max-Age=7200; path=/; httponly';

    final out = FlexPageDump.mergeCookies('PHPSESSID=old1', header);

    expect(out, contains('PHPSESSID=new1'));
    expect(out, contains('laravel_session=new2'));
    expect(out, isNot(contains('old1')));
    // The Expires value was not mistaken for a cookie name/value.
    expect(out, isNot(contains('Wed')));
    expect(out, isNot(contains('21 Oct 2026')));
  });
}
