// lib/services/flex_page_dump.dart
//
// TEMPORARY — Phase 0 of the Flex alerts feature, and nothing else.
//
// Nothing in the app knows what the portal's fees, marks and grades pages
// look like. A parser written against guessed markup is worthless, so this
// fetches the dashboard, follows the portal's own links to anything that
// looks like one of those pages, and writes the raw HTML out where it can
// be read.
//
// The routes are read off /Home rather than invented. Attendance already
// paid for that lesson: the semester id changes every term and a wrong one
// returns an empty page that looks exactly like "nothing here", so the
// dashboard is asked what the link is.
//
// It writes to app-specific external storage, which `adb pull` reaches
// without root:
//
//     adb pull /storage/emulated/0/Android/data/com.mahad.fastcompanion/files/flex_dump
//
// Alongside the pages goes a `report.txt` saying what each fetch did. The
// first run lost four pages to failed fetches and there was no way to tell
// a 404 from a dead session from a throttled run — the answers to that
// question are exactly the ones that have to survive until someone reads
// them, and logcat is not where that happens.
//
// The pages carry the student's roll number, fee balance and marks, so
// nothing here is logged to logcat — only paths, sizes and status codes
// are. Delete the directory, this file and the debug button in FlexScreen
// that triggers it once the parsers exist.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'flex_session_service.dart';

/// What one run of the dump did, in enough detail to put on screen.
class FlexDumpReport {
  const FlexDumpReport({
    required this.directory,
    required this.written,
    required this.failures,
  });

  /// Where the files went, or `''` when nothing was written.
  final String directory;

  /// Absolute paths of the files that were written.
  final List<String> written;

  /// Anything that went wrong, in the reader's words rather than
  /// exception text.
  final List<String> failures;

  /// True when the whole run produced nothing.
  bool get isEmpty => written.isEmpty;
}

/// One portal request: what came back, plus the cookie to send next.
/// [body] is `null` when the page is unusable, but [cookie] is carried
/// forward either way — a `Set-Cookie` on a response we cannot read still
/// changes which session we should be using.
///
/// Worth having seen the absence of one: across three runs the portal
/// never sent a `Set-Cookie` at all, which is what ruled rotation out as
/// the reason the session was dying.
class _Page {
  const _Page({
    required this.status,
    required this.loginRedirect,
    required this.body,
    required this.cookie,
    required this.setCookieNames,
  });

  /// HTTP status, or `null` when the request never completed.
  final int? status;

  /// True when a 200 was actually the sign-in page.
  final bool loginRedirect;

  final String? body;

  /// The cookie string to send on the next request.
  final String cookie;

  /// Names of the cookies this response set, for the report.
  final List<String> setCookieNames;
}

class FlexPageDump {
  FlexPageDump._();

  /// Host every fetched page has to be on. The dashboard links out to
  /// things that are not the portal, and there is no reason to go
  /// fetching them.
  static const String _host = 'flexstudent.nu.edu.pk';

  /// Words that, in a link's text or its href, mark a page worth
  /// following. Deliberately broad — narrowing it here would mean
  /// guessing the portal's own vocabulary, and this exists precisely
  /// because nobody has seen those pages yet. Too broad is fine: extra
  /// files cost nothing to read and delete.
  static const List<String> keywords = [
    'fee',
    'challan',
    'dues',
    'payment',
    'invoice',
    'mark',
    'grade',
    'result',
    'transcript',
    'gpa',
    'cgpa',
  ];

  /// Fetched first, most-wanted first.
  ///
  /// What goes in these slots is the whole value of a run, because the
  /// portal serves a session five requests and refuses the sixth. That
  /// count fits every run so far — including the first one, recorded
  /// before any of this was known — and it was settled by tests rather
  /// than assumed: a fifteen-second pause did not recover it, the
  /// browser's own cookie jar made no difference, reading the pages out
  /// of the live document behaved no better than bare HTTP, and a real
  /// navigation bounced exactly like a `fetch()` did. Nothing about the
  /// client matters; the count does.
  ///
  /// Fees sat at the front while their markup was still missing; now
  /// that it is on disk, the pages the parsers have never seen take
  /// those slots — marks, then the transcript, which is where grades
  /// live.
  ///
  /// GradeReport goes last on purpose. It was refused from both
  /// positions it has been tried from — third and fourth — while pages
  /// queued behind it still came back, so it is not the session giving
  /// out but that page. Two attempts are spent on it either way, and
  /// front-loading them costs the run a page it could otherwise keep.
  static const List<String> _priority = [
    'studentmarks',
    'transcript',
    'challan',
    'consolidated',
    'gradereport',
  ];

