import 'dart:async';

import 'ui_bridge.dart' show HtgcUi;

final saveCompleted = Completer<void>();
HtgcUi? previousPage;
String? lastInput;
int inputEvents = 0;
int saveCalls = 0;

void editMemo(String value, HtgcUi ui) {
  if (ui.getValue('memo') != value) throw StateError('Stale input value');
  lastInput = value;
  inputEvents++;
}

Future<void> saveMemo(HtgcUi ui) async {
  saveCalls++;
  previousPage = ui;
  final memo = ui.getValue('memo');
  ui.setDisabled('save', true);
  ui.setDisabled('memo', true);
  ui.setVisible('status', true);
  ui.setText('status', '保存中');
  await saveCompleted.future;
  ui.setValue('memo', '');
  ui.setText('message', '$memoを保存');
  await ui.showModal('saved');
  ui.setDisabled('save', false);
  ui.setDisabled('memo', false);
}

void closeMemo(HtgcUi ui) {
  ui.closeModal('saved');
}
