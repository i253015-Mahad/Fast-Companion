# Session Notes

## Task (CURRENT) — Faculty directory: website sources + office overlay + per-source resilience, error cause display, & campus SSL trust fix

**Status: DONE (verified). Next: user builds & installs the APK, then confirms on the phone that Engineering/Management load with no handshake errors.**

**Background:** The university publishes no faculty sheets for Engineering or Management. Identity (name, designation, email) is scraped from the campus website (DCE, DEE, DMS, DAF); office numbers come from a thin overlay sheet the user fills gradually. Computing's sheet stays untouched. SCHOOL filter row was removed per user request (departments feed the DEPT filter row instead). Additionally, the load mechanism was made **per-source resilient** with a quick retry and on-screen exception reporting so any network/DNS/parse issues on the phone degrade gracefully rather than dying completely. Finally, a **CERTIFICATE_VERIFY_FAILED** seen only on the phone (all 4 site pages failing, Google sheet fine) was traced to the device's Android trust store missing *Sectigo Public Server Authentication Root R46* (2021) that `isb.nu.edu.pk` chains to — fixed by extending the site fetch's trust with the embedded public root.

**Files changed:**
- `lib/services/faculty_directory_service.dart`:
  - `FacultySitePage {url, school, department}` + `kFacultySitePages` — 4 pages: `Faculty-DCE.php`→School of Engineering/Computer Engineering, `Faculty-DEE.php`→Engineering/Electrical Engineering, `Faculty-DMS.php`→Management/Management Sciences, `Faculty-DAF.php`→Management/Accounting & Finance. **DSH deliberately absent** (Computing sheet already lists Science And Humanities → scraping it would duplicate ~34 people).
  - `kFacultyOfficeSheetId = ''` (empty until user supplies overlay sheet link; skipped like an empty sheetId). Overlay: `Email | Office` CSV → `Map<lowercased email, office>`, applied post-parse (`applyOffices`); overlay rows win on match, everyone else keeps sheet value; **fetch failure is non-fatal**.
  - `parseFacultyHtml(html, {school, department})`: cuts cards at `<div class="faculty-card">`; person = card containing `mailto:`; name from `<h4>`, designation from `faculty-title` (entities decoded); office `''`; skips cards without mailto and `Head of Department` exact title (spotlight); dedupe on email only when non-empty; throws `FormatException` if no card markers found.
  - `load({forceRefresh, fetchSheet, fetchSite})`: **per-source resilience**. Reads each of the 5 sources in its own `_attempt` (1 quick retry if first attempt failed quickly; timeouts skipping retry). Preference order: full fresh → full cached → **partial fresh** (handed back uncached so next open retries missing sources) → rethrow first failure only if *all* sources fail and no cache exists.
  - Test hooks: `fetchSheet` / `fetchSite` injected params on `load()`.
  - `_cacheVersion` **1 → 2**.
  - **SSL trust fix:** `_sectigoPem` const embeds the two public certs of the live chain (Sectigo Public Server Authentication **CA DV R36** intermediate + **Root R46**); lazy `_siteClient` builds `SecurityContext(withTrustedRoots: true)..setTrustedCertificatesBytes(utf8.encode(_sectigoPem))` + `IOClient(HttpClient(context:…))`; `_fetchSite` routes through it (`_fetchSheet` untouched on default client). Any setup error falls back to `http.Client()` with a debugPrint — never disables SSL verification. Test hook `debugSectigoPem`.
- `lib/Screens/teachers_screen.dart`:
  - **SCHOOL filter row deleted** + `_schoolAll`, `_school` state, `_schools` getter, and school clause in `_visible`. DEPT/RANK/SORT rows derive from data automatically.
  - `_errorDetail` field + `_shortCause(e)` helper: under "Could not load the faculty list. Check your connection", surfaces the short exception string (`FormatException`, `SocketException`, `TimeoutException`) in small selectable text so device-side failures report their exact cause.
- `test/faculty_directory_test.dart`:
  - +18 tests total (+13 html/overlay + 4 load resilience + 1 PEM test: both certs present and `setTrustedCertificatesBytes` accepts them without throwing).

**Verification:**
- ✅ `dart analyze lib test` — No issues found.
- ✅ `flutter test` — **209/209 passing** (191 original + 18 new).
- ✅ Chain proof (node tls, trust store = the exact embedded PEM, server `isb.nu.edu.pk`): `authorized: true`. Live chain: leaf → DV R36 → Root R46 (server sends all three).
- ⏳ On-phone confirmation pending (device `DSP2XAXIII001515` was detached at final step): expect zero `CERTIFICATE_VERIFY_FAILED` and Eng/Mgmt lists visible. If it ever regresses, the on-screen error detail (Teachers tab) shows the exact exception.
- `dart format` NOT run (project-wide non-compliance).

**Files:** `lib/services/faculty_directory_service.dart`, `lib/Screens/teachers_screen.dart`, `test/faculty_directory_test.dart`, `SESSION_NOTES.md`. No pubspec/Firebase changes.

**User still owes (non-blocking):** office-overlay Google Sheet — share "Anyone with the link → Viewer", columns `Email | Office`; paste the link and I extract the ID into `kFacultyOfficeSheetId`. Until then Eng/Mgmt show *"No office listed"*.

