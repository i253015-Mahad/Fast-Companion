// lib/services/flex_session_service.dart

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Owns the app's session with the university's Flex student portal.
///
/// The portal sits behind Cloudflare Turnstile, which a plain HTTP client
/// cannot satisfy on its own — a real browser engine has to run the
/// challenge. So the student signs in inside a WebView and this service
/// adopts the cookie the portal issues. The app never sees, stores or
/// transmits the password; all it keeps is the session the university's
/// own site handed out, which expires like any other session.
///
/// That copied cookie exists so later stages can fetch portal pages the
/// way a browser would (fast, parseable in Dart) instead of driving the
/// WebView for every read. If it ever stops working the WebView remains
/// the fallback, which is why [FlexScreen] always renders the live site
/// rather than only our parsed view of it.
///
/// What a session is worth, measured rather than guessed: the portal
/// serves **five** requests and refuses the sixth, and nothing brings it
/// back. A fifteen-second pause, re-reading the browser's own cookie
/// jar, a `fetch()` made from inside the live document, and a real
/// navigation were each tried and each failed identically — so neither
/// the client nor the cookie is being rejected, the session is simply
/// spent. Not one response in any run carried a `Set-Cookie`, so it is
/// never rotated away from us either.
///
/// Two things follow for anything that reads pages. Route links must
/// come from the document the WebView is already showing rather than by
/// fetching `/Home`, since that fetch costs one of the five. And a
/// polling loop has to plan for five reads per sign-in, not free
/// reading. `/Student/GradeReport` is refused from every position it
/// was tried at while pages queued behind it still came back, so it is
/// unavailable on its own account — grades come from `Transcript`.
class FlexSessionService {
  FlexSessionService._();

  static final FlexSessionService instance = FlexSessionService._();

  /// Portal origin. Every route is a path under this host.
  static const String baseUrl = 'https://flexstudent.nu.edu.pk';

  static final Uri home = Uri.parse(baseUrl);

  /// The sign-in page wraps its form in `id="m_login"` (verified against
  /// the live portal). Finding that marker in a response means we were
  /// redirected to the sign-in page, i.e. the session has lapsed.
  static const String _loginMarker = 'id="m_login"';

  static const String _cookiePref = 'flex_session_cookie';
  static const Duration _timeout = Duration(seconds: 15);

  /// Sent alongside the cookie so the portal sees an ordinary browser.
  /// The default `Dart/x.y` agent would otherwise mark our requests out
  /// as non-browser traffic.
  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  /// The cookie header to replay, as `name=value; name2=value2`.
  String _cookie = '';

  /// Told about the session moving — a sign-in adopted out of the
  /// WebView, or a sign-out dropping it.
  ///
  /// Kept to a plain callback list rather than a notifier because the
  /// only thing that listens is the timetable, and all it wants to know
  /// is that attendance may have become fetchable: the tabs share one
  /// tree and the timetable stays mounted, so it would otherwise have no
  /// way of hearing that the student has just signed in.
  final List<VoidCallback> _listeners = [];

  /// True once a session cookie is held and can be replayed.
  bool get hasSession => _cookie.isNotEmpty;

  void addSessionListener(VoidCallback listener) => _listeners.add(listener);

  void removeSessionListener(VoidCallback listener) =>
      _listeners.remove(listener);

