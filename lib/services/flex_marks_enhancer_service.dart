import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/flex_marks_model.dart';
import 'local_storage_service.dart';

/// Reads the marks the Flex portal has already put on screen and turns it
/// into numbers the portal never shows: attained absolutes, your percentage,
/// the class average and the gap to it, and how much weightage is still to
/// come.
///
/// The split of labour is deliberate:
///
///  * JavaScript does the *reading*. It is inside the page, so it has the
///    parsed DOM for free — a Dart parser would have to re-fetch the page,
///    and the portal gives a session exactly five requests (the budget that
///    killed background polling). It sends back raw items and nothing else.
///  * Dart does the *arithmetic*, in [FlexCourseMarks], so the in-page cards
///    and the native analytics card are two renderings of one calculation
///    and can never drift apart.
///  * JavaScript does the *drawing* again only when Dart hands it the
///    finished metrics via `window.__fcRenderMetrics`.
///
/// The script is a raw string on purpose: it is JavaScript, and a non-raw
/// Dart string silently eats the backslashes its regular expressions need
/// (`\d` becomes `d`, which quietly stops every course code from matching)
/// while reading its `${...}` template holes as Dart interpolation.
class FlexMarksEnhancerService {
  FlexMarksEnhancerService._();

  static final FlexMarksEnhancerService instance = FlexMarksEnhancerService._();

