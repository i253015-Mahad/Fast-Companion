# FAST-Companion — AI Coding Instructions

## Project
- Flutter application written in Dart.
- Package name: fast_companion.
- Dart SDK constraint: ^3.12.1.
- Main entry point: `lib/main.dart`.
- Backend services include Firebase Core, Firebase Authentication, and Firebase Realtime Database.
- Local preferences use SharedPreferences.

## Project Structure
- `lib/Screens/` — application screens.
- `lib/models/` — data models.
- `lib/services/` — database, authentication, timetable, attendance, notifications, and other services.
- `lib/widgets/` — reusable UI components.
- `lib/theme/` — colors and text styles.
- `lib/utils/` — utility code.
- `assets/images/` — application images and branding.

## Important Rules
1. Inspect relevant existing files before making changes.
2. Reuse existing models, services, widgets, and themes wherever possible.
3. Do not create duplicate screens, services, or models.
4. Preserve existing functionality unless explicitly asked to change it.
5. Avoid unnecessary dependencies and package upgrades.
6. Keep UI consistent with the existing application design.
7. Keep Firebase operations in the appropriate service layer.
8. Never hardcode API keys, passwords, tokens, or other secrets.
9. Do not modify Firebase configuration or database structure without permission.
10. Make focused changes instead of rewriting entire files.
11. Explain important changes briefly.
12. After completing code changes, run `flutter analyze` and relevant tests when possible.
13. Fix errors introduced by your changes before declaring the task complete.
14. Never claim tests passed unless they were actually executed successfully.
15. Do not modify unrelated files just to fix pre-existing warnings.
16. Never run `flutter build` or `adb install` — building and installing the APK is the user's job. After code changes, update `SESSION_NOTES.md` and tell the user to build and install.
17. Never run `git commit`, `git push`, or any other git command that changes repository state — committing is the user's job.

## Flutter Commands
- Check errors: `flutter analyze`
- Run tests: `flutter test`
- Get dependencies: `flutter pub get`

After making changes, run relevant checks when possible and report any remaining errors.

## Token Efficiency
- Track which files have already been inspected during the current task; do not reread unchanged files without a reason.
- Before requesting more context, check whether the existing conversation already contains the required information.
- Prefer targeted searches over reading entire files.
- Read `PROJECT_MAP.md` before exploring the project structure.
- Read only files relevant to the requested task.
- Avoid repeatedly reading unchanged files.
- Do not inspect generated folders such as `build/` or `.dart_tool/`.
- Do not dump entire project files unless necessary.
- Prefer small, targeted edits.
- Ask before making major architectural changes.
- Use `SESSION_NOTES.md` to preserve important project progress between sessions.
- Update it after completing a significant task.
- Record completed work, files changed, outstanding tasks, and known issues.
- Keep notes concise; remove outdated information.
- Read it when continuing a previous task, rather than reconstructing progress from the entire conversation.
- **Agent Handoff:** Before finishing a task, update `SESSION_NOTES.md` with the current task, changes made, unfinished work, known issues, and the exact next step. Keep it concise and updated so another AI coding agent can continue without needing the previous conversation.
- **Minimal Context:** Read only the files directly relevant to the current task. Avoid exploring the entire project.
- **No Generated Files:** Never inspect build/, .dart_tool/, .git/, or other generated/cache directories unless explicitly necessary.
- **Targeted Reads:** Use search to locate relevant classes and functions before opening large files. Read only the necessary sections.
- **Concise Communication:** Keep progress updates and final summaries brief. Avoid repeating information already provided.
- **Avoid Rework:** Reuse existing analysis and project documentation. Do not reread unchanged files without a reason.
- **Focused Tool Use:** Avoid unnecessary terminal commands, repeated checks, and redundant tool calls.
- **Task Boundaries:** Do not perform unrelated improvements, refactoring, or cleanup while completing a task.
