// lib/services/faculty_directory_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/faculty_member.dart';
import 'csv_reader.dart';

/// One school whose faculty-offices sheet the app knows how to read.
///
/// A list rather than a flag on purpose: a second school is a row here.
class FacultySource {
  final String id;
  final String label;

  /// The Google Sheet's own id, from the share link.
  final String sheetId;

  const FacultySource({
    required this.id,
    required this.label,
    required this.sheetId,
  });
}

/// Every faculty-offices sheet the app can read.
///
/// Only Computing publishes one. The university maintains no sheet for
/// Engineering or Management — their faculty come from the campus
/// website instead, in [kFacultySitePages], with room numbers supplied
/// separately through [kFacultyOfficeSheetId].
const List<FacultySource> kFacultySources = [
  FacultySource(
    id: 'computing',
    label: 'School of Computing',
    sheetId: '1HF6g11HUJdnHo9D35fvtCzSxR2fTeu_K',
  ),
];

/// One faculty page on the campus website, read instead of a sheet.
///
/// The site publishes name, designation and email per department and
/// is maintained by the university itself; it carries no office rooms,
/// which is what [kFacultyOfficeSheetId] is for.
class FacultySitePage {
  final String url;

  /// Which school the department sits in, phrased like a sheet label
  /// (`School of Computing`) so both source kinds merge into one list
  /// without the UI telling them apart.
  final String school;

  /// The department as the directory should file people under, with the
  /// site's `Dept. of ` prefix already dropped.
  final String department;

  const FacultySitePage({
    required this.url,
    required this.school,
    required this.department,
  });
}

/// The website pages the app reads faculty identity from.
///
/// Four departments: DCE and DEE under Engineering, DMS and DAF under
/// Management. Science & Humanities is deliberately absent: the
/// Computing sheet already lists it, and scraping its page too would
/// put every one of those people in the directory twice.
const List<FacultySitePage> kFacultySitePages = [
  FacultySitePage(
    url: 'https://isb.nu.edu.pk/Academics/Faculty-DCE.php',
    school: 'School of Engineering',
    department: 'Computer Engineering',
  ),
  FacultySitePage(
    url: 'https://isb.nu.edu.pk/Academics/Faculty-DEE.php',
    school: 'School of Engineering',
    department: 'Electrical Engineering',
  ),
  FacultySitePage(
    url: 'https://isb.nu.edu.pk/Academics/Faculty-DMS.php',
    school: 'School of Management',
    department: 'Management Sciences',
  ),
  FacultySitePage(
    url: 'https://isb.nu.edu.pk/Academics/Faculty-DAF.php',
    school: 'School of Management',
    department: 'Accounting & Finance',
  ),
];

/// A sheet of `Email | Office` rows filling in the rooms the website
/// does not publish — shared "Anyone with the link → Viewer".
///
/// Empty until one exists: an empty id is skipped exactly like a sheet
/// source with no id, and everyone it would have matched keeps showing
/// *No office listed* meanwhile. Its failures are never fatal either —
/// a broken office sheet costs rooms, not the directory.
const String kFacultyOfficeSheetId = '';

/// A directory loaded from the schools' faculty-offices sheets.
typedef FacultyDirectory = ({
  List<FacultyMember> members,
  String term,
  DateTime fetchedAt,
  bool fromCache,
});

/// Reads the faculty directory's sources: Computing's offices sheet and
/// the campus website's department pages — who teaches where, and how
/// to reach them.
///
/// Deliberately its own service rather than more methods on
/// `TimetableService`. The two read different documents on different
/// rhythms — a timetable changes every term and is fetched per day, a
/// faculty list changes once a term and is fetched once — and folding
/// this in would add a second caching profile to a class that already
/// carries one.
class FacultyDirectoryService {
  FacultyDirectoryService._();

  static final FacultyDirectoryService instance = FacultyDirectoryService._();

  static const Duration _timeout = Duration(seconds: 15);

  /// How long a directory stays fresh.
  ///
  /// A day, rather than the rooms' six hours: this sheet is rewritten
  /// between terms, not between lectures, and re-reading it on every
  /// open would be network spent on a document that has not moved.
  static const Duration _ttl = Duration(hours: 24);