  /// Ceiling on followed links, so a dashboard full of them doesn't write
  /// fifty files or keep the student waiting.
  static const int maxPages = 12;

  /// Gap between requests. The portal cuts the session off after five of
  /// them regardless, and a university portal has no reason to be
  /// hammered anyway.
  static const Duration _gap = Duration(milliseconds: 2000);

  /// How long to pause when the portal serves the sign-in page for a
  /// request it had just accepted.
  ///
  /// Two causes were suspected and both tested away: a cookie going
  /// stale behind us (the browser's own jar made no difference) and a
  /// budget that refills over time (fifteen seconds did not recover
  /// it). What is left is a hard count of five requests, which no wait
  /// undoes. The pause stays because a budget that really were a window
  /// would look exactly like this one while it was empty, and because
  /// [run] stops after two consecutive refusals, so the wait can only
  /// ever cost the run that one attempt.
  static const Duration _retryWait = Duration(seconds: 15);

  /// Fetches /Home, follows the interesting links, writes everything.
  ///
  /// [controller] is the Flex tab's live WebView. It exists so the session
  /// cookie can be read out of the browser's own jar before every request
  /// rather than trusted from a snapshot — see [liveCookie].
  static Future<FlexDumpReport> run({
    InAppWebViewController? controller,
  }) async {
    final dir = await _directory();
    if (dir == null) {
      return const FlexDumpReport(
        directory: '',
        written: [],
        failures: ['Could not open a directory to write into.'],
      );
    }

    final written = <String>[];
    final failures = <String>[];
    final report = <String>[];

    Future<FlexDumpReport> finish() async {
      await _write(dir, 'report.txt', report.join('\n'));
      return FlexDumpReport(
        directory: dir.path,
        written: written,
        failures: failures,
      );
    }

    // The session cookie, read out of the browser's own jar rather than
    // out of the mirror the session service keeps.
    //
    // Only worth doing at the start and on a retry. Re-reading it before
    // *every* request was tried and changed nothing, which is part of
    // what ruled a stale snapshot out as the cause — it stays because
    // the HTTP fallback still needs a cookie to send, and because a
    // retry costs one platform call to cover the case anyway.
    Future<String> liveCookie() async {
      if (controller != null) {
        await FlexSessionService.instance.adoptFromWebView(controller);
      }
      return FlexSessionService.instance.debugHeaders['Cookie'] ?? '';
    }

    /// One page, with a single wait-and-retry if the portal bounces it.
    Future<({_Page page, String cookie, bool retried})> attempt(
      String path,
      String start,
    ) async {
      var page = await _fetch(path, start, controller);
      if (page.body != null || !page.loginRedirect) {
        return (page: page, cookie: page.cookie, retried: false);
      }

      await Future<void>.delayed(_retryWait);
      final fresh = await liveCookie();
      page = await _fetch(path, fresh, controller);
      return (page: page, cookie: page.cookie, retried: true);
    }

    var cookie = await liveCookie();
    if (cookie.isEmpty) {
      report.add('no session — open the portal and sign in first');
      return finish();
    }

    // The link list comes off the dashboard the WebView is already
    // showing whenever that document carries any links. Reading it
    // spends no request, and with three to spend that is the
    // difference between reaching two data pages and reaching three.
    String? live = controller == null ? null : await _currentDocument(controller);
    if (live != null && interestingLinks(live).isEmpty) {
      live = null;
    }

    _Page result;
    if (live != null) {
      result = _Page(
        status: 200,
        loginRedirect: false,
        body: live,
        cookie: cookie,
        setCookieNames: const [],
      );
      report.add('links read off the live dashboard (${live.length} bytes)');
    } else {
      final home = await attempt('/Home', cookie);
      result = home.page;
      cookie = home.cookie;
      if (home.retried) {
        report.add(
          '/Home -> bounced; waited ${_retryWait.inSeconds}s and retried',
        );
      }
      if (result.body == null) {
        report.add('/Home -> ${_why(result)}${_set(result)}');
        return finish();
      }
      report.add('/Home -> 200 (${result.body!.length} bytes)${_set(result)}');
    }

    final homeFile = await _write(dir, '00_home.html', result.body!);
    if (homeFile == null) {
      failures.add('/Home: write failed');
    } else {
      written.add(homeFile.path);
    }

    var n = 1;
    // The session does not come back: once a page bounces, every page
    // after it bounces too, and each one would be tried twice with the
    // full retry wait between. Two in a row is enough to say so.
    var dead = 0;
    for (final link in ordered(interestingLinks(result.body!))) {
      if (n > maxPages) {
        failures.add('Stopped after $maxPages pages — there were more.');
        report.add('stopped at the $maxPages page cap');
        break;
      }

      await Future<void>.delayed(_gap);

      final attempt1 = await attempt(link, cookie);
      final page = attempt1.page;
      cookie = attempt1.cookie;
      if (attempt1.retried) {
        report.add(
          '$link -> bounced; waited ${_retryWait.inSeconds}s and retried',
        );
      }
      if (page.body == null) {
        failures.add('$link: ${_why(page)}');
        report.add('$link -> ${_why(page)}${_set(page)}');
        if (++dead >= 2) {
          report.add('session lost — stopped rather than retry the rest');
          break;
        }
        continue;
      }
      dead = 0;
      report.add('$link -> 200 (${page.body!.length} bytes)${_set(page)}');

      final name = '${n.toString().padLeft(2, '0')}_${_nameFor(link)}.html';
      final file = await _write(dir, name, page.body!);
      if (file == null) {
        failures.add('$link: write failed');
        continue;
      }
      written.add(file.path);
      n++;
    }

    // Leave the session this run ended with in the service, so the next
    // run starts from where this one finished rather than from the
    // WebView's last page load.
    FlexSessionService.instance.debugAdoptCookie(cookie);

    return finish();
  }