  void _notifySessionChanged() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  /// Reads the persisted copy of the cookie.
  ///
  /// The WebView's own cookie store is what actually keeps the student
  /// signed in across launches — it persists itself, and this version of
  /// the plugin exposes no explicit flush. This field is the mirror the
  /// Dart-side fetches replay, adopted fresh from that store on every
  /// page load.
  Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      _cookie = prefs.getString(_cookiePref) ?? '';
    } catch (e) {
      // Preferences are best-effort: an unreadable cookie just means the
      // next page load re-adopts it from the WebView.
      debugPrint('Flex session restore failed: $e');
    }
  }

  /// Copies the portal's cookies out of the WebView and persists them.
  ///
  /// Called after each page load so Dart-side requests carry the same
  /// session the browser does. The read goes through the platform cookie
  /// store rather than JavaScript, so HttpOnly cookies — which the
  /// session almost certainly is — are included.
  Future<void> adoptFromWebView(InAppWebViewController controller) async {
    final List<Cookie> cookies;
    try {
      cookies = await CookieManager.instance().getCookies(
        url: WebUri(baseUrl),
        webViewController: controller,
      );
    } catch (e) {
      debugPrint('Flex cookie read failed: $e');
      return;
    }

    final header = [
      for (final c in cookies)
        if (c.name.isNotEmpty) '${c.name}=${c.value ?? ''}',
    ].join('; ');
    if (header == _cookie) return;
    _cookie = header;
    await _persist();
    // Only on a real change: this runs after every page load, and a
    // listener that fired every time would fetch attendance behind a
    // student still sitting on the sign-in page.
    _notifySessionChanged();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_cookie.isEmpty) {
        await prefs.remove(_cookiePref);
      } else {
        await prefs.setString(_cookiePref, _cookie);
      }
    } catch (e) {
      debugPrint('Flex session save failed: $e');
    }
  }

  /// Headers for a Dart-side portal request, so the cookie, agent and
  /// referer are the same whichever fetch goes out.
  Map<String, String> get _headers => {
        'Cookie': _cookie,
        'User-Agent': _userAgent,
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,'
            '*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
        'Referer': baseUrl,
      };

  /// Fetches a portal page exactly as the browser would, so the HTML can
  /// be parsed in Dart without driving a WebView.
  ///
  /// Returns `null` when there is no session, the portal answered with
  /// anything other than 200, it redirected to the sign-in page, or the
  /// request failed. Callers must treat `null` as "unknown", never as
  /// "no data" — the WebView remains the source of truth, so a rejected
  /// fetch degrades to showing the live site rather than a wrong answer.
  Future<String?> getHtml(String path) async {
    final result = await getHtmlDetailed(path);
    return result.body;
  }

  /// TEMPORARY — Phase 0 of the Flex alerts feature.
  ///
  /// The request headers this service sends, so the page dump can make
  /// its own requests without copying them. Goes away with FlexPageDump.
  Map<String, String> get debugHeaders => _headers;

  /// TEMPORARY — Phase 0 of the Flex alerts feature.
  ///
  /// Adopts a cookie handed back by the portal, the way a browser would.
  /// Goes away with FlexPageDump.
  void debugAdoptCookie(String cookie) {
    if (cookie.isNotEmpty) _cookie = cookie;
  }

  /// TEMPORARY — Phase 0 of the Flex alerts feature.
  ///
  /// The same request as [getHtml], but it says what went wrong instead
  /// of folding every failure into `null`. [getHtml] collapses "the
  /// portal said 404" and "we were bounced to sign-in" into one answer
  /// because its callers only care that they have nothing; the page
  /// dump needs to tell them apart, since a route that 404s is a
  /// different problem from a session that died mid-run.
  ///
  /// Goes away with FlexPageDump.
  Future<({int? status, bool loginRedirect, String? body})> getHtmlDetailed(
    String path,
  ) async {
    if (!hasSession) {
      return (status: null, loginRedirect: false, body: null);
    }
    final uri = Uri.parse(baseUrl + (path.startsWith('/') ? path : '/$path'));
    try {
      final response = await http
          .get(uri, headers: _headers)
          .timeout(_timeout);
      if (response.statusCode != 200) {
        return (
          status: response.statusCode,
          loginRedirect: false,
          body: null,
        );
      }
      if (response.body.contains(_loginMarker)) {
        return (status: 200, loginRedirect: true, body: null);
      }
      return (status: 200, loginRedirect: false, body: response.body);
    } catch (e) {
      debugPrint('Flex fetch failed: $e');
      return (status: null, loginRedirect: false, body: null);
    }
  }

  /// Drops the session everywhere — our copy, the shared preference and
  /// the WebView's own cookie jar — so the portal asks for credentials
  /// again the next time it is opened.
  Future<void> signOut() async {
    _cookie = '';
    await _persist();
    try {
      await CookieManager.instance().deleteAllCookies();
    } catch (e) {
      debugPrint('Flex cookie clear failed: $e');
    }
  }
}