  static const String _marksEnhancerScript = r'''
    (function () {
      if (window.__fcMarksEnhancerApplied) return;
      window.__fcMarksEnhancerApplied = true;

      function isMarksPage() {
        return window.location.pathname.toLowerCase().includes('studentmarks');
      }

      function toNumber(text) {
        if (text === undefined || text === null) return null;
        // Cells may carry a unit the markup never announces (the old
        // scraper stripped a lone currency mark, so something was there).
        // Replacing rather than deleting keeps "77/100" readable as 77 —
        // parseFloat stops at the space, where deletion would glue the
        // two halves into one enormous mark.
        var cleaned = String(text).replace(/[^0-9.+-]/g, ' ');
        var value = parseFloat(cleaned);
        return isNaN(value) ? null : value;
      }

      // A cell is read by the class the portal gives it (.weightage,
      // .ObtMarks, …), falling back to its column position for markup that
      // ships without those classes. The positional path needs all eight
      // columns: with fewer, the positions below would point at the wrong
      // cell, which is how min and max were being read from stddev.
      function cellText(row, className, index) {
        if (className) {
          var byClass = row.querySelector('td.' + className);
          if (byClass) return (byClass.textContent || '').trim();
        }
        var cells = row.querySelectorAll('td');
        if (cells.length < 8) return '';
        return (cells[index] ? cells[index].textContent : '').trim();
      }

      function scrapeMarksPage() {
        var courses = [];

        document.querySelectorAll('.tab-pane').forEach(function (tab) {
          if (!tab.id) return;

          var titleElement = tab.querySelector('h5');
          var courseTitle = titleElement ? titleElement.textContent.trim() : '';
          var courseCode = courseTitle.match(/[A-Z]+\d+/)
            ? courseTitle.match(/[A-Z]+\d+/)[0]
            : '';

          // A tab with no marks table is a leftover of the portal's
          // navigation, not a course — and matching on the table rather
          // than a hand-kept list of department prefixes is what lets a
          // degree outside CL/CS/EE/EL/MT/SE/SS be read at all.
          if (!courseCode || !tab.querySelector('.sum_table')) return;

          var sectionMatch = courseTitle.match(/\([A-Z]+-\d+[A-Z-]*\)/);
          var items = [];

          tab.querySelectorAll('.card').forEach(function (card) {
            var header = card.querySelector('.card-header');
            var category = header
              ? (header.id || (header.querySelector('button')
                  ? header.querySelector('button').textContent
                  : ''))
              : '';
            category = category.trim();

            // The portal's own grand-total table is empty until its
            // onclick runs, and the totals are computed in Dart anyway.
            if (!category || category === 'Grand Total Marks') return;

            card.querySelectorAll('.sum_table .calculationrow').forEach(function (row) {
              var weightage = toNumber(cellText(row, 'weightage', 1));
              if (weightage === null || weightage <= 0) return;

              // There is no name column — the header reads "Lab Work #" —
              // so an item is named after its category and its number.
              items.push({
                name: category + ' ' + cellText(row, '', 0),
                category: category,
                weightage: weightage,
                obtainedMarks: toNumber(cellText(row, 'ObtMarks', 2)),
                totalMarks: toNumber(cellText(row, 'GrandTotal', 3)),
                averageMarks: toNumber(cellText(row, 'AverageMarks', 4)),
                stdDev: toNumber(cellText(row, 'StdDev', 5)),
                minMarks: toNumber(cellText(row, 'MinMarks', 6)),
                maxMarks: toNumber(cellText(row, 'MaxMarks', 7)),
              });
            });
          });

          if (items.length === 0) return;

          courses.push({
            courseCode: courseCode,
            courseName: courseTitle,
            section: sectionMatch ? sectionMatch[0] : '',
            items: items,
          });
        });

        return courses;
      }

      // Walks every table on the page: the transcript renders one table
      // per semester, so no single id can be assumed. A row qualifies when
      // one cell contains a course-code pattern and a later cell holds a
      // plain integer 1-6 — the plain-integer rule is what keeps a 3.7
      // grade point from being read as 3 credits.
      function scrapeCreditsPage() {
        var credits = {};
        var rowsAccepted = 0;
        document.querySelectorAll('table tbody tr').forEach(function (row) {
          var cells = row.querySelectorAll('td');
          if (cells.length < 3) return;

          var code = null;
          var codeIndex = -1;
          for (var i = 0; i < cells.length; i++) {
            var found = (cells[i].textContent || '').trim().match(/[A-Za-z]{2,5}\s*-?\d{3,5}/);
            if (found) {
              code = found[0];
              codeIndex = i;
              break;
            }
          }
          if (!code) return;

          for (var j = codeIndex + 1; j < cells.length; j++) {
            var text = (cells[j].textContent || '').trim();
            if (!/^\d{1,2}$/.test(text)) continue;
            var value = parseInt(text, 10);
            if (value >= 1 && value <= 6) {
              credits[code] = value;
              rowsAccepted++;
              return;
            }
          }
        });
        return { credits: credits, rows: rowsAccepted };
      }

      function enhanceMarksPage() {
        try {
          // Transcript page: scrape the course → credit mapping only.
          // 'transcript' without the slash, because the real route is not
          // guaranteed to sit directly under the origin (ViewTranscript,
          // MyTranscript, … would all miss a '/transcript' check).
          if (window.location.pathname.toLowerCase().includes('transcript')) {
            var result = scrapeCreditsPage();
            var creditsData = result.credits || {};
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              if (Object.keys(creditsData).length > 0) {
                window.flutter_inappwebview.callHandler('onFlexCreditsParsed', {
                  credits: creditsData,
                });
              }
              // Reported even when nothing matched: an empty parse is
              // invisible otherwise, and the counts say whether the page
              // shape or the values were the reason.
              window.flutter_inappwebview.callHandler('onFlexDebug', {
                source: 'transcript',
                pathname: window.location.pathname,
                tables: document.querySelectorAll('table').length,
                rows: result.rows || 0,
                codes: Object.keys(creditsData).slice(0, 5),
              });
            }
            return;
          }

          if (!isMarksPage()) return;

          var marksData = scrapeMarksPage();
          if (marksData.length === 0) return;

          // Raw items only. Every percentage on this page is computed by
          // FlexCourseMarks in Dart and sent back through
          // __fcRenderMetrics — the box in the page and the cards in the
          // bottom sheet are the same numbers twice because Dart, not two
          // languages, did the sum.
          if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
            window.flutter_inappwebview.callHandler('onFlexMarksParsed', {
              timestamp: Date.now(),
              data: marksData,
            });
          }
        } catch (error) {
          console.error('Fast Companion: Error enhancing marks page:', error);
        }
      }

      function clearRenderedMarks() {
        document.querySelectorAll('[data-fc-marks]').forEach(function (node) {
          node.remove();
        });
        var style = document.getElementById('fc-marks-style');
        if (style) style.remove();
      }

      // Called from Dart with metrics that are already computed.
      window.__fcRenderMetrics = function (payload) {
        if (!payload || !payload.overall) return;
        if (!isMarksPage()) return;

        clearRenderedMarks();

        var style = document.createElement('style');
        style.id = 'fc-marks-style';
        style.textContent = `
          .fast-companion-marks-summary {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 20px;
            margin: 20px 0;
            border-radius: 12px;
            box-shadow: 0 4px 20px rgba(0,0,0,0.15);
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
          }

          .fast-companion-metrics {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 15px;
            margin: 15px 0;
          }

          .fast-companion-metric {
            text-align: center;
            padding: 10px;
            background: white;
            border-radius: 8px;
            border: 1px solid #e9ecef;
          }

          .fast-companion-metric-value {
            font-size: 24px;
            font-weight: bold;
            color: #667eea;
          }

          .fast-companion-metric-label {
            font-size: 12px;
            color: #6c757d;
            margin-top: 4px;
          }
        `;
        document.head.appendChild(style);

        var overall = payload.overall || {};
        var contentDiv = document.querySelector('.m-content');
        if (contentDiv) {
          var summary = document.createElement('div');
          summary.className = 'fast-companion-marks-summary';
          summary.setAttribute('data-fc-marks', '');
          summary.innerHTML = `
            <h3 style="margin: 0 0 15px 0;">📊 Semester Overview</h3>
            <div id="fast-companion-summary-stats">
              <div class="fast-companion-metrics">
                <div class="fast-companion-metric">
                  <div class="fast-companion-metric-value">${(overall.percentage || 0).toFixed(1)}%</div>
                  <div class="fast-companion-metric-label">Your Score · ${overall.courseCount || 0} courses</div>
                </div>
                <div class="fast-companion-metric">
                  <div class="fast-companion-metric-value">${(overall.classAvgPercentage || 0).toFixed(1)}%</div>
                  <div class="fast-companion-metric-label">Class Avg</div>
                </div>
              </div>
            </div>
          `;
          // At the bottom, after the last course's tables: the box reads
          // as the page's closing scorecard rather than a banner pushing
          // the portal's own content down.
          contentDiv.appendChild(summary);
        }
      };

      function runEnhancer() {
        enhanceMarksPage();
      }

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', runEnhancer);
      } else {
        runEnhancer();
      }

      var lastUrl = location.href;
      new MutationObserver(function () {
        if (location.href !== lastUrl) {
          lastUrl = location.href;
          setTimeout(runEnhancer, 500);
        }
      }).observe(document, { subtree: true, childList: true });
    })();
  ''';

