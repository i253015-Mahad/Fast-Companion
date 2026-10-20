// lib/models/note.dart

class TodoItem {
  String text;
  bool isDone;
  DateTime? dueDateTime;
  Duration? remainingDuration;

  TodoItem({
    required this.text,
    this.isDone = false,
    this.dueDateTime,
    this.remainingDuration,
  });

  Map<String, dynamic> toJson() {
    return {
      'text': text,
      'isDone': isDone,
      'dueDateTime': dueDateTime?.toIso8601String(),
      'remainingDurationMs': remainingDuration?.inMilliseconds,
    };
  }

  factory TodoItem.fromJson(Map<String, dynamic> json) {
    return TodoItem(
      text: json['text'] ?? '',
      isDone: json['isDone'] ?? false,
      dueDateTime: json['dueDateTime'] != null
          ? DateTime.tryParse(json['dueDateTime'])
          : null,
      remainingDuration: json['remainingDurationMs'] != null
          ? Duration(milliseconds: json['remainingDurationMs'])
          : null,
    );
  }
}

class CounterItem {
  String label;
  int count;

  CounterItem({required this.label, this.count = 0});

  Map<String, dynamic> toJson() {
    return {'label': label, 'count': count};
  }

  factory CounterItem.fromJson(Map<String, dynamic> json) {
    return CounterItem(label: json['label'] ?? '', count: json['count'] ?? 0);
  }
}

class Note {
  String id;
  String title;
  String body;

  String type;

  bool isStarred;

  List<TodoItem> todoList;

  List<CounterItem> counterList;

  Note({
    required this.id,
    required this.title,
    required this.body,
    this.type = 'text',
    this.isStarred = false,
    List<TodoItem>? todoList,
    List<CounterItem>? counterList,
  }) : todoList = todoList ?? [],
       counterList = counterList ?? [];

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'body': body,
      'type': type,
      'isStarred': isStarred,
      'todoList': todoList.map((e) => e.toJson()).toList(),
      'counterList': counterList.map((e) => e.toJson()).toList(),
    };
  }

  factory Note.fromJson(Map<String, dynamic> json) {
    return Note(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      body: json['body'] ?? '',
      type: json['type'] ?? 'text',
      isStarred: json['isStarred'] ?? false,
      todoList: json['todoList'] != null
          ? (json['todoList'] as List)
                .map((e) => TodoItem.fromJson(Map<String, dynamic>.from(e)))
                .toList()
          : [],
      counterList: json['counterList'] != null
          ? (json['counterList'] as List)
                .map((e) => CounterItem.fromJson(Map<String, dynamic>.from(e)))
                .toList()
          : [],
    );
  }

}
