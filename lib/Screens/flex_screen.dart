import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/flex_marks_model.dart';
import '../services/flex_marks_enhancer_service.dart';
import '../services/flex_session_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../widgets/flex_marks_analytics.dart';

/// The Flex tab: the university's own student portal, embedded.
///
/// This is stage 1 of the Flex integration — the live site wrapped in
/// native chrome. Sign-in happens on the portal itself: it sits behind
/// Cloudflare Turnstile, which only a real browser engine can run, so
/// this screen never handles credentials. It adopts whatever session the
/// portal issues into [FlexSessionService] after every load, and leaves
/// parsing the portal's HTML into native UI to a later stage — until
/// then the site is rendered by the site, darkened to match the app.
class FlexScreen extends StatefulWidget {
  const FlexScreen({super.key});

  @override
  State<FlexScreen> createState() => _FlexScreenState();
}

class _FlexScreenState extends State<FlexScreen> {
  static const String _darkModeScript = '''
(function () {
  if (window.__fcDarkApplied) return;
  window.__fcDarkApplied = true;

  function boot() {
    var root = document.head || document.documentElement;
    if (!root) { setTimeout(boot, 10); return; }

    var css = [
      'html, body { background-color: #111111 !important; }',
      '.m-body { background-color: #111111 !important; }',
      '.m-wrapper { filter: invert(1) hue-rotate(180deg) !important; }',
      '.m-wrapper img, .m-wrapper picture, .m-wrapper video,',
      '.m-wrapper canvas,',
      '.m-wrapper svg { filter: invert(1) hue-rotate(180deg) !important; }',
      '.m-footer { filter: invert(1) hue-rotate(180deg) !important; }',
      '.m-footer img, .m-footer picture, .m-footer video,',
      '.m-footer canvas, .m-footer svg {',
      '  filter: invert(1) hue-rotate(180deg) !important; }',
      '.m-page--fluid .m-header, .m-page--wide .m-header {',
      '  background-color: #355C7D !important; }',
      '.m-header-head { background-color: #355C7D !important; }',
      '.m-topbar { background-color: transparent !important;',
      '  box-shadow: none !important; }',
      'body.m-header--fixed-mobile .m-topbar { top: -51px !important; }',
      '[id^=\"overlay\"], .loader-box {',
      '  background-color: rgba(0,0,0,0.8) !important; }',
      '[id^=\"overlay\"] *, .loader-box * {',
      '  color: #dcdcdc !important; }',
      '.m-login.m-login--1 { background-color: #1a1a1a !important; }',
      '.m-login.m-login--1 h1,',
      '.m-login.m-login--1 h2,',
      '.m-login.m-login--1 h3,',
      '.m-login.m-login--1 h4,',
      '.m-login.m-login--1 h5,',
      '.m-login.m-login--1 .m-login__title,',
      '.m-login.m-login--1 .m-login__desc,',
      '.m-login.m-login--1 .m-form__help,',
      '.m-login.m-login--1 .m-checkbox { color: #dcdcdc !important; }',
      '.m-login.m-login--1 .form-control {',
      '  background-color: #1a1a1a !important;',
      '  border-color: #3a3a3a !important;',
      '  color: #ffffff !important; }',
      '.m-login.m-login--1 .form-control:focus {',
      '  background-color: #1a1a1a !important;',
      '  border-color: #5867dd !important;',
      '  box-shadow: none !important; }',
      '.m-login.m-login--1 .form-control::placeholder {',
      '  color: #8a8a8a !important; }',
      '.m-login.m-login--1 .form-control:-webkit-autofill {',
      '  -webkit-box-shadow: 0 0 0 1000px #1a1a1a inset !important;',
      '  -webkit-text-fill-color: #ffffff !important; }',
      '.m-login.m-login--1 .input-group-addon {',
      '  background-color: #1a1a1a !important;',
      '  border-color: #3a3a3a !important;',
      '  color: #b9c2c9 !important; }',
      '.m-login.m-login--1 .m-link { color: #8c9eff !important; }',
      '.m-login.m-login--1 .m-login__content {',
      '  box-shadow: inset 0 0 0 2000px rgba(0, 0, 0, 0.55) !important; }',
      '.m-login.m-login--1 .cf-turnstile,',
      '.m-login.m-login--1 .g-recaptcha {',
      '  filter: invert(1) hue-rotate(180deg) !important; }'
    ].join('\\n');

    var style = document.createElement('style');
    style.textContent = css;
    root.appendChild(style);
  }

  function syncHeaderOffset(tries) {
    try {
      var header = document.querySelector('header.m-header');
      var body = document.querySelector('.m-body');
      if (!header || !body) {
        if ((tries || 0) < 300) {
          setTimeout(function () { syncHeaderOffset((tries || 0) + 1); }, 50);
        }
        return;
      }
      var rows = header.querySelectorAll('.m-brand, .m-header-head');
      var bottom = 0;
      for (var i = 0; i < rows.length; i++) {
        var edge = rows[i].getBoundingClientRect().bottom;
        if (edge > bottom) bottom = edge;
      }
      if (bottom > 0) body.style.paddingTop = Math.ceil(bottom) + 'px';
    } catch (e) {
    }
  }

  boot();
  syncHeaderOffset();
  window.addEventListener('load', function () { syncHeaderOffset(); });
  window.addEventListener('resize', function () { syncHeaderOffset(); });
  setTimeout(syncHeaderOffset, 2500);
})();
''';