  /// The document the WebView is already showing, read straight off the
  /// page.
  ///
  /// Nothing is sent to the server for it, and that is the whole point:
  /// the session is worth three requests, and spending the first on a
  /// link list the browser is already holding in front of us would leave
  /// only two for the pages that carry data.
  static Future<String?> _currentDocument(
    InAppWebViewController controller,
  ) async {
    try {
      final html = await controller.evaluateJavascript(
        source: 'document.documentElement.outerHTML',
      );
      // Size only — the markup itself carries the student's data.
      if (html is String && html.isNotEmpty) {
        debugPrint('Flex live document (${html.length} bytes)');
        return html;
      }
    } catch (e) {
      debugPrint('Flex live document read failed: $e');
    }
    return null;
  }

  /// One portal request, from inside the portal's own document when a
  /// live page is available, and over plain HTTP otherwise.
  static Future<_Page> _fetch(
    String path,
    String cookie,
    InAppWebViewController? controller,
  ) async {
    if (controller != null) {
      final html = await _fetchInPage(controller, path);
      if (html != null) {
        final bounced = html.contains('id="m_login"');
        return _Page(
          status: 200,
          loginRedirect: bounced,
          body: bounced ? null : html,
          cookie: cookie,
          setCookieNames: const [],
        );
      }
      // A page that refuses a fetch is still readable over HTTP while
      // the session lasts, so this is a fallback rather than a failure.
      debugPrint('Flex in-page unavailable -> falling back to HTTP $path');
    }

    final uri = Uri.parse(
      FlexSessionService.baseUrl + (path.startsWith('/') ? path : '/$path'),
    );
    try {
      final response = await http
          .get(
            uri,
            headers: {...FlexSessionService.instance.debugHeaders, 'Cookie': cookie},
          )
          .timeout(const Duration(seconds: 15));

      final next = mergeCookies(cookie, response.headers['set-cookie']);
      final names = _cookieNames(response.headers['set-cookie']);
      final bounced = response.statusCode == 200 &&
          response.body.contains('id="m_login"');

      return _Page(
        status: response.statusCode,
        loginRedirect: bounced,
        body: response.statusCode == 200 && !bounced ? response.body : null,
        cookie: next,
        setCookieNames: names,
      );
    } catch (e) {
      debugPrint('Flex dump fetch failed: $e');
      return _Page(
        status: null,
        loginRedirect: false,
        body: null,
        cookie: cookie,
        setCookieNames: const [],
      );
    }
  }