  /// Bumped when the member shape or the parsing changes, so caches
  /// written by an older parse are discarded rather than shown as a
  /// list with the wrong fields in it.
  static const int _cacheVersion = 2;

  static const String _cacheKey = 'faculty_directory';

  // ================= PUBLIC API =================

  /// Loads every configured school's directory.
  ///
  /// [forceRefresh] (pull-to-refresh) ignores the cache age and hits the
  /// network. Each source is read on its own, with one quick retry, so a
  /// single unreachable host costs its own school rather than the whole
  /// directory. When something went wrong the answer is the best list
  /// available: a full fresh one, else the saved one — an out-of-date
  /// list of offices beats no list — else whatever the sources that did
  /// answer produced, handed back uncached so the next open tries the
  /// missing ones again. Only when every source failed and nothing is
  /// saved does the error propagate, which really is a dead connection.
  ///
  /// [fetchSheet] and [fetchSite] substitute for the network in tests.
  Future<FacultyDirectory> load({
    bool forceRefresh = false,
    Future<String> Function(String sheetId)? fetchSheet,
    Future<String> Function(String url)? fetchSite,
  }) async {
    final cached = await _readCache();

    if (!forceRefresh &&
        cached != null &&
        DateTime.now().difference(cached.fetchedAt) < _ttl) {
      return cached;
    }

    final readSheet = fetchSheet ?? _fetchSheet;
    final readSite = fetchSite ?? _fetchSite;

    final members = <FacultyMember>[];
    final terms = <String>{};
    final missed = <String>[];
    Object? firstFailure;

    for (final source in kFacultySources) {
      if (source.sheetId.isEmpty) continue;
      final read = await _attempt(source.label, () async {
        final csv = await readSheet(source.sheetId);
        return parseFacultyCsv(csv, school: source.label);
      });
      final parsed = read.ok;
      if (parsed == null) {
        missed.add(source.label);
        firstFailure ??= read.error;
        continue;
      }
      members.addAll(parsed.members);
      if (parsed.term.isNotEmpty) terms.add(parsed.term);
    }

    for (final page in kFacultySitePages) {
      final read = await _attempt(page.department, () async {
        final html = await readSite(page.url);
        return parseFacultyHtml(
          html,
          school: page.school,
          department: page.department,
        );
      });
      if (read.ok == null) {
        missed.add(page.department);
        firstFailure ??= read.error;
        continue;
      }
      members.addAll(read.ok!);
    }

    final term = terms.join(' · ');
    final fetchedAt = DateTime.now();

    if (missed.isEmpty) {
      final merged = applyOffices(members, await _fetchOffices());
      await _writeCache(merged, term, fetchedAt);
      return (
        members: merged,
        term: term,
        fetchedAt: fetchedAt,
        fromCache: false,
      );
    }

    debugPrint('Faculty directory: no answer from ${missed.join(', ')}');

    // A whole saved list beats a partial fresh one; a partial fresh one
    // still beats an error screen when nothing is saved.
    if (cached != null) {
      return (
        members: cached.members,
        term: cached.term,
        fetchedAt: cached.fetchedAt,
        fromCache: true,
      );
    }
    if (members.isNotEmpty) {
      final merged = applyOffices(members, await _fetchOffices());
      // Deliberately not cached: a cache is written whole or not at
      // all, so the next open re-attempts the sources this one lost.
      return (
        members: merged,
        term: term,
        fetchedAt: fetchedAt,
        fromCache: false,
      );
    }
    throw firstFailure ?? Exception('Faculty directory is unreachable');
  }

