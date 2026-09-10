class KeyValue {
  String text;
  final Map<String, String> paramTypes;

  KeyValue({required this.text, required this.paramTypes});
}

typedef KeyMap = Map<String, KeyValue>;