  /// Fetches a portal page from within the page the portal is already
  /// serving.
  ///
  /// This is the one that works, and the failure that led here was the
  /// informative part. Plain HTTP delivered exactly three pages on
  /// every run before the portal served the sign-in page — and it was
  /// not any of the obvious things: no response ever carried a
  /// `Set-Cookie` (so the session was never rotated away from us), a
  /// fifteen-second pause did not recover it (so it was not rate
  /// limiting), and re-reading the browser's own cookie jar before
  /// each request changed nothing (so it was not a stale snapshot).
  /// What stayed true through every run was that the WebView itself
  /// kept working. The portal was rejecting the *client*, not the
  /// cookie — it can tell a request with no browser behind it, and
  /// after enough of them it stops serving pages to it.
  ///
  /// Running the fetch inside the document puts it where the session
  /// provably works: same origin, real browser, real TLS, and the very
  /// cookies the page is using. Returns `null` when that does not work
  /// either, so the caller can fall back to HTTP rather than dying.
  static Future<String?> _fetchInPage(
    InAppWebViewController controller,
    String path,
  ) async {
    final uri = Uri.parse(
      FlexSessionService.baseUrl + (path.startsWith('/') ? path : '/$path'),
    );
    const slot = 'window.__flexDump';

    // Status only — never the markup, which carries the student's data
    // and would otherwise land in logcat.
    debugPrint('Flex in-page -> $path');

    try {
      // The result is stashed on the page rather than returned, because
      // a plain evaluateJavascript is not depended on to await a
      // Promise — polling for completion needs nothing more exotic than
      // reading a value. The IIFE keeps the statement's own completion
      // value undefined so nothing hands a Promise back either.
      final kick = await controller.evaluateJavascript(
        source: "(function () {\n"
            "  $slot = {state: 0};\n"
            "  fetch(${jsonEncode(uri.toString())}, {credentials: 'include'})\n"
            "    .then(function (r) { return r.text(); })\n"
            "    .then(function (t) { $slot = {state: 1, html: t}; })\n"
            "    .catch(function () { $slot = {state: 2}; });\n"
            "})();",
      );
      debugPrint('Flex in-page kick -> ${kick.runtimeType}=$kick');

      // Twelve seconds is far longer than any of these take; it is a
      // ceiling so a hung fetch fails the page instead of the run.
      var first = true;
      for (var i = 0; i < 120; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final state = await controller.evaluateJavascript(
          source: '$slot ? $slot.state : 0',
        );
        if (first) {
          debugPrint('Flex in-page poll  -> ${state.runtimeType}=$state');
          first = false;
        }
        if (state is! num || state == 0) continue;

        if (state != 1) {
          debugPrint('Flex in-page fetch rejected (state=$state) for $path');
          return null;
        }
        final html = await controller.evaluateJavascript(
          source: '$slot ? $slot.html : null',
        );
        await controller.evaluateJavascript(source: '$slot = null');
        if (html is! String || html.isEmpty) {
          debugPrint('Flex in-page empty body for $path');
          return null;
        }
        // Size only.
        debugPrint('Flex in-page ok ($path) ${html.length} bytes');
        return html;
      }
      debugPrint('Flex in-page timed out for $path');
      return null;
    } catch (e) {
      // Only the failure: whatever came back may be the portal's own
      // markup, and this goes to logcat.
      debugPrint('Flex in-page fetch failed: $e');
      return null;
    }
  }

  /// Folds a `Set-Cookie` response header into the cookie string the next
  /// request sends.
  ///
  /// `http` joins several Set-Cookie headers with ", ", which is also the
  /// separator inside an Expires value — so the split only happens at a
  /// comma that starts another name=value pair.
  static String mergeCookies(String current, String? header) {
    if (header == null || header.isEmpty) return current;

    final jar = <String, String>{};
    for (final pair in current.split(';')) {
      final i = pair.indexOf('=');
      if (i > 0) jar[pair.substring(0, i).trim()] = pair.substring(i + 1).trim();
    }

    for (final entry in header.split(RegExp(r',(?=\s*[^;,]+=)'))) {
      final i = entry.indexOf('=');
      if (i <= 0) continue;
      jar[entry.substring(0, i).trim()] =
          entry.substring(i + 1).split(';').first.trim();
    }

    return [for (final e in jar.entries) '${e.key}=${e.value}'].join('; ');
  }

  /// Names of the cookies a response set — names only, never values:
  /// this ends up in a file the student reads.
  static List<String> _cookieNames(String? header) {
    if (header == null || header.isEmpty) return const [];
    final out = <String>[];
    for (final entry in header.split(RegExp(r',(?=\s*[^;,]+=)'))) {
      final i = entry.indexOf('=');
      if (i > 0) out.add(entry.substring(0, i).trim());
    }
    return out;
  }