  /// One source's read, tried at most twice.
  ///
  /// The second try only follows failures that were cheap: a timeout
  /// already spent the whole `15s` budget hanging on a host that would
  /// hang again, while a refused connection, a rejected page or bad
  /// markup costs milliseconds to rediscover. Returns either the value
  /// or the last error for [load] to weigh against the cache.
  Future<({T? ok, Object? error})> _attempt<T>(
    String label,
    Future<T> Function() read,
  ) async {
    for (var attempt = 1;; attempt++) {
      final started = DateTime.now();
      try {
        return (ok: await read(), error: null);
      } catch (e) {
        debugPrint('Faculty directory: $label failed (try $attempt): $e');
        if (attempt >= 2 ||
            e is TimeoutException ||
            DateTime.now().difference(started) >= _timeout) {
          return (ok: null, error: e);
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
  }

  Future<String> _fetchSheet(String sheetId) async {
    // The CSV export, not the gviz endpoint: gviz merges the sheet's
    // department header rows into the cell below them, which is exactly
    // the structure the parse depends on to know who is in which
    // department.
    final uri = Uri.parse(
      'https://docs.google.com/spreadsheets/d/$sheetId'
      '/export?format=csv',
    );
    final response = await http.get(uri).timeout(_timeout);
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Faculty sheet fetch failed (${response.statusCode})',
        uri,
      );
    }
    final body = response.body;
    // Google answers with an HTML login/consent page when the sheet
    // isn't shared publicly — treat that as a failure, not as data.
    if (body.trimLeft().startsWith('<!DOCTYPE') ||
        body.trimLeft().startsWith('<html')) {
      throw const FormatException('Faculty sheet is not publicly shared');
    }
    return body;
  }

  Future<String> _fetchSite(String url) async {
    final uri = Uri.parse(url);
    // The campus server answers plain http with a 403; https only, and
    // with a browser's user agent so the request reads as one.
    if (uri.scheme != 'https') {
      throw FormatException('Faculty page is not https: $url');
    }
    final response = await _siteClient
        .get(uri, headers: {'User-Agent': _browserAgent})
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Faculty page fetch failed (${response.statusCode})',
        uri,
      );
    }
    final body = response.body;
    // A block page or a soft 404 is HTML too, so the shape of the page
    // is what is checked: no contact links means no faculty, and
    // handing back an empty school would quietly delete it from the
    // directory. Throwing falls back to the cached list instead.
    if (!body.contains('mailto:')) {
      throw const FormatException('Faculty page carries no contacts');
    }
    return body;
  }

  /// The office overlay as `email (lowercased) → room`, or no entries.
  ///
  /// Never throws: [kFacultyOfficeSheetId] being empty, unshared or
  /// broken all land on the same answer — the directory loads without
  /// rooms rather than not at all.
  Future<Map<String, String>> _fetchOffices() async {
    if (kFacultyOfficeSheetId.isEmpty) return const {};
    try {
      return parseOfficeCsv(await _fetchSheet(kFacultyOfficeSheetId));
    } catch (e) {
      debugPrint('Faculty office overlay fetch failed: $e');
      return const {};
    }
  }

  static const String _browserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Safari/537.36';

  /// Sectigo Public Server Authentication roots for campus website HTTPS.
  ///
  /// Android devices missing the 2021 Sectigo Root R46 in their trust store
  /// produce HandshakeException when fetching isb.nu.edu.pk. Adding these
  /// to the SecurityContext extends device trust without disabling SSL.
  static const String _sectigoPem = '''
-----BEGIN CERTIFICATE-----
MIIGTDCCBDSgAwIBAgIQOXpmzCdWNi4NqofKbqvjsTANBgkqhkiG9w0BAQwFADBf
MQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTYwNAYDVQQD
Ey1TZWN0aWdvIFB1YmxpYyBTZXJ2ZXIgQXV0aGVudGljYXRpb24gUm9vdCBSNDYw
HhcNMjEwMzIyMDAwMDAwWhcNMzYwMzIxMjM1OTU5WjBgMQswCQYDVQQGEwJHQjEY
MBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTcwNQYDVQQDEy5TZWN0aWdvIFB1Ymxp
YyBTZXJ2ZXIgQXV0aGVudGljYXRpb24gQ0EgRFYgUjM2MIIBojANBgkqhkiG9w0B
AQEFAAOCAY8AMIIBigKCAYEAljZf2HIz7+SPUPQCQObZYcrxLTHYdf1ZtMRe7Yeq
RPSwygz16qJ9cAWtWNTcuICc++p8Dct7zNGxCpqmEtqifO7NvuB5dEVexXn9RFFH
12Hm+NtPRQgXIFjx6MSJcNWuVO3XGE57L1mHlcQYj+g4hny90aFh2SCZCDEVkAja
EMMfYPKuCjHuuF+bzHFb/9gV8P9+ekcHENF2nR1efGWSKwnfG5RawlkaQDpRtZTm
M64TIsv/r7cyFO4nSjs1jLdXYdz5q3a4L0NoabZfbdxVb+CUEHfB0bpulZQtH1Rv
38e/lIdP7OTTIlZh6OYL6NhxP8So0/sht/4J9mqIGxRFc0/pC8suja+wcIUna0HB
pXKfXTKpzgis+zmXDL06ASJf5E4A2/m+Hp6b84sfPAwQ766rI65mh50S0Di9E3Pn
2WcaJc+PILsBmYpgtmgWTR9eV9otfKRUBfzHUHcVgarub/XluEpRlTtZudU5xbFN
xx/DgMrXLUAPaI60fZ6wA+PTAgMBAAGjggGBMIIBfTAfBgNVHSMEGDAWgBRWc1hk
lfmSGrASKgRieaFAFYghSTAdBgNVHQ4EFgQUaMASFhgOr872h6YyV6NGUV3LBycw
DgYDVR0PAQH/BAQDAgGGMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0lBBYwFAYI
KwYBBQUHAwEGCCsGAQUFBwMCMBsGA1UdIAQUMBIwBgYEVR0gADAIBgZngQwBAgEw
VAYDVR0fBE0wSzBJoEegRYZDaHR0cDovL2NybC5zZWN0aWdvLmNvbS9TZWN0aWdv
UHVibGljU2VydmVyQXV0aGVudGljYXRpb25Sb290UjQ2LmNybDCBhAYIKwYBBQUH
AQEEeDB2ME8GCCsGAQUFBzAChkNodHRwOi8vY3J0LnNlY3RpZ28uY29tL1NlY3Rp
Z29QdWJsaWNTZXJ2ZXJBdXRoZW50aWNhdGlvblJvb3RSNDYucDdjMCMGCCsGAQUF
BzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOCAgEA
YtOC9Fy+TqECFw40IospI92kLGgoSZGPOSQXMBqmsGWZUQ7rux7cj1du6d9rD6C8
ze1B2eQjkrGkIL/OF1s7vSmgYVafsRoZd/IHUrkoQvX8FZwUsmPu7amgBfaY3g+d
q1x0jNGKb6I6Bzdl6LgMD9qxp+3i7GQOnd9J8LFSietY6Z4jUBzVoOoz8iAU84OF
h2HhAuiPw1ai0VnY38RTI+8kepGWVfGxfBWzwH9uIjeooIeaosVFvE8cmYUB4TSH
5dUyD0jHct2+8ceKEtIoFU/FfHq/mDaVnvcDCZXtIgitdMFQdMZaVehmObyhRdDD
4NQCs0gaI9AAgFj4L9QtkARzhQLNyRf87Kln+YU0lgCGr9HLg3rGO8q+Y4ppLsOd
unQZ6ZxPNGIfOApbPVf5hCe58EZwiWdHIMn9lPP6+F404y8NNugbQixBber+x536
WrZhFZLjEkhp7fFXf9r32rNPfb74X/U90Bdy4lzp3+X1ukh1BuMxA/EEhDoTOS3l
7ABvc7BYSQubQ2490OcdkIzUh3ZwDrakMVrbaTxUM2p24N6dB+ns2zptWCva6jzW
r8IWKIMxzxLPv5Kt3ePKcUdvkBU/smqujSczTzzSjIoR5QqQA6lN1ZRSnuHIWCvh
JEltkYnTAH41QJ6SAWO66GrrUESwN/cgZzL4JLEqz1Y=
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIIFijCCA3KgAwIBAgIQdY39i658BwD6qSWn4cetFDANBgkqhkiG9w0BAQwFADBf
MQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTYwNAYDVQQD
Ey1TZWN0aWdvIFB1YmxpYyBTZXJ2ZXIgQXV0aGVudGljYXRpb24gUm9vdCBSNDYw
HhcNMjEwMzIyMDAwMDAwWhcNNDYwMzIxMjM1OTU5WjBfMQswCQYDVQQGEwJHQjEY
MBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTYwNAYDVQQDEy1TZWN0aWdvIFB1Ymxp
YyBTZXJ2ZXIgQXV0aGVudGljYXRpb24gUm9vdCBSNDYwggIiMA0GCSqGSIb3DQEB
AQUAA4ICDwAwggIKAoICAQCTvtU2UnXYASOgHEdCSe5jtrch/cSV1UgrJnwUUxDa
ef0rty2k1Cz66jLdScK5vQ9IPXtamFSvnl0xdE8H/FAh3aTPaE8bEmNtJZlMKpnz
SDBh+oF8HqcIStw+KxwfGExxqjWMrfhu6DtK2eWUAtaJhBOqbchPM8xQljeSM9xf
iOefVNlI8JhD1mb9nxc4Q8UBUQvX4yMPFF1bFOdLvt30yNoDN9HWOaEhUTCDsG3X
ME6WW5HwcCSrv0WBZEMNvSE6Lzzpng3LILVCJ8zab5vuZDCQOc2TZYEhMbUjUDM3
IuM47fgxMMxF/mL50V0yeUKH32rMVhlATc6qu/m1dkmU8Sf4kaWD5QazYw6A3OAS
VYCmO2a0OYctyPDQ0RTp5A1NDvZdV3LFOxxHVp3i1fuBYYzMTYCQNFu31xR13NgE
SJ/AwSiItOkcyqex8Va3e0lMWeUgFaiEAin6OJRpmkkGj80feRQXEgyDet4fsZfu
+Zd4KKTIRJLpfSYFplhym3kT2BFfrsU4YjRosoYwjviQYZ4ybPUHNs2iTG7sijbt
8uaZFURww3y8nDnAtOFr94MlI1fZEoDlSfB1D++N6xybVCi0ITz8fAr/73trdf+L
HaAZBav6+CuBQug4urv7qv094PPK306Xlynt8xhW6aWWrL3DkJiy4Pmi1KZHQ3xt
zwIDAQABo0IwQDAdBgNVHQ4EFgQUVnNYZJX5khqwEioEYnmhQBWIIUkwDgYDVR0P
AQH/BAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQEMBQADggIBAC9c
mTz8Bl6MlC5w6tIyMY208FHVvArzZJ8HXtXBc2hkeqK5Duj5XYUtqDdFqij0lgVQ
YKlJfp/imTYpE0RHap1VIDzYm/EDMrraQKFz6oOht0SmDpkBm+S8f74TlH7Kph52
gDY9hAaLMyZlbcp+nv4fjFg4exqDsQ+8FxG75gbMY/qB8oFM2gsQa6H61SilzwZA
Fv97fRheORKkU55+MkIQpiGRqRxOF3yEvJ+M0ejf5lG5Nkc/kLnHvALcWxxPDkjB
JYOcCj+esQMzEhonrPcibCTRAUH4WAP+JWgiH5paPHxsnnVI84HxZmduTILA7rpX
DhjvLpr3Etiga+kFpaHpaPi8TD8SHkXoUsCjvxInebnMMTzD9joiFgOgyY9mpFui
TdaBJQbpdqQACj7LzTWb4OE4y2BThihCQRxEV+ioratF4yUQvNs+ZUH7G6aXD+u5
dHn5HrwdVw1Hr8Mvn4dGp+smWg9WY7ViYG4A++MnESLn/pmPNPW56MORcr3Ywx65
LvKRRFHQV80MNNVIIb/bE/FmJUNS0nAiNs2fxBx1IK1jcmMGDw4nztJqDby1ORrp
0XZ60Vzk50lJLVU3aPAaOpg+VBeHVOmmJ1CJeyAvP/+/oYtKR5j/K3tJPsMpRmAY
QqszKbrAKbkTidOIijlBO8n9pu0f9GBj39ItVQGL
-----END CERTIFICATE-----
''';

  static http.Client? _siteHttpClient;

  static http.Client get _siteClient {
    if (_siteHttpClient != null) return _siteHttpClient!;
    try {
      final context = SecurityContext(withTrustedRoots: true);
      context.setTrustedCertificatesBytes(utf8.encode(_sectigoPem));
      _siteHttpClient = IOClient(HttpClient(context: context));
    } catch (e) {
      debugPrint(
        'Faculty directory: SecurityContext setup failed ($e), using default client',
      );
      _siteHttpClient = http.Client();
    }
    return _siteHttpClient!;
  }

  // ================= PARSING =================

  /// Reads a faculty-offices CSV into people.
  ///
  /// The sheet is not a tidy table. It opens with a title row and a
  /// header row, files the head of the faculty above every department
  /// with no serial number at all, marks each department with a
  /// `Faculty Department of …` row spanning the width of the sheet, and
  /// ends Software Engineering with a row that is entirely blank.
  ///
  /// So the parse keys off two signals rather than on column numbers:
  ///
  /// * a row beginning `Faculty Department of` switches which department
  ///   the following people belong to;
  /// * a row containing an `@` is a person.
  ///
  /// Everything else — title, header, department marker, blank row —
  /// fails the second test and falls out, which is why the head of the
  /// faculty is still found: their serial number is missing and their
  /// name has slid into the first column, but their email has not
  /// moved.
  ///
  /// Rows are **not** de-duplicated. The sheet genuinely contains two
  /// people called Irfan Ullah in different departments at different
  /// ranks, and Science & Humanities lists Mishal Shahid and Maheen Ali
  /// twice with different addresses. Any merge keyed on a name would
  /// delete a real faculty member to tidy up a row; the sheet's owner
  /// is the one who can tell which copy is right.
  static ({List<FacultyMember> members, String term}) parseFacultyCsv(
    String csv, {
    required String school,
  }) {
    final members = <FacultyMember>[];
    var department = '';

    // The title is the first row, column zero, and it names the term the
    // list was published for. Read before the loop rather than inside it:
    // any later row that fails the email test is junk, and letting those
    // compete for the term would let a stray `3,,,,` row win.
    final rows = parseCsv(csv);
    final term = rows.isEmpty ? '' : _clean(rows.first.first);

    for (final raw in rows) {
      final cells = [for (final c in raw) _clean(c)];
      if (cells.every((c) => c.isEmpty)) continue;

      // A department marker, before the email test: it has no email and
      // would otherwise be skipped as noise.
      final marker = cells.first.toLowerCase();
      if (marker.startsWith(_departmentPrefix)) {
        // Only a marker when the rest of the row is empty — a person's
        // name could begin with the same words, though none does yet.
        if (cells.skip(1).every((c) => c.isEmpty)) {
          department = _clean(cells.first.substring(_departmentPrefix.length));
          continue;
        }
      }

      final emailAt = cells.indexWhere((c) => c.contains('@'));
      // No email means this is not a person: the header row, a
      // department marker, a blank row left behind by the sheet's own
      // editor.
      if (emailAt < 0) continue;

      // Walk back from the email rather than counting columns from the
      // left, because the head of the faculty has no serial number and
      // so every column after theirs sits one place to the left of where
      // everyone else's does.
      final designationAt = _lastNonEmptyBefore(cells, emailAt);
      final nameAt =
          designationAt == null ? null : _lastNonEmptyBefore(cells, designationAt);
      if (nameAt == null) continue; // an email with no name above it

      members.add(
        FacultyMember.fromRow(
          name: cells[nameAt],
          designation: designationAt == null ? '' : cells[designationAt],
          email: cells[emailAt],
          office: emailAt + 1 < cells.length ? cells[emailAt + 1] : '',
          // Filed under no department means filed under nobody but the
          // head — the sheet puts the FSC head above every marker.
          department: department.isEmpty ? _fscDepartment : department,
          school: school,
        ),
      );
    }

    return (members: members, term: term);
  }

  /// Reads one campus-website faculty page into people.
  ///
  /// The page's unit is `class="faculty-card"`: a photo, an `<h4>` name,
  /// a `faculty-title` designation, sometimes a bio, and a contact row
  /// of `Tel:` extension, `mailto:` and profile links. Cards are cut at
  /// their own opening tag, and a card with no `mailto:` link at all is
  /// not a person — the same test the CSV parser uses (`an address
  /// makes a person`), which throws page furniture out.
  ///
  /// One real card (Ms. Tooba, DCE) carries an empty address —
  /// `href="mailto:"`, the site's own oversight. She is still listed:
  /// making a colleague disappear over the university's typo is worse
  /// than a card with no Email button, which the directory screen
  /// already knows how to draw.
  ///
  /// The `Tel:` links are phone extensions (`4000`, sometimes the
  /// placeholder `123`), never rooms, so the office is left empty here
  /// for [kFacultyOfficeSheetId] to fill in later.
  static List<FacultyMember> parseFacultyHtml(
    String html, {
    required String school,
    required String department,
  }) {
    final starts = [for (final m in _cardStart.allMatches(html)) m.start];
    if (starts.isEmpty) {
      // The fetch proved the page has contacts, so a page that parses
      // to nothing means the markup moved. Throwing keeps the cached
      // list; returning empty would quietly delete the school.
      throw const FormatException('Faculty page markup not recognised');
    }

    final members = <FacultyMember>[];
    final seen = <String>{};
    for (var i = 0; i < starts.length; i++) {
      // Cut at the next card rather than at any closing tag: how deep
      // the divs nest is the page's business, and the fields wanted are
      // the first of each kind inside the card anyway.
      final card = html.substring(
        starts[i],
        i + 1 < starts.length ? starts[i + 1] : html.length,
      );

      // A card with no address row at all is furniture, not a person.
      // The link itself may be empty (`href="mailto:"`); the extract
      // below then just comes back with no address.
      if (!card.contains('mailto:')) continue;
      final emailAt = _mailto.firstMatch(card);
      final email = emailAt?.group(1)?.split('?').first ?? '';

      final name = _field(card, _h4);
      if (name == null || name.isEmpty) continue; // an address, no one
      var designation = _field(card, _title) ?? '';
      // The spotlight's own line, should it ever sit inside a card with
      // an address: the same person is always listed properly below it.
      if (designation.toLowerCase() == 'head of department') continue;

      // Two cards with no address are two people, not one — an empty
      // email is no key to dedupe on.
      if (email.isNotEmpty && !seen.add(email.toLowerCase())) continue;

      members.add(
        FacultyMember.fromRow(
          name: name,
          designation: designation,
          email: email,
          office: '', // the site publishes no rooms
          department: department,
          school: school,
        ),
      );
    }
    return members;
  }

  /// Reads the office overlay CSV into `email (lowercased) → room`.
  ///
  /// Two columns, `Email | Office`, plus whatever header row the sheet
  /// opens with — which the email test discards, along with any row
  /// that has an address but no room beside it, leaving that person
  /// unlisted rather than roomless-in-name-only.
  static Map<String, String> parseOfficeCsv(String csv) {
    final offices = <String, String>{};
    for (final raw in parseCsv(csv)) {
      final cells = [for (final c in raw) _clean(c)];
      final emailAt = cells.indexWhere((c) => c.contains('@'));
      if (emailAt < 0 || emailAt + 1 >= cells.length) continue;
      final office = cells[emailAt + 1];
      if (office.isEmpty) continue;
      offices[cells[emailAt].toLowerCase()] = office;
    }
    return offices;
  }

  /// Writes overlay rooms onto members, keyed by lowercased email.
  ///
  /// Keyed on email because the directory genuinely holds two people
  /// called Irfan Ullah, and email is the one field the site and the
  /// sheet agree is per-person. A member no overlay row mentions keeps
  /// whatever the sheet gave them — Computing's 195 rooms included —
  /// and where a row exists the overlay has the final word.
  static List<FacultyMember> applyOffices(
    List<FacultyMember> members,
    Map<String, String> offices,
  ) {
    if (offices.isEmpty) return members;
    final merged = <FacultyMember>[];
    for (final m in members) {
      final room = offices[m.email.toLowerCase()];
      merged.add(
        room == null
            ? m
            : FacultyMember.fromRow(
                name: m.name,
                designation: m.designation,
                email: m.email,
                office: room,
                department: m.department,
                school: m.school,
              ),
      );
    }
    return merged;
  }

  // ================= CACHE =================

  Future<FacultyDirectory?> _readCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return null;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (decoded['v'] != _cacheVersion) return null; // stale format
      return (
        members: [
          for (final m in decoded['members'] as List<dynamic>)
            FacultyMember.fromJson(Map<String, dynamic>.from(m as Map)),
        ],
        term: decoded['term'] as String? ?? '',
        fetchedAt:
            DateTime.tryParse(decoded['fetchedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        fromCache: true,
      );
    } catch (e) {
      debugPrint('Faculty cache read failed: $e');
      return null;
    }
  }

  Future<void> _writeCache(
    List<FacultyMember> members,
    String term,
    DateTime fetchedAt,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey,
        jsonEncode({
          'v': _cacheVersion,
          'fetchedAt': fetchedAt.toIso8601String(),
          'term': term,
          'members': [for (final m in members) m.toJson()],
        }),
      );
    } catch (e) {
      debugPrint('Faculty cache write failed: $e');
    }
  }

  // Test hook. Only [load] should drive the parser; tests hand it a
  // saved copy of the real sheet instead of fetching over the network.
  ({List<FacultyMember> members, String term}) debugParseFacultyCsv(
    String csv, {
    String school = 'School of Computing',
  }) => parseFacultyCsv(csv, school: school);

  List<FacultyMember> debugParseFacultyHtml(
    String html, {
    String school = 'School of Engineering',
    String department = 'Computer Engineering',
  }) => parseFacultyHtml(html, school: school, department: department);

  Map<String, String> debugParseOfficeCsv(String csv) => parseOfficeCsv(csv);

  List<FacultyMember> debugApplyOffices(
    List<FacultyMember> members,
    Map<String, String> offices,
  ) => applyOffices(members, offices);

  // Test hook. Lets the test suite prove the embedded PEM still parses
  // into real certificates, so a typo here fails the build, not a fetch.
  String get debugSectigoPem => _sectigoPem;

  static const String _departmentPrefix = 'faculty department of';

  /// The department the sheet files the head of the faculty under: none
  /// of them, because that row sits above every department marker.
  static const String _fscDepartment = 'FSC Administration';

  // ---- reading the website ----

  /// Each card's opening tag, which is where a card is cut from.
  static final RegExp _cardStart = RegExp(
    r'<div[^>]*class="[^"]*faculty-card[^"]*"',
  );

  static final RegExp _mailto = RegExp(r'''mailto:([^"'\s<>]+)''');

  static final RegExp _h4 = RegExp(r'<h4[^>]*>(.*?)</h4>', dotAll: true);

  static final RegExp _title = RegExp(
    r'<p[^>]*class="[^"]*faculty-title[^"]*"[^>]*>(.*?)</p>',
    dotAll: true,
  );

  /// The text of [re]'s first match in [html] — inner tags dropped,
  /// entities read, whitespace collapsed — or null when the field is
  /// not on the page at all.
  static String? _field(String html, RegExp re) {
    final m = re.firstMatch(html);
    if (m == null) return null;
    final inner = m.group(1)!.replaceAll(RegExp(r'<[^>]*>'), ' ');
    return _clean(_decodeEntities(inner));
  }

  /// What the site writes as `&amp;` back into what a person reads as
  /// `&`, plus the numeric forms a name containing an apostrophe or a
  /// dash would arrive in. `&amp;` is decoded last so a double-encoded
  /// `&amp;#39;` ends up an apostrophe rather than stopped halfway.
  static String _decodeEntities(String s) => s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAllMapped(
        RegExp(r'&#x([0-9a-fA-F]+);'),
        (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
      )
      .replaceAllMapped(
        RegExp(r'&#(\d+);'),
        (m) => String.fromCharCode(int.parse(m.group(1)!)),
      )
      .replaceAll('&amp;', '&');

  /// A cell's worth of the sheet's sloppiness: tabs, carriage returns
  /// and line breaks all become one space, and runs of spaces collapse.
  ///
  /// This is where `"Mr. Shoaib Saleem Khattak \n"` stops being a name
  /// with a line break hiding in it, and `Dr. Muhammad Arshad Islam \t`
  /// stops carrying a tab nobody can see until it is printed.
  static String _clean(String s) => s
      .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// The last non-empty cell before [before], or null.
  static int? _lastNonEmptyBefore(List<String> cells, int before) {
    for (var i = before - 1; i >= 0; i--) {
      if (cells[i].isNotEmpty) return i;
    }
    return null;
  }
}