---

## Task (PREVIOUS) — Analytics sheet: "Abs Diff" rename, Class Avg row, single standing bar (now percentage-based)

**Status: DONE (verified). Next: user builds & installs the APK.**

**User's requests (verbatim):** *"in the first row (your score stays as it is, class average stays as it is, abs diff claculation stays as is, just change the name from "Diff from Avg" to "Abs Diff") in the box (Attained absolutes as is, after attainded abs, show class avg abs, and finally the remaining abs as is) and finally the bars (make it a single bar of 100 abs with a verticle line on it showing avg abs, and another showing where we stand)"*, then a correction: *"you got it all wrong, you have changed the attained abs which I told you not to change and because of that the class avg abs is also wrong. Put those back as they were. And in the bar write 0 on the left and 100 on the right below the bar to show the range. I said that in your calculation of remaining abs, you need to do 100 - alloted abs and that was it"*, then: *"Everything is perfect now!! Just one change which is in the final bar. instead of showing abs, show the percentage, the rest remains exactly the same"* — when asked which percentage, the user chose **"Score on graded work (80.0% / 70.0%)"**, not course completion.

**IMPORTANT — a normalisation was added and then fully reverted.** An earlier round applied a `100/Σweightage` factor to the absolutes; the user rejected it. The model is back to its **original raw getters** — do not reintroduce scaling.

**Files changed:**
- `lib/models/flex_marks_model.dart` — reverted to raw sums; only rule is `remainingWeightage = 100.0 - evaluatedWeightage` (`< 0` guard kept). `_rawTotalWeightage` / `_normalisationFactor` deleted. `totalWeightage` = Σ item weightage (always 100 for real FAST courses). `attainedAbsolutes` / `classAvgAbsolutes` / `evaluatedWeightage` are plain folds with **no factor**. `percentage` / `classAvgPercentage` / `diffFromAvg` / `letterGrade` / `gradePoint` untouched.
- `lib/widgets/flex_marks_analytics.dart` — the UI changes below + overflow hardening.
- `test/flex_marks_analytics_test.dart` — **new**, 6 tests, retargeted to raw semantics.

**Widget (`flex_marks_analytics.dart`):**
1. Tile label `'Diff from Avg'` → **`'Abs Diff'`** (value/sign/colors unchanged).
2. Grey box = three rows via `_boxRow(label, value)`, in order: `Attained Absolutes: 32.0 / 100.0 (80.0%)` → `Class Avg Absolutes: 28.0 / 100.0 (70.0%)` (new) → `Remaining Absolutes: 60.0`.
3. Both progress bars + `_buildProgressBar` **deleted**; `_buildStandingBar(percentage, classAvgPercentage)` — **percentage, not absolutes** (call site line ~160; both locals already in `build()`): header **`Standing (0–100%)`**, grey 6px track, orange fill to your score (80% of track), dark (`textPrimary`) 3px line at the class avg score (70%), orange 3px line at your position **drawn last** (wins on overlap), lines span 20px and overhang the track, then a `SpaceBetween` row of **`0%` (left end) and `100%` (right end)**, then legend **`You 80.0%  ·  Avg 70.0%`** — the same figures as the two tiles. `LayoutBuilder` + `Stack` + `Positioned`; fractions clamped `0..1`, left clamped `[0, w-3]`. Params renamed `yourScore`/`classAvgScore`. **Untouched:** box rows, three tiles, `Abs Diff`, grade badge, Semester GPA, `attained`/`classAvgAbsolutes`/`total`/`remaining` locals.

**Overflow fix (keep):** grey-box rows overflowed because `RenderFlex` lays **non-flexible** children out **unbounded** — a plain `Text` (or an `FittedBox` around one) takes natural width and blows past the Row, and a `Flexible` label alone can't help when the *value* is the wide part. Fix in `_boxRow`: **both** children `Flexible`; label ellipsizes, value wrapped in `FittedBox(fit: scaleDown)`. Layout only — moves no numbers.

**Tests (6):** model — raw-100 figures exact; raw-95 reported **raw** (attained 23, evaluated 40, classAvg 25, total 95) with `remaining == 100 - evaluated == 60`; percentages/diff/grade from raw sums (`diffFromAvg == -2.0`; grade reads `D+` because 57.5 sits on the D+/C- boundary and `23/40*100` lands a hair under 57.5 in binary — the model's own arithmetic, deliberately unchanged). Widget (DS BD3 Pro 1080x2412@3.0): `Abs Diff`+`+4.0`, three box rows **in order** with exact strings, bar header `Standing (0–100%)`, **`0%` and `100%` each present with `0%.left == track.left` and `100%.right == track.right`**, legend figures `'80.0%'`/`'70.0%'` asserted as **`findsNWidgets(2)`** (tile + legend each — exact `'32.0'`/`'28.0'` strings no longer exist anywhere on the card, so those finds were dropped), the 4 `Positioned` children measured against the track's width (`fill == 80%`, avg at `70% - 1.5`, you at `80% - 1.5`, colors `textPrimary`/`cardOrange`, you-line last), ungraded course keeps both markers at the left edge (0%).

**Verification:**
- ✅ `dart analyze lib test` — No issues found.
- ✅ `flutter test` — **191/191 passing**.