  static String _why(_Page p) => p.loginRedirect
      ? 'bounced to sign-in'
      : p.status == null
          ? 'request failed'
          : 'status ${p.status}';

  static String _set(_Page p) =>
      p.setCookieNames.isEmpty ? '' : ' set-cookie: ${p.setCookieNames.join(', ')}';

  /// The portal's own links that look like the pages we want, with the
  /// wanted ones first and everything in dashboard order otherwise.
  ///
  /// Anchor text is matched alongside the href because the portal writes
  /// its navigation as text — `Fee Challan` — over routes that say
  /// something else entirely. Only double-quoted hrefs are matched, the
  /// same shape attendance already parses off this portal successfully.
  static List<String> interestingLinks(String html) {
    final anchor = RegExp(
      '<a\\b[^>]*?href="([^"]*)"[^>]*>([\\s\\S]*?)</a>',
      caseSensitive: false,
    );

    final seen = <String>{};
    final out = <String>[];

    for (final m in anchor.allMatches(html)) {
      final raw = (m.group(1) ?? '').trim();
      if (raw.isEmpty || raw.startsWith('#')) continue;
      if (raw.toLowerCase().startsWith('javascript:')) continue;

      final text = _textOf(m.group(2) ?? '');
      final href = _normalise(raw);
      if (href.isEmpty) continue;

      // The dashboard links off-site too; those are not the portal.
      if (href.startsWith('http') && !href.contains(_host)) continue;

      final haystack = '$href $text'.toLowerCase();
      if (!keywords.any(haystack.contains)) continue;

      if (!seen.add(href)) continue;
      out.add(href);
    }
    return out;
  }

  /// Puts [_priority] matches first, in that order; the rest keep the
  /// order the dashboard lists them in.
  static List<String> ordered(List<String> links) {
    int rank(String link) {
      final lower = link.toLowerCase();
      for (var i = 0; i < _priority.length; i++) {
        if (lower.contains(_priority[i])) return i;
      }
      return _priority.length;
    }

    // Stable, so equal ranks stay in dashboard order.
    final indexed = [for (var i = 0; i < links.length; i++) (links[i], i)];
    indexed.sort((a, b) {
      final byRank = rank(a.$1).compareTo(rank(b.$1));
      return byRank != 0 ? byRank : a.$2.compareTo(b.$2);
    });
    return [for (final e in indexed) e.$1];
  }

  /// Turns a link into the path form [FlexSessionService.getHtml] takes.
  ///
  /// Absolute URLs are reduced to their path and query so the session,
  /// user-agent and referer the service supplies are the ones used — a
  /// bare link to the same host would work, but a link anywhere else
  /// would silently fetch from it instead.
  static String _normalise(String href) {
    final clean = href.replaceAll('&amp;', '&');
    if (clean.startsWith('http')) {
      final uri = Uri.tryParse(clean);
      if (uri == null) return '';
      return uri.path + (uri.query.isEmpty ? '' : '?${uri.query}');
    }
    if (clean.startsWith('/')) return clean;
    return '/$clean';
  }

  /// Visible text of an anchor, with its markup stripped.
  static String _textOf(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// A path turned into something safe to put in a filename. Two paths
  /// can collapse onto the same name, so the caller prefixes a counter.
  static String _nameFor(String path) {
    final base = path.replaceFirst(RegExp(r'^/+'), '');
    final safe = base
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return safe.isEmpty ? 'page' : safe.toLowerCase();
  }

  /// App-specific external storage, which `adb pull` can read without
  /// root. Falls back to the documents directory rather than failing —
  /// the files are still readable, just by other means.
  static Future<Directory?> _directory() async {
    try {
      final base =
          await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}/flex_dump');
      await dir.create(recursive: true);
      return dir;
    } catch (e) {
      debugPrint('Flex dump directory failed: $e');
      return null;
    }
  }

  static Future<File?> _write(Directory dir, String name, String html) async {
    try {
      final file = File('${dir.path}/$name');
      await file.writeAsString(html);
      return file;
    } catch (e) {
      // Only the failure, never the contents: this is going to logcat.
      debugPrint('Flex dump write failed ($name): $e');
      return null;
    }
  }
}