  static const String _autofillScript = '''
(function () {
  if (window.__fcAutofillApplied) return;
  window.__fcAutofillApplied = true;

  function unmask(el) {
    try {
      if (!el || !el.inputmask || !el.inputmask.remove) return;
      el.inputmask.remove();
      if (!/[A-Za-z0-9]/.test(el.value || '')) el.value = '';
    } catch (e) {
    }
  }

  function label() {
    try {
      var inputs = document.querySelectorAll('input');
      var lastText = null;
      for (var i = 0; i < inputs.length; i++) {
        var el = inputs[i];
        var type = (el.getAttribute('type') || 'text').toLowerCase();
        if (type === 'password') {
          if (!lastText) continue;
          var existing =
            (lastText.getAttribute('autocomplete') || '').toLowerCase();
          if (existing && existing !== 'off' && existing !== 'on') continue;
          lastText.setAttribute('autocomplete', 'username');
          unmask(lastText);
        } else if (
          type === 'text' ||
          type === 'tel' ||
          type === 'number' ||
          type === 'email'
        ) {
          lastText = el;
        }
      }
    } catch (e) {
    }
  }

  try {
    document.addEventListener('focusin', function (ev) {
      unmask(ev.target);
    }, true);
  } catch (e) {
  }

  function boot() {
    var root = document.documentElement;
    if (!root) { setTimeout(boot, 10); return; }

    label();
    setTimeout(label, 300);
    setTimeout(label, 1200);
    try {
      new MutationObserver(function () { label(); }).observe(root, {
        childList: true,
        subtree: true,
      });
    } catch (e) {
    }
  }

  boot();
})();
''';

  static final RegExp _downloadRe = RegExp(
    r'\\.(pdf|xlsx?|docx?|csv|zip)$',
    caseSensitive: false,
  );

  static final String _windowOpenScript = '''
(function () {
  var originalOpen = window.open;
  window.open = function (url) {
    if (!url) { return originalOpen.apply(window, arguments); }
    window.location.href = url;
    return { focus: function () {}, close: function () {} };
  };
})();
''';

  static const String _hideMaskScript = '''
(function () {
  var masks = document.querySelectorAll('[id^=\"overlay\"], .loader-box');
  for (var i = 0; i < masks.length; i++) {
    masks[i].style.setProperty('display', 'none', 'important');
  }
})();
''';

  InAppWebViewController? _controller;
  late final PullToRefreshController _pullToRefresh;

  String _url = FlexSessionService.baseUrl;

  bool _loading = true;
  bool _canGoBack = false;

  bool _loaded = false;

  bool _failed = false;

  bool get _onLoginPage {
    final path = Uri.tryParse(_url)?.path.toLowerCase() ?? '';
    return path == '/login' || path.startsWith('/login/');
  }

  bool get _onMarksPage => _url.toLowerCase().contains('studentmarks');

  @override
  void initState() {
    super.initState();
    FlexSessionService.instance.restore();
    _pullToRefresh = PullToRefreshController(
      onRefresh: () => _controller?.reload(),
    );
  }