  /// Set by [FlexScreen]. Receives the first course of every parse, after
  /// the metrics are computed, so the screen knows new data is cached.
  void Function(FlexCourseMarks marks)? onMarksParsed;

  static const String _flexCreditsKey = 'cached_flex_credits';

  /// Saves course-code → credit-hour mapping for weighted GPA.
  Future<void> saveFlexCredits(Map<String, int> credits) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(credits);
      await prefs.setString(_flexCreditsKey, encoded);
    } catch (e) {
      debugPrint('Fast Companion: Failed to save credits: $e');
    }
  }

  /// Loads cached credit mapping.
  Future<Map<String, int>> loadFlexCredits() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final encoded = prefs.getString(_flexCreditsKey);
      if (encoded == null || encoded.isEmpty) return {};
      final rawMap = jsonDecode(encoded);
      if (rawMap is! Map) return {};
      final Map<String, int> result = {};
      rawMap.forEach((k, v) {
        if (v is num) {
          result[k.toString()] = v.toInt();
        } else if (v is String) {
          result[k.toString()] = int.tryParse(v) ?? 0;
        }
      });
      return result;
    } catch (e) {
      debugPrint('Fast Companion: Failed to load credits: $e');
      return {};
    }
  }

  /// Match keys are compared without case or punctuation so that the marks
  /// page's `CS241` and a transcript cell reading `CS-241` are the same course.
  static String _normalizeCourseKey(String raw) =>
      raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  /// Compute the credits‑weighted semester GPA from cached marks and credits.
  ///
  /// Returns null if no courses with both grades and credits exist.
  Future<double?> computeSemesterGpa() async {
    final courses = await loadCachedMarks();
    if (courses.isEmpty) {
      debugPrint('Fast Companion: GPA null — no cached marks');
      return null;
    }
    final credits = await loadFlexCredits();
    final normalizedCredits = <String, int>{
      for (final entry in credits.entries)
        _normalizeCourseKey(entry.key): entry.value,
    };

    double totalPoints = 0.0;
    double totalCredits = 0.0;

    for (final course in courses) {
      final gradePoint = course.gradePoint; // 0.0–4.0 or null
      if (gradePoint == null) continue;
      final credit = normalizedCredits[_normalizeCourseKey(course.courseCode)] ??
          0;
      if (credit <= 0) continue;
      totalPoints += gradePoint * credit;
      totalCredits += credit;
    }

    if (totalCredits <= 0) {
      debugPrint(
        'Fast Companion: GPA null — ${courses.length} marks, '
        '${credits.length} credit entries, no course matched. '
        'marks keys: ${courses.take(3).map((c) => c.courseCode).toList()}, '
        'credit keys: ${credits.keys.take(3).toList()}',
      );
      return null;
    }
    return totalPoints / totalCredits;
  }

  /// Which controllers have already had the script registered as a user
  /// script. Registered once per WebView: [injectScript] is called again on
  /// every page load (to run the script on the document that just opened),
  /// and piling up a copy per load would scrape the page once per visit.
  static final Expando<bool> _userScriptAddedFor = Expando<bool>(
    'flexMarksEnhancerUserScript',
  );

  /// Makes the marks page read itself and send the items back to Dart.
  ///
  /// Two paths, because they cover different windows: the user script runs
  /// at document start on every load that begins *after* this call, and the
  /// direct evaluation covers the document that is already open. Both are
  /// idempotent — the script refuses to apply twice to one document, and a
  /// second document has nothing to refuse.
  Future<void> injectScript(InAppWebViewController controller) async {
    try {
      if (_userScriptAddedFor[controller] != true) {
        await controller.addUserScript(
          userScript: UserScript(
            source: _marksEnhancerScript,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
            forMainFrameOnly: true,
          ),
        );
        _userScriptAddedFor[controller] = true;
      }

      await controller.evaluateJavascript(source: _marksEnhancerScript);
      debugPrint('Fast Companion: Flex marks enhancer script injected');
    } catch (e) {
      debugPrint('Fast Companion: Failed to inject marks enhancer script: $e');
    }
  }

  /// Registers the handler the page's script posts to, and answers a post
  /// by computing the metrics and asking the page to draw them.
  Future<void> registerJavaScriptHandler(
    InAppWebViewController controller,
  ) async {
    try {
      // Returns void in this plugin version — there is no future to await.
      controller.addJavaScriptHandler(
        handlerName: 'onFlexMarksParsed',
        callback: (args) async {
          try {
            // The page posts ONE object: { timestamp, data }. Reading it as
            // a positional (timestamp, data) pair threw on every message,
            // and the throw was swallowed — so no parse ever reached Dart.
            final payload = args.isNotEmpty ? args.first : null;
            if (payload is! Map) return;

            final rawCourses = payload['data'];
            if (rawCourses is! List || rawCourses.isEmpty) return;

            final courses = rawCourses
                .map(
                  (e) => FlexCourseMarks.fromJson(
                    Map<String, dynamic>.from(e as Map),
                  ),
                )
                .toList();

            await LocalStorageService.saveFlexMarks(
              FlexCourseMarks.encodeList(courses),
            );
            debugPrint(
              'Fast Companion: Received ${courses.length} courses from the marks page',
            );

            // Computing here (rather than in the page) is what keeps the
            // two renderings honest: the box at the bottom of the page and
            // the sheet's cards are the same numbers twice.
            await controller.evaluateJavascript(
              source:
                  'window.__fcRenderMetrics?.(${jsonEncode(_metricsPayload(courses))});',
            );

            // Cache the transcript for later credits-weighted GPA calculation.
            await controller.evaluateJavascript(
              source: '''window.scrapeCreditsPage?.();''',
            );

            onMarksParsed?.call(courses.first);
          } catch (e) {
            debugPrint(
              'Fast Companion: Error processing JavaScript marks data: $e',
            );
          }
        },
      );

      controller.addJavaScriptHandler(
        handlerName: 'onFlexCreditsParsed',
        callback: (args) async {
          try {
            final payload = args.isNotEmpty ? args.first : null;
            if (payload is! Map) return;

            final credits = payload['credits'];
            if (credits is Map) {
              final Map<String, int> parsedCredits = {};
              credits.forEach((k, v) {
                final intVal = (v is num)
                    ? v.toInt()
                    : (int.tryParse(v.toString()) ?? 0);
                parsedCredits[k.toString()] = intVal;
              });
              await saveFlexCredits(parsedCredits);
              debugPrint('Fast Companion: Cached ${parsedCredits.length} credit entries');
            }
          } catch (e) {
            debugPrint('Fast Companion: Error processing credits data: $e');
          }
        },
      );

      controller.addJavaScriptHandler(
        handlerName: 'onFlexDebug',
        callback: (args) async {
          // What the transcript scrape saw — pathname, table count, rows
          // accepted — so a GPA that stays locked can be diagnosed from
          // logcat instead of guessed at.
          final payload = args.isNotEmpty ? args.first : null;
          debugPrint('Flex debug: $payload');
        },
      );

      debugPrint('Fast Companion: Flex marks JavaScript handler registered');
    } catch (e) {
      debugPrint('Fast Companion: Failed to register JS handler: $e');
    }
  }

  /// The metrics the page is asked to draw. Only the semester summary
  /// crosses the bridge — the per-course detail never leaves the cache,
  /// served to the bottom sheet from Dart, and the items themselves have
  /// already been used to do this arithmetic.
  static Map<String, dynamic> _metricsPayload(List<FlexCourseMarks> courses) {
    final attained = courses.fold<double>(
      0.0,
      (s, c) => s + c.attainedAbsolutes,
    );
    final classAvg = courses.fold<double>(
      0.0,
      (s, c) => s + c.classAvgAbsolutes,
    );
    final evaluated = courses.fold<double>(
      0.0,
      (s, c) => s + c.evaluatedWeightage,
    );

    return {
      'generatedAt': DateTime.now().millisecondsSinceEpoch,
      'overall': {
        'courseCount': courses.length,
        // One semester-wide figure, weighted by the work actually graded
        // rather than an average of course averages — a 2-credit course
        // must not outvote a 3-credit one.
        'percentage': evaluated > 0 ? (attained / evaluated) * 100.0 : 0.0,
        'classAvgPercentage': evaluated > 0
            ? (classAvg / evaluated) * 100.0
            : 0.0,
      },
    };
  }

  /// Loads cached marks for offline viewing and for the analytics sheet.
  Future<List<FlexCourseMarks>> loadCachedMarks() async {
    try {
      final jsonStr = await LocalStorageService.loadFlexMarks();
      if (jsonStr.isEmpty) {
        return [];
      }

      final courses = FlexCourseMarks.decodeList(jsonStr);
      debugPrint('Fast Companion: Loaded ${courses.length} courses from cache');
      return courses;
    } catch (e) {
      debugPrint('Fast Companion: Failed to load cached marks: $e');
      return [];
    }
  }

  /// Clears cached marks data and refreshes the current page.
  Future<void> clearCachedMarksAndRefresh(
    InAppWebViewController controller,
  ) async {
    try {
      await LocalStorageService.saveFlexMarks('');
      await controller.reload();
      debugPrint('Fast Companion: Cached marks cleared and page refreshed');
    } catch (e) {
      debugPrint('Fast Companion: Failed to clear cached marks: $e');
    }
  }
}
