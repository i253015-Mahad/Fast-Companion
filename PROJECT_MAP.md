# FAST-Companion — Project Map

## Entry Points
- `lib/main.dart` — main Flutter application entry point.
- `lib/firebase_options.dart` — Firebase configuration.
- `lib/app_signals.dart` — application signals.
- `lib/widget_background_main.dart` — home widget background entry point.
- `lib/widget_config_main.dart` — home widget configuration entry point.

## Screens
- `home_screen.dart` — home screen.
- `flex_screen.dart` — FLEX portal integration.
- `timetable_screen.dart` — timetable.
- `rooms_screen.dart` — room occupancy.
- `teachers_screen.dart` — faculty directory.
- `wayfinding_screen.dart` — campus navigation.
- `todo_screen.dart` — to-do list.
- `timed_task_screen.dart` — timed tasks.
- `edit_note_screen.dart` — note editing.
- `counter_screen.dart` — counter screen.

## Models
- `faculty_member.dart`
- `flex_marks_model.dart`
- `note.dart`
- `room_occupancy.dart`
- `timetable_entry.dart`

## Services
- `database_service.dart`
- `multi_account_auth_service.dart`
- `local_storage_service.dart`
- `flex_session_service.dart`
- `flex_attendance_service.dart`
- `flex_marks_enhancer_service.dart`
- `faculty_directory_service.dart`
- `timetable_service.dart`
- `csv_reader.dart`
- `home_widget_service.dart`
- `reminder_notification_service.dart`
- `note_history.dart`
- `note_preview.dart`
- `profile_photo_cache.dart`

## Shared UI
- `widgets/` — reusable components.
- `theme/app_colors.dart` — app colors.
- `theme/app_text_styles.dart` — text styles.
- `utils/color_extensions.dart` — color utilities.

## Navigation Rules
- Trace navigation from `main.dart` and `home_screen.dart` before changing routes.
- Check existing screen and service dependencies before editing a feature.
- Do not assume filenames fully describe behavior; inspect the relevant implementation.

## Important
- This map is a navigation aid, not a substitute for reading relevant source code.
- Update it when files or major features are added, removed, or renamed.