  // ================= BUILD =================

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 6, 0),
          child: Row(
            children: [
              const Expanded(child: Text('Flex', style: AppTextStyles.title)),
              if (_canGoBack)
                _action(
                  tooltip: 'Back',
                  icon: Icons.arrow_back_rounded,
                  onTap: () => _controller?.goBack(),
                ),
              _action(
                tooltip: 'Open in browser',
                icon: Icons.open_in_new_rounded,
                onTap: _openInBrowser,
              ),
              _action(
                tooltip: 'Refresh',
                icon: Icons.refresh_rounded,
                onTap: () => _controller?.reload(),
              ),
              if (_onMarksPage) _analyticsAction(),
              if (!_onLoginPage)
                _action(
                  tooltip: 'Sign out',
                  icon: Icons.logout_rounded,
                  color: AppColors.cardOrange,
                  onTap: _confirmSignOut,
                ),
            ],
          ),
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: LinearProgressIndicator(
              color: AppColors.cardOrange,
              backgroundColor: AppColors.navBar,
              minHeight: 3,
            ),
          )
        else
          const SizedBox(height: 11),
        const SizedBox(height: 4),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _action({
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
    Color color = Colors.white,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, color: color),
      visualDensity: VisualDensity.compact,
    );
  }

  Future<void> _showAnalytics() async {
    final List<FlexCourseMarks> courses =
        await FlexMarksEnhancerService.instance.loadCachedMarks();
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.navBar,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.6,
          child: courses.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Open the Marks page once to load your analytics.',
                      style: AppTextStyles.body.copyWith(color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.1), width: 1)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Semester GPA',
                            style: AppTextStyles.body.copyWith(color: Colors.white.withValues(alpha: 0.8)),
                          ),
                          FutureBuilder<double?>(
                            future: FlexMarksEnhancerService.instance.computeSemesterGpa(),
                            builder: (context, snapshot) {
                              if (snapshot.connectionState == ConnectionState.waiting) {
                                return const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2));
                              }
                              final gpa = snapshot.data;
                              if (gpa == null) {
                                // Credits are cached the first time the
                                // portal's Transcript page is opened — say so
                                // instead of leaving a bare dash.
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text('-', style: AppTextStyles.body.copyWith(color: Colors.white.withValues(alpha: 0.5))),
                                    Text(
                                      'Open Flex → Transcript once to unlock',
                                      style: AppTextStyles.bodySmall.copyWith(color: Colors.white.withValues(alpha: 0.5), fontSize: 11),
                                    ),
                                  ],
                                );
                              }
                              return Text(
                                gpa.toStringAsFixed(2),
                                style: AppTextStyles.title.copyWith(color: AppColors.cardOrange),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.only(top: 8, bottom: 16),
                        itemCount: courses.length,
                        itemBuilder: (_, index) => FlexMarksAnalyticsWidget(marks: courses[index]),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _analyticsAction() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message: 'Marks analytics',
        child: Material(
          color: AppColors.cardOrange.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: _showAnalytics,
            child: const Padding(
              padding: EdgeInsets.all(10),
              child: Icon(
                Icons.bar_chart_rounded,
                size: 20,
                color: AppColors.cardOrange,
              ),
            ),
          ),
        ),
      ),
    );
  }
  Widget _buildBody() {
    return Stack(
      children: [
        InAppWebView(
          initialUrlRequest: URLRequest(
            url: WebUri(FlexSessionService.baseUrl),
          ),
          initialSettings: InAppWebViewSettings(
            useShouldOverrideUrlLoading: true,
            useOnDownloadStart: true,
          ),
          initialUserScripts: UnmodifiableListView<UserScript>([
            UserScript(
              source: _darkModeScript,
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              forMainFrameOnly: true,
            ),
            UserScript(
              source: _autofillScript,
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              forMainFrameOnly: false,
            ),
            UserScript(
              source: _windowOpenScript,
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              forMainFrameOnly: true,
            ),
          ]),
          pullToRefreshController: _pullToRefresh,
          onWebViewCreated: (controller) async {
            _controller = controller;
            await FlexMarksEnhancerService.instance.registerJavaScriptHandler(controller);
          },
          onLoadStart: (controller, url) {
            if (mounted) {
              setState(() {
                _loading = true;
                if (url != null) _url = url.toString();
              });
            }
          },
          onLoadStop: (controller, url) async {
            if (mounted) {
              setState(() {
                _loading = false;
                _loaded = true;
                _failed = false;
                if (url != null) _url = url.toString();
              });
            }
            await _updateBackAvailability(controller);
            await FlexSessionService.instance.adoptFromWebView(controller);
            await FlexMarksEnhancerService.instance.injectScript(controller);
          },
          onReceivedError: (controller, url, error) {
            if (_loaded || _failed) return;
            if (mounted) {
              setState(() {
                _failed = true;
                _loading = false;
              });
            }
          },
          onUpdateVisitedHistory: (controller, url, isReload) async {
            await _updateBackAvailability(controller);
          },
          shouldOverrideUrlLoading: (controller, navigationAction) async {
            final url = navigationAction.request.url;
            if (url == null) return NavigationActionPolicy.ALLOW;

            final scheme = url.scheme.toLowerCase();
            if (scheme == 'http' || scheme == 'https') {
              if (_downloadRe.hasMatch(url.path)) {
                unawaited(_saveDownload(url));
                return NavigationActionPolicy.CANCEL;
              }
              return NavigationActionPolicy.ALLOW;
            }

            await _launchExternally(url);
            return NavigationActionPolicy.CANCEL;
          },
          onDownloadStarting: (controller, downloadStartRequest) async {
            unawaited(
              _saveDownload(
                downloadStartRequest.url,
                suggestedName: downloadStartRequest.suggestedFilename,
                mimeType: downloadStartRequest.mimeType,
              ),
            );
            return null;
          },
        ),
        if (_failed)
          Positioned.fill(
            child: Container(
              color: AppColors.background,
              child: _buildMessage(
                icon: Icons.cloud_off_rounded,
                message: 'Could not reach Flex.\nCheck your connection.',
                actionLabel: 'Retry',
                onAction: () {
                  setState(() {
                    _failed = false;
                    _loading = true;
                  });
                  _controller?.reload();
                },
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _updateBackAvailability(
    InAppWebViewController controller,
  ) async {
    var canGoBack = false;
    try {
      canGoBack = await controller.canGoBack();
    } catch (_) {
    }
    if (!mounted || canGoBack == _canGoBack) return;
    setState(() => _canGoBack = canGoBack);
  }

  Future<void> _openInBrowser() async {
    await _launchExternally(Uri.parse(_url));
  }

  Future<void> _launchExternally(Uri url) async {
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('Could not open $url: $e');
    }
  }


  Future<void> _saveDownload(
    Uri url, {
    String? suggestedName,
    String? mimeType,
  }) async {
    if (mounted) setState(() => _loading = false);

    try {
      await _controller?.evaluateJavascript(source: _hideMaskScript);
    } catch (e) {
      debugPrint('Flex mask hide failed: $e');
    }

    final result = await FlexSessionService.instance.fetchBytes(url);
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final bytes = result.bytes;
    if (bytes == null) {
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: AppColors.navBar,
          content: Text(
            result.loginRedirect
                ? 'Your Flex session has expired. '
                      'Sign in again, then retry the download.'
                : 'Could not download the file. '
                      'Check your connection and try again.',
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
      return;
    }

    final name = _downloadFileName(url, suggestedName, mimeType);
    try {
      final saved = await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(data: bytes, fileName: name),
      );
      if (saved != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppColors.cardOrange,
            content: Text(
              'Saved $name',
              style: const TextStyle(color: Colors.black87),
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('Flex save failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: AppColors.navBar,
            content: Text(
              'Could not save the file.',
              style: TextStyle(color: Colors.white),
            ),
          ),
        );
      }
    }
  }

  static String _downloadFileName(
    Uri url,
    String? suggested,
    String? mimeType,
  ) {
    var name = (suggested ?? '').trim();
    if (name.isEmpty) {
      final segment = url.pathSegments.isNotEmpty ? url.pathSegments.last : '';
      name = segment.trim();
    }
    if (name.isEmpty || !name.contains('.')) {
      final ext = switch (mimeType?.toLowerCase() ?? '') {
        'application/pdf' => 'pdf',
        'text/csv' => 'csv',
        var m when m.contains('wordprocessingml') => 'docx',
        var m when m.contains('msword') => 'doc',
        var m when m.contains('spreadsheetml') => 'xlsx',
        var m when m.contains('ms-excel') => 'xls',
        var m when m.contains('zip') => 'zip',
        _ => 'pdf',
      };
      name = name.isEmpty ? 'flex-download.$ext' : '$name.$ext';
    }
    return name;
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.navBar,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text(
          'Sign out of Flex?',
          style: TextStyle(color: Colors.white, fontSize: 17),
        ),
        content: const Text(
          "You'll need your university credentials to sign back in.",
          style: TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white70),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.cardOrange,
              foregroundColor: AppColors.textDark,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );

    if (confirmed == true) await _signOut();
  }

  Future<void> _signOut() async {
    final controller = _controller;
    if (mounted) setState(() => _loading = true);

    await FlexSessionService.instance.signOut();

    if (controller == null) return;
    try {
      await InAppWebViewController.clearAllCache(includeDiskFiles: true);
      await controller.evaluateJavascript(
        source:
            "try { localStorage.clear(); sessionStorage.clear(); } "
            'catch (e) {}',
      );
    } catch (e) {
      debugPrint('Flex sign-out cleanup failed: $e');
    }
    await controller.loadUrl(
      urlRequest: URLRequest(url: WebUri(FlexSessionService.baseUrl)),
    );
  }

  Widget _buildMessage({
    required IconData icon,
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.navBar,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: AppColors.cardOrange),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: onAction,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.cardOrange,
                  foregroundColor: AppColors.textDark,
                ),
                child: Text(actionLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}